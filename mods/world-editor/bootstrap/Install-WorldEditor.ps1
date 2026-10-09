<#
.SYNOPSIS
    Downloads and installs 3DX World Editor from its GitHub releases.

.DESCRIPTION
    Runs outside the mod loader's capability gate on purpose, same as the
    other bootstrap scripts: the mod itself never touches the network, this
    explicitly-run script does, once.

    What it does, in order:
      1. asks GitHub for the latest release of Deaeath/3dx-world-editor
      2. downloads 3DXWorldEditor.exe and SHA256SUMS.txt
      3. refuses to continue unless the exe's SHA-256 matches
      4. asks before installing (skip with -Yes)
      5. copies it to %LOCALAPPDATA%\Programs\3DX World Editor and adds a
         Start menu shortcut

    Running it again updates to the latest release. Nothing needs admin.

.PARAMETER Yes
    Install without the confirmation prompt.

.PARAMETER Open
    Start the editor when done.

.PARAMETER NoShortcut
    Skip the Start menu shortcut.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Open,
    [switch]$NoShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'Deaeath/3dx-world-editor'
$dir = Join-Path $env:LOCALAPPDATA 'Programs\3DX World Editor'
$exe = Join-Path $dir '3DXWorldEditor.exe'

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = '3DXModKit' }
$version = $release.tag_name.TrimStart('v')
$asset = $release.assets | Where-Object { $_.name -eq '3DXWorldEditor.exe' } | Select-Object -First 1
$sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
if (-not $asset -or -not $sums) { throw "Release $($release.tag_name) has no 3DXWorldEditor.exe or SHA256SUMS.txt." }

$installed = $null
$versionFile = Join-Path $dir 'version.txt'
if (Test-Path -LiteralPath $versionFile) { $installed = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }
if ($installed -eq $version -and (Test-Path -LiteralPath $exe)) {
    Write-Host "3DX World Editor $version is already installed and up to date." -ForegroundColor Green
    if ($Open) { Start-Process -FilePath $exe -WorkingDirectory $dir }
    return
}

$tmp = Join-Path $env:TEMP "3DXWorldEditor-$version.exe"
Write-Host "Downloading $($asset.name) from $repo $($release.tag_name)..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
$sumText = (Invoke-WebRequest -Uri $sums.browser_download_url -UseBasicParsing).Content
if ($sumText -is [byte[]]) { $sumText = [System.Text.Encoding]::UTF8.GetString($sumText) }

$expected = $null
foreach ($line in ($sumText -split "`r?`n")) {
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $asset.name) { $expected = $Matches[1] }
}
$actual = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
if (-not $expected) { throw "SHA256SUMS.txt has no entry for $($asset.name) - not installing." }
if ($actual -ne $expected.ToUpperInvariant()) { throw "Checksum mismatch for $($asset.name) - not installing. Expected $expected, got $actual." }
Write-Host "Checksum OK ($actual)." -ForegroundColor Green

if (-not $Yes) {
    $what = if ($installed) { "update from $installed to $version" } else { "install $version" }
    $answer = Read-Host "3DX World Editor: ${what} in $dir? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; return }
}

if (@(Get-Process -Name '3DXWorldEditor' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw '3DX World Editor is running - close its window, then run this again.'
}
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -LiteralPath $tmp -Destination $exe -Force
Set-Content -LiteralPath $versionFile -Value $version -Encoding ASCII
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) '3DX World Editor.lnk'
if (-not $NoShortcut) { try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($startMenu)
    $link.TargetPath = $exe
    $link.WorkingDirectory = $dir
    $link.Description = 'Edit 3DXChat worlds in 3D'
    $link.Save()
} catch {
    Write-Host "Couldn't add the Start menu shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
} }

$where = if ($NoShortcut) { "the modkit's Mods tab opens it" } else { "it's in the Start menu, and the modkit's Mods tab opens it" }
Write-Host "Installed 3DX World Editor $version - $where." -ForegroundColor Green
Write-Host 'The first time it opens it reads the game''s models (about two minutes), then opens the editor in your browser.'
if ($Open) { Start-Process -FilePath $exe -WorkingDirectory $dir }
