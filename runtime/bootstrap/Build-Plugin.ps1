<#
.SYNOPSIS
    Builds ModKit.Runtime against the local BepInEx install and deploys it.

.DESCRIPTION
    The plugin references the interop assemblies BepInEx generated from *this*
    game build, so the game must have been launched once after installing
    BepInEx before this will compile.

    Requires a .NET SDK that can target netstandard2.1 (SDK 5.0+).

.EXAMPLE
    .\Build-Plugin.ps1 -GamePath "C:\...\3DXChat\Game"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [ValidateSet('Debug','Release')][string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bepinex = Join-Path $GamePath 'BepInEx'
if (-not (Test-Path -LiteralPath $bepinex)) {
    throw "BepInEx not found at $bepinex. Run Install-BepInEx.ps1 first."
}

$interop = Join-Path $bepinex 'interop'
if (-not (Test-Path -LiteralPath $interop)) {
    throw @"
Interop assemblies not generated yet: $interop

Launch the game once with BepInEx installed and let it reach the login screen.
BepInEx dumps the IL2CPP metadata into interop\ on first run; it can take
several minutes and the game may look frozen while it works.
"@
}

$core = Join-Path $bepinex 'core'
foreach ($dll in @('BepInEx.Core.dll','BepInEx.Unity.IL2CPP.dll','Il2CppInterop.Runtime.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $core $dll))) {
        throw "Missing $dll in $core - is this the IL2CPP build of BepInEx 6?"
    }
}

# Verify the SDK can target netstandard2.1.
$sdk = (dotnet --version)
Write-Host "dotnet SDK: $sdk" -ForegroundColor Cyan
if ([version](($sdk -split '-')[0]) -lt [version]'5.0.0') {
    throw "dotnet SDK $sdk cannot target netstandard2.1. Install SDK 5.0 or newer."
}

$proj = Join-Path $PSScriptRoot '..\src\ModKit.Runtime\ModKit.Runtime.csproj'
$proj = [System.IO.Path]::GetFullPath($proj)

Write-Host "building $proj" -ForegroundColor Cyan
& dotnet build $proj -c $Configuration "-p:BepInExPath=$bepinex" --nologo
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

$built = Join-Path (Split-Path $proj -Parent) "bin\$Configuration\netstandard2.1\ModKit.Runtime.dll"
if (-not (Test-Path -LiteralPath $built)) { throw "Build reported success but $built is missing." }

$pluginDir = Join-Path $bepinex 'plugins\3DXModKit'
New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
Copy-Item -LiteralPath $built -Destination $pluginDir -Force

Write-Host ''
Write-Host "Deployed to $pluginDir" -ForegroundColor Green
Write-Host 'Launch the game, then confirm the runtime came up:' -ForegroundColor White
Write-Host "  Select-String -Path `"$bepinex\LogOutput.log`" -Pattern '3DXModKit'" -ForegroundColor DarkGray
