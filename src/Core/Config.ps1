# 3DXModKit - Layered configuration
#
# Precedence, lowest to highest:
#   1. mod's own config.default.json   (shipped with the mod)
#   2. active profile's per-mod block  (the "modpack" definition)
#   3. user override in config/<mod-id>.json
#
# Merging is a deep merge on objects; scalars and arrays replace wholesale.

Set-StrictMode -Version Latest

function Merge-ModKitHashtable {
    <#
    .SYNOPSIS
        Deep-merges $Override onto $Base, returning a new hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$Base,
        [Parameter(Mandatory)][AllowNull()][hashtable]$Override
    )

    if ($null -eq $Base)     { $Base = @{} }
    if ($null -eq $Override) { return $Base.Clone() }

    $result = $Base.Clone()
    foreach ($key in $Override.Keys) {
        $ov = $Override[$key]
        if ($result.ContainsKey($key) -and
            $result[$key] -is [hashtable] -and $ov -is [hashtable]) {
            $result[$key] = Merge-ModKitHashtable -Base $result[$key] -Override $ov
        } else {
            $result[$key] = $ov
        }
    }
    return $result
}

function ConvertTo-ModKitHashtable {
    <#
    .SYNOPSIS
        Recursively converts PSCustomObject (from ConvertFrom-Json) to hashtable.
    .DESCRIPTION
        PowerShell 5.1's ConvertFrom-Json has no -AsHashtable, and deep-merging
        PSCustomObjects is painful, so everything is normalised on the way in.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }

    # Order matters: test the concrete container types before falling back to
    # the scalar case. Testing -is [psobject] first would match everything,
    # since PowerShell adapts every value into a PSObject.

    if ($InputObject -is [hashtable]) {
        $ht = @{}
        foreach ($key in $InputObject.Keys) {
            $ht[$key] = ConvertTo-ModKitHashtable -InputObject $InputObject[$key]
        }
        return $ht
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-ModKitHashtable -InputObject $prop.Value
        }
        return $ht
    }

    # Arrays only - strings are IEnumerable too and must stay scalar.
    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($item in $InputObject) { $list += ,(ConvertTo-ModKitHashtable -InputObject $item) }
        return ,$list
    }

    return $InputObject
}

function Read-ModKitJsonFile {
    <#
    .SYNOPSIS
        Reads a JSON file into a hashtable, or $null when absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        return ConvertTo-ModKitHashtable -InputObject ($raw | ConvertFrom-Json)
    } catch {
        throw "Invalid JSON in $Path : $($_.Exception.Message)"
    }
}

function Get-ModKitModConfig {
    <#
    .SYNOPSIS
        Resolves the effective configuration for one mod.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Manifest,
        [Parameter(Mandatory)][string]$ConfigRoot,
        [AllowNull()][hashtable]$ProfileConfig
    )

    $defaults = Read-ModKitJsonFile -Path (Join-Path $Manifest.Root 'config.default.json')
    if ($null -eq $defaults) { $defaults = @{} }

    $merged = Merge-ModKitHashtable -Base $defaults -Override $ProfileConfig

    $userPath = Join-Path $ConfigRoot ($Manifest.Id + '.json')
    $user = Read-ModKitJsonFile -Path $userPath
    $merged = Merge-ModKitHashtable -Base $merged -Override $user

    return $merged
}

function Get-ModKitProfile {
    <#
    .SYNOPSIS
        Loads a profile ("modpack"): a named set of enabled mods plus their config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilesPath,
        [Parameter(Mandatory)][string]$Name
    )

    $path = Join-Path $ProfilesPath "$Name.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Profile '$Name' not found at $path"
    }

    $p = Read-ModKitJsonFile -Path $path
    if ($null -eq $p) { throw "Profile '$Name' is empty" }

    $enabled = @()
    if ($p.ContainsKey('enabled') -and $p['enabled']) { $enabled = @($p['enabled']) }

    $modConfigs = @{}
    if ($p.ContainsKey('config') -and $p['config'] -is [hashtable]) { $modConfigs = $p['config'] }

    $desc = ''
    if ($p.ContainsKey('description')) { $desc = [string]$p['description'] }

    [pscustomobject]@{
        Name        = $Name
        Description = $desc
        Enabled     = $enabled
        ModConfigs  = $modConfigs
        Path        = $path
    }
}
