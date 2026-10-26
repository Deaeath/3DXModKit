# 3DXModKit - Host runtime
#
# The host owns the loop. Mods never poll; they subscribe to events and are
# called back. Each mod receives a context object whose surface is trimmed to
# the capabilities its manifest declared - a mod without 'memory.trim.system'
# has no method to call to purge the standby list.
#
# Events raised by the host:
#   game.started        game process appeared          { Pid, Process }
#   game.stopped        game process disappeared       { Pid }
#   game.focused        game gained foreground         { Pid }
#   game.blurred        game lost foreground           { Pid }
#   game.minimized      game window minimised          { Pid }
#   game.restored       game window un-minimised       { Pid }
#   system.lowmemory    available RAM crossed below threshold { AvailPercent, AvailGB }
#   system.idle         no user input for idleSeconds  { IdleSeconds }
#   tick                every tickSeconds              { Tick, Uptime }

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Event bus
# ---------------------------------------------------------------------------

function New-ModKitEventBus {
    [CmdletBinding()]
    param()

    $bus = [pscustomobject]@{
        Handlers = @{}   # eventName -> List of @{ ModId; Action }
    }

    $bus | Add-Member -MemberType ScriptMethod -Name Subscribe -Value {
        param([string]$EventName, [string]$ModId, [scriptblock]$Action)
        if (-not $this.Handlers.ContainsKey($EventName)) {
            $this.Handlers[$EventName] = New-Object System.Collections.Generic.List[psobject]
        }
        $this.Handlers[$EventName].Add([pscustomobject]@{ ModId = $ModId; Action = $Action })
    }

    $bus | Add-Member -MemberType ScriptMethod -Name Unsubscribe -Value {
        param([string]$ModId)
        foreach ($key in @($this.Handlers.Keys)) {
            $keep = @($this.Handlers[$key] | Where-Object { $_.ModId -ne $ModId })
            $list = New-Object System.Collections.Generic.List[psobject]
            foreach ($h in $keep) { $list.Add($h) }
            $this.Handlers[$key] = $list
        }
    }

    # Publish never lets one misbehaving mod take down the loop.
    $bus | Add-Member -MemberType ScriptMethod -Name Publish -Value {
        param([string]$EventName, [hashtable]$EventData, [psobject]$Logger)
        if (-not $this.Handlers.ContainsKey($EventName)) { return }
        foreach ($h in $this.Handlers[$EventName]) {
            try {
                & $h.Action $EventData
            } catch {
                if ($Logger) {
                    $Logger.Error($h.ModId, "handler for '$EventName' threw: $($_.Exception.Message)")
                }
            }
        }
    }

    return $bus
}

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

function New-ModKitLogger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [ValidateSet('Debug','Info','Warn','Error')][string]$Level = 'Info'
    )

    $logger = [pscustomobject]@{
        LogPath = $LogPath
        Level   = $Level
        Ranks   = @{ Debug = 0; Info = 1; Warn = 2; Error = 3 }
    }

    $logger | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param([string]$Severity, [string]$Source, [string]$Message)
        if ($this.Ranks[$Severity] -lt $this.Ranks[$this.Level]) { return }

        $stamp = (Get-Date).ToString('HH:mm:ss')
        $line  = "[$stamp] [$Severity] [$Source] $Message"

        $color = switch ($Severity) {
            'Debug' { 'DarkGray' }
            'Info'  { 'Gray' }
            'Warn'  { 'Yellow' }
            'Error' { 'Red' }
        }
        Write-Host $line -ForegroundColor $color

        try {
            $full = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Severity] [$Source] $Message"
            Add-Content -LiteralPath $this.LogPath -Value $full -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }

    $logger | Add-Member -MemberType ScriptMethod -Name Debug -Value {
        param([string]$Source,[string]$Message) $this.Write('Debug',$Source,$Message)
    }
    $logger | Add-Member -MemberType ScriptMethod -Name Info -Value {
        param([string]$Source,[string]$Message) $this.Write('Info',$Source,$Message)
    }
    $logger | Add-Member -MemberType ScriptMethod -Name Warn -Value {
        param([string]$Source,[string]$Message) $this.Write('Warn',$Source,$Message)
    }
    $logger | Add-Member -MemberType ScriptMethod -Name Error -Value {
        param([string]$Source,[string]$Message) $this.Write('Error',$Source,$Message)
    }

    return $logger
}

# ---------------------------------------------------------------------------
# App restart
# ---------------------------------------------------------------------------

function Restart-ModKitApp {
    <#
    .SYNOPSIS
        Closes every process of a desktop app and relaunches it the way it was
        started. Never the game.
    .DESCRIPTION
        Only ever called by the control panel, after you click its "restart?"
        notification - no mod can restart anything. Closed without Success
        means the app is gone and did not come back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$GameProcessName = '3DXChat'
    )

    $r = [pscustomobject]@{ Success = $false; Closed = $false; Error = $null; ReopenedFolders = 0 }
    if ($Name -ieq $GameProcessName) { $r.Error = 'never restarts the game'; return $r }

    $procs = @(Get-CimInstance Win32_Process -Filter "Name='$($Name -replace "'", "''").exe'" -OperationTimeoutSec 10 -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { $r.Error = 'not running'; return $r }

    try {
        if ($Name -ieq 'explorer') {
            # Folder windows live inside the shell; note where they were so
            # they reopen. Windows restarts the shell itself (AutoRestartShell)
            # - start it only if it doesn't.
            $folders = @()
            try {
                $folders = @((New-Object -ComObject Shell.Application).Windows() | ForEach-Object {
                    try { $_.Document.Folder.Self.Path } catch { }
                } | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
            } catch { }
            Stop-Process -Name explorer -Force -ErrorAction Stop
            $r.Closed = $true
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline -and -not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 500 }
            if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            Start-Sleep -Seconds 3
            foreach ($f in $folders) { Start-Process explorer.exe -ArgumentList ('"' + $f + '"'); $r.ReopenedFolders++ }
            $r.Success = $true
            return $r
        }

        # Relaunch the way it was started: the root process, the one whose
        # parent isn't another copy of itself.
        $ids  = @($procs | ForEach-Object { $_.ProcessId })
        $root = $procs | Where-Object { $ids -notcontains $_.ParentProcessId -and $_.CommandLine -notmatch '--type=' } | Select-Object -First 1
        if (-not $root -or -not $root.ExecutablePath) { $r.Error = 'cannot tell how it was started'; return $r }
        $exe = $root.ExecutablePath
        $launchArgs = ''
        if ($root.CommandLine -match '^\s*("[^"]*"|\S+)\s*(.*)$') { $launchArgs = $matches[2].Trim() }

        # Squirrel apps (Discord and friends) live in an app-x.y.z folder and
        # restart through their own Update.exe, like their shortcut.
        $appDir = Split-Path -Parent $exe
        $update = Join-Path (Split-Path -Parent $appDir) 'Update.exe'
        $squirrel = ((Split-Path -Leaf $appDir) -match '^app-\d') -and (Test-Path -LiteralPath $update)

        foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and (Get-Process -Name $Name -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 500 }
        if (Get-Process -Name $Name -ErrorAction SilentlyContinue) { $r.Error = 'would not close (it may be running as administrator)'; return $r }
        $r.Closed = $true

        if ($squirrel) {
            Start-Process -FilePath $update -ArgumentList '--processStart', ('"' + (Split-Path -Leaf $exe) + '"')
        } elseif ($launchArgs) {
            Start-Process -FilePath $exe -ArgumentList $launchArgs -WorkingDirectory $appDir
        } else {
            Start-Process -FilePath $exe -WorkingDirectory $appDir
        }
        $r.Success = $true
    } catch { $r.Error = $_.Exception.Message }
    return $r
}

function Restart-ModKitService {
    <#
    .SYNOPSIS
        Restarts a Windows service, after you click the control panel's
        "restart?" notification. Unelevated, Windows asks first (UAC).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $r = [pscustomobject]@{ Success = $false; Error = $null }
    try {
        if ([ThreeDX.ModKit.Native.MemOps]::IsElevated()) {
            Restart-Service -Name $Name -Force -ErrorAction Stop
        } else {
            $cmd = "Restart-Service -Name '$($Name -replace "'", "''")' -Force -ErrorAction Stop"
            $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop `
                -ArgumentList "-NoProfile -Command `"$cmd`""
            if ($p.ExitCode -ne 0) { throw "restart failed (exit code $($p.ExitCode))" }
        }
        $r.Success = $true
    } catch { $r.Error = $_.Exception.Message }
    return $r
}

function Clear-ModKitCaps {
    <#
    .SYNOPSIS
        Lifts every hard RAM ceiling and restores normal memory priority on
        the processes that have one. Run when the governor stops, so nothing
        stays capped after 3dxGC is gone - including when it was killed.
    #>
    [CmdletBinding()]
    param()
    $n = 0
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        if ([ThreeDX.ModKit.Native.MemOps]::IsCapped($p.Id)) {
            [void][ThreeDX.ModKit.Native.MemOps]::UncapProcess($p.Id)
            [void][ThreeDX.ModKit.Native.MemOps]::SetMemoryPriority($p.Id, [ThreeDX.ModKit.Native.MemOps]::MemoryPriorityNormal)
            $n++
        }
    }
    return $n
}

# ---------------------------------------------------------------------------
# Mod context (capability-gated)
# ---------------------------------------------------------------------------

function New-ModKitContext {
    <#
    .SYNOPSIS
        Builds the context object handed to one mod's Initialize().
    .DESCRIPTION
        Only the members backed by a declared capability are attached. A mod
        that did not ask for 'memory.trim.system' has no PurgeStandby method to
        call, so the capability list in mod.json is the real access boundary
        rather than documentation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Manifest,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][psobject]$Bus,
        [Parameter(Mandatory)][psobject]$Logger,
        # Not named -Host: that collides with PowerShell's automatic $Host.
        [Parameter(Mandatory)][psobject]$HostObject,
        # The profile's block for this mod, kept so ReloadConfig can rebuild
        # the same layers.
        [AllowNull()][hashtable]$ProfileConfig = $null
    )

    $caps = @($Manifest.Capabilities)
    $modId = $Manifest.Id

    $ctx = [pscustomobject]@{
        ModId        = $modId
        Version      = $Manifest.Version
        Config       = $Config
        Capabilities = $caps
        Root         = $Manifest.Root
    }

    # --- always available: logging + event subscription -------------------
    $ctx | Add-Member -MemberType NoteProperty -Name _bus -Value $Bus
    $ctx | Add-Member -MemberType NoteProperty -Name _log -Value $Logger
    $ctx | Add-Member -MemberType NoteProperty -Name _host -Value $HostObject

    $ctx | Add-Member -MemberType ScriptMethod -Name On -Value {
        param([string]$EventName,[scriptblock]$Action)
        $this._bus.Subscribe($EventName, $this.ModId, $Action)
    }
    $ctx | Add-Member -MemberType ScriptMethod -Name Log -Value {
        param([string]$Message) $this._log.Info($this.ModId, $Message)
    }
    $ctx | Add-Member -MemberType ScriptMethod -Name LogWarn -Value {
        param([string]$Message) $this._log.Warn($this.ModId, $Message)
    }
    $ctx | Add-Member -MemberType ScriptMethod -Name LogError -Value {
        param([string]$Message) $this._log.Error($this.ModId, $Message)
    }
    $ctx | Add-Member -MemberType ScriptMethod -Name LogDebug -Value {
        param([string]$Message) $this._log.Debug($this.ModId, $Message)
    }
    $ctx | Add-Member -MemberType NoteProperty -Name _manifest -Value $Manifest
    $ctx | Add-Member -MemberType NoteProperty -Name _profileConfig -Value $ProfileConfig
    $ctx | Add-Member -MemberType ScriptMethod -Name ReloadConfig -Value {
        # The same layers read fresh (defaults < profile < config\<mod-id>.json),
        # so a setting changed from the control panel applies without a restart.
        # $null when a file is mid-write or invalid - keep what you had.
        try { return Get-ModKitModConfig -Manifest $this._manifest -ConfigRoot $this._host.ConfigRoot -ProfileConfig $this._profileConfig }
        catch { return $null }
    }

    # --- process.query ----------------------------------------------------
    if ($caps -contains 'process.query') {
        $ctx | Add-Member -MemberType ScriptMethod -Name GetGamePid -Value {
            return $this._host.GamePid
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetProcessMemory -Value {
            param([int]$ProcessId)
            return [ThreeDX.ModKit.Native.MemOps]::GetProcessMemory($ProcessId)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetSystemMemory -Value {
            return [ThreeDX.ModKit.Native.MemOps]::GetSystemMemory()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetIdleSeconds -Value {
            return [ThreeDX.ModKit.Native.MemOps]::GetIdleSeconds()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name IsGameForeground -Value {
            if ($this._host.GamePid -le 0) { return $false }
            return ([ThreeDX.ModKit.Native.MemOps]::GetForegroundPid() -eq $this._host.GamePid)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetGameDirectory -Value {
            # Directory containing the running 3DXChat.exe, or $null if the
            # game isn't currently running. Lets a host-tier mod that needs
            # to inspect (or, via its own explicit bootstrap script, write
            # into) the install directory find it without hardcoding a path.
            if ($this._host.GamePid -le 0) { return $null }
            try {
                $p = Get-Process -Id $this._host.GamePid -ErrorAction Stop
                if ($p.Path) { return (Split-Path -Parent $p.Path) }
            } catch { }
            return $null
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetForegroundPid -Value {
            return [ThreeDX.ModKit.Native.MemOps]::GetForegroundPid()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetForegroundProcessName -Value {
            $fg = [ThreeDX.ModKit.Native.MemOps]::GetForegroundPid()
            if ($fg -le 0) { return $null }
            try { return [System.Diagnostics.Process]::GetProcessById($fg).ProcessName } catch { return $null }
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name IsGameMinimized -Value {
            if ($this._host.GamePid -le 0) { return $false }
            return [ThreeDX.ModKit.Native.MemOps]::IsProcessMinimized($this._host.GamePid)
        }
    }

    # --- memory.trim.self (unprivileged, targeted) ------------------------
    if ($caps -contains 'memory.trim.self') {
        $ctx | Add-Member -MemberType ScriptMethod -Name TrimGame -Value {
            if ($this._host.GamePid -le 0) { return $null }
            return [ThreeDX.ModKit.Native.MemOps]::TrimProcess($this._host.GamePid)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name TrimProcess -Value {
            param([int]$ProcessId)
            return [ThreeDX.ModKit.Native.MemOps]::TrimProcess($ProcessId)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name TrimByName -Value {
            param([string]$ProcessName)
            return [ThreeDX.ModKit.Native.MemOps]::TrimProcessesByName($ProcessName)
        }
    }

    # --- memory.trim.system (privileged, system-wide) ---------------------
    if ($caps -contains 'memory.trim.system') {
        $ctx | Add-Member -MemberType ScriptMethod -Name EmptyAllWorkingSets -Value {
            return [ThreeDX.ModKit.Native.MemOps]::EmptyAllWorkingSets()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name EmptySystemWorkingSet -Value {
            return [ThreeDX.ModKit.Native.MemOps]::EmptySystemWorkingSet()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name FlushModifiedPageList -Value {
            return [ThreeDX.ModKit.Native.MemOps]::FlushModifiedPageList()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name PurgeStandbyList -Value {
            return [ThreeDX.ModKit.Native.MemOps]::PurgeStandbyList()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name PurgeLowPriorityStandby -Value {
            return [ThreeDX.ModKit.Native.MemOps]::PurgeLowPriorityStandby()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name EmptyAll -Value {
            return [ThreeDX.ModKit.Native.MemOps]::EmptyAll()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name IsElevated -Value {
            return [ThreeDX.ModKit.Native.MemOps]::IsElevated()
        }
    }

    # --- memory.diagnose --------------------------------------------------
    # Finds leaks: exited processes a driver is still holding, processes and
    # services that only ever grow, and whether an app is in use right now.
    # Read-only, except that StartLeakTest starts a few short whoami.exe
    # processes. Nothing here closes or restarts anything - no mod can; only
    # the control panel can, and only when you click its notification.
    if ($caps -contains 'memory.diagnose') {
        $ctx | Add-Member -MemberType ScriptMethod -Name GetKernelLeak -Value {
            return [ThreeDX.ModKit.Native.MemOps]::GetKernelLeak()
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name StartLeakTest -Value {
            param([int]$Count = 6)
            return [ThreeDX.ModKit.Native.MemOps]::StartLeakTest($Count)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name CountHeld -Value {
            param([int[]]$ProcessIds)
            return [ThreeDX.ModKit.Native.MemOps]::CountHeld($ProcessIds)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetProcessSample -Value {
            # One row per process - only what growth tracking needs.
            return @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{
                    Id           = $_.Id
                    Name         = $_.ProcessName
                    PrivateBytes = $_.PrivateMemorySize64
                    WorkingSet   = $_.WorkingSet64
                    Handles      = $_.HandleCount
                }
            })
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetServiceHandles -Value {
            # Handle count of the service's process, or -1 if it isn't running.
            param([string]$Name)
            try {
                $svc = Get-CimInstance Win32_Service -Filter "Name='$($Name -replace "'", "''")'" -OperationTimeoutSec 10 -ErrorAction Stop
                if (-not $svc -or $svc.ProcessId -le 0) { return -1 }
                return (Get-Process -Id $svc.ProcessId -ErrorAction Stop).HandleCount
            } catch { return -1 }
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetAppActivity -Value {
            # Is anyone using this app right now? When in doubt, say yes.
            param([string]$Name)
            $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
            $a = [pscustomobject]@{ Running = ($procs.Count -gt 0); PrivateMB = 0; Foreground = $false
                                    Sound = $false; Camera = $false; Microphone = $false }
            if (-not $a.Running) { return $a }

            $ids = @($procs | ForEach-Object { $_.Id })
            $a.PrivateMB  = [math]::Round(($procs | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB)
            $a.Foreground = $ids -contains [ThreeDX.ModKit.Native.MemOps]::GetForegroundPid()
            try {
                $playing = [ThreeDX.ModKit.Native.AudioActivity]::GetActiveProcessIds()
                $a.Sound = @($playing | Where-Object { $ids -contains $_ }).Count -gt 0
            } catch { $a.Sound = $true }

            # Windows' own in-use markers (the taskbar's camera and mic icons). A
            # crash can leave one stuck "on"; those are older than the running
            # copy, so only markers stamped after it started count.
            $started = @($procs | ForEach-Object { try { $_.StartTime.ToFileTime() } catch { } })
            $since   = if ($started.Count) { ($started | Measure-Object -Minimum).Minimum } else { 0 }
            $paths   = @($procs | ForEach-Object { try { $_.Path } catch { } } | Where-Object { $_ } | Select-Object -Unique)
            $store   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
            foreach ($cap in 'webcam', 'microphone') {
                foreach ($path in $paths) {
                    $v = Get-ItemProperty -LiteralPath "$store\$cap\NonPackaged\$($path -replace '\\', '#')" -ErrorAction SilentlyContinue
                    if (-not $v) { continue }
                    $stop  = $v.PSObject.Properties['LastUsedTimeStop']
                    $start = $v.PSObject.Properties['LastUsedTimeStart']
                    if ($stop -and $start -and [long]$stop.Value -eq 0 -and [long]$start.Value -ge $since) {
                        if ($cap -eq 'webcam') { $a.Camera = $true } else { $a.Microphone = $true }
                    }
                }
            }
            return $a
        }
    }

    # --- memory.cap -------------------------------------------------------
    # Hard RAM ceilings and low memory priority for other apps. Windows
    # enforces a ceiling continuously - past it the app pages against itself,
    # it never gets more. Never the game, never 3dxGC itself.
    if ($caps -contains 'memory.cap') {
        $ctx | Add-Member -MemberType NoteProperty -Name _ownPids -Value @(
            $PID, (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -OperationTimeoutSec 10 -ErrorAction SilentlyContinue).ParentProcessId)
        $ctx | Add-Member -MemberType ScriptMethod -Name CapProcess -Value {
            param([int]$ProcessId, [long]$MaxBytes)
            if ($ProcessId -eq $this._host.GamePid -or $this._ownPids -contains $ProcessId) { return $null }
            return [ThreeDX.ModKit.Native.MemOps]::CapProcess($ProcessId, $MaxBytes)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name UncapProcess -Value {
            param([int]$ProcessId)
            return [ThreeDX.ModKit.Native.MemOps]::UncapProcess($ProcessId)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name SetMemoryPriority -Value {
            param([int]$ProcessId, [int]$Priority)
            if ($ProcessId -eq $this._host.GamePid -or $this._ownPids -contains $ProcessId) { return $false }
            return [ThreeDX.ModKit.Native.MemOps]::SetMemoryPriority($ProcessId, $Priority)
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name ReleaseAllCaps -Value {
            return Clear-ModKitCaps
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name GetSessionProcesses -Value {
            # Every process in your desktop session - id, parent, name, working
            # set, fault count - from one kernel call. What capping chooses
            # from; services in session 0 are never touched.
            $session = (Get-Process -Id $PID).SessionId
            return @([ThreeDX.ModKit.Native.MemOps]::GetProcessList() | Where-Object { $_.SessionId -eq $session })
        }
    }

    # --- process.priority -------------------------------------------------
    if ($caps -contains 'process.priority') {
        $ctx | Add-Member -MemberType ScriptMethod -Name SetGamePriority -Value {
            param([string]$PriorityClass)
            if ($this._host.GamePid -le 0) { return $false }
            try {
                $p = Get-Process -Id $this._host.GamePid -ErrorAction Stop
                $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$PriorityClass
                return $true
            } catch { return $false }
        }
    }

    # --- ipc.runtime ------------------------------------------------------
    # Machine-local named pipe to the in-process plugin. NamedPipeClientStream
    # is constructed against "." (this machine) only - there is no code path
    # here that opens a socket or names a remote host.
    if ($caps -contains 'ipc.runtime') {
        $ctx | Add-Member -MemberType ScriptMethod -Name SendRuntimeCommand -Value {
            param([string]$Command, [int]$TimeoutMs = 2000)

            $pipe = $null
            try {
                $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
                    '.', '3dxmodkit-runtime', [System.IO.Pipes.PipeDirection]::InOut)
                $pipe.Connect($TimeoutMs)

                $writer = New-Object System.IO.StreamWriter($pipe)
                $writer.AutoFlush = $true
                $writer.WriteLine($Command)

                $reader = New-Object System.IO.StreamReader($pipe)
                $response = $reader.ReadLine()

                if ([string]::IsNullOrWhiteSpace($response)) { return $null }
                return ($response | ConvertFrom-Json)
            } catch {
                return $null
            } finally {
                if ($pipe) { $pipe.Dispose() }
            }
        }

        $ctx | Add-Member -MemberType ScriptMethod -Name IsRuntimeAvailable -Value {
            return (Test-Path -LiteralPath '\\.\pipe\3dxmodkit-runtime')
        }
    }

    # --- process.launch.companion -----------------------------------------
    # Starts a separate desktop app as its own process. Only an existing .exe
    # outside the game directory, so it can never launch or wrap the client.
    if ($caps -contains 'process.launch.companion') {
        $ctx | Add-Member -MemberType ScriptMethod -Name StartCompanion -Value {
            param([string]$ExePath, [string[]]$Arguments = @())
            if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { return $false }
            $full = [System.IO.Path]::GetFullPath($ExePath)
            if ([System.IO.Path]::GetExtension($full) -ne '.exe') { return $false }
            if ($this._host.GamePid -gt 0) {
                try {
                    $game = Get-Process -Id $this._host.GamePid -ErrorAction Stop
                    if ($game.Path) {
                        $gameDir = (Split-Path -Parent $game.Path).TrimEnd('\') + '\'
                        if ($full.StartsWith($gameDir, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                    }
                } catch { }
            }
            try {
                $startArgs = @{ FilePath = $full; WorkingDirectory = (Split-Path -Parent $full) }
                if ($Arguments.Count) { $startArgs.ArgumentList = $Arguments }
                Start-Process @startArgs
                return $true
            } catch { return $false }
        }
    }

    # --- ui.open.companion -------------------------------------------------
    # Opens a companion web app (a local .html page) in the default browser.
    # Only existing .html/.htm files outside the game directory.
    if ($caps -contains 'ui.open.companion') {
        $ctx | Add-Member -MemberType ScriptMethod -Name OpenCompanionPage -Value {
            param([string]$PagePath)
            if (-not $PagePath -or -not (Test-Path -LiteralPath $PagePath -PathType Leaf)) { return $false }
            $full = [System.IO.Path]::GetFullPath($PagePath)
            if ([System.IO.Path]::GetExtension($full) -notin @('.html', '.htm')) { return $false }
            if ($this._host.GamePid -gt 0) {
                try {
                    $game = Get-Process -Id $this._host.GamePid -ErrorAction Stop
                    if ($game.Path) {
                        $gameDir = (Split-Path -Parent $game.Path).TrimEnd('\') + '\'
                        if ($full.StartsWith($gameDir, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                    }
                } catch { }
            }
            try { Start-Process -FilePath $full; return $true } catch { return $false }
        }
    }

    # --- fs.write.config --------------------------------------------------
    if ($caps -contains 'fs.write.config') {
        $ctx | Add-Member -MemberType ScriptMethod -Name SaveState -Value {
            param([hashtable]$State)
            $path = Join-Path $this._host.ConfigRoot ($this.ModId + '.state.json')
            $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name LoadState -Value {
            $path = Join-Path $this._host.ConfigRoot ($this.ModId + '.state.json')
            return Read-ModKitJsonFile -Path $path
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name WriteStatus -Value {
            # What the mod is doing right now, for the control panel to show.
            # Its own file, rewritten whole each time - never your settings.
            param([hashtable]$Status)
            $path = Join-Path $this._host.ConfigRoot ($this.ModId + '.status.json')
            try { $Status | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $path -Encoding UTF8 } catch { }
        }
    }

    return $ctx
}

# ---------------------------------------------------------------------------
# Host object + main loop
# ---------------------------------------------------------------------------

function New-ModKitHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][psobject]$Logger,
        [Parameter(Mandatory)][psobject]$Bus,
        [string]$GameProcessName = '3DXChat'
    )

    $hostObj = [pscustomobject]@{
        RootPath        = $RootPath
        ConfigRoot      = (Join-Path $RootPath 'config')
        GameProcessName = $GameProcessName
        GamePid         = 0
        Logger          = $Logger
        Bus             = $Bus
        LoadedMods      = @{}
        StartedAt       = Get-Date
        Tick            = 0
        Running         = $false
    }

    if (-not (Test-Path -LiteralPath $hostObj.ConfigRoot)) {
        New-Item -ItemType Directory -Force -Path $hostObj.ConfigRoot | Out-Null
    }

    return $hostObj
}

function Start-ModKitLoop {
    <#
    .SYNOPSIS
        Runs the host event loop until Ctrl+C.
    .DESCRIPTION
        Tracks game presence, focus, minimisation, idle time, and memory
        pressure, raising events as state changes. Edge-triggered: an event
        fires on transition, not on every tick, so mods are not re-entered
        while a condition simply persists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$HostObject,
        [int]$TickSeconds = 5,
        [double]$LowMemoryThresholdPercent = 15.0,
        [double]$IdleSecondsThreshold = 120.0
    )

    $h   = $HostObject
    $log = $h.Logger
    $bus = $h.Bus

    $h.Running = $true

    # Previous-state trackers for edge detection.
    $prevPid       = 0
    $prevForeground= $false
    $prevMinimized = $false
    $prevLowMem    = $false
    $prevIdle      = $false

    $log.Info('host', "loop started (tick ${TickSeconds}s, lowmem <${LowMemoryThresholdPercent}%, idle >${IdleSecondsThreshold}s)")

    try {
        while ($h.Running) {
            $h.Tick = $h.Tick + 1

            # --- game presence -------------------------------------------
            # Several processes can share the name (helpers, crash handlers,
            # a second client). The one worth governing is the one actually
            # holding memory, so pick the largest working set rather than
            # whichever the enumerator happened to return first.
            $proc = @(Get-Process -Name $h.GameProcessName -ErrorAction SilentlyContinue |
                      Sort-Object WorkingSet64 -Descending)
            $curPid = 0
            if ($proc.Count -gt 0) { $curPid = $proc[0].Id }
            $h.GamePid = $curPid

            if ($curPid -ne 0 -and $prevPid -eq 0) {
                $log.Info('host', "game detected (pid $curPid)")
                $bus.Publish('game.started', @{ Pid = $curPid; Process = $proc[0] }, $log)
            } elseif ($curPid -eq 0 -and $prevPid -ne 0) {
                $log.Info('host', "game exited (pid $prevPid)")
                $bus.Publish('game.stopped', @{ Pid = $prevPid }, $log)
                $prevForeground = $false
                $prevMinimized  = $false
            }

            # --- focus / minimise ----------------------------------------
            if ($curPid -ne 0) {
                $isFg  = ([ThreeDX.ModKit.Native.MemOps]::GetForegroundPid() -eq $curPid)
                $isMin = [ThreeDX.ModKit.Native.MemOps]::IsProcessMinimized($curPid)

                if ($isFg -and -not $prevForeground) {
                    $bus.Publish('game.focused', @{ Pid = $curPid }, $log)
                } elseif (-not $isFg -and $prevForeground) {
                    $bus.Publish('game.blurred', @{ Pid = $curPid }, $log)
                }

                if ($isMin -and -not $prevMinimized) {
                    $bus.Publish('game.minimized', @{ Pid = $curPid }, $log)
                } elseif (-not $isMin -and $prevMinimized) {
                    $bus.Publish('game.restored', @{ Pid = $curPid }, $log)
                }

                $prevForeground = $isFg
                $prevMinimized  = $isMin
            }

            # --- memory pressure -----------------------------------------
            $sys = [ThreeDX.ModKit.Native.MemOps]::GetSystemMemory()
            $isLow = ($sys.AvailPercent -lt $LowMemoryThresholdPercent)
            if ($isLow -and -not $prevLowMem) {
                $log.Warn('host', "low memory: $($sys.AvailPercent)% free ($($sys.AvailPhysGB) GB)")
                $bus.Publish('system.lowmemory', @{
                    AvailPercent = $sys.AvailPercent
                    AvailGB      = $sys.AvailPhysGB
                    LoadPercent  = $sys.MemoryLoadPercent
                }, $log)
            }
            $prevLowMem = $isLow

            # --- desktop idle --------------------------------------------
            $idleSec = [ThreeDX.ModKit.Native.MemOps]::GetIdleSeconds()
            $isIdle = ($idleSec -gt $IdleSecondsThreshold)
            if ($isIdle -and -not $prevIdle) {
                $bus.Publish('system.idle', @{ IdleSeconds = $idleSec }, $log)
            }
            $prevIdle = $isIdle

            # --- tick -----------------------------------------------------
            $bus.Publish('tick', @{
                Tick   = $h.Tick
                Uptime = ((Get-Date) - $h.StartedAt).TotalSeconds
            }, $log)

            $prevPid = $curPid
            Start-Sleep -Seconds $TickSeconds
        }
    } finally {
        $log.Info('host', 'loop stopped')
        $h.Running = $false
    }
}
