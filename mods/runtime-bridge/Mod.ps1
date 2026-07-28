# Runtime Bridge - host side of the two-tier memory story
#
# The division of labour:
#
#   in-process (ModKit.Runtime)  Resources.UnloadUnusedAssets() + GC.Collect()
#                                actually *release* memory. Unity holds onto
#                                textures, meshes and clips from rooms and
#                                avatars you have already left; nothing outside
#                                the process can free those.
#
#   external (3dxgc)             EmptyWorkingSet evicts what remains resident.
#
# Running them in that order matters. Trimming first just pushes pages to the
# standby list that the game is still referencing, and they fault back in.
# Unloading first shrinks what the game actually holds, so the subsequent trim
# is smaller and stickier.
#
# This mod loads at priority 5 (before 3dxgc at 10) so its handlers
# are registered - and therefore run - first.
#
# If the runtime plugin is not installed, every method here becomes a no-op and
# the host tier carries on alone.

@{
    Initialize = {
        param($ctx)

        $cfg = $ctx.Config

        $state = [pscustomobject]@{
            LastUnloadAt   = [datetime]::MinValue
            TotalUnloads   = 0
            TotalFreedMB   = 0
            RuntimeSeen    = $false
            WarnedMissing  = $false
        }

        $requestUnload = {
            param($reason)

            if (-not $cfg.enabled) { return }
            if ($ctx.GetGamePid() -le 0) { return }

            if (-not $ctx.IsRuntimeAvailable()) {
                if ($cfg.warnIfRuntimeMissing -and -not $state.WarnedMissing) {
                    $ctx.LogWarn('in-process runtime not detected - asset unloading unavailable, host-tier trimming continues')
                    $ctx.LogWarn('install it with runtime\bootstrap\Install-BepInEx.ps1 then Build-Plugin.ps1')
                    $state.WarnedMissing = $true
                }
                return
            }

            if (-not $state.RuntimeSeen) {
                $ctx.Log('in-process runtime connected')
                $state.RuntimeSeen = $true
            }

            $since = ((Get-Date) - $state.LastUnloadAt).TotalSeconds
            if ($since -lt $cfg.minSecondsBetweenUnloads) {
                $ctx.LogDebug(('unload rate-limited ({0:N0}s since last)' -f $since))
                return
            }

            $before = $ctx.GetProcessMemory($ctx.GetGamePid())
            $resp = $ctx.SendRuntimeCommand('unload', $cfg.connectTimeoutMs)

            if ($null -eq $resp) {
                $ctx.LogWarn("unload [$reason]: no response from runtime")
                return
            }
            if (-not $resp.ok) {
                $ctx.LogDebug("unload [$reason] declined: $($resp.error)")
                return
            }

            $state.LastUnloadAt = Get-Date
            $state.TotalUnloads = $state.TotalUnloads + 1

            Start-Sleep -Milliseconds 400
            $after = $ctx.GetProcessMemory($ctx.GetGamePid())
            $privDelta = [math]::Round($before.PrivateMB - $after.PrivateMB, 1)
            $state.TotalFreedMB = $state.TotalFreedMB + $privDelta

            # Private bytes is the number that matters here - unlike a working
            # set trim, this should genuinely go down.
            $ctx.Log(("unload [{0}] private {1} MB -> {2} MB (-{3} MB) | mono {4} MB, reserved {5} MB" -f `
                $reason, $before.PrivateMB, $after.PrivateMB, $privDelta,
                $resp.monoUsedMB, $resp.totalReservedMB))
        }.GetNewClosure()

        # --- wiring -------------------------------------------------------

        $ctx.On('game.started', {
            param($e)
            $state.RuntimeSeen   = $false
            $state.WarnedMissing = $false
            if ($ctx.IsRuntimeAvailable()) {
                $ctx.Log('in-process runtime detected')
                $state.RuntimeSeen = $true
            }
        }.GetNewClosure())

        if ($cfg.unloadOnBackground) {
            $ctx.On('game.minimized', {
                param($e) & $requestUnload 'minimized'
            }.GetNewClosure())
        }

        if ($cfg.unloadOnIdle) {
            $ctx.On('system.idle', {
                param($e) & $requestUnload ('idle {0:N0}s' -f $e.IdleSeconds)
            }.GetNewClosure())
        }

        if ($cfg.unloadOnLowMemory) {
            $ctx.On('system.lowmemory', {
                param($e) & $requestUnload ('low memory {0}%' -f $e.AvailPercent)
            }.GetNewClosure())
        }

        $ctx.On('tick', {
            param($e)
            if ($cfg.logStatsEveryTicks -le 0) { return }
            if (($e.Tick % $cfg.logStatsEveryTicks) -ne 0) { return }
            if (-not $ctx.IsRuntimeAvailable()) { return }

            $stats = $ctx.SendRuntimeCommand('stats', $cfg.connectTimeoutMs)
            if ($null -ne $stats -and $stats.ok) {
                $ctx.Log(("unity: mono {0} MB used / {1} MB heap | reserved {2} MB | unused reserved {3} MB" -f `
                    $stats.monoUsedMB, $stats.monoHeapMB,
                    $stats.totalReservedMB, $stats.totalUnusedReservedMB))
            }
        }.GetNewClosure())

        $ctx.On('game.stopped', {
            param($e)
            if ($state.TotalUnloads -gt 0) {
                $ctx.Log(("session: {0} unloads, {1} MB of private bytes released" -f `
                    $state.TotalUnloads, [math]::Round($state.TotalFreedMB,1)))
            }
        }.GetNewClosure())

        if ($ctx.IsRuntimeAvailable()) {
            $ctx.Log('ready - in-process runtime available')
        } else {
            $ctx.Log('ready - waiting for in-process runtime (host-tier trimming works without it)')
        }
    }

    Shutdown = {
        param($ctx)
        $ctx.Log('bridge stopped')
    }
}
