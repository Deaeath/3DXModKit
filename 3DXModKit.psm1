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
$Script:ModKitRepo = 'Deaeath/3DXModKit'

function Get-ModKitVersion {
    <#
    .SYNOPSIS
        The installed version, read from the module manifest - the single
        source of truth so the CLI, GUI, and updater never disagree.
    #>
    [CmdletBinding()]
    param()
    (Test-ModuleManifest -Path (Join-Path $Script:ModKitRoot '3DXModKit.psd1')).Version.ToString()
}

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
        ModKitVersion = Get-ModKitVersion
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

function Get-ModKitModSettings {
    <#
    .SYNOPSIS
        A mod's effective settings for a profile: its defaults, the profile's
        block, then your overrides in config\<mod-id>.json - what the mod sees.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModId,
        [string]$ProfileName = 'default'
    )
    $manifest = ConvertTo-ModKitManifest -Path (Join-Path $Script:ModKitRoot "mods\$ModId\mod.json")
    $profileCfg = $null
    try {
        $p = Get-ModKitProfile -ProfilesPath (Join-Path $Script:ModKitRoot 'profiles') -Name $ProfileName
        if ($p.ModConfigs.ContainsKey($ModId)) { $profileCfg = $p.ModConfigs[$ModId] }
    } catch { }
    Get-ModKitModConfig -Manifest $manifest -ConfigRoot (Join-Path $Script:ModKitRoot 'config') -ProfileConfig $profileCfg
}

function Set-ModKitUserSetting {
    <#
    .SYNOPSIS
        Writes one setting into your overrides (config\<mod-id>.json), keeping
        everything else in that file. -Path is dotted, e.g. leakWatch.capApps;
        -Value $null removes it. The governor re-reads settings it watches
        live (caps), so those apply without a restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModId,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Value
    )
    $file = Join-Path $Script:ModKitRoot "config\$ModId.json"
    $all = Read-ModKitJsonFile -Path $file
    if ($null -eq $all) { $all = @{} }
    $keys = $Path -split '\.'
    $node = $all
    for ($i = 0; $i -lt $keys.Count - 1; $i++) {
        if (-not ($node[$keys[$i]] -is [hashtable])) { $node[$keys[$i]] = @{} }
        $node = $node[$keys[$i]]
    }
    if ($null -eq $Value) { $node.Remove($keys[-1]) } else { $node[$keys[-1]] = $Value }
    # A fresh install has no config\ until something is first saved.
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $all | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding UTF8
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

    $logger.Info('modkit', "3DXModKit $(Get-ModKitVersion) starting (profile '$ProfileName')")
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
        $ctx = New-ModKitContext -Manifest $manifest -Config $cfg -Bus $bus -Logger $logger -HostObject $hostObj -ProfileConfig $profileCfg

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

function Test-ModKitUpdate {
    <#
    .SYNOPSIS
        Checks GitHub Releases for a newer version. Never throws - a network
        hiccup here must never take down the caller, since this runs
        unattended in the background.
    .OUTPUTS
        PSCustomObject: UpdateAvailable, LocalVersion, RemoteVersion,
        DownloadUrl (the zip), SetupUrl (3dxGC-Setup), SumsUrl
        (SHA256SUMS.txt), ReleaseUrl, Error.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 10)

    $local = Get-ModKitVersion
    $result = [pscustomobject]@{
        UpdateAvailable = $false
        LocalVersion    = $local
        RemoteVersion   = $null
        DownloadUrl     = $null
        SetupUrl        = $null
        SumsUrl         = $null
        ReleaseUrl      = $null
        Error           = $null
    }

    try {
        $uri = "https://api.github.com/repos/$Script:ModKitRepo/releases/latest"
        $resp = Invoke-RestMethod -Uri $uri -Headers @{
            'User-Agent' = '3DXModKit-updater'
            'Accept'     = 'application/vnd.github+json'
        } -TimeoutSec $TimeoutSec -UseBasicParsing

        $tag = [string]$resp.tag_name
        $remote = $tag.TrimStart('v', 'V')

        $zip   = $resp.assets | Where-Object { $_.name -like '3DXModKit-*.zip' } | Select-Object -First 1
        $setup = $resp.assets | Where-Object { $_.name -like '3dxGC-Setup-*.exe' } | Select-Object -First 1
        $sums  = $resp.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
        if (-not $zip -and -not $setup) {
            $result.Error = "release '$tag' has neither a 3DXModKit-*.zip nor a 3dxGC-Setup-*.exe"
            return $result
        }

        $result.RemoteVersion = $remote
        if ($zip)   { $result.DownloadUrl = $zip.browser_download_url }
        if ($setup) { $result.SetupUrl    = $setup.browser_download_url }
        if ($sums)  { $result.SumsUrl     = $sums.browser_download_url }
        $result.ReleaseUrl    = $resp.html_url

        try {
            $result.UpdateAvailable = ([version]$remote) -gt ([version]$local)
        } catch {
            # Non-semver tag - fall back to a straight string inequality so a
            # weird tag still surfaces as "different" rather than being
            # silently treated as no-op.
            $result.UpdateAvailable = ($remote -ne $local)
        }
    } catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-ModKitInstall {
    <#
    .SYNOPSIS
        The Apps & Features entry 3dxGC-Setup made for this copy, or $null
        for a copy run from the zip or a git checkout. The key is
        build\3dxGC.iss's AppId.
    #>
    [CmdletBinding()]
    param()
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B4E7C2A1-9F3D-4E58-A6C1-7D2B8E4F1A90}_is1'
    try {
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        $at   = [IO.Path]::GetFullPath([string]$entry.InstallLocation).TrimEnd('\')
        $here = [IO.Path]::GetFullPath($Script:ModKitRoot).TrimEnd('\')
        if ($at -eq $here) { return $entry }
    } catch { }
    return $null
}

function Save-ModKitUpdate {
    <#
    .SYNOPSIS
        Downloads one release file and keeps it only if its SHA-256 matches
        the release's SHA256SUMS.txt. Never throws.
    .OUTPUTS
        PSCustomObject: Ok, Path (the verified file, in a new temp folder),
        Error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$SumsUrl,
        [int]$TimeoutSec = 120
    )
    $result = [pscustomobject]@{ Ok = $false; Path = $null; Error = $null }
    if (-not $SumsUrl) { $result.Error = 'the release has no SHA256SUMS.txt, so the download cannot be verified'; return $result }

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('3dxgc-update-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $name = [IO.Path]::GetFileName(([uri]$Url).AbsolutePath)
        $file = Join-Path $dir $name
        $sums = Join-Path $dir 'SHA256SUMS.txt'
        Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing -TimeoutSec $TimeoutSec
        Invoke-WebRequest -Uri $SumsUrl -OutFile $sums -UseBasicParsing -TimeoutSec 30

        $expected = $null
        foreach ($line in Get-Content -LiteralPath $sums) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $name) { $expected = $Matches[1].ToLowerInvariant() }
        }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $expected) {
            $result.Error = "SHA256SUMS.txt has no line for $name"
        } elseif ($actual -ne $expected) {
            $result.Error = "$name does not match its checksum (got $actual, expected $expected) - not using it"
        } else {
            $result.Ok   = $true
            $result.Path = $file
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    if (-not $result.Ok) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    return $result
}

# ---------------------------------------------------------------------------
# Companion apps
# ---------------------------------------------------------------------------
# Separate apps the modkit can install and open: they run on their own, never
# inside the game. The control panel's Mods tab and the matching mods use this.

$Script:ProfileStudioDir = Join-Path $env:LOCALAPPDATA 'Programs\3DX Profile Studio'
$Script:WorldEditorDir = Join-Path $env:LOCALAPPDATA 'Programs\3DX World Editor'

function Get-ModKitCompanions {
    <#
    .SYNOPSIS
        3DX Radio Streamer, 3DX Profile Studio and 3DX World Editor: whether each is installed,
        where, which version, and the script that installs it.
    #>
    [CmdletBinding()]
    param()

    $radioExe = $null
    $uninstallRoots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($root in $uninstallRoots) {
        try {
            $dir = (Get-ItemProperty -Path (Join-Path $root '{6F1C2B7A-3D58-4E8B-9A57-2C41E7A0B3D9}_is1') -Name 'InstallLocation' -ErrorAction Stop).InstallLocation
            $exe = Join-Path $dir '3DX Radio Streamer.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) { $radioExe = $exe; break }
        } catch { }
    }
    if (-not $radioExe) {
        foreach ($dir in @((Join-Path $env:LOCALAPPDATA 'Programs\3DX Radio Streamer'), (Join-Path $env:ProgramFiles '3DX Radio Streamer'))) {
            $exe = Join-Path $dir '3DX Radio Streamer.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) { $radioExe = $exe; break }
        }
    }
    $radioVersion = $null
    if ($radioExe) { $radioVersion = (Get-Item -LiteralPath $radioExe).VersionInfo.ProductVersion }

    $page = Join-Path $Script:ProfileStudioDir '3DX Profile Studio.html'
    $pageVersion = $null
    $versionFile = Join-Path $Script:ProfileStudioDir 'version.txt'
    if (Test-Path -LiteralPath $versionFile) { $pageVersion = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }

    $worldExe = Join-Path $Script:WorldEditorDir '3DXWorldEditor.exe'
    $worldVersion = $null
    $worldVersionFile = Join-Path $Script:WorldEditorDir 'version.txt'
    if (Test-Path -LiteralPath $worldVersionFile) { $worldVersion = (Get-Content -LiteralPath $worldVersionFile -TotalCount 1).Trim() }

    @(
        [pscustomobject]@{
            Id        = 'radio-streamer'
            Name      = '3DX Radio Streamer'
            Kind      = 'app'
            Path      = $radioExe
            Installed = [bool]$radioExe
            Version   = $radioVersion
            Running   = @(Get-Process -Name '3DX Radio Streamer' -ErrorAction SilentlyContinue).Count -gt 0
            Installer = Join-Path $Script:ModKitRoot 'mods\radio-streamer\bootstrap\Install-RadioStreamer.ps1'
            WebUrl    = $null
            Repo      = 'https://github.com/Deaeath/3dx-radio-streamer'
        }
        [pscustomobject]@{
            Id        = 'profile-studio'
            Name      = '3DX Profile Studio'
            Kind      = 'page'
            Path      = $(if (Test-Path -LiteralPath $page -PathType Leaf) { $page } else { $null })
            Installed = (Test-Path -LiteralPath $page -PathType Leaf)
            Version   = $pageVersion
            Running   = $false
            Installer = Join-Path $Script:ModKitRoot 'mods\profile-studio\bootstrap\Install-ProfileStudio.ps1'
            WebUrl    = 'https://deaeath.github.io/3dx-profile-studio/'
            Repo      = 'https://github.com/Deaeath/3dx-profile-studio'
        }
        [pscustomobject]@{
            Id        = 'world-editor'
            Name      = '3DX World Editor'
            Kind      = 'app'
            Path      = $(if (Test-Path -LiteralPath $worldExe -PathType Leaf) { $worldExe } else { $null })
            Installed = (Test-Path -LiteralPath $worldExe -PathType Leaf)
            Version   = $worldVersion
            Running   = @(Get-Process -Name '3DXWorldEditor' -ErrorAction SilentlyContinue).Count -gt 0
            Installer = Join-Path $Script:ModKitRoot 'mods\world-editor\bootstrap\Install-WorldEditor.ps1'
            WebUrl    = 'https://deaeath.github.io/3dx-world-editor/'
            Repo      = 'https://github.com/Deaeath/3dx-world-editor'
        }
    )
}

Export-ModuleMember -Function @(
    'Get-ModKitCompanions'
    'Get-ModKitInfo'
    'Get-ModKitVersion'
    'Test-ModKitUpdate'
    'Get-ModKitInstall'
    'Save-ModKitUpdate'
    'Test-ModKitMods'
    'Invoke-ModKitEmpty'
    'Start-ModKit'
    'Get-ModKitCapabilityCatalog'
    'Get-ModKitMods'
    'Resolve-ModKitLoadOrder'
    'ConvertTo-ModKitManifest'
    'Test-ModKitManifest'
    'Restart-ModKitApp'
    'Restart-ModKitService'
    'Clear-ModKitCaps'
    'Get-ModKitModSettings'
    'Set-ModKitUserSetting'
)
