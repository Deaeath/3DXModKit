# 3DXModKit - module entry point
#
# A modular, client-side-only mod framework for 3DXChat (Unity 2021.3.45f2, IL2CPP).
#
# Mod contract
# ------------
# A mod's entry script is *invoked* (not dot-sourced) and must return a hashtable:
#
#     @{
#         Initialize = { param($ctx) ... }   # required - subscribe to events here
#         Shutdown   = { param($ctx) ... }   # optional
#     }
#
# Invoking rather than dot-sourcing keeps each mod in its own scope, so two mods
# defining a helper of the same name cannot clobber each other.

Set-StrictMode -Version Latest

$Script:ModKitRoot = $PSScriptRoot

# --- load native layer once -------------------------------------------------
if (-not ('ThreeDX.ModKit.Native.MemOps' -as [type])) {
    $nativeSrc = Join-Path $PSScriptRoot 'src\Native\MemoryApi.cs'
    if (-not (Test-Path -LiteralPath $nativeSrc)) {
        throw "Native source missing: $nativeSrc"
    }
    Add-Type -TypeDefinition (Get-Content -LiteralPath $nativeSrc -Raw) -Language CSharp
}

# --- dot-source framework ---------------------------------------------------
. (Join-Path $PSScriptRoot 'src\Core\Manifest.ps1')
. (Join-Path $PSScriptRoot 'src\Core\Resolver.ps1')
. (Join-Path $PSScriptRoot 'src\Core\Config.ps1')
. (Join-Path $PSScriptRoot 'src\Host\Runtime.ps1')

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-ModKitInfo {
    <#
    .SYNOPSIS
        Framework, game, and environment summary.
    #>
    [CmdletBinding()]
    param()

    $sys = [ThreeDX.ModKit.Native.MemOps]::GetSystemMemory()
    $game = @(Get-Process -Name '3DXChat' -ErrorAction SilentlyContinue)

    [pscustomobject]@{
        ModKitVersion = '1.0.0'
        ModKitRoot    = $Script:ModKitRoot
        Elevated      = [ThreeDX.ModKit.Native.MemOps]::IsElevated()
        TotalRamGB    = $sys.TotalPhysGB
        AvailRamGB    = $sys.AvailPhysGB
        AvailPercent  = $sys.AvailPercent
        MemoryLoad    = $sys.MemoryLoadPercent
        GameRunning   = ($game.Count -gt 0)
        GamePid       = $(if ($game.Count -gt 0) { $game[0].Id } else { 0 })
    }
}

function Test-ModKitMods {
    <#
    .SYNOPSIS
        Validates every installed mod and reports capability violations.
    #>
    [CmdletBinding()]
    param(
        [string]$ModsPath = (Join-Path $Script:ModKitRoot 'mods')
    )

    $all = Get-ModKitMods -ModsPath $ModsPath
    foreach ($v in $all) {
        [pscustomobject]@{
            Id       = $v.Manifest.Id
            Name     = $v.Manifest.Name
            Version  = $v.Manifest.Version
            Tier     = $v.Manifest.Tier
            Valid    = $v.IsValid
            Errors   = ($v.Errors -join '; ')
            Warnings = ($v.Warnings -join '; ')
        }
    }
}

function Invoke-ModKitEmpty {
    <#
    .SYNOPSIS
        Fires RAMMap's Empty operations on demand.
    .DESCRIPTION
        -Target Game        trims only the 3DXChat working set (no elevation needed)
        -Target All         every system-wide Empty operation (needs admin)
        -Target WorkingSets|SystemWorkingSet|ModifiedList|Standby|LowPriorityStandby
                            one specific operation
    .EXAMPLE
        Invoke-ModKitEmpty -Target Game
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Game','All','WorkingSets','SystemWorkingSet','ModifiedList','Standby','LowPriorityStandby')]
        [string]$Target = 'Game'
    )

    $M = [ThreeDX.ModKit.Native.MemOps]
    $before = $M::GetSystemMemory()

    $results = switch ($Target) {
        'Game'               { @($M::TrimProcessesByName('3DXChat')) }
        'All'                { $M::EmptyAll() }
        'WorkingSets'        { @($M::EmptyAllWorkingSets()) }
        'SystemWorkingSet'   { @($M::EmptySystemWorkingSet()) }
        'ModifiedList'       { @($M::FlushModifiedPageList()) }
        'Standby'            { @($M::PurgeStandbyList()) }
        'LowPriorityStandby' { @($M::PurgeLowPriorityStandby()) }
    }

    Start-Sleep -Milliseconds 250
    $after = $M::GetSystemMemory()

    foreach ($r in $results) {
        [pscustomobject]@{
            Operation = $r.Operation
            Success   = $r.Success
            FreedMB   = $r.FreedMB
            Ms        = $r.DurationMs
            Error     = $r.Error
        }
    }

    Write-Host ''
    Write-Host ("Available RAM: {0} GB -> {1} GB  (net {2} MB)" -f `
        $before.AvailPhysGB, $after.AvailPhysGB,
        [math]::Round(($after.AvailPhysBytes - $before.AvailPhysBytes)/1MB,1)) -ForegroundColor Cyan
}

function Start-ModKit {
    <#
    .SYNOPSIS
        Loads a profile's mods and runs the host loop.
    .EXAMPLE
        Start-ModKit -Profile default
    #>
    [CmdletBinding()]
    param(
        [string]$ProfileName = 'default',
        [string]$ModsPath    = (Join-Path $Script:ModKitRoot 'mods'),
        [string]$ProfilesPath= (Join-Path $Script:ModKitRoot 'profiles'),
        [int]$TickSeconds    = 5,
        [ValidateSet('Debug','Info','Warn','Error')][string]$LogLevel = 'Info',

        # Overridable so the pipeline can be exercised against a stand-in
        # process, and so a renamed or repackaged client still works.
        [string]$GameProcessName = '3DXChat'
    )

    $logDir = Join-Path $Script:ModKitRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $logPath = Join-Path $logDir ("modkit-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

    $logger = New-ModKitLogger -LogPath $logPath -Level $LogLevel
    $bus    = New-ModKitEventBus
    $hostObj= New-ModKitHost -RootPath $Script:ModKitRoot -Logger $logger -Bus $bus -GameProcessName $GameProcessName

    $logger.Info('modkit', "3DXModKit 1.0.0 starting (profile '$ProfileName')")
    if (-not [ThreeDX.ModKit.Native.MemOps]::IsElevated()) {
        $logger.Warn('modkit', 'not elevated - system-wide purges unavailable, per-process trimming still works')
    }

    # --- profile ----------------------------------------------------------
    $profileObj = Get-ModKitProfile -ProfilesPath $ProfilesPath -Name $ProfileName
    $logger.Info('modkit', "profile: $($profileObj.Description)")

    # --- discover + validate ---------------------------------------------
    $discovered = Get-ModKitMods -ModsPath $ModsPath
    $enabled = @()
    foreach ($v in $discovered) {
        if ($profileObj.Enabled -notcontains $v.Manifest.Id) {
            $logger.Debug('modkit', "skipping '$($v.Manifest.Id)' (not in profile)")
            continue
        }
        foreach ($w in $v.Warnings) { $logger.Warn($v.Manifest.Id, $w) }
        if (-not $v.IsValid) {
            foreach ($e in $v.Errors) { $logger.Error($v.Manifest.Id, $e) }
            $logger.Error('modkit', "refusing to load '$($v.Manifest.Id)'")
            continue
        }
        $enabled += $v.Manifest
    }

    if ($enabled.Count -eq 0) {
        $logger.Error('modkit', 'no valid mods to load - exiting')
        return
    }

    # --- order ------------------------------------------------------------
    $resolved = Resolve-ModKitLoadOrder -Manifests $enabled
    foreach ($w in $resolved.Warnings) { $logger.Warn('modkit', $w) }
    if ($resolved.Errors.Count -gt 0) {
        foreach ($e in $resolved.Errors) { $logger.Error('modkit', $e) }
        return
    }

    $logger.Info('modkit', "load order: $(($resolved.Order | ForEach-Object { $_.Id }) -join ' -> ')")

    # --- initialise -------------------------------------------------------
    foreach ($manifest in $resolved.Order) {
        $profileCfg = $null
        if ($profileObj.ModConfigs.ContainsKey($manifest.Id)) {
            $profileCfg = $profileObj.ModConfigs[$manifest.Id]
        }
        $cfg = Get-ModKitModConfig -Manifest $manifest -ConfigRoot $hostObj.ConfigRoot -ProfileConfig $profileCfg
        $ctx = New-ModKitContext -Manifest $manifest -Config $cfg -Bus $bus -Logger $logger -HostObject $hostObj

        try {
            $entryPath = Join-Path $manifest.Root $manifest.Entry
            $mod = & $entryPath
            if ($null -eq $mod -or -not $mod.ContainsKey('Initialize')) {
                throw "entry script did not return a hashtable with an Initialize block"
            }
            & $mod.Initialize $ctx
            $hostObj.LoadedMods[$manifest.Id] = [pscustomobject]@{
                Manifest = $manifest; Context = $ctx; Mod = $mod
            }
            $logger.Info('modkit', "loaded $($manifest.Id) v$($manifest.Version) [$($manifest.Capabilities -join ', ')]")
        } catch {
            $logger.Error($manifest.Id, "failed to load: $($_.Exception.Message)")
            $bus.Unsubscribe($manifest.Id)
        }
    }

    if ($hostObj.LoadedMods.Count -eq 0) {
        $logger.Error('modkit', 'every mod failed to load - exiting')
        return
    }

    # --- run --------------------------------------------------------------
    try {
        Start-ModKitLoop -HostObject $hostObj -TickSeconds $TickSeconds
    } finally {
        foreach ($entry in $hostObj.LoadedMods.Values) {
            if ($entry.Mod.ContainsKey('Shutdown')) {
                try { & $entry.Mod.Shutdown $entry.Context }
                catch { $logger.Error($entry.Manifest.Id, "shutdown threw: $($_.Exception.Message)") }
            }
        }
        $logger.Info('modkit', 'stopped')
    }
}

Export-ModuleMember -Function @(
    'Get-ModKitInfo'
    'Test-ModKitMods'
    'Invoke-ModKitEmpty'
    'Start-ModKit'
    'Get-ModKitCapabilityCatalog'
    'Get-ModKitMods'
    'Resolve-ModKitLoadOrder'
    'ConvertTo-ModKitManifest'
    'Test-ModKitManifest'
)
