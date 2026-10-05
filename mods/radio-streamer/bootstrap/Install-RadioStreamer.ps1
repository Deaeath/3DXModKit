<#
.SYNOPSIS
    Downloads and installs 3DX Radio Streamer from its GitHub releases.

.DESCRIPTION
    Runs outside the mod loader's capability gate on purpose, same as the
    reshade and lossless-scaling bootstrap scripts: the mod itself never
    touches the network, this explicitly-run script does, once.

    What it does, in order:
      1. asks GitHub for the latest release of Deaeath/3dx-radio-streamer
      2. downloads the installer (...-setup.exe) and SHA256SUMS.txt
      3. refuses to continue unless the installer's SHA-256 matches
      4. asks before running it (skip with -Yes)

    The installer is per-user by default (no admin prompt) and adds an
    uninstall entry, which is how the radio-streamer mod finds it.

.PARAMETER Yes
    Install without the confirmation prompt.

.PARAMETER Portable
    Download the portable zip and unzip it to -Destination instead of
    running the installer. Set the mod's installPath to the exe it reports.

.PARAMETER Destination
    Where -Portable unzips to.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Portable,
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\3DX Radio Streamer (portable)')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'Deaeath/3dx-radio-streamer'
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = '3DXModKit' }
$pattern = if ($Portable) { '-win64-portable\.zip$' } else { '-setup\.exe$' }
$asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
$sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
if (-not $asset -or -not $sums) { throw "Release $($release.tag_name) has no $pattern asset or SHA256SUMS.txt." }

$work = Join-Path $env:TEMP "3dxmodkit-radio-$($release.tag_name)"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$file = Join-Path $work $asset.name
Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB) from $repo $($release.tag_name)..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing
$sumText = (Invoke-WebRequest -Uri $sums.browser_download_url -UseBasicParsing).Content
if ($sumText -is [byte[]]) { $sumText = [System.Text.Encoding]::UTF8.GetString($sumText) }

$expected = $null
foreach ($line in ($sumText -split "`r?`n")) {
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $asset.name) { $expected = $Matches[1] }
}
$actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
if (-not $expected) { throw "SHA256SUMS.txt has no entry for $($asset.name) - not installing." }
if ($actual -ne $expected.ToUpperInvariant()) { throw "Checksum mismatch for $($asset.name) - not installing. Expected $expected, got $actual." }
Write-Host "Checksum OK ($actual)." -ForegroundColor Green

if (-not $Yes) {
    $what = if ($Portable) { "unzip it to $Destination" } else { 'run the installer' }
    $answer = Read-Host "Install 3DX Radio Streamer $($release.tag_name) - ${what}? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; return }
}

if ($Portable) {
    Expand-Archive -LiteralPath $file -DestinationPath $Destination -Force
    $exe = Get-ChildItem -LiteralPath $Destination -Recurse -Filter '3DX Radio Streamer.exe' | Select-Object -First 1
    Write-Host "Unzipped. Set installPath in the radio-streamer mod's config to:" -ForegroundColor Green
    Write-Host "  $($exe.FullName)"
} else {
    $p = Start-Process -FilePath $file -ArgumentList '/SILENT', '/CURRENTUSER' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "The installer exited with code $($p.ExitCode)." }
    Write-Host 'Installed. Open 3DX Radio Streamer from the Start menu and follow its setup wizard.' -ForegroundColor Green
}
