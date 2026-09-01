<#
.SYNOPSIS
    3dxGC control panel - WPF desktop app with system tray.

.DESCRIPTION
    Unified front end for 3DXModKit and the 3DXChat Debug Toolkit.

    Design notes:

      * The governor runs in a SEPARATE PowerShell process, not in this one. A
        long-running loop on the UI thread would freeze the window. A child
        process starts and stops cleanly, and the GUI tails its log file.

      * Live telemetry is read directly on a DispatcherTimer. The P/Invoke
        calls cost microseconds, so this is safe on the UI thread.

      * Toolkit scripts launch in their own console windows rather than being
        captured, because several are interactive or long-running.

      * ASCII only. Windows PowerShell 5.1 reads BOM-less files as ANSI, so
        non-ASCII glyphs arrive as mojibake. Status dots are XAML Ellipses.

.EXAMPLE
    .\Start-Gui.ps1
    .\Start-Gui.ps1 -Minimized
#>
[CmdletBinding()]
param(
    [switch]$Minimized,
    [string]$ToolkitPath = "$env:USERPROFILE\Documents\3DXChat-Debug-Toolkit",
    # Set by Apply-Update.ps1 on the relaunch after a self-update, so this
    # instance can show a one-time "updated to vX" confirmation.
    [string]$JustUpdated = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase,
                       System.Windows.Forms, System.Drawing

$ModKitRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ModKitRoot '3DXModKit.psm1') -Force

$M = [ThreeDX.ModKit.Native.MemOps]
$BrushConv = New-Object Windows.Media.BrushConverter

function New-Brush { param([string]$Hex) return $BrushConv.ConvertFromString($Hex) }

$Colours = @{
    Dim   = '#FF8B93A3'
    Text  = '#FFE6E9EF'
    Good  = '#FF4ADE80'
    Warn  = '#FFFBBF24'
    Bad   = '#FFF87171'
    Blue  = '#FF4FA3FF'
}

# ---------------------------------------------------------------------------
# Load window
# ---------------------------------------------------------------------------

[xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

$UI = @{}
$xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($n) { $UI[$n] = $win.FindName($n) }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$State = [pscustomobject]@{
    GovernorProcess   = $null
    LogPath           = $null
    LogPosition       = 0
    History           = New-Object System.Collections.Generic.List[psobject]
    Reclaimed         = 0.0
    TrimCount         = 0
    LastGameWS        = 0.0
    ToolkitPath       = $ToolkitPath
    UpdateCheckJob    = $null
    UpdateDownloadJob = $null
    LastUpdateCheckAt = [datetime]::MinValue
    UpdateApplying    = $false
}

function Set-Status {
    param([string]$Message, [string]$Colour = '#FF8B93A3')
    $UI.TxtStatus.Text = $Message
    $UI.TxtStatus.Foreground = New-Brush $Colour
}

# ---------------------------------------------------------------------------
# Settings (last-used profile, auto-update opt-out) and "start with Windows"
# ---------------------------------------------------------------------------

$Script:GuiSettingsPath = Join-Path $ModKitRoot 'config\gui-settings.json'
$Script:AutoStartRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$Script:AutoStartValue  = '3dxGC'

function Get-GuiSettings {
    $defaults = @{
        LastProfile              = 'default'
        AutoUpdateEnabled        = $true
        LastUpdateAppliedVersion = ''
        LastUpdateAppliedAt      = [datetime]::MinValue.ToString('o')
    }
    if (-not (Test-Path -LiteralPath $Script:GuiSettingsPath)) { return $defaults }
    try {
        $raw = Get-Content -LiteralPath $Script:GuiSettingsPath -Raw
        $j = $raw | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'LastProfile' -and $j.LastProfile) { $defaults.LastProfile = [string]$j.LastProfile }
        if ($j.PSObject.Properties.Name -contains 'AutoUpdateEnabled') { $defaults.AutoUpdateEnabled = [bool]$j.AutoUpdateEnabled }
        if ($j.PSObject.Properties.Name -contains 'LastUpdateAppliedVersion') { $defaults.LastUpdateAppliedVersion = [string]$j.LastUpdateAppliedVersion }
        if ($j.PSObject.Properties.Name -contains 'LastUpdateAppliedAt') { $defaults.LastUpdateAppliedAt = [string]$j.LastUpdateAppliedAt }
    } catch { }
    return $defaults
}

function Save-GuiSettings {
    param([hashtable]$Settings)
    try {
        $dir = Split-Path -Parent $Script:GuiSettingsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $Script:GuiSettingsPath -Encoding UTF8
    } catch { }
}

function Test-ModKitAutoStart {
    $v = Get-ItemProperty -Path $Script:AutoStartRunKey -Name $Script:AutoStartValue -ErrorAction SilentlyContinue
    return ($null -ne $v)
}

function Enable-ModKitAutoStart {
    $launcher = Join-Path $ModKitRoot '3dxGC.bat'
    New-ItemProperty -Path $Script:AutoStartRunKey -Name $Script:AutoStartValue `
        -Value ('"' + $launcher + '" -Minimized') -PropertyType String -Force | Out-Null
}

function Disable-ModKitAutoStart {
    Remove-ItemProperty -Path $Script:AutoStartRunKey -Name $Script:AutoStartValue -ErrorAction SilentlyContinue
}

function Add-LogLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    $colour = 'Gainsboro'
    if     ($Line -match '\[Error\]') { $colour = 'Salmon' }
    elseif ($Line -match '\[Warn\]')  { $colour = 'Orange' }
    elseif ($Line -match 'trim \[')   { $colour = 'LightGreen' }

    $item = New-Object Windows.Controls.ListBoxItem
    $item.Content = $Line
    $item.Foreground = $colour
    [void]$UI.LstLog.Items.Add($item)

    while ($UI.LstLog.Items.Count -gt 400) { $UI.LstLog.Items.RemoveAt(0) }
    $UI.LstLog.ScrollIntoView($item)
}

# ---------------------------------------------------------------------------
# Graph
# ---------------------------------------------------------------------------

function Add-Polyline {
    param($Canvas, $Values, [double]$Max, [string]$Colour, [double]$W, [double]$H)

    if ($Values.Count -lt 2) { return }

    $poly = New-Object Windows.Shapes.Polyline
    $poly.Stroke = New-Brush $Colour
    $poly.StrokeThickness = 1.8

    $points = New-Object Windows.Media.PointCollection
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $x = ($i / [double]([math]::Max(1, $Values.Count - 1))) * $W
        $y = $H - (([double]$Values[$i] / $Max) * $H)
        if ($y -lt 0)  { $y = 0 }
        if ($y -gt $H) { $y = $H }
        $points.Add((New-Object Windows.Point($x, $y)))
    }
    $poly.Points = $points
    [void]$Canvas.Children.Add($poly)
}

function Update-Graph {
    $canvas = $UI.GraphCanvas
    $canvas.Children.Clear()

    $w = $canvas.ActualWidth
    $h = $canvas.ActualHeight
    if ($w -lt 10 -or $h -lt 10) { return }
    if ($State.History.Count -lt 2) { return }

    $pts = @($State.History)

    # Scale working set to the largest sample, with a floor so an idle game
    # does not render as a full-height line.
    $maxWS = ($pts | ForEach-Object { $_.GameWS } | Measure-Object -Maximum).Maximum
    if ($maxWS -lt 100) { $maxWS = 100 }

    foreach ($frac in @(0.25, 0.5, 0.75)) {
        $line = New-Object Windows.Shapes.Line
        $line.X1 = 0; $line.X2 = $w
        $line.Y1 = $h * $frac; $line.Y2 = $h * $frac
        $line.Stroke = New-Brush '#FF2E333D'
        $line.StrokeThickness = 1
        [void]$canvas.Children.Add($line)
    }

    Add-Polyline -Canvas $canvas -Values @($pts | ForEach-Object { $_.GameWS }) `
                 -Max $maxWS -Colour $Colours.Blue -W $w -H $h
    Add-Polyline -Canvas $canvas -Values @($pts | ForEach-Object { $_.SysFree }) `
                 -Max 100 -Colour $Colours.Good -W $w -H $h
}

# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

function Read-GovernorLog {
    if (-not $State.LogPath) { return }
    if (-not (Test-Path -LiteralPath $State.LogPath)) { return }
    try {
        $fs = [IO.File]::Open($State.LogPath, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $State.LogPosition) { $State.LogPosition = 0 }
            [void]$fs.Seek($State.LogPosition, 'Begin')
            $sr = New-Object IO.StreamReader($fs)
            while (-not $sr.EndOfStream) { Add-LogLine $sr.ReadLine() }
            $State.LogPosition = $fs.Position
        } finally { $fs.Dispose() }
    } catch { }
}

function Update-Telemetry {
    $sys = $M::GetSystemMemory()
    $game = @(Get-Process -Name '3DXChat' -ErrorAction SilentlyContinue |
              Sort-Object WorkingSet64 -Descending)

    $UI.TxtSysFree.Text = "$($sys.AvailPhysGB) GB"
    $UI.TxtSysPct.Text  = "$($sys.AvailPercent)% of $($sys.TotalPhysGB) GB"

    $sysColour = $Colours.Good
    if     ($sys.AvailPercent -lt 15) { $sysColour = $Colours.Bad }
    elseif ($sys.AvailPercent -lt 30) { $sysColour = $Colours.Warn }
    $UI.TxtSysFree.Foreground = New-Brush $sysColour

    $gameWS = 0.0
    if ($game.Count -gt 0) {
        $mem = $M::GetProcessMemory($game[0].Id)
        if ($mem) {
            $gameWS = $mem.WorkingSetMB
            $UI.TxtGameWS.Text   = "$($mem.WorkingSetMB) MB"
            $UI.TxtGamePeak.Text = "peak $($mem.PeakWorkingSetMB) MB"
            $UI.TxtGamePriv.Text = "$($mem.PrivateMB) MB"

            # A drop over 50 MB between samples is a trim landing.
            $drop = $State.LastGameWS - $gameWS
            if ($State.LastGameWS -gt 0 -and $drop -gt 50) {
                $State.Reclaimed = $State.Reclaimed + $drop
                $State.TrimCount = $State.TrimCount + 1
                $UI.TxtReclaimed.Text = "$([math]::Round($State.Reclaimed,0)) MB"
                $UI.TxtTrimCount.Text = "$($State.TrimCount) trims"
            }
            $State.LastGameWS = $gameWS
        }
        $UI.TxtGameState.Text = "game running (pid $($game[0].Id))"
        $UI.TxtGameState.Foreground = New-Brush $Colours.Good
        $UI.DotGame.Fill = New-Brush $Colours.Good
    } else {
        $UI.TxtGameWS.Text = '--'
        $UI.TxtGamePeak.Text = '--'
        $UI.TxtGamePriv.Text = '--'
        $UI.TxtGameState.Text = 'game not running'
        $UI.TxtGameState.Foreground = New-Brush $Colours.Dim
        $UI.DotGame.Fill = New-Brush $Colours.Dim
        $State.LastGameWS = 0
    }

    $pipeUp = Test-Path '\\.\pipe\3dxmodkit-runtime'
    if ($pipeUp) {
        $UI.TxtRuntimeState.Text = 'connected'
        $UI.TxtRuntimeState.Foreground = New-Brush $Colours.Good
    } else {
        $UI.TxtRuntimeState.Text = 'not present'
        $UI.TxtRuntimeState.Foreground = New-Brush $Colours.Dim
    }

    $State.History.Add([pscustomobject]@{ GameWS = $gameWS; SysFree = $sys.AvailPercent })
    while ($State.History.Count -gt 120) { $State.History.RemoveAt(0) }
    Update-Graph

    if ($State.GovernorProcess) {
        if ($State.GovernorProcess.HasExited) {
            $State.GovernorProcess = $null
            $UI.BtnGovernor.Content = 'Start'
            $UI.TxtGovState.Text = 'stopped'
            Set-Status 'Governor exited.'
            Update-OnboardingBanner
        } else {
            Read-GovernorLog
        }
    }

    if ((Get-Date) - $State.LastUpdateCheckAt -gt [TimeSpan]::FromHours(6)) {
        Start-UpdateCheck
    }
    Receive-UpdateCheck
    Receive-UpdateDownload
}

# ---------------------------------------------------------------------------
# Onboarding banner - this is the answer to "what do I do now / can I close
# this", shown as plain state rather than something the user has to ask about.
# ---------------------------------------------------------------------------

function Update-OnboardingBanner {
    $running = $false
    if ($State.GovernorProcess -and -not $State.GovernorProcess.HasExited) { $running = $true }

    if ($running) {
        $profileName = $UI.CmbProfile.SelectedItem
        $UI.TxtOnboarding.Text = "3dxGC is protecting your game (profile: $profileName). " +
            "Minimize any time to keep it running from the tray icon - closing this window stops it."
        $UI.BannerOnboarding.Background = New-Brush '#FF15321F'
        $UI.BannerOnboarding.BorderBrush = New-Brush $Colours.Good
        $UI.DotOnboarding.Fill = New-Brush $Colours.Good
    } else {
        $UI.TxtOnboarding.Text = "3dxGC is not currently running. Click Start below, " +
            "or just close and reopen this panel - it starts itself automatically."
        $UI.BannerOnboarding.Background = New-Brush '#FF3A2E12'
        $UI.BannerOnboarding.BorderBrush = New-Brush $Colours.Warn
        $UI.DotOnboarding.Fill = New-Brush $Colours.Warn
    }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-MemOp {
    param([string]$Name, [scriptblock]$Op)

    Set-Status "$Name ..." $Colours.Blue
    $before = $M::GetSystemMemory()
    $result = & $Op
    Start-Sleep -Milliseconds 250
    $after = $M::GetSystemMemory()
    $delta = [math]::Round(($after.AvailPhysBytes - $before.AvailPhysBytes) / 1MB, 1)

    $failed = @(@($result) | Where-Object { -not $_.Success })
    if ($failed.Count -gt 0) {
        $msg = (@($failed | ForEach-Object { $_.Error }) | Select-Object -Unique) -join '; '
        Set-Status "$Name - $msg" $Colours.Warn
        Add-LogLine "[Warn] $Name : $msg"
    } else {
        Set-Status "$Name - freed $delta MB" $Colours.Good
        Add-LogLine "[Info] $Name : freed $delta MB"
    }
    Update-Telemetry
}

function Start-Governor {
    $profileName = $UI.CmbProfile.SelectedItem
    if (-not $profileName) {
        Set-Status 'Pick a profile first.' $Colours.Warn
        return
    }

    $State.LogPath = Join-Path $ModKitRoot ("logs\modkit-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    if (Test-Path -LiteralPath $State.LogPath) {
        $State.LogPosition = (Get-Item -LiteralPath $State.LogPath).Length
    } else {
        $State.LogPosition = 0
    }

    $cli = Join-Path $ModKitRoot 'modkit.ps1'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                     $cli + '" run -ProfileName ' + $profileName
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $ModKitRoot

    try {
        $State.GovernorProcess = [Diagnostics.Process]::Start($psi)
        $UI.BtnGovernor.Content = 'Stop'
        $UI.TxtGovState.Text = "running (pid $($State.GovernorProcess.Id))"
        Set-Status "Governor started on profile '$profileName'." $Colours.Good
        $settings = Get-GuiSettings
        $settings.LastProfile = $profileName
        Save-GuiSettings $settings
        Update-OnboardingBanner
    } catch {
        Set-Status "Could not start governor: $($_.Exception.Message)" $Colours.Bad
    }
}

function Stop-Governor {
    if ($State.GovernorProcess) {
        try {
            if (-not $State.GovernorProcess.HasExited) { $State.GovernorProcess.Kill() }
        } catch { }
    }
    $State.GovernorProcess = $null
    $UI.BtnGovernor.Content = 'Start'
    $UI.TxtGovState.Text = 'stopped'
    Set-Status 'Governor stopped.'
    Update-OnboardingBanner
}

function Invoke-ToolkitScript {
    param([string]$RelativePath, [string[]]$ScriptArgs = @())

    $full = Join-Path $State.ToolkitPath $RelativePath
    if (-not (Test-Path -LiteralPath $full)) {
        Set-Status "Not found: $RelativePath" $Colours.Bad
        return
    }

    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"' + $full + '"'))
    if ($ScriptArgs.Count -gt 0) { $argList += $ScriptArgs }

    Start-Process powershell.exe -ArgumentList $argList
    Set-Status "Launched $RelativePath"
}

function Open-Path {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Start-Process explorer.exe (Resolve-Path -LiteralPath $Path).Path
    } else {
        Set-Status "Not found: $Path" $Colours.Warn
    }
}

function Update-ModList {
    $UI.LstMods.Items.Clear()
    foreach ($m in (Test-ModKitMods -ModsPath (Join-Path $ModKitRoot 'mods'))) {
        $mark = '[ok]'
        $colour = 'Gainsboro'
        if (-not $m.Valid) { $mark = '[!!]'; $colour = 'Salmon' }

        $text = "$mark  $($m.Id)   v$($m.Version)   [$($m.Tier)]"
        if ($m.Errors) { $text = $text + '   - ' + $m.Errors }

        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = $text
        $item.Foreground = $colour
        [void]$UI.LstMods.Items.Add($item)
    }
}

# ---------------------------------------------------------------------------
# Auto-update
#
# Check -> download+verify -> silently restart-and-swap, no click required,
# because the whole point of this redesign is that a user like Alicia never
# has to think about this app at all. Every step is logged to the status bar
# and log pane so it's auditable in hindsight even though nothing interrupts
# her. Off switch for anyone who wants it: set AutoUpdateEnabled: false in
# config\gui-settings.json (no UI toggle - this is a power-user escape
# hatch, not something the target audience should need to find).
#
# Both phases run as background jobs (separate processes) polled from the
# existing telemetry timer tick, so a slow GitHub response never freezes the
# window. Applying an update always exits this process for real and lets
# Apply-Update.ps1 (a separate process) do the file swap once this one is
# actually gone - never overwriting files a running process still has open.
# ---------------------------------------------------------------------------

function Start-UpdateCheck {
    if ($State.UpdateCheckJob -or $State.UpdateDownloadJob -or $State.UpdateApplying) { return }
    $settings = Get-GuiSettings
    if (-not $settings.AutoUpdateEnabled) { return }

    $State.LastUpdateCheckAt = Get-Date
    $modulePath = Join-Path $ModKitRoot '3DXModKit.psm1'
    $State.UpdateCheckJob = Start-Job -ScriptBlock {
        param($ModulePath)
        Import-Module $ModulePath -Force
        Test-ModKitUpdate
    } -ArgumentList $modulePath
}

function Receive-UpdateCheck {
    if (-not $State.UpdateCheckJob) { return }
    if ($State.UpdateCheckJob.State -notin @('Completed', 'Failed', 'Stopped')) { return }

    $result = $null
    try { $result = Receive-Job -Job $State.UpdateCheckJob -ErrorAction SilentlyContinue } catch { }
    Remove-Job -Job $State.UpdateCheckJob -Force -ErrorAction SilentlyContinue
    $State.UpdateCheckJob = $null

    if (-not $result) { return }
    if ($result.Error) {
        Add-LogLine "[Warn] update check: $($result.Error)"
        return
    }
    if ($result.UpdateAvailable) {
        # Guards against a tight relaunch loop if a release's own version
        # string does not actually match its tag (has happened) or any other
        # reason the "is this newer" comparison keeps saying yes right after
        # applying it - LastUpdateCheckAt alone cannot catch this, because it
        # lives in $State and resets to nothing on every restart, including
        # ones the updater itself causes. This lives in config\, which
        # Apply-Update.ps1 never touches, so it survives the swap.
        $settings = Get-GuiSettings
        $alreadyTried = ($settings.LastUpdateAppliedVersion -eq $result.RemoteVersion)
        $recently = $false
        try { $recently = ((Get-Date) - [datetime]$settings.LastUpdateAppliedAt) -lt [TimeSpan]::FromHours(1) } catch { }

        if ($alreadyTried -and $recently) {
            Add-LogLine "[Warn] update to v$($result.RemoteVersion) was already applied recently and still looks newer - skipping to avoid a loop"
            return
        }

        Add-LogLine "[Info] update available: v$($result.RemoteVersion) (currently v$($result.LocalVersion))"
        Start-UpdateDownload -DownloadUrl $result.DownloadUrl -Version $result.RemoteVersion
    }
}

function Start-UpdateDownload {
    param([string]$DownloadUrl, [string]$Version)
    if ($State.UpdateDownloadJob -or $State.UpdateApplying) { return }

    Set-Status "Downloading update v$Version..." $Colours.Blue
    $State.UpdateDownloadJob = Start-Job -ScriptBlock {
        param($Url, $Ver)

        $result = [pscustomobject]@{ Ok = $false; SourceDir = $null; Error = $null; Version = $Ver }
        try {
            $stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('3dxgc-update-' + [guid]::NewGuid().ToString('N'))
            $zipPath = Join-Path ([IO.Path]::GetTempPath()) ('3dxgc-update-' + [guid]::NewGuid().ToString('N') + '.zip')

            Invoke-WebRequest -Uri $Url -OutFile $zipPath -UseBasicParsing -TimeoutSec 60

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stagingRoot)
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

            $sourceDir = Join-Path $stagingRoot '3DXModKit'
            $launcherOk = Test-Path -LiteralPath (Join-Path $sourceDir '3dxGC.bat')
            $guiOk = Test-Path -LiteralPath (Join-Path $sourceDir 'gui\Start-Gui.ps1')

            if (-not ($launcherOk -and $guiOk)) {
                $result.Error = 'downloaded package failed validation (missing expected files)'
                Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
                return $result
            }

            $result.Ok = $true
            $result.SourceDir = $sourceDir
        } catch {
            $result.Error = $_.Exception.Message
        }
        return $result
    } -ArgumentList $DownloadUrl, $Version
}

function Receive-UpdateDownload {
    if (-not $State.UpdateDownloadJob) { return }
    if ($State.UpdateDownloadJob.State -notin @('Completed', 'Failed', 'Stopped')) { return }

    $result = $null
    try { $result = Receive-Job -Job $State.UpdateDownloadJob -ErrorAction SilentlyContinue } catch { }
    Remove-Job -Job $State.UpdateDownloadJob -Force -ErrorAction SilentlyContinue
    $State.UpdateDownloadJob = $null

    if (-not $result -or -not $result.Ok) {
        $msg = if ($result) { $result.Error } else { 'unknown failure' }
        Add-LogLine "[Warn] update download failed: $msg"
        Set-Status "Update download failed: $msg" $Colours.Warn
        return
    }

    Add-LogLine "[Info] update v$($result.Version) downloaded and verified - applying"
    Set-Status "Update v$($result.Version) ready - applying..." $Colours.Good
    Start-SilentUpdateApply -SourceDir $result.SourceDir -Version $result.Version
}

function Start-SilentUpdateApply {
    param([string]$SourceDir, [string]$Version)

    $State.UpdateApplying = $true
    $helper = Join-Path $ModKitRoot 'gui\Apply-Update.ps1'
    $wasMinimized = (-not $win.IsVisible) -or ($win.WindowState -eq 'Minimized')

    # Every path is wrapped in embedded quotes: Start-Process -ArgumentList
    # does not auto-quote array elements, and $ModKitRoot contains a space
    # ("...\Power User\...") on a great many real Windows installs, not just
    # this one - an unquoted path here silently splits into multiple broken
    # tokens and the helper fails parameter binding before it can log anything.
    $argList = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', ('"' + $helper + '"'),
        '-SourceDir', ('"' + $SourceDir + '"'), '-TargetDir', ('"' + $ModKitRoot + '"'),
        '-WaitPid', $PID, '-NewVersion', $Version
    )
    if ($wasMinimized) { $argList += '-Minimized' }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList | Out-Null
    } catch {
        Add-LogLine "[Error] could not launch updater: $($_.Exception.Message)"
        $State.UpdateApplying = $false
        return
    }

    # Recorded before the swap so the loop guard in Receive-UpdateCheck sees
    # it immediately on the relaunched instance's very first check, no matter
    # what that instance's own version string turns out to say.
    $settings = Get-GuiSettings
    $settings.LastUpdateAppliedVersion = $Version
    $settings.LastUpdateAppliedAt = (Get-Date).ToString('o')
    Save-GuiSettings $settings

    # The updater is now waiting on this exact process id - Close() is what
    # lets it safely swap the files once this process is actually gone.
    $win.Close()
}

# ---------------------------------------------------------------------------
# Wire up
# ---------------------------------------------------------------------------

Get-ChildItem (Join-Path $ModKitRoot 'profiles') -Filter *.json | ForEach-Object {
    [void]$UI.CmbProfile.Items.Add($_.BaseName)
}
$guiSettings = Get-GuiSettings
if ($UI.CmbProfile.Items.Contains($guiSettings.LastProfile)) {
    $UI.CmbProfile.SelectedItem = $guiSettings.LastProfile
} elseif ($UI.CmbProfile.Items.Contains('default')) {
    $UI.CmbProfile.SelectedItem = 'default'
} elseif ($UI.CmbProfile.Items.Count -gt 0) {
    $UI.CmbProfile.SelectedIndex = 0
}

$UI.ChkAutoStart.IsChecked = Test-ModKitAutoStart
$UI.ChkAutoStart.Add_Click({
    if ($UI.ChkAutoStart.IsChecked) {
        Enable-ModKitAutoStart
        Set-Status '3dxGC will start automatically with Windows.' $Colours.Good
    } else {
        Disable-ModKitAutoStart
        Set-Status 'Start-with-Windows disabled.'
    }
})

$UI.TxtVersion.Text = "3DXModKit v$(Get-ModKitVersion)"

if ($M::IsElevated()) {
    $UI.TxtElevated.Text = 'elevated'
    $UI.TxtElevated.Foreground = New-Brush $Colours.Good
    $UI.DotElevated.Fill = New-Brush $Colours.Good
} else {
    foreach ($b in @('BtnWorkingSets','BtnSysWS','BtnModified','BtnStandby','BtnLowPrio','BtnEmptyAll')) {
        $UI[$b].ToolTip = 'Requires Administrator. Relaunch the panel elevated to enable.'
    }
}

$cat = Get-ModKitCapabilityCatalog
foreach ($p in $cat.ForbiddenPrefixes) { [void]$UI.LstForbidden.Items.Add($p + '*') }

# memory buttons
$UI.BtnTrimGame.Add_Click({    Invoke-MemOp 'Trim game'                  { $M::TrimProcessesByName('3DXChat') } })
$UI.BtnWorkingSets.Add_Click({ Invoke-MemOp 'Empty working sets'         { $M::EmptyAllWorkingSets() } })
$UI.BtnSysWS.Add_Click({       Invoke-MemOp 'Empty system working set'   { $M::EmptySystemWorkingSet() } })
$UI.BtnModified.Add_Click({    Invoke-MemOp 'Flush modified page list'   { $M::FlushModifiedPageList() } })
$UI.BtnStandby.Add_Click({     Invoke-MemOp 'Purge standby list'         { $M::PurgeStandbyList() } })
$UI.BtnLowPrio.Add_Click({     Invoke-MemOp 'Purge low-priority standby' { $M::PurgeLowPriorityStandby() } })
$UI.BtnEmptyAll.Add_Click({    Invoke-MemOp 'Empty all'                  { $M::EmptyAll() } })

$UI.BtnGovernor.Add_Click({
    $running = $false
    if ($State.GovernorProcess) {
        if (-not $State.GovernorProcess.HasExited) { $running = $true }
    }
    if ($running) { Stop-Governor } else { Start-Governor }
})

$UI.BtnValidate.Add_Click({ Update-ModList; Set-Status 'Revalidated all mods.' $Colours.Good })
$UI.BtnOpenMods.Add_Click({ Open-Path (Join-Path $ModKitRoot 'mods') })

$runtimeHelp = @'
The in-process runtime is a BepInEx 6 (IL2CPP) plugin. It is what actually
releases Unity asset memory. Working-set trimming alone only evicts resident
pages, which fault back in.

Installing it writes into the game directory, which diverges from the
PGP-signed integrity.conf shipped in Game\ and Launcher\.

    cd runtime\bootstrap
    .\Install-BepInEx.ps1 -GamePath "<...>\3DXChat\Game"
    (launch the game once so interop assemblies generate)
    .\Build-Plugin.ps1 -GamePath "<...>\3DXChat\Game"

Every added file is recorded, so Uninstall-BepInEx.ps1 reverts exactly.
'@

$UI.BtnRuntimeDocs.Add_Click({
    [void][Windows.MessageBox]::Show($runtimeHelp, 'In-process runtime', 'OK', 'Information')
})

# toolkit tabs
$localLow = Join-Path $env:LOCALAPPDATA '..\LocalLow\SexGameDevil\3DXChat'

$UI.BtnAnalyzeLog.Add_Click({    Invoke-ToolkitScript 'logs\Analyze-GameLog.ps1' })
$UI.BtnWatchLog.Add_Click({      Invoke-ToolkitScript 'logs\Watch-GameLog.ps1' })
$UI.BtnQuickDiag.Add_Click({     Invoke-ToolkitScript 'Quick-Diagnostic.ps1' })
$UI.BtnWorlds.Add_Click({        Invoke-ToolkitScript 'Diagnose-CommunityWorlds.ps1' })
$UI.BtnOpenPlayerLog.Add_Click({ Open-Path $localLow })

$UI.BtnTestConn.Add_Click({    Invoke-ToolkitScript 'network\Test-Connectivity.ps1' })
$UI.BtnMonitorConn.Add_Click({ Invoke-ToolkitScript 'network\Monitor-Connections.ps1' })
$UI.BtnCapture.Add_Click({     Invoke-ToolkitScript 'network\Capture-Traffic.ps1' })

$UI.BtnHttpCache.Add_Click({ Invoke-ToolkitScript 'cache\Analyze-HTTPCache.ps1' })
$UI.BtnLibrary.Add_Click({   Invoke-ToolkitScript 'cache\Analyze-Library.ps1' })
$UI.BtnChatHist.Add_Click({  Invoke-ToolkitScript 'cache\Analyze-ChatHistory.ps1' })
$UI.BtnOpenCache.Add_Click({ Open-Path (Join-Path $localLow 'HTTPCache') })

$UI.BtnRepairCheck.Add_Click({ Invoke-ToolkitScript 'maintenance\Repair-Installation.ps1' @('-Check') })
$UI.BtnBackup.Add_Click({      Invoke-ToolkitScript 'maintenance\Backup-Config.ps1' })
$UI.BtnClearCache.Add_Click({  Invoke-ToolkitScript 'maintenance\Clear-Cache.ps1' })
$UI.BtnRepair.Add_Click({      Invoke-ToolkitScript 'maintenance\Repair-Installation.ps1' })

# ---------------------------------------------------------------------------
# System tray
# ---------------------------------------------------------------------------

$tray = New-Object System.Windows.Forms.NotifyIcon
try {
    $tray.Icon = [Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
} catch {
    $tray.Icon = [System.Drawing.SystemIcons]::Application
}
$tray.Text = '3dxGC'
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miShow = $menu.Items.Add('Show panel')
$miShow.Add_Click({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })

[void]$menu.Items.Add('-')

$miTrim = $menu.Items.Add('Trim game now')
$miTrim.Add_Click({
    $r = $M::TrimProcessesByName('3DXChat')
    $msg = 'Game not running'
    if ($r.Success -and $r.AffectedProcesses -gt 0) { $msg = "Trimmed - $($r.FreedMB) MB freed" }
    $tray.ShowBalloonTip(2500, '3dxGC', $msg, 'Info')
})

$miEmpty = $menu.Items.Add('Empty all (needs admin)')
$miEmpty.Add_Click({
    $results = $M::EmptyAll()
    $bad = @($results | Where-Object { -not $_.Success })
    if ($bad.Count -eq $results.Count) {
        $msg = 'Needs Administrator'
    } else {
        $total = ($results | Measure-Object -Property BytesFreed -Sum).Sum / 1MB
        $msg = "Freed $([math]::Round($total,0)) MB"
    }
    $tray.ShowBalloonTip(3000, '3dxGC', $msg, 'Info')
})

[void]$menu.Items.Add('-')

$miExit = $menu.Items.Add('Exit 3dxGC')
$miExit.Add_Click({ $win.Close() })

$tray.ContextMenuStrip = $menu
$tray.Add_MouseDoubleClick({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })

function Hide-ToTray {
    try {
        $win.Hide()
        $tray.ShowBalloonTip(1500, '3dxGC', 'Still running in the tray - right-click the icon for options.', 'Info')
    } catch { }
}

# Minimise hides to tray instead of the taskbar. Closing (the OS close box,
# or the tray's own "Exit") is a real exit either way - both go through the
# same Closing handler below.
$win.Add_StateChanged({
    if ($win.WindowState -eq 'Minimized') { Hide-ToTray }
})

# Closing runs cleanup once; Closed stops the message loop so the script can
# return past Dispatcher.Run() below and the process can exit. Guarded so a
# second close event (or the silent updater's own Close() call) can never
# double-run it.
$Script:IsShuttingDown = $false
function Stop-App {
    if ($Script:IsShuttingDown) { return }
    $Script:IsShuttingDown = $true
    Stop-Governor
    $tray.Visible = $false
    $tray.Dispose()
}

$win.Add_Closing({ Stop-App })
$win.Add_Closed({ $win.Dispatcher.InvokeShutdown() })

# A window shown via ShowDialog() cannot be Hide()-den - WPF throws
# InvalidOperationException, and because nothing here caught it, that
# exception used to take the whole process down the instant the window was
# minimised: window, tray icon, everything, unrecoverable. Show() plus running
# the dispatcher directly (InvokeShutdown above is what lets this call
# return) avoids the trap entirely.
#
# Dispatcher.UnhandledException is the same fix applied generally: any other
# uncaught exception on the UI thread was equally fatal before. Marking it
# Handled keeps the panel open and logs the error instead of silently killing
# the app.
$win.Dispatcher.add_UnhandledException({
    param($evtSender, $e)
    try {
        Add-LogLine ("[Error] " + $e.Exception.GetType().Name + ": " + $e.Exception.Message)
        Set-Status ("Error: " + $e.Exception.Message) $Colours.Bad
    } catch { }
    $e.Handled = $true
})

# ---------------------------------------------------------------------------
# Timer + show
# ---------------------------------------------------------------------------

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ try { Update-Telemetry } catch { } })
$timer.Start()

Update-ModList

# The whole point of this redesign: protection starts itself. No click
# required - "do I have to click anything" should simply not come up.
if ($UI.CmbProfile.SelectedItem) {
    Start-Governor
} else {
    Set-Status 'No profiles found - nothing to start.' $Colours.Warn
}
Update-OnboardingBanner

Update-Telemetry
Set-Status 'Ready.'

$win.Show()
if ($Minimized) { $win.WindowState = 'Minimized' }

if ($JustUpdated) {
    Add-LogLine "[Info] updated to v$JustUpdated"
    $tray.ShowBalloonTip(3000, '3dxGC', "Updated to v$JustUpdated - still running in the background.", 'Info')
}

[Windows.Threading.Dispatcher]::Run()

$timer.Stop()
