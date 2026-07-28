<#
.SYNOPSIS
    Relocates 3DXModKit into the 3DXChat-Debug-Toolkit repository.

.DESCRIPTION
    3DXModKit was built at %USERPROFILE%\3DXModKit because Windows Defender
    Controlled Folder Access is enabled on this machine and blocks all writes
    under Documents\. CFA denies writes with a misleading "Could not find file"
    error rather than an access-denied, which is why this is worth stating
    explicitly.

    Once writes to Documents\ are possible again, this script moves the tree
    into the toolkit repo.

    To allow writes, pick one (both need Administrator):

      1. Allow the app through CFA - keeps protection on:
           Add-MpPreference -ControlledFolderAccessAllowedApplications `
             "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

      2. Turn CFA off entirely - reduces protection on all your user folders:
           Set-MpPreference -EnableControlledFolderAccess Disabled

    Option 1 is the narrower change. Neither is done for you; both are
    security-boundary decisions and yours to make.

.PARAMETER ToolkitPath
    The 3DXChat-Debug-Toolkit repository root.

.PARAMETER Copy
    Copy instead of move, leaving the source in place.

.EXAMPLE
    .\Install-ToToolkit.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ToolkitPath = "$env:USERPROFILE\Documents\3DXChat-Debug-Toolkit",
    [switch]$Copy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
$dest   = Join-Path $ToolkitPath 'modkit'

if (-not (Test-Path -LiteralPath $ToolkitPath)) {
    throw "Toolkit not found: $ToolkitPath"
}

# Probe writability directly - CFA does not surface as an ACL denial, so
# checking permissions would report success and the copy would still fail.
$probe = Join-Path $ToolkitPath ("_probe_{0}.tmp" -f [guid]::NewGuid().ToString('N').Substring(0,8))
try {
    [IO.File]::WriteAllText($probe, 'probe')
    Remove-Item -LiteralPath $probe -Force
    Write-Host "Destination is writable." -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Cannot write to $ToolkitPath" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Controlled Folder Access is almost certainly the cause.' -ForegroundColor Yellow
    Write-Host 'From an elevated shell, either allow PowerShell:' -ForegroundColor White
    Write-Host '  Add-MpPreference -ControlledFolderAccessAllowedApplications "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"' -ForegroundColor DarkGray
    Write-Host 'or disable the feature (broader impact):' -ForegroundColor White
    Write-Host '  Set-MpPreference -EnableControlledFolderAccess Disabled' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "3DXModKit keeps working where it is: $source" -ForegroundColor Cyan
    return
}

if (Test-Path -LiteralPath $dest) {
    throw "$dest already exists. Remove or rename it first."
}

$verb = if ($Copy) { 'Copy' } else { 'Move' }
if (-not $PSCmdlet.ShouldProcess($dest, "$verb 3DXModKit")) { return }

if ($Copy) {
    Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
} else {
    Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
    Write-Host 'Copied. Verify it runs, then delete the original:' -ForegroundColor Yellow
    Write-Host "  Remove-Item -Recurse -Force `"$source`"" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host "3DXModKit is now at $dest" -ForegroundColor Green
Write-Host 'Run it with:' -ForegroundColor White
Write-Host "  cd `"$dest`"; .\modkit.ps1 status" -ForegroundColor DarkGray
