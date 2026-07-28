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
    [string]$ToolkitPath = "$env:USERPROFILE\Documents\3DXChat-Debug-Toolkit"
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
    GovernorProcess = $null
    LogPath         = $null
    LogPosition     = 0
    History         = New-Object System.Collections.Generic.List[psobject]
    Reclaimed       = 0.0
    TrimCount       = 0
    LastGameWS      = 0.0
    ToolkitPath     = $ToolkitPath
}

function Set-Status {
    param([string]$Message, [string]$Colour = '#FF8B93A3')
    $UI.TxtStatus.Text = $Message
    $UI.TxtStatus.Foreground = New-Brush $Colour
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
        } else {
            Read-GovernorLog
        }
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
# Wire up
# ---------------------------------------------------------------------------

Get-ChildItem (Join-Path $ModKitRoot 'profiles') -Filter *.json | ForEach-Object {
    [void]$UI.CmbProfile.Items.Add($_.BaseName)
}
if ($UI.CmbProfile.Items.Contains('default')) {
    $UI.CmbProfile.SelectedItem = 'default'
} elseif ($UI.CmbProfile.Items.Count -gt 0) {
    $UI.CmbProfile.SelectedIndex = 0
}

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

$miExit = $menu.Items.Add('Exit')
$miExit.Add_Click({
    Stop-Governor
    $tray.Visible = $false
    $tray.Dispose()
    $win.Close()
})

$tray.ContextMenuStrip = $menu
$tray.Add_MouseDoubleClick({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })

# Minimise hides to tray instead of the taskbar.
$win.Add_StateChanged({
    if ($win.WindowState -eq 'Minimized') {
        $win.Hide()
        $tray.ShowBalloonTip(1500, '3dxGC', 'Still governing in the background.', 'Info')
    }
})

$win.Add_Closing({
    Stop-Governor
    $tray.Visible = $false
    $tray.Dispose()
})

# ---------------------------------------------------------------------------
# Timer + show
# ---------------------------------------------------------------------------

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ try { Update-Telemetry } catch { } })
$timer.Start()

Update-ModList
Update-Telemetry
Set-Status 'Ready.'

if ($Minimized) {
    $win.WindowState = 'Minimized'
    [void]$win.ShowDialog()
} else {
    [void]$win.ShowDialog()
}

$timer.Stop()
$tray.Visible = $false
$tray.Dispose()
