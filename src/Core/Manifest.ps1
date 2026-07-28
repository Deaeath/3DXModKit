# 3DXModKit - Mod manifest schema, capability model, and validation
#
# Every mod ships a mod.json. The loader refuses to run anything it cannot
# validate, and refuses outright to run anything declaring a capability in the
# forbidden namespace. That deny-list is the enforcement point for the
# client-side-only rule: a mod cannot touch the wire, the game protocol, or
# server-authoritative state, and it cannot opt itself back in via config.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Capability model
# ---------------------------------------------------------------------------
# Capabilities are declarative. The host grants them; the mod cannot widen its
# own grant at runtime. Anything not declared is not available.

$Script:ModKitCapabilities = @{
    # --- host tier (external, no injection) -------------------------------
    'process.query'         = 'Read process memory counters and window state'
    'process.priority'      = 'Adjust process priority / affinity'
    'memory.trim.self'      = 'Trim the working set of the game process (unprivileged)'
    'memory.trim.system'    = 'System-wide standby/modified-list purges (requires admin)'
    'fs.read.gamedata'      = 'Read game install + LocalLow data directories'
    'fs.write.config'       = 'Write within the modkit config directory only'
    'fs.write.gamedir'      = 'Write into the game install directory (integrity-affecting)'
    'input.hotkey'          = 'Register global hotkeys'
    'ui.console'            = 'Write to the modkit console/log'
    'ipc.runtime'           = 'Talk to the in-process runtime over the local named pipe (machine-local IPC, not a socket)'

    # --- runtime tier (in-process) ----------------------------------------
    'runtime.load'          = 'Load an assembly into the game process'
    'runtime.patch.client'  = 'Harmony-patch client-only types (rendering, UI, local cache)'
    'ui.overlay'            = 'Draw an in-game overlay'
}

# Hard deny-list. Declaring any of these fails validation unconditionally.
# There is deliberately no config switch to override this.
$Script:ModKitForbiddenCapabilityPrefixes = @(
    'net.'              # any socket / HTTP / wire access
    'game.protocol.'    # packet construction, parsing, replay
    'game.state.'       # server-authoritative state mutation
    'account.'          # credentials, session tokens, licensing
    'runtime.patch.net' # Harmony patches on networking types
)

# Namespaces a runtime-tier mod may never Harmony-patch. Enforced again inside
# the in-process plugin, so this is defence in depth rather than a lone gate.
$Script:ModKitForbiddenPatchNamespaces = @(
    'System.Net'
    'System.Net.Sockets'
    'System.Net.Http'
    'UnityEngine.Networking'
    'Photon'
    'LiteNetLib'
    'Telepathy'
    'Mirror'
    'BestHTTP'
    'WebSocketSharp'
)

function Get-ModKitCapabilityCatalog {
    <#
    .SYNOPSIS
        Returns the catalog of grantable capabilities and the forbidden prefixes.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        Grantable          = $Script:ModKitCapabilities
        ForbiddenPrefixes  = $Script:ModKitForbiddenCapabilityPrefixes
        ForbiddenNamespaces= $Script:ModKitForbiddenPatchNamespaces
    }
}

function Test-ModKitCapability {
    <#
    .SYNOPSIS
        Classifies a single capability string.
    .OUTPUTS
        PSCustomObject with Name, Known, Forbidden, Reason.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Capability)

    $forbidden = $false
    $reason    = $null
    foreach ($p in $Script:ModKitForbiddenCapabilityPrefixes) {
        if ($Capability -like "$p*") {
            $forbidden = $true
            $reason = "matches forbidden namespace '$p' (client-side-only policy)"
            break
        }
    }

    [pscustomobject]@{
        Name      = $Capability
        Known     = $Script:ModKitCapabilities.ContainsKey($Capability)
        Forbidden = $forbidden
        Reason    = $reason
    }
}

# ---------------------------------------------------------------------------
# Manifest parsing + validation
# ---------------------------------------------------------------------------

function ConvertTo-ModKitManifest {
    <#
    .SYNOPSIS
        Parses a mod.json into a normalised manifest object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        throw "Manifest is not valid JSON ($Path): $($_.Exception.Message)"
    }

    # Normalise optional collections so downstream code never null-checks.
    $caps = @()
    if ($json.PSObject.Properties.Name -contains 'capabilities' -and $json.capabilities) {
        $caps = @($json.capabilities)
    }
    $deps = @()
    if ($json.PSObject.Properties.Name -contains 'dependencies' -and $json.dependencies) {
        $deps = @($json.dependencies)
    }
    $conflicts = @()
    if ($json.PSObject.Properties.Name -contains 'conflicts' -and $json.conflicts) {
        $conflicts = @($json.conflicts)
    }

    $tier = 'host'
    if ($json.PSObject.Properties.Name -contains 'tier' -and $json.tier) { $tier = [string]$json.tier }

    $priority = 100
    if ($json.PSObject.Properties.Name -contains 'loadPriority' -and $null -ne $json.loadPriority) {
        $priority = [int]$json.loadPriority
    }

    $entry = $null
    if ($json.PSObject.Properties.Name -contains 'entry' -and $json.entry) { $entry = [string]$json.entry }

    $desc = ''
    if ($json.PSObject.Properties.Name -contains 'description' -and $json.description) {
        $desc = [string]$json.description
    }

    $author = ''
    if ($json.PSObject.Properties.Name -contains 'author' -and $json.author) {
        $author = [string]$json.author
    }

    $gameVer = $null
    if ($json.PSObject.Properties.Name -contains 'gameVersion' -and $json.gameVersion) {
        $gameVer = [string]$json.gameVersion
    }

    [pscustomobject]@{
        Id           = [string]$json.id
        Name         = [string]$json.name
        Version      = [string]$json.version
        Description  = $desc
        Author       = $author
        Tier         = $tier
        Entry        = $entry
        Capabilities = $caps
        Dependencies = $deps
        Conflicts    = $conflicts
        LoadPriority = $priority
        GameVersion  = $gameVer
        ManifestPath = (Resolve-Path -LiteralPath $Path).Path
        Root         = (Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path)
    }
}

function Test-ModKitManifest {
    <#
    .SYNOPSIS
        Validates a manifest. Returns an object with IsValid, Errors, Warnings.
    .DESCRIPTION
        Validation is total - it collects every problem rather than throwing on
        the first, so `modkit validate` can report a full picture.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Manifest
    )

    $errors   = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # --- required fields ---------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Manifest.Id)) {
        $errors.Add("'id' is required")
    } elseif ($Manifest.Id -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        $errors.Add("'id' must be kebab-case ([a-z0-9-]), got '$($Manifest.Id)'")
    }

    if ([string]::IsNullOrWhiteSpace($Manifest.Name)) { $errors.Add("'name' is required") }

    if ([string]::IsNullOrWhiteSpace($Manifest.Version)) {
        $errors.Add("'version' is required")
    } elseif ($Manifest.Version -notmatch '^\d+\.\d+\.\d+') {
        $errors.Add("'version' must be semver-like (x.y.z), got '$($Manifest.Version)'")
    }

    if ($Manifest.Tier -notin @('host','runtime')) {
        $errors.Add("'tier' must be 'host' or 'runtime', got '$($Manifest.Tier)'")
    }

    # --- entry point -------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Manifest.Entry)) {
        $errors.Add("'entry' is required")
    } else {
        $entryPath = Join-Path $Manifest.Root $Manifest.Entry
        if (-not (Test-Path -LiteralPath $entryPath)) {
            $errors.Add("entry point not found: $($Manifest.Entry)")
        }
    }

    # --- capability validation (the client-side-only gate) -----------------
    if ($Manifest.Capabilities.Count -eq 0) {
        $warnings.Add("declares no capabilities - it will be able to do nothing")
    }
    foreach ($cap in $Manifest.Capabilities) {
        $c = Test-ModKitCapability -Capability $cap
        if ($c.Forbidden) {
            $errors.Add("REFUSED capability '$cap': $($c.Reason)")
        } elseif (-not $c.Known) {
            $errors.Add("unknown capability '$cap' (not in catalog)")
        }
    }

    # --- tier/capability coherence ----------------------------------------
    $runtimeCaps = @($Manifest.Capabilities | Where-Object { $_ -like 'runtime.*' -or $_ -eq 'ui.overlay' })
    if ($Manifest.Tier -eq 'host' -and $runtimeCaps.Count -gt 0) {
        $errors.Add("tier 'host' cannot declare in-process capabilities: $($runtimeCaps -join ', ')")
    }
    if ($Manifest.Tier -eq 'runtime' -and $Manifest.Capabilities -notcontains 'runtime.load') {
        $errors.Add("tier 'runtime' must declare 'runtime.load'")
    }

    # --- integrity warning -------------------------------------------------
    if ($Manifest.Capabilities -contains 'fs.write.gamedir') {
        $warnings.Add("declares 'fs.write.gamedir' - writes into the game install will diverge from the signed integrity.conf")
    }

    [pscustomobject]@{
        Manifest = $Manifest
        IsValid  = ($errors.Count -eq 0)
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
    }
}
