<#
.SYNOPSIS
    Checks for Lossless Scaling (Steam App ID 993090) and, if present, tunes
    a 3DXChat profile in its Settings.xml for realistic-looking upscaling.

.DESCRIPTION
    Lossless Scaling is a paid Steam app - there is no such thing as a
    scripted purchase, and this never attempts one. If it isn't installed,
    this opens its Steam store page directly (steam://store/993090, the
    same URI scheme Steam's own client and website links use) and stops.

    If it IS installed, this edits its real settings file directly:
        %LocalAppData%\Lossless Scaling\Settings.xml
    (found by actually launching the app once and diffing AppData - not
    guessed) rather than describing GUI clicks.

    Honest limitation, found by direct testing, not assumed: writing
    <ExeOrProcessName> or <GamePath> into a <Profile> block does NOT
    survive the app's own load/save cycle - it silently drops both fields
    on the very next launch. Whatever actually binds a profile to a running
    game isn't reliably scriptable from what's been verified so far. So
    this script only ever manages a profile's TUNING fields (scaling
    algorithm, sharpness, frame generation, capture API) - creating a
    "3DXChat"-titled profile if none exists, or updating one if it does -
    and tells you plainly that binding it to the actual running game still
    needs one manual step in the app's own UI (its "Add"/browse flow).

    Settings recommended here and why, from actually testing this session:
      ScalingType   = LS1        general AI upscaler; Anime4K (the shipped
                                  default) is tuned for flat-shaded art and
                                  pushes semi-realistic 3D content the wrong
                                  way, toward more stylized, not more real.
      LS1Type       = BALANCED   a real quality step up from PERFORMANCE,
                                  confirmed as a valid value (not guessed).
      Sharpness     = 3          deliberately conservative - the intuitive
      LS1Sharpness  = 1          move (push sharpening up for "more detail")
                                  makes skin/faces look LESS real, not more:
                                  it exaggerates texture noise and produces
                                  edge halos that read as digital.
      FrameGeneration = Off      motion smoothness is a different axis from
                                  per-frame detail; it doesn't make anyone
                                  look more realistic, and it's the actual
                                  source of the latency already reported
                                  this session - decoupled here on purpose.
      CaptureApi    = DXGI       matches 3DXChat's real render backend
                                  (Unity 2021.3, D3D11/D3D12 on Windows),
                                  same conclusion independently reached
                                  while setting up ReShade.

.PARAMETER GameExePath
    Path to 3DXChat.exe, shown in the printed instructions for the one
    remaining manual binding step.
#>
[CmdletBinding()]
param(
    [string]$GameExePath = 'C:\Users\Power User\Downloads\3DXChatLauncherV6\3DXChat\Game\3DXChat.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SteamAppId = '993090'

function Write-Step { param($m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "  $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Locate Steam and its libraries (do not assume the default install path)
# ---------------------------------------------------------------------------

function Get-SteamPath {
    try {
        $p = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction Stop).SteamPath
        if ($p) { return $p -replace '/', '\' }
    } catch { }
    $fallback = 'C:\Program Files (x86)\Steam'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Get-SteamLibraryPaths {
    param([string]$SteamPath)
    $paths = @($SteamPath)
    $vdf = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $content = Get-Content -LiteralPath $vdf -Raw
        $matches = [regex]::Matches($content, '"path"\s*"([^"]+)"')
        foreach ($m in $matches) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            if ($paths -notcontains $p) { $paths += $p }
        }
    }
    return $paths
}

function Find-LosslessScalingInstall {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { return $null }
    foreach ($lib in (Get-SteamLibraryPaths -SteamPath $steamPath)) {
        $manifest = Join-Path $lib "steamapps\appmanifest_$SteamAppId.acf"
        $exe = Join-Path $lib 'steamapps\common\Lossless Scaling\LosslessScaling.exe'
        if ((Test-Path -LiteralPath $manifest) -and (Test-Path -LiteralPath $exe)) {
            return $exe
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Not installed: open the store page, do not attempt to buy anything
# ---------------------------------------------------------------------------

$lsExe = Find-LosslessScalingInstall
if (-not $lsExe) {
    Write-Host ''
    Write-Warn2 'Lossless Scaling is not installed.'
    Write-Warn2 "It's a paid Steam app (~$7 USD) - only you can buy it, via your own Steam account."
    Write-Host ''
    Write-Step 'Opening its Steam store page now...'
    try {
        Start-Process "steam://store/$SteamAppId"
        Write-Ok 'If Steam is running, its store page should be opening now.'
    } catch {
        Write-Warn2 "Could not launch the steam:// link directly. Search 'Lossless Scaling' in your Steam client (App ID $SteamAppId)."
    }
    Write-Host ''
    Write-Host 'Once purchased and installed, run this script again to configure it.' -ForegroundColor White
    return
}

Write-Ok "Lossless Scaling found: $lsExe"

# ---------------------------------------------------------------------------
# Installed: tune (or create) the 3DXChat profile
# ---------------------------------------------------------------------------

$settingsPath = Join-Path $env:LOCALAPPDATA 'Lossless Scaling\Settings.xml'

if (-not (Test-Path -LiteralPath $settingsPath)) {
    Write-Step 'No settings file yet - launching Lossless Scaling once to generate it.'
    Start-Process $lsExe
    Start-Sleep -Seconds 5
    Get-Process -Name 'LosslessScaling' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "Settings.xml still not found at $settingsPath after launching the app once. Launch it manually, then re-run this script."
    }
}

# A running instance holds the file and will overwrite our edit on its own
# next save - same reason the ReShade script requires the game closed first.
if (Get-Process -Name 'LosslessScaling' -ErrorAction SilentlyContinue) {
    Write-Step 'Closing Lossless Scaling first (it would overwrite this edit on its own next save).'
    Get-Process -Name 'LosslessScaling' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

$backupPath = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $settingsPath -Destination $backupPath -Force
Write-Ok "backed up existing settings to $backupPath"

[xml]$xml = Get-Content -LiteralPath $settingsPath -Raw

# Field values, verified this session to be real and correctly named -
# not guessed - via reflection over the compiled Profile class plus an
# actual round-trip test through the running app.
$recommended = [ordered]@{
    ScalingMode        = 'Auto'
    ScalingFitMode     = 'AspectRatio'
    ScaleFactor        = '1.5'
    ResizeBeforeScaling= 'false'
    WindowedMode       = 'false'
    ScalingType        = 'LS1'
    FSRType            = 'ORIGINAL'
    LS1Type            = 'BALANCED'
    LSFG2Mode          = 'X2'
    LSFG3Mode1         = 'FIXED'
    LSFG3Multiplier    = '2'
    LSFG3Target        = '240'
    LSFGFlowScale      = '100'
    LSFGSize           = 'BALANCED'
    Anime4kType        = 'S'
    Sharpness          = '3'
    LS1Sharpness       = '1'
    VRS                = 'false'
    FrameGeneration    = 'Off'
    ClipCursor         = 'true'
    AdjustCursorSpeed  = 'false'
    HideCursor         = 'false'
    ScaleCursor        = 'false'
    SyncMode           = 'DEFAULT'
    MaxFrameLatency    = '3'
    GsyncSupport       = 'true'
    HdrSupport         = 'false'
    DrawFps            = 'true'
    CaptureApi         = 'DXGI'
    QueueTarget        = '1'
    PreferredGpuId     = '0'
    OutputDisplayId    = '0'
    CropInput          = 'false'
    CropInputLeft      = '0'
    CropInputTop       = '0'
    CropInputRight     = '0'
    CropInputBottom    = '0'
    MultiDisplayMode   = 'false'
}

$gameProfiles = $xml.Settings.GameProfiles
if (-not $gameProfiles) {
    $gameProfiles = $xml.CreateElement('GameProfiles')
    [void]$xml.Settings.AppendChild($gameProfiles)
}

$existing = $gameProfiles.Profile | Where-Object { $_.Title -eq '3DXChat' }

if ($existing) {
    Write-Step "updating existing '3DXChat' profile"
    foreach ($key in $recommended.Keys) {
        $node = $existing.SelectSingleNode($key)
        if ($node) { $node.InnerText = $recommended[$key] }
        else {
            $new = $xml.CreateElement($key)
            $new.InnerText = $recommended[$key]
            [void]$existing.AppendChild($new)
        }
    }
} else {
    Write-Step "creating new '3DXChat' profile"
    $profile = $xml.CreateElement('Profile')
    $titleEl = $xml.CreateElement('Title'); $titleEl.InnerText = '3DXChat'
    [void]$profile.AppendChild($titleEl)
    $autoEl = $xml.CreateElement('AutoScale'); $autoEl.InnerText = 'true'
    [void]$profile.AppendChild($autoEl)
    $delayEl = $xml.CreateElement('AutoScaleDelay'); $delayEl.InnerText = '0'
    [void]$profile.AppendChild($delayEl)
    foreach ($key in $recommended.Keys) {
        $el = $xml.CreateElement($key)
        $el.InnerText = $recommended[$key]
        [void]$profile.AppendChild($el)
    }
    [void]$gameProfiles.AppendChild($profile)
}

$xml.Save($settingsPath)
Write-Ok "profile written to $settingsPath"

Write-Host ''
Write-Host 'Done - but one manual step remains.' -ForegroundColor White
Write-Warn2 "Directly writing which .exe this profile targets does not survive Lossless Scaling's own save cycle (verified by testing, not assumed)."
Write-Host ''
Write-Host 'To bind it to the actual game:' -ForegroundColor White
Write-Host "  1. Launch Lossless Scaling, select the '3DXChat' profile."
Write-Host "  2. Use its own Add/browse control to point at:"
Write-Host "       $GameExePath" -ForegroundColor DarkGray
Write-Host '  3. Launch 3DXChat, then press the scale hotkey (default Ctrl+Alt+S) once in-game.'
Write-Host ''
