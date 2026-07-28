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
        [Parameter(Mandatory)][psobject]$HostObject
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
