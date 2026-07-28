<#
.SYNOPSIS
    Removes BepInEx and the 3DXModKit runtime plugin from the game directory.

.DESCRIPTION
    Uses the files-added.txt manifest recorded by Install-BepInEx.ps1 to delete
    exactly what was added, then restores any files that were overwritten. If
    the backup is unavailable, -Aggressive falls back to removing the known
    BepInEx footprint.

.EXAMPLE
    .\Uninstall-BepInEx.ps1 -GamePath "C:\...\Game" -BackupPath "..\..\backups\20260728-051500"

.EXAMPLE
    .\Uninstall-BepInEx.ps1 -GamePath "C:\...\Game" -Aggressive
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [string]$BackupPath,
    [switch]$Aggressive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $GamePath)) { throw "Game path not found: $GamePath" }
if (Get-Process -Name '3DXChat' -ErrorAction SilentlyContinue) {
    throw "3DXChat is running. Close the game first."
}

if (-not $PSCmdlet.ShouldProcess($GamePath, 'Remove BepInEx and restore original files')) {
    Write-Host 'Cancelled.' -ForegroundColor Yellow
    return
}

$removed = 0

# --- manifest-driven removal (preferred) ------------------------------------

if ($BackupPath -and (Test-Path -LiteralPath (Join-Path $BackupPath 'files-added.txt'))) {
    Write-Host "Using manifest from $BackupPath" -ForegroundColor Cyan

    $added = Get-Content -LiteralPath (Join-Path $BackupPath 'files-added.txt') -Encoding UTF8
    foreach ($rel in $added) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $full = Join-Path $GamePath $rel
        if (Test-Path -LiteralPath $full) {
            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }

    # Restore anything the install overwrote.
    foreach ($f in @('winhttp.dll','doorstop_config.ini','.doorstop_version','integrity.conf','settings.json')) {
        $bak = Join-Path $BackupPath $f
        if (Test-Path -LiteralPath $bak) {
            Copy-Item -LiteralPath $bak -Destination (Join-Path $GamePath $f) -Force
            Write-Host "  restored $f" -ForegroundColor Green
        }
    }

} elseif ($Aggressive) {
    Write-Host 'No manifest - removing the known BepInEx footprint.' -ForegroundColor Yellow

    foreach ($item in @('BepInEx','dotnet','winhttp.dll','doorstop_config.ini','.doorstop_version','changelog.txt')) {
        $full = Join-Path $GamePath $item
        if (Test-Path -LiteralPath $full) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  removed $item" -ForegroundColor Green
            $removed++
        }
    }
} else {
    throw "No -BackupPath given and -Aggressive not set. Refusing to guess what to delete."
}

# Prune empty directories left behind.
Get-ChildItem -LiteralPath $GamePath -Recurse -Directory -ErrorAction SilentlyContinue |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object {
        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

Write-Host ''
Write-Host "Removed $removed items. Game directory restored." -ForegroundColor Green
Write-Host 'If the launcher still reports a mismatch, run its own repair/verify to re-fetch originals.' -ForegroundColor DarkGray
