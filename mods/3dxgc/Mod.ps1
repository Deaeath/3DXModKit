# 3dxGC - adaptive working-set management for 3DXChat
#
# Why adaptive rather than a timer:
#
# EmptyWorkingSet does not reduce a process's committed memory. It evicts
# resident pages to the standby list, where they are reclaimable by other
# processes but still fault back in on demand. Trimming a game that is actively
# rendering therefore buys a burst of hard faults - stutter - in exchange for
# RAM the game is about to ask for again.
#
# So the governor trims when the game is *not* the thing you are looking at
# (backgrounded, minimised, desktop idle), and escalates to system-wide purges
# only when free memory is genuinely scarce. Every action is rate-limited.
#
# Client-side only: this mod reads process counters and calls memory-management
# APIs. It never opens a handle for VM_WRITE, never touches game files, and
# never goes near the network. Nothing here is observable by the server.

@{
    Initialize = {
        param($ctx)

        $cfg = $ctx.Config

        # --- mutable state, closed over by the handlers -------------------
        $state = [pscustomobject]@{
            LastTrimAt      = [datetime]::MinValue
            LastPurgeAt     = [datetime]::MinValue
            BlurredAt       = $null
            TotalTrims      = 0
            TotalPurges     = 0
            TotalFreedMB    = 0.0
            SessionPeakWSMB = 0.0
            RamArmed        = $true
            LastRamTrimAt   = [datetime]::MinValue
            # leak watch
            LastLeakCheckAt  = [datetime]::MinValue
            HeldSamples      = New-Object System.Collections.Generic.List[psobject]
            HeldGB           = 0.0
            LastHeldWarnAt   = [datetime]::MinValue
            HeldTrimNoted    = $false
            ProcHistory      = @{}   # pid -> { Name; Samples }
            ProcWarnedAt     = @{}   # pid -> when last reported
            ServiceRestartAt = @{}   # service name -> when last restarted
            OptimizersWarned = @{}
        }

        # ------------------------------------------------------------------
        # helpers
        # ------------------------------------------------------------------

        $shouldSkip = {
            param($reason, $ignoreFocus = $false)

            if (-not $cfg.enabled) { return 'mod disabled' }
            if ($ctx.GetGamePid() -le 0) { return 'game not running' }

            if (-not $ignoreFocus -and
                $cfg.safety.neverTrimWhenForeground -and $ctx.IsGameForeground()) {
                # Minimised-but-foreground is not a real state; if it is
                # minimised we always allow the trim through.
                if (-not $ctx.IsGameMinimized()) { return 'game has focus' }
            }

            $since = ((Get-Date) - $state.LastTrimAt).TotalSeconds
            if ($since -lt $cfg.thresholds.minSecondsBetweenTrims) {
                return ('rate-limited ({0:N0}s since last trim)' -f $since)
            }

            $mem = $ctx.GetProcessMemory($ctx.GetGamePid())
            if ($null -eq $mem) { return 'cannot read process memory' }
            if ($mem.WorkingSetMB -lt $cfg.thresholds.minWorkingSetMB) {
                return ('working set already low ({0} MB)' -f $mem.WorkingSetMB)
            }

            return $null
        }.GetNewClosure()

        # Each helper is closed over as it is defined, so the one defined next
        # captures the finished version of the previous. Without this the
        # handlers below would capture only their own locals and lose these.
        $doTrim = {
            param($reason, $ignoreFocus = $false)

            $skip = & $shouldSkip $reason $ignoreFocus
            if ($skip) {
                # Always visible at Debug - "nothing happened" is otherwise
                # indistinguishable from a broken trigger. logEverySkip only
                # escalates the same message to Info.
                $ctx.LogDebug("skip [$reason]: $skip")
                if ($cfg.safety.logEverySkip) { $ctx.Log("skip [$reason]: $skip") }
                return
            }

            $gamePid = $ctx.GetGamePid()
            $before  = $ctx.GetProcessMemory($gamePid)
            if ($before.WorkingSetMB -gt $state.SessionPeakWSMB) {
                $state.SessionPeakWSMB = $before.WorkingSetMB
            }

            $result = $ctx.TrimGame()
            Start-Sleep -Milliseconds 200
            $after = $ctx.GetProcessMemory($gamePid)

            if ($null -eq $result -or -not $result.Success) {
                $err = if ($result) { $result.Error } else { 'no result' }
                $ctx.LogWarn("trim failed [$reason]: $err")
                return
            }

            $delta = [math]::Round($before.WorkingSetMB - $after.WorkingSetMB, 1)
            $state.LastTrimAt   = Get-Date
            $state.TotalTrims   = $state.TotalTrims + 1
            $state.TotalFreedMB = $state.TotalFreedMB + $delta

            $ctx.Log(("trim [{0}] {1} MB -> {2} MB  (-{3} MB, {4} ms)" -f `
                $reason, $before.WorkingSetMB, $after.WorkingSetMB, $delta, $result.DurationMs))

            # Companion processes (launcher) get the same treatment.
            if ($cfg.companions.trimLauncher) {
                foreach ($name in $cfg.companions.processNames) {
                    $r = $ctx.TrimByName($name)
                    if ($r.Success -and $r.AffectedProcesses -gt 0) {
                        $ctx.LogDebug("trimmed companion '$name' ($($r.AffectedProcesses) proc)")
                    }
                }
            }
        }.GetNewClosure()

        $doSystemPurge = {
            param($reason, $availPercent)

            if (-not $cfg.systemWide.enabled) { return }

            if (-not $ctx.IsElevated()) {
                $ctx.LogWarn("system purge [$reason] needs Administrator - skipped (per-process trim still applied)")
                return
            }

            if ($cfg.systemWide.onlyWhenCritical -and
                $availPercent -gt $cfg.thresholds.criticalMemoryPercent) {
                $ctx.LogDebug("system purge [$reason] withheld: ${availPercent}% free is above critical")
                return
            }

            $since = ((Get-Date) - $state.LastPurgeAt).TotalSeconds
            if ($since -lt $cfg.systemWide.minSecondsBetweenPurges) {
                $ctx.LogDebug(('system purge rate-limited ({0:N0}s)' -f $since))
                return
            }

            $before = $ctx.GetSystemMemory()
            $ops = @()

            if ($cfg.systemWide.flushModifiedList)       { $ops += $ctx.FlushModifiedPageList() }
            if ($cfg.systemWide.purgeLowPriorityStandby) { $ops += $ctx.PurgeLowPriorityStandby() }
            if ($cfg.systemWide.purgeStandby)            { $ops += $ctx.PurgeStandbyList() }
            if ($cfg.systemWide.emptySystemWorkingSet)   { $ops += $ctx.EmptySystemWorkingSet() }

            Start-Sleep -Milliseconds 300
            $after = $ctx.GetSystemMemory()
            $freed = [math]::Round(($after.AvailPhysBytes - $before.AvailPhysBytes)/1MB, 1)

            $state.LastPurgeAt  = Get-Date
            $state.TotalPurges  = $state.TotalPurges + 1

            $failed = @($ops | Where-Object { -not $_.Success })
            if ($failed.Count -gt 0) {
                foreach ($f in $failed) { $ctx.LogWarn("$($f.Operation): $($f.Error)") }
            }

            $ctx.Log(("system purge [{0}] {1} GB -> {2} GB free (+{3} MB)" -f `
                $reason, $before.AvailPhysGB, $after.AvailPhysGB, $freed))
        }.GetNewClosure()

        # ------------------------------------------------------------------
        # leak watch
        # ------------------------------------------------------------------
        # Trimming moves pages between lists; it cannot return memory that
        # something else is leaking. The PC this was written on sat at 0.1 GB
        # free with a driver holding every exited process (18 GB pinned) and
        # Armoury Crate on 100k+ handles, while each trim only made the game
        # fault its pages back in. Leak watch names those causes instead.

        $checkLeaks = {
            $lw  = $cfg.leakWatch
            $now = Get-Date

            # 1. Exited processes the kernel is still holding.
            $held = $lw.heldProcesses
            if ($held -and $held.enabled) {
                $k = $ctx.GetKernelLeak()
                if ($k.Error) {
                    $ctx.LogDebug("leak watch: cannot read kernel counters: $($k.Error)")
                } else {
                    $state.HeldGB = $k.HeldGB
                    $state.HeldSamples.Add([pscustomobject]@{ At = $now; Count = $k.HeldExited })
                    while ($state.HeldSamples.Count -gt 13) { $state.HeldSamples.RemoveAt(0) }

                    if ($k.HeldExited -ge $held.warnAbove -and
                        ($now - $state.LastHeldWarnAt).TotalMinutes -ge $held.warnEveryMinutes) {
                        $state.LastHeldWarnAt = $now
                        $first = $state.HeldSamples[0]
                        $hours = ($now - $first.At).TotalHours
                        $rate  = if ($hours -gt 0.05) { ' growing {0:N0}/h,' -f (($k.HeldExited - $first.Count) / $hours) } else { '' }
                        $ctx.LogWarn(("{0:N0} exited processes are still held by the kernel (~{1} GB no process owns,{2} {3:N0} running). A driver is keeping them alive - no trim or purge frees this, only Restart (not Shut down: Fast Startup keeps it)." -f `
                            $k.HeldExited, $k.HeldGB, $rate, $k.RunningProcesses))

                        if ($held.leakTest) {
                            $n = 6
                            $stuck = $ctx.RunLeakTest($n)
                            if ($stuck -gt 0) {
                                $ctx.LogWarn("leak test: $stuck of $n new processes were still held after exiting - the leak is active. Usual suspects are kernel drivers that watch every process (AMD Radeon iGPU drivers older than 32.0.21045, antivirus, VPN split tunnelling, input remappers): update the one to blame, then Restart.")
                            } else {
                                $ctx.Log("leak test: 0 of $n new processes held - not leaking now; the ones already held go at the next Restart.")
                            }
                        }
                    }
                }
            }

            $optimizers = @($lw.competingOptimizers | Where-Object { $_ })
            $pw = $lw.processes
            $sample = @()
            if (($pw -and $pw.enabled) -or $optimizers.Count -gt 0) { $sample = $ctx.GetProcessSample() }

            # 2. Processes that only ever grow.
            if ($pw -and $pw.enabled) {
                $ignore = @($pw.ignore)
                $seen = @{}
                foreach ($p in $sample) {
                    if ($ignore -contains $p.Name) { continue }
                    $seen[$p.Id] = $true

                    $hist = $state.ProcHistory[$p.Id]
                    if ($null -eq $hist -or $hist.Name -ne $p.Name) {
                        $hist = [pscustomobject]@{ Name = $p.Name; Samples = New-Object System.Collections.Generic.List[psobject] }
                        $state.ProcHistory[$p.Id] = $hist
                    }
                    $hist.Samples.Add([pscustomobject]@{ At = $now; Priv = $p.PrivateBytes; Handles = $p.Handles })
                    while ($hist.Samples.Count -gt $pw.windowSamples) { $hist.Samples.RemoveAt(0) }
                    if ($hist.Samples.Count -lt $pw.windowSamples) { continue }

                    $warned = $state.ProcWarnedAt[$p.Id]
                    if ($warned -and ($now - $warned).TotalMinutes -lt $pw.warnEveryMinutes) { continue }

                    $s     = $hist.Samples
                    $last  = $s[$s.Count - 1]
                    $hours = ($last.At - $s[0].At).TotalHours
                    if ($hours -le 0) { continue }

                    # Rising at (nearly) every sample, not just overall: a cache
                    # that fills and then plateaus is not a leak.
                    $privUp = 0; $handlesUp = 0
                    for ($i = 1; $i -lt $s.Count; $i++) {
                        if ($s[$i].Priv -gt $s[$i - 1].Priv) { $privUp++ }
                        if ($s[$i].Handles -gt $s[$i - 1].Handles) { $handlesUp++ }
                    }
                    $steps      = $s.Count - 1
                    $privMB     = $last.Priv / 1MB
                    $privPerHr  = ($last.Priv - $s[0].Priv) / 1MB / $hours
                    $handlesPerHr = ($last.Handles - $s[0].Handles) / $hours

                    $why = @()
                    if ($privUp -ge $steps - 1 -and $privMB -ge $pw.minPrivateMB -and $privPerHr -ge $pw.privateMBPerHour) {
                        $why += ('memory +{0:N0} MB/h (now {1:N0} MB)' -f $privPerHr, $privMB)
                    }
                    if ($handlesUp -ge $steps - 1 -and $last.Handles -ge $pw.minHandles -and $handlesPerHr -ge $pw.handlesPerHour) {
                        $why += ('handles +{0:N0}/h (now {1:N0})' -f $handlesPerHr, $last.Handles)
                    }
                    if ($why.Count -gt 0) {
                        $state.ProcWarnedAt[$p.Id] = $now
                        $ctx.LogWarn(("leak suspect: {0} (pid {1}) {2} - restarting it gives this back" -f $p.Name, $p.Id, ($why -join ', ')))
                    }
                }
                foreach ($id in @($state.ProcHistory.Keys)) {
                    if (-not $seen.ContainsKey($id)) { $state.ProcHistory.Remove($id); $state.ProcWarnedAt.Remove($id) }
                }
            }

            # 3. Services with a known leak: restart once past the line.
            $rs = $lw.restartServices
            if ($rs -and $rs.enabled) {
                foreach ($name in @($rs.names | Where-Object { $_ })) {
                    $handles = $ctx.GetServiceHandles($name)
                    if ($handles -lt $rs.aboveHandles) { continue }
                    $restarted = $state.ServiceRestartAt[$name]
                    if ($restarted -and ($now - $restarted).TotalMinutes -lt $rs.cooldownMinutes) { continue }
                    $state.ServiceRestartAt[$name] = $now

                    if (-not $ctx.IsElevated()) {
                        $ctx.LogWarn(("{0} is leaking ({1:N0} handles) - restarting it needs Administrator; reopen 3dxGC and accept the prompt" -f $name, $handles))
                        continue
                    }
                    $r = $ctx.RestartService($name)
                    if ($r.Success) {
                        $ctx.Log(("restarted {0}: {1:N0} -> {2:N0} handles ({3} s)" -f $name, $handles, $ctx.GetServiceHandles($name), $r.Seconds))
                    } else {
                        $ctx.LogWarn("could not restart ${name}: $($r.Error)")
                    }
                }
            }

            # 4. Another optimiser emptying working sets alongside this one.
            foreach ($name in $optimizers) {
                if ($state.OptimizersWarned.ContainsKey($name)) { continue }
                if (@($sample | Where-Object { $_.Name -eq $name }).Count -gt 0) {
                    $state.OptimizersWarned[$name] = $true
                    $ctx.LogWarn("$name is also emptying working sets. Two optimisers fight - each trim makes the other's pages fault back in. Close one of them.")
                }
            }
        }.GetNewClosure()

        # ------------------------------------------------------------------
        # event wiring
        # ------------------------------------------------------------------

        $ctx.On('game.started', {
            param($e)
            $mem = $ctx.GetProcessMemory($e.Pid)
            $ctx.Log("governing pid $($e.Pid) (working set $($mem.WorkingSetMB) MB)")
            $state.BlurredAt = $null
            $state.RamArmed  = $true
        }.GetNewClosure())

        $ctx.On('game.stopped', {
            param($e)
            $ctx.Log(("session totals: {0} trims, {1} purges, {2} MB reclaimed, peak WS {3} MB" -f `
                $state.TotalTrims, $state.TotalPurges,
                [math]::Round($state.TotalFreedMB,1), $state.SessionPeakWSMB))
            $state.BlurredAt = $null
        }.GetNewClosure())

        if ($cfg.triggers.onMinimize.enabled) {
            $ctx.On('game.minimized', {
                param($e)
                Start-Sleep -Seconds $cfg.triggers.onMinimize.delaySeconds
                & $doTrim 'minimized'
            }.GetNewClosure())
        }

        if ($cfg.triggers.onBlur.enabled) {
            # Blur is debounced: alt-tabbing out and straight back should not
            # cost a trim. The timestamp is recorded here and checked on tick.
            $ctx.On('game.blurred', {
                param($e)
                $state.BlurredAt = Get-Date
                $ctx.LogDebug("lost focus - trim armed in $($cfg.triggers.onBlur.delaySeconds)s")
            }.GetNewClosure())

            $ctx.On('game.focused', {
                param($e)
                $state.BlurredAt = $null
                $ctx.LogDebug('regained focus - trim disarmed')
            }.GetNewClosure())
        }

        if ($cfg.triggers.onIdle.enabled) {
            $ctx.On('system.idle', {
                param($e)
                if ($e.IdleSeconds -ge $cfg.triggers.onIdle.idleSeconds) {
                    & $doTrim ('idle {0:N0}s' -f $e.IdleSeconds)
                }
            }.GetNewClosure())
        }

        if ($cfg.triggers.onLowMemory.enabled) {
            $ctx.On('system.lowmemory', {
                param($e)
                $ctx.LogWarn("memory pressure: $($e.AvailPercent)% free ($($e.AvailGB) GB)")
                & $doTrim ('low memory {0}%' -f $e.AvailPercent)
                & $doSystemPurge ('low memory {0}%' -f $e.AvailPercent) $e.AvailPercent
            }.GetNewClosure())
        }

        # Tick drives leak watch, the debounced blur trim, the RAM-amount
        # trigger and the periodic sweep.
        $ctx.On('tick', {
            param($e)

            $lw = $cfg.leakWatch
            if ($lw -and $lw.enabled -and
                ((Get-Date) - $state.LastLeakCheckAt).TotalSeconds -ge $lw.everySeconds) {
                $state.LastLeakCheckAt = Get-Date
                & $checkLeaks
            }

            if ($null -ne $state.BlurredAt) {
                $elapsed = ((Get-Date) - $state.BlurredAt).TotalSeconds
                if ($elapsed -ge $cfg.triggers.onBlur.delaySeconds) {
                    $state.BlurredAt = $null
                    & $doTrim ('backgrounded {0:N0}s' -f $elapsed)
                }
            }

            # RAM amount: fires on how much memory is in use rather than on
            # time or focus. Edge-triggered - one trim per climb past the
            # line, re-armed once the reading drops back under it - so a game
            # that genuinely needs the memory is not re-trimmed every tick it
            # stays high. cooldownSeconds bounds how often a climb can fire.
            $ram = $cfg.triggers.onRamAmount
            if ($ram -and $ram.enabled -and $ctx.GetGamePid() -gt 0) {
                $over   = $null
                $sysLow = $false

                $mem = $ctx.GetProcessMemory($ctx.GetGamePid())
                if ($ram.gameAboveMB -gt 0 -and $null -ne $mem -and
                    $mem.WorkingSetMB -ge $ram.gameAboveMB) {
                    $over = 'game {0} MB >= {1} MB' -f $mem.WorkingSetMB, $ram.gameAboveMB
                }

                $sys    = $ctx.GetSystemMemory()
                $freeMB = [math]::Round($sys.AvailPhysBytes / 1MB, 0)
                if ($ram.systemFreeBelowMB -gt 0 -and $freeMB -lt $ram.systemFreeBelowMB) {
                    $sysLow = $true
                    if (-not $over) {
                        $over = 'system free {0} MB < {1} MB' -f $freeMB, $ram.systemFreeBelowMB
                    }
                }

                if (-not $over) {
                    $state.RamArmed = $true
                } elseif ($state.RamArmed) {
                    $since = ((Get-Date) - $state.LastRamTrimAt).TotalSeconds
                    if ($since -ge $ram.cooldownSeconds) {
                        # Only a trim that actually landed disarms; a skipped
                        # one (rate limit, focus) stays armed and retries.
                        # Free RAM eaten by memory the kernel is holding is not
                        # the game's to give back; trimming it while you play
                        # would only buy stutter.
                        $focusOk = [bool]$ram.whileFocused
                        $held = if ($lw) { $lw.heldProcesses } else { $null }
                        if ($focusOk -and $sysLow -and $over -notlike 'game*' -and
                            $held -and $held.skipFocusedTrimAboveGB -gt 0 -and
                            $state.HeldGB -ge $held.skipFocusedTrimAboveGB) {
                            $focusOk = $false
                            if (-not $state.HeldTrimNoted) {
                                $state.HeldTrimNoted = $true
                                $ctx.Log("free RAM is low because the kernel is holding ~$($state.HeldGB) GB - not trimming the game while it has focus")
                            }
                        }

                        $trimsBefore = $state.TotalTrims
                        & $doTrim "ram: $over" $focusOk
                        if ($state.TotalTrims -gt $trimsBefore) {
                            $state.RamArmed      = $false
                            $state.LastRamTrimAt = Get-Date
                        }
                        if ($sysLow) { & $doSystemPurge "ram: $over" $sys.AvailPercent }
                    }
                }
            }

            if ($cfg.triggers.periodic.enabled) {
                $since = ((Get-Date) - $state.LastTrimAt).TotalSeconds
                if ($since -ge $cfg.triggers.periodic.everySeconds) {
                    if ($cfg.triggers.periodic.onlyWhenBackgrounded -and $ctx.IsGameForeground()) {
                        return
                    }
                    & $doTrim 'periodic'
                }
            }
        }.GetNewClosure())

        $ctx.Log("ready - triggers: blur=$($cfg.triggers.onBlur.enabled) minimize=$($cfg.triggers.onMinimize.enabled) idle=$($cfg.triggers.onIdle.enabled) lowmem=$($cfg.triggers.onLowMemory.enabled) ram=$(if ($cfg.triggers.onRamAmount) { $cfg.triggers.onRamAmount.enabled } else { $false }) leakwatch=$(if ($cfg.leakWatch) { $cfg.leakWatch.enabled } else { $false })")
        if (-not $ctx.IsElevated()) {
            $ctx.LogWarn('unelevated: per-process trimming active, system-wide purges unavailable')
        }
    }

    Shutdown = {
        param($ctx)
        $ctx.Log('governor stopped')
    }
}
