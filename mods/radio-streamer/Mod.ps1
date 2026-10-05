# Radio Streamer - companion status for 3DX Radio Streamer.
# Never installs anything - that's bootstrap\Install-RadioStreamer.ps1, run
# explicitly, same split as reshade and lossless-scaling.
#
# Client-side only: 3DX Radio Streamer is its own desktop app. It talks to
# the user's radio host; the game only ever plays the station's public URL
# like any other room radio. This mod reads that app's settings file (outside
# the game directory) and its process list entry, and can start it. It never
# opens a socket, and the source password in those settings is never logged.

@{
    Initialize = {
        param($ctx)

        $cfg = $ctx.Config
        $appId = '{6F1C2B7A-3D58-4E8B-9A57-2C41E7A0B3D9}_is1'     # Inno Setup AppId of the installer
        $processName = '3DX Radio Streamer'
        $settingsPath = Join-Path $env:APPDATA '3DXRadioStreamer\settings.json'
        $sources = @{
            queue    = 'its playlist'
            loopback = 'everything this PC plays (game sounds included)'
            app      = 'one app only'
            device   = 'an audio input'
        }

        $prop = {
            param($obj, [string]$Name, $Default = $null)
            if ($obj -and $obj.PSObject.Properties.Name -contains $Name) { return $obj.$Name }
            return $Default
        }

        $findInstall = {
            if ($cfg.installPath -and (Test-Path -LiteralPath $cfg.installPath -PathType Leaf)) { return $cfg.installPath }
            $roots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                       'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                       'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
            foreach ($root in $roots) {
                try {
                    $dir = (Get-ItemProperty -Path (Join-Path $root $appId) -Name 'InstallLocation' -ErrorAction Stop).InstallLocation
                    $exe = Join-Path $dir "$processName.exe"
                    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
                } catch { }
            }
            foreach ($dir in @((Join-Path $env:LOCALAPPDATA "Programs\$processName"), (Join-Path $env:ProgramFiles $processName))) {
                $exe = Join-Path $dir "$processName.exe"
                if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
            }
            return $null
        }.GetNewClosure()

        $roomUrl = {
            param($s)
            $hostName = [string](& $prop $s 'host' '')
            if (-not $hostName.Trim()) { return $null }
            $base = "http://$($hostName.Trim()):$(& $prop $s 'port' 8000)"
            switch ([string](& $prop $s 'server_type' 'Shoutcast v1')) {
                'Icecast 2'    { $mount = [string](& $prop $s 'mount' '/stream')
                                 if (-not $mount.StartsWith('/')) { $mount = "/$mount" }
                                 return "$base$mount" }
                'Shoutcast v2' { return "$base/stream/$(& $prop $s 'sid' 1)/" }
                # The trailing ';' makes Shoutcast v1 send the audio stream rather than
                # its HTML status page - the form the game's own Player.log shows playing.
                default        { return "$base/;" }
            }
        }.GetNewClosure()

        $report = {
            $exe = & $findInstall
            if (-not $exe) {
                if ($cfg.warnIfMissing) {
                    $ctx.LogWarn('3DX Radio Streamer is not installed. Run mods\radio-streamer\bootstrap\Install-RadioStreamer.ps1 to download and install it.')
                }
                return
            }

            $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0
            $ctx.Log("3DX Radio Streamer is installed ($exe) and $(if ($running) { 'running' } else { 'not running' }).")

            if (-not (Test-Path -LiteralPath $settingsPath)) {
                $ctx.LogWarn('3DX Radio Streamer has not been set up yet. Open it once and follow its setup wizard.')
            } else {
                try {
                    $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
                    $src = [string](& $prop $s 'source' 'queue')
                    $what = if ($sources.ContainsKey($src)) { $sources[$src] } else { $src }
                    if ($src -eq 'app' -and (& $prop $s 'app_name' '')) { $what += " ($(& $prop $s 'app_name'))" }
                    $ctx.Log("Station '$(& $prop $s 'name' 'My Radio')' on $(& $prop $s 'provider' 'a custom server'), airing $what.")
                    $url = & $roomUrl $s
                    if ($url) {
                        $ctx.Log("Room radio URL: $url")
                    } else {
                        $ctx.LogWarn('No radio server set in 3DX Radio Streamer yet (Server tab or File > Setup wizard).')
                    }
                } catch {
                    $ctx.LogWarn("Could not read 3DX Radio Streamer's settings: $($_.Exception.Message)")
                }
            }

            if ($cfg.launchWithGame -and -not $running -and $ctx.GetGamePid() -gt 0) {
                if ($ctx.StartCompanion($exe)) {
                    $ctx.Log('Started 3DX Radio Streamer (launchWithGame is on).')
                } else {
                    $ctx.LogWarn("Could not start 3DX Radio Streamer from $exe.")
                }
            }
        }.GetNewClosure()

        $ctx.On('game.started', { param($e) & $report }.GetNewClosure())

        # When the game is already running, the host raises game.started right
        # after loading, so reporting here too would print everything twice.
        # (At load time the host hasn't looked for the game yet, so ask Windows.)
        if (@(Get-Process -Name '3DXChat' -ErrorAction SilentlyContinue).Count -eq 0) { & $report }
    }

    Shutdown = {
        param($ctx)
    }
}
