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

# ---------------------------------------------------------------------------
# One control panel per session
#
# Two of them means two governors trimming the same game and fighting over
# it - easy to get by opening 3dxGC.bat while the "start with Windows" copy
# sits in the tray. The short wait covers the updater's relaunch, which
# starts just after the old instance exits.
# ---------------------------------------------------------------------------

$Script:InstanceMutex = $null
$haveInstance = $false
try {
    $Script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\3dxGC-ControlPanel')
    try {
        $haveInstance = $Script:InstanceMutex.WaitOne([TimeSpan]::FromSeconds(5))
    } catch {
        # The previous owner exited without releasing it - ours now.
        $inner = $_.Exception
        while ($inner -and $inner -isnot [System.Threading.AbandonedMutexException]) { $inner = $inner.InnerException }
        $haveInstance = [bool]$inner
    }
} catch {
    # Access denied: held by a copy running at a different elevation.
    $haveInstance = $false
}
if (-not $haveInstance) {
    if (-not $Minimized) {
        [System.Windows.MessageBox]::Show(
            "3dxGC is already running - look for its icon in the system tray.`n`n" +
            "To run it as administrator instead, right-click the tray icon, choose Exit 3dxGC, then open 3dxGC.bat again.",
            '3dxGC', 'OK', 'Information') | Out-Null
    }
    exit 0
}

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
    AppRestartJob     = $null
    AppRestartName    = $null
    AppRestartSize    = $null
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

# Small tray notifications ("trimmed", "still running in the tray"). Windows
# may hold these back (Do Not Disturb, games, full screen), so nothing that
# needs an answer goes through here - questions use the prompt card below.
function Show-Notice {
    param([int]$Milliseconds, [string]$Title, [string]$Text, [string]$Icon = 'Info')
    $tray = Get-Variable -Name tray -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($tray) { $tray.ShowBalloonTip($Milliseconds, $Title, $Text, $Icon) }
}

# ---------------------------------------------------------------------------
# Prompt card
#
# 3dxGC's own question window, because Windows' notifications can't be
# trusted to show one: Do Not Disturb, game mode and full-screen apps send
# them silently to the notification centre. The card sits in the corner on
# top of everything but never takes focus - the game keeps the keyboard and
# mouse - has real buttons, and closes itself as "Not now" after a minute.
# One at a time; the rest wait their turn.
# ---------------------------------------------------------------------------

if (-not ('ThreeDX.ModKit.Gui.NoActivate' -as [type])) {
    Add-Type -Namespace ThreeDX.ModKit.Gui -Name NoActivate -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
'@
}

$Script:GuiRoot     = $PSScriptRoot
$Script:PromptQueue = New-Object System.Collections.Generic.Queue[hashtable]
$Script:PromptCard  = $null
$Script:PromptTimer = $null
$Script:PromptCurrent = $null

# Queue a card. -Action (data) is what "Restart" does; without one the card
# just informs and has a single OK button.
function Show-PromptCard {
    param([string]$Title, [string]$Text, [hashtable]$Action = $null, [int]$Seconds = 60)
    $Script:PromptQueue.Enqueue(@{ Title = $Title; Text = $Text; Action = $Action; Seconds = $Seconds })
    if (-not $Script:PromptCard) { Open-NextPromptCard }
}

function Open-NextPromptCard {
    if ($Script:PromptCard -or $Script:PromptQueue.Count -eq 0) { return }
    $p = $Script:PromptQueue.Dequeue()
    $Script:PromptCurrent = $p

    [xml]$x = Get-Content -LiteralPath (Join-Path $Script:GuiRoot 'PromptCard.xaml') -Raw
    $card = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $card.FindName('TxtTitle').Text = $p.Title
    $card.FindName('TxtBody').Text  = $p.Text
    if (-not $p.Action) {
        $card.FindName('BtnYes').Visibility = 'Collapsed'
        $card.FindName('BtnNo').Content = 'OK'
    }
    $card.FindName('BtnYes').Add_Click({ $a = $Script:PromptCurrent.Action; Close-PromptCard; Invoke-PromptAction $a })
    $card.FindName('BtnNo').Add_Click({ Close-PromptCard })

    # No-activate + tool window: clicking it never takes focus from the game,
    # and it stays out of Alt+Tab.
    $card.Add_SourceInitialized({
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Script:PromptCard)).Handle
        $ex = [ThreeDX.ModKit.Gui.NoActivate]::GetWindowLong($h, -20)
        [void][ThreeDX.ModKit.Gui.NoActivate]::SetWindowLong($h, -20, ($ex -bor 0x08000000 -bor 0x80))
    })
    # Bottom-right of the work area, once its height is known.
    $card.Add_SizeChanged({
        $wa = [System.Windows.SystemParameters]::WorkArea
        $Script:PromptCard.Left = $wa.Right - $Script:PromptCard.ActualWidth - 6
        $Script:PromptCard.Top  = $wa.Bottom - $Script:PromptCard.ActualHeight - 6
    })

    $Script:PromptCard = $card
    $Script:PromptCurrent.Remaining = $p.Seconds
    $card.FindName('TxtCountdown').Text = "closes in $($p.Seconds)s"
    $Script:PromptTimer = New-Object Windows.Threading.DispatcherTimer
    $Script:PromptTimer.Interval = [TimeSpan]::FromSeconds(1)
    $Script:PromptTimer.Add_Tick({
        $Script:PromptCurrent.Remaining--
        if ($Script:PromptCurrent.Remaining -le 0) { Close-PromptCard; return }
        $Script:PromptCard.FindName('TxtCountdown').Text = "closes in $($Script:PromptCurrent.Remaining)s"
    })
    $Script:PromptTimer.Start()
    $card.Show()
}

function Close-PromptCard {
    if ($Script:PromptTimer) { $Script:PromptTimer.Stop(); $Script:PromptTimer = $null }
    if ($Script:PromptCard)  { $Script:PromptCard.Close(); $Script:PromptCard = $null }
    $Script:PromptCurrent = $null
    # Next one after this click has finished, not inside it.
    if ($Script:PromptQueue.Count -gt 0) {
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Action]{ Open-NextPromptCard })
    }
}

function Invoke-PromptAction {
    param([hashtable]$Action)
    if (-not $Action) { return }
    switch ($Action.Kind) {
        'restart-app'     { Start-AppRestart -Name $Action.Name -Size $Action.Size }
        'restart-service' { Start-AppRestart -Name $Action.Name -Size $Action.Size -Service }
    }
}

# The governor asks about restarts through its log; this turns those lines
# into prompt cards. Nothing restarts unless you press Restart - 3dxGC never
# restarts an app, a service or Windows by itself.
function Show-AppRestartNotice {
    param([string]$Line)
    if ($Line -match '\[3dxgc\] (\S+) has grown to (.+? MB) - asking whether to restart it') {
        $app = $matches[1]; $size = $matches[2]
        Show-PromptCard "Restart $app?" `
            "$app has grown to $size of memory. Restarting it gives that back. Not now leaves it running - you'll be asked again in a few hours if it's still this big." `
            @{ Kind = 'restart-app'; Name = $app; Size = $size }
    } elseif ($Line -match '\[3dxgc\] (\S+) service is leaking \((.+?) handles\) - asking whether to restart it') {
        $svc = $matches[1]; $handles = $matches[2]
        Show-PromptCard "Restart $svc?" `
            "This service is leaking - it holds $handles handles. Restarting it fixes that (Windows will ask for administrator). Not now leaves it running." `
            @{ Kind = 'restart-service'; Name = $svc; Size = "$handles handles" }
    }
}

# A pressed Restart. Runs as a job - closing an app and waiting for it to
# come back takes seconds and must not freeze the window.
function Start-AppRestart {
    param([string]$Name, [string]$Size, [switch]$Service)
    if ($State.AppRestartJob) { return }
    $State.AppRestartName = $Name
    $State.AppRestartSize = $Size
    $State.AppRestartJob = Start-Job -ScriptBlock {
        param($ModulePath, $Target, $IsService)
        Import-Module $ModulePath -Force
        if ($IsService) { Restart-ModKitService -Name $Target } else { Restart-ModKitApp -Name $Target }
    } -ArgumentList (Join-Path $ModKitRoot '3DXModKit.psm1'), $Name, ([bool]$Service)
    Add-LogLine "[Info] restarting $Name (you pressed Restart)"
}

function Receive-AppRestart {
    if (-not $State.AppRestartJob) { return }
    if ($State.AppRestartJob.State -notin @('Completed', 'Failed', 'Stopped')) { return }
    $r = $null
    try { $r = Receive-Job -Job $State.AppRestartJob -ErrorAction SilentlyContinue | Select-Object -Last 1 } catch { }
    Remove-Job -Job $State.AppRestartJob -Force -ErrorAction SilentlyContinue
    $State.AppRestartJob = $null
    $name = $State.AppRestartName

    if ($r -and $r.Success) {
        Add-LogLine "[Info] restarted $name"
        Show-PromptCard "Restarted $name" "It had grown to $($State.AppRestartSize). It's back and starting fresh." -Seconds 8
    } elseif ($r -and $r.Closed) {
        Add-LogLine "[Warn] closed $name but could not reopen it: $($r.Error)"
        Show-PromptCard "$name closed but didn't reopen" "Reopening it failed ($($r.Error)). Open it again yourself." -Seconds 60
    } else {
        $err = if ($r) { $r.Error } else { 'no result' }
        Add-LogLine "[Warn] could not restart ${name}: $err"
        Show-PromptCard "Couldn't restart $name" "$err - nothing was closed." -Seconds 20
    }
}

function Read-GovernorLog {
    if (-not $State.LogPath) { return }
    if (-not (Test-Path -LiteralPath $State.LogPath)) { return }
    try {
        $fs = [IO.File]::Open($State.LogPath, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $State.LogPosition) { $State.LogPosition = 0 }
            [void]$fs.Seek($State.LogPosition, 'Begin')
            $sr = New-Object IO.StreamReader($fs)
            while (-not $sr.EndOfStream) {
                $line = $sr.ReadLine()
                Add-LogLine $line
                Show-AppRestartNotice $line
            }
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
    Receive-AppRestart
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

Installing it adds a few files next to 3DXChat.exe. A game update or
launcher repair may remove them again - just re-run the installer.

    cd runtime\bootstrap
    .\Install-BepInEx.ps1 -GamePath "<...>\3DXChat\Game"
    (launch the game once so interop assemblies generate)
    .\Build-Plugin.ps1 -GamePath "<...>\3DXChat\Game"

Every added file is recorded, so Uninstall-BepInEx.ps1 reverts exactly.
'@

$UI.BtnRuntimeDocs.Add_Click({
    [void][Windows.MessageBox]::Show($runtimeHelp, 'In-process runtime', 'OK', 'Information')
})

# companion apps (Mods tab)
function Update-Companions {
    foreach ($c in (Get-ModKitCompanions)) {
        $text = if ($c.Installed) {
            $v = if ($c.Version) { "v$($c.Version) installed" } else { 'installed' }
            if ($c.Running) { "$v, running" } else { $v }
        } elseif ($c.WebUrl) { 'not installed - Open can install it or use the online version' } else { 'not installed' }
        $txt, $install = switch ($c.Id) {
            'profile-studio' { $UI.TxtProfileStudio, $UI.BtnInstallProfileStudio }
            'world-editor'   { $UI.TxtWorldEditor, $UI.BtnInstallWorldEditor }
            default          { $UI.TxtRadioStreamer, $UI.BtnInstallRadioStreamer }
        }
        $txt.Text = $text
        $txt.Foreground = New-Brush $(if ($c.Installed) { $Colours.Good } else { $Colours.Dim })
        $install.Content = if ($c.Installed) { 'Update' } else { 'Install' }
    }
}

function Start-CompanionInstaller {
    param($Companion, [switch]$Open)
    if (-not (Test-Path -LiteralPath $Companion.Installer)) {
        Set-Status "Installer not found: $($Companion.Installer)" $Colours.Bad
        return
    }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"' + $Companion.Installer + '"'))
    if ($Open -and $Companion.WebUrl) { $argList += '-Open' }   # the installers with an online version take -Open
    Start-Process powershell.exe -ArgumentList $argList
    Set-Status "Installing $($Companion.Name) in a new window. Come back to this tab to see it." $Colours.Blue
}

function Open-Companion {
    param([string]$Id)
    $c = Get-ModKitCompanions | Where-Object { $_.Id -eq $Id }
    if ($c.Installed) {
        Start-Process -FilePath $c.Path
        Set-Status "Opened $($c.Name)." $Colours.Good
        return
    }
    if ($c.WebUrl) {
        $answer = [Windows.MessageBox]::Show(
            "$($c.Name) isn't installed yet.`n`nYes: install it now. It downloads the latest release and checks it against its checksum, then opens it.`nNo: open the online version instead.",
            $c.Name, 'YesNoCancel', 'Question')
        if ($answer -eq 'Yes') { Start-CompanionInstaller $c -Open }
        elseif ($answer -eq 'No') { Start-Process $c.WebUrl; Set-Status "Opened the online $($c.Name)." $Colours.Good }
    } else {
        $answer = [Windows.MessageBox]::Show(
            "$($c.Name) isn't installed yet. Install it now?`n`nIt downloads the latest release, checks it against its checksum and asks once more before running the installer.",
            $c.Name, 'YesNo', 'Question')
        if ($answer -eq 'Yes') { Start-CompanionInstaller $c }
    }
}

$UI.BtnOpenProfileStudio.Add_Click({ Open-Companion 'profile-studio' })
$UI.BtnOpenRadioStreamer.Add_Click({ Open-Companion 'radio-streamer' })
$UI.BtnInstallProfileStudio.Add_Click({ Start-CompanionInstaller (Get-ModKitCompanions | Where-Object { $_.Id -eq 'profile-studio' }) })
$UI.BtnInstallRadioStreamer.Add_Click({ Start-CompanionInstaller (Get-ModKitCompanions | Where-Object { $_.Id -eq 'radio-streamer' }) })
$UI.BtnOpenWorldEditor.Add_Click({ Open-Companion 'world-editor' })
$UI.BtnInstallWorldEditor.Add_Click({ Start-CompanionInstaller (Get-ModKitCompanions | Where-Object { $_.Id -eq 'world-editor' }) })
$UI.Tabs.Add_SelectionChanged({
    param($s, $e)
    # SelectionChanged bubbles up from list boxes inside the tabs too
    if ($e.OriginalSource -eq $UI.Tabs -and $UI.Tabs.SelectedItem.Header -eq 'Mods') { Update-Companions }
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
    Show-Notice 2500 '3dxGC' $msg
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
    Show-Notice 3000 '3dxGC' $msg
})

[void]$menu.Items.Add('-')

$miExit = $menu.Items.Add('Exit 3dxGC')
$miExit.Add_Click({ $win.Close() })

$tray.ContextMenuStrip = $menu
$tray.Add_MouseDoubleClick({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })

function Hide-ToTray {
    try {
        $win.Hide()
        Show-Notice 1500 '3dxGC' 'Still running in the tray - right-click the icon for options.'
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
Update-Companions

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
    Show-Notice 3000 '3dxGC' "Updated to v$JustUpdated - still running in the background."
}

[Windows.Threading.Dispatcher]::Run()

$timer.Stop()
