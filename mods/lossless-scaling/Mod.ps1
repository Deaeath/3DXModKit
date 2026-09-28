# Lossless Scaling Status - reports whether it's installed/configured.
# Never installs, never configures, never purchases anything - that's all
# bootstrap\Setup-LosslessScaling.ps1, run explicitly, same split as reshade.
#
# Chosen over ReShade for "make it look nicer" specifically because it's
# genuinely external: it captures and reprocesses the game's own rendered
# window (AI upscaling + optional frame generation), so nothing is added to
# the game's install directory at all - nothing for its anti-tamper systems
# to react to, unlike ReShade's dxgi.dll, which this session watched get
# silently stripped after every launch.
#
# Client-side only, trivially: this only reads local files belonging to a
# separate desktop application. Never touches the network, the chat
# protocol, or anything server-authoritative.

@{
    Initialize = {
        param($ctx)

        $cfg = $ctx.Config
        $state = [pscustomobject]@{ Checked = $false }
        $steamAppId = '993090'

        $findInstall = {
            $steamPath = $null
            try {
                $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction Stop).SteamPath -replace '/', '\'
            } catch { }
            if (-not $steamPath) {
                $fallback = 'C:\Program Files (x86)\Steam'
                if (Test-Path -LiteralPath $fallback) { $steamPath = $fallback }
            }
            if (-not $steamPath) { return $null }

            $libs = @($steamPath)
            $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
            if (Test-Path -LiteralPath $vdf) {
                $content = Get-Content -LiteralPath $vdf -Raw
                foreach ($m in [regex]::Matches($content, '"path"\s*"([^"]+)"')) {
                    $p = $m.Groups[1].Value -replace '\\\\', '\'
                    if ($libs -notcontains $p) { $libs += $p }
                }
            }

            foreach ($lib in $libs) {
                $exe = Join-Path $lib 'steamapps\common\Lossless Scaling\LosslessScaling.exe'
                if (Test-Path -LiteralPath $exe) { return $exe }
            }
            return $null
        }.GetNewClosure()

        $checkStatus = {
            if ($cfg.checkOnlyOnce -and $state.Checked) { return }
            $state.Checked = $true

            $exe = & $findInstall
            if (-not $exe) {
                if ($cfg.warnIfMissing) {
                    $ctx.LogWarn("Lossless Scaling is not installed (a paid Steam app, ~`$7). Run mods\lossless-scaling\bootstrap\Setup-LosslessScaling.ps1 - it opens the store page (App ID $steamAppId) for you.")
                }
                return
            }

            $settingsPath = Join-Path $env:LOCALAPPDATA 'Lossless Scaling\Settings.xml'
            if (-not (Test-Path -LiteralPath $settingsPath)) {
                $ctx.LogWarn('Lossless Scaling is installed but has never been run. Launch it once, or run bootstrap\Setup-LosslessScaling.ps1.')
                return
            }

            try {
                [xml]$xml = Get-Content -LiteralPath $settingsPath -Raw
                $profile = $xml.Settings.GameProfiles.Profile | Where-Object { $_.Title -eq '3DXChat' }
                if ($profile) {
                    $ctx.Log("Lossless Scaling is installed and has a '3DXChat' profile (ScalingType=$($profile.ScalingType), FrameGeneration=$($profile.FrameGeneration)).")
                } elseif ($cfg.warnIfMissing) {
                    $ctx.LogWarn("Lossless Scaling is installed but has no '3DXChat' profile yet. Run mods\lossless-scaling\bootstrap\Setup-LosslessScaling.ps1 to create one.")
                }
            } catch {
                $ctx.LogWarn("Could not read Lossless Scaling's settings: $($_.Exception.Message)")
            }
        }.GetNewClosure()

        $ctx.On('game.started', { param($e) & $checkStatus }.GetNewClosure())

        # In case the game is already running when the profile starts.
        & $checkStatus
    }

    Shutdown = {
        param($ctx)
    }
}
