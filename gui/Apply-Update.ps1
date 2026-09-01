<#
.SYNOPSIS
    Waits for the running GUI to exit, then swaps in a staged update.

.DESCRIPTION
    This is a separate, standalone process by design. A running app cannot
    safely overwrite its own open files while it's still executing, so the
    GUI spawns this, then exits itself; this script waits for that exit to be
    real (not just "the window closed"), copies the staged files over the
    install, and relaunches.

    logs\ and config\ in the target are never touched - only everything else
    is replaced. Losing a user's log history or config overrides as a side
    effect of an update they never asked to think about would be exactly the
    kind of surprise this whole redesign exists to prevent.

    Always relaunches unelevated. Re-triggering a UAC prompt in the middle of
    a background update the user did not initiate would be a worse surprise
    than temporarily losing the four admin-only RAMMap operations; reopening
    via 3dxGC.bat restores them.

.PARAMETER SourceDir
    Root of the freshly-extracted new version (contains gui\, src\, mods\, ...).
.PARAMETER TargetDir
    The install directory being updated in place.
.PARAMETER WaitPid
    Process ID of the GUI that must exit before files are touched.
.PARAMETER NewVersion
    Version string passed through to the relaunched GUI via -JustUpdated.
.PARAMETER Minimized
    Relaunch straight to tray, matching how the app was running before.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$TargetDir,
    [Parameter(Mandatory)][int]$WaitPid,
    [Parameter(Mandatory)][string]$NewVersion,
    [switch]$Minimized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logPath = Join-Path $TargetDir 'logs\updater.log'
function Write-UpdateLog {
    param([string]$Message)
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message"
    try {
        $dir = Split-Path -Parent $logPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
}

Write-UpdateLog "applying update to $NewVersion (source: $SourceDir)"

# --- wait for the old process to actually exit ------------------------------
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $p = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
    if (-not $p) { break }
    Start-Sleep -Milliseconds 300
}
$stillRunning = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
if ($stillRunning) {
    Write-UpdateLog "pid $WaitPid did not exit within 30s - aborting update, nothing was touched"
    exit 1
}
Start-Sleep -Milliseconds 500  # let the OS release file handles

# --- copy everything except logs\ and config\ -------------------------------
if (-not (Test-Path -LiteralPath $SourceDir)) {
    Write-UpdateLog "source dir missing: $SourceDir - aborting"
    exit 1
}

$sep = [char]92
$srcFull = [IO.Path]::GetFullPath($SourceDir)
$copied = 0
$failed = 0

try {
    Get-ChildItem -LiteralPath $srcFull -Recurse -File | ForEach-Object {
        $rel = [IO.Path]::GetFullPath($_.FullName).Substring($srcFull.Length).TrimStart($sep)
        $topDir = $rel.Split($sep)[0]
        if ($topDir -eq 'logs' -or $topDir -eq 'config') { return }

        $dest = Join-Path $TargetDir $rel
        $destDir = Split-Path -Parent $dest
        try {
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            $copied++
        } catch {
            $failed++
            Write-UpdateLog "FAILED to copy $rel : $($_.Exception.Message)"
        }
    }
} catch {
    Write-UpdateLog "update copy pass threw: $($_.Exception.Message)"
}

Write-UpdateLog "copied $copied file(s), $failed failure(s)"

try { Remove-Item -LiteralPath $srcFull -Recurse -Force -ErrorAction SilentlyContinue } catch { }

if ($failed -gt 0 -and $copied -eq 0) {
    Write-UpdateLog "every file failed to copy - not relaunching, install may be in a bad state, reopen via 3dxGC.bat"
    exit 1
}

# --- relaunch -----------------------------------------------------------
$guiScript = Join-Path $TargetDir 'gui\Start-Gui.ps1'
if (-not (Test-Path -LiteralPath $guiScript)) {
    Write-UpdateLog "gui\Start-Gui.ps1 missing after update - not relaunching"
    exit 1
}

# Every path element is wrapped in embedded quotes: Start-Process
# -ArgumentList does not auto-quote array elements, and an unquoted path
# containing a space (a great many real Windows installs have one, e.g.
# "...\Power User\...") silently splits into multiple broken tokens and the
# relaunch fails parameter binding with no visible error.
$relaunchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', ('"' + $guiScript + '"'), '-JustUpdated', $NewVersion)
if ($Minimized) { $relaunchArgs += '-Minimized' }

try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -WorkingDirectory $TargetDir | Out-Null
    Write-UpdateLog "relaunched (minimized: $($Minimized.IsPresent))"
} catch {
    Write-UpdateLog "relaunch failed: $($_.Exception.Message)"
    exit 1
}

exit 0
