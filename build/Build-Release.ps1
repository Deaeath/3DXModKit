<#
.SYNOPSIS
    Builds a release: the zip the in-app updater downloads, and the installer.

.DESCRIPTION
    Stages the committed tree with git archive, so stray local files never
    ship, compiles 3dxGC.exe into it, then writes to dist\:

      3DXModKit-v<ver>.zip     the folder under 3DXModKit\, which the in-app
                               updater (and anyone unzipping by hand) expects
      3dxGC-Setup-<ver>.exe    the per-user installer, from build\3dxGC.iss
      SHA256SUMS.txt

    The version is the module manifest's.

    Needs Inno Setup 6 (winget install JRSoftware.InnoSetup) and the .NET
    Framework 4 csc.exe that ships with Windows.

.PARAMETER Uncommitted
    Builds from the working tree's tracked and staged changes instead of
    HEAD - for testing before a commit. Untracked files are still left out.
#>
[CmdletBinding()]
param(
    [switch]$Uncommitted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$stageParent = Join-Path $dist 'stage'
$stage = Join-Path $stageParent '3DXModKit'

$version = (Test-ModuleManifest -Path (Join-Path $root '3DXModKit.psd1')).Version.ToString()

$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found - winget install JRSoftware.InnoSetup' }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc" }

# Runs a native tool and returns its standard output. Windows PowerShell
# under 'Stop' turns any stderr line - git's line-ending warnings, say -
# into a terminating error, so here the exit code alone decides.
function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $errors = New-Object System.Collections.Generic.List[string]
    $out = & $Exe @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { $errors.Add("$_") } else { "$_" }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path -Leaf $Exe) failed ($LASTEXITCODE):`n$((@($out) + $errors) -join "`n")"
    }
    $out
}

# --- stage ------------------------------------------------------------------
$rev = 'HEAD'
if ($Uncommitted) {
    # A commit object of the working tree, made without touching the branch,
    # the index or any file. Empty when nothing has changed.
    $stash = Invoke-Tool git @('-C', $root, 'stash', 'create')
    if ($stash) { $rev = $stash }
}

if (Test-Path -LiteralPath $stageParent) { Remove-Item -LiteralPath $stageParent -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stageParent | Out-Null
$archive = Join-Path $stageParent 'tree.zip'
Invoke-Tool git @('-C', $root, 'archive', '--format=zip', '--prefix=3DXModKit/', '-o', $archive, $rev) | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $stageParent)
Remove-Item -LiteralPath $archive

# --- 3dxGC.exe ----------------------------------------------------------------
$versionCs = Join-Path $stageParent 'Version.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("3dxGC")]
[assembly: AssemblyProduct("3dxGC")]
[assembly: AssemblyCompany("Deaeath")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
"@ | Set-Content -LiteralPath $versionCs -Encoding UTF8

Invoke-Tool $csc @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/win32icon:$(Join-Path $stage 'gui\3dxGC.ico')",
    "/out:$(Join-Path $stage '3dxGC.exe')",
    '/reference:System.Windows.Forms.dll',
    (Join-Path $PSScriptRoot 'Launcher\Launcher.cs'), $versionCs
) | Out-Null
Remove-Item -LiteralPath $versionCs

# --- zip ----------------------------------------------------------------------
$zip = Join-Path $dist "3DXModKit-v$version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
# Windows' own tar, not ZipFile: under PowerShell 5.1 ZipFile writes
# backslashes into entry names, which only Windows reads as folders.
Invoke-Tool (Join-Path $env:WINDIR 'System32\tar.exe') @('-a', '-cf', $zip, '-C', $stageParent, '3DXModKit') | Out-Null

# --- installer ----------------------------------------------------------------
Invoke-Tool $iscc @('/Qp', "/DAppVersion=$version", "/DStageDir=$stage", (Join-Path $PSScriptRoot '3dxGC.iss')) | Out-Null
$setup = Join-Path $dist "3dxGC-Setup-$version.exe"

# --- checksums ----------------------------------------------------------------
$sums = foreach ($f in $zip, $setup) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Leaf $f)
}
$sums | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ASCII

Remove-Item -LiteralPath $stageParent -Recurse -Force
Get-Item -LiteralPath $zip, $setup | ForEach-Object { '{0}  {1:N1} MB' -f $_.Name, ($_.Length / 1MB) }
