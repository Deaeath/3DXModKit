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

        # Tick drives the debounced blur trim, the RAM-amount trigger and the
        # periodic sweep.
        $ctx.On('tick', {
            param($e)

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
                        $trimsBefore = $state.TotalTrims
                        & $doTrim "ram: $over" ([bool]$ram.whileFocused)
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

        $ctx.Log("ready - triggers: blur=$($cfg.triggers.onBlur.enabled) minimize=$($cfg.triggers.onMinimize.enabled) idle=$($cfg.triggers.onIdle.enabled) lowmem=$($cfg.triggers.onLowMemory.enabled) ram=$(if ($cfg.triggers.onRamAmount) { $cfg.triggers.onRamAmount.enabled } else { $false })")
        if (-not $ctx.IsElevated()) {
            $ctx.LogWarn('unelevated: per-process trimming active, system-wide purges unavailable')
        }
    }

    Shutdown = {
        param($ctx)
        $ctx.Log('governor stopped')
    }
}
