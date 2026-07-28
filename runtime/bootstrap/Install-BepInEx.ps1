<#
.SYNOPSIS
    Installs BepInEx 6 (IL2CPP, x64) into the 3DXChat game directory.

.DESCRIPTION
    This is the only script in 3DXModKit that writes into the game install.
    Everything it touches is backed up first, and Uninstall-BepInEx.ps1 restores
    the directory to exactly its prior state.

    Read this before running it:

      * The game ships a PGP-signed integrity.conf in both Game\ and Launcher\.
        Adding files to Game\ will diverge from that manifest. Whether the
        launcher enforces the manifest, and what it does on mismatch, is the
        publisher's call and can change with any patch.

      * 3DXChat is a live online service tied to your account. Loading code
        into the client is a Terms of Service question, not just a technical
        one. 3DXModKit is client-side only by design and does not touch the
        network, the protocol, or server-authoritative state - but that is a
        property of this framework, not a guarantee about how the operator
        interprets client modification.

      * The launcher may restore or re-download modified files, silently
        undoing this install.

    Nothing here is hidden from you and nothing runs without -Confirm.

.PARAMETER GamePath
    The 3DXChat Game directory (contains 3DXChat.exe and GameAssembly.dll).

.PARAMETER Version
    BepInEx 6 IL2CPP release to install.

.PARAMETER Force
    Reinstall over an existing BepInEx install.

.EXAMPLE
    .\Install-BepInEx.ps1 -GamePath "C:\...\3DXChat\Game"
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$GamePath,

    [string]$Version = '6.0.0-pre.2',

    [string]$DownloadUrl,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "  $m" -ForegroundColor Yellow }

# --- validate target --------------------------------------------------------

if (-not (Test-Path -LiteralPath $GamePath)) {
    throw "Game path not found: $GamePath"
}

$exe = Join-Path $GamePath '3DXChat.exe'
$gameAssembly = Join-Path $GamePath 'GameAssembly.dll'

if (-not (Test-Path -LiteralPath $exe)) {
    throw "3DXChat.exe not found in $GamePath - is this the Game directory?"
}
if (-not (Test-Path -LiteralPath $gameAssembly)) {
    throw "GameAssembly.dll not found - this build is not IL2CPP, so the IL2CPP BepInEx is wrong for it."
}

$unityVersion = (Get-Item (Join-Path $GamePath 'UnityPlayer.dll')).VersionInfo.ProductVersion
Write-Host ''
Write-Host 'Target' -ForegroundColor White
Write-Step "path    : $GamePath"
Write-Step "unity   : $unityVersion"
Write-Step "backend : IL2CPP (GameAssembly.dll present)"
Write-Host ''

if (Get-Process -Name '3DXChat' -ErrorAction SilentlyContinue) {
    throw "3DXChat is running. Close the game before installing."
}

$existing = Join-Path $GamePath 'BepInEx'
if ((Test-Path -LiteralPath $existing) -and -not $Force) {
    throw "BepInEx already present at $existing. Re-run with -Force to reinstall."
}

# --- integrity notice -------------------------------------------------------

$integrity = Join-Path $GamePath 'integrity.conf'
if (Test-Path -LiteralPath $integrity) {
    Write-Warn2 'integrity.conf is present in this directory (PGP-signed manifest).'
    Write-Warn2 'Installing will add files the manifest does not describe.'
    Write-Host ''
}

if (-not $PSCmdlet.ShouldProcess($GamePath, "Install BepInEx $Version (IL2CPP x64)")) {
    Write-Host 'Cancelled.' -ForegroundColor Yellow
    return
}

# --- backup -----------------------------------------------------------------

$backupRoot = Join-Path $PSScriptRoot ('..\..\backups\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$backupRoot = [System.IO.Path]::GetFullPath($backupRoot)
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

Write-Step "backing up to $backupRoot"

# Record the pre-install file list so uninstall can remove exactly what we added.
$manifestBefore = Get-ChildItem -LiteralPath $GamePath -Recurse -File |
    ForEach-Object { $_.FullName.Substring($GamePath.Length).TrimStart('\') }
$manifestBefore | Set-Content -LiteralPath (Join-Path $backupRoot 'files-before.txt') -Encoding UTF8

# Back up files BepInEx is known to replace at the game root.
foreach ($f in @('winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'integrity.conf', 'settings.json')) {
    $src = Join-Path $GamePath $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $backupRoot $f) -Force
        Write-Ok "backed up $f"
    }
}

@{
    GamePath      = $GamePath
    UnityVersion  = $unityVersion
    BepInExVersion= $Version
    InstalledAt   = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupRoot 'install.json') -Encoding UTF8

# --- download ---------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
    $DownloadUrl = "https://github.com/BepInEx/BepInEx/releases/download/v$Version/BepInEx-Unity.IL2CPP-win-x64-$Version.zip"
}

$tmp = Join-Path $env:TEMP ("bepinex-$Version.zip")
Write-Step "downloading $DownloadUrl"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $tmp -UseBasicParsing
} catch {
    throw "Download failed: $($_.Exception.Message)`nFetch the IL2CPP win-x64 zip manually and pass -DownloadUrl, or extract it into $GamePath yourself."
}

$zipHash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
Write-Ok "downloaded ($([math]::Round((Get-Item $tmp).Length/1MB,1)) MB)"
Write-Step "sha256  : $zipHash"
Set-Content -LiteralPath (Join-Path $backupRoot 'download.sha256') -Value $zipHash -Encoding UTF8

# --- extract ----------------------------------------------------------------

Write-Step "extracting into $GamePath"
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }   # directory
            $dest = Join-Path $GamePath $entry.FullName
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    } finally {
        $zip.Dispose()
    }
} catch {
    throw "Extract failed: $($_.Exception.Message)"
}

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
Write-Ok 'extracted'

# --- record what changed ----------------------------------------------------

$manifestAfter = Get-ChildItem -LiteralPath $GamePath -Recurse -File |
    ForEach-Object { $_.FullName.Substring($GamePath.Length).TrimStart('\') }
$added = Compare-Object -ReferenceObject $manifestBefore -DifferenceObject $manifestAfter |
    Where-Object { $_.SideIndicator -eq '=>' } |
    ForEach-Object { $_.InputObject }
$added | Set-Content -LiteralPath (Join-Path $backupRoot 'files-added.txt') -Encoding UTF8

Write-Ok "$($added.Count) files added (recorded for clean uninstall)"

# --- next steps -------------------------------------------------------------

Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next:' -ForegroundColor White
Write-Host '  1. Launch the game once and let it sit at the login screen for a few minutes.'
Write-Host '     BepInEx generates interop assemblies from GameAssembly.dll on first run;'
Write-Host '     this is slow and the game may appear frozen. Watch:'
Write-Host "       $GamePath\BepInEx\LogOutput.log" -ForegroundColor DarkGray
Write-Host '  2. Close the game, then build and deploy the runtime plugin:'
Write-Host "       .\Build-Plugin.ps1 -GamePath `"$GamePath`"" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'To revert completely:' -ForegroundColor White
Write-Host "  .\Uninstall-BepInEx.ps1 -GamePath `"$GamePath`" -BackupPath `"$backupRoot`"" -ForegroundColor DarkGray
Write-Host ''
