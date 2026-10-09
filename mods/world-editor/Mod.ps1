# World Editor - companion status for 3DX World Editor.
# Never installs anything - that's bootstrap\Install-WorldEditor.ps1, run
# explicitly (the control panel's Mods tab Open / Install buttons run it too).
#
# Client-side only: 3DX World Editor is its own app. It edits .world files on
# disk and reads the game's data files read-only to draw the real models. This
# mod checks that it is installed and has read the models, and can start it.

@{
    Initialize = {
        param($ctx)

        $cfg = $ctx.Config
        $dir = Join-Path $env:LOCALAPPDATA 'Programs\3DX World Editor'
        $exe = Join-Path $dir '3DXWorldEditor.exe'
        $cache = Join-Path $env:LOCALAPPDATA '3DXWorldEditor\assets\catalog.json'
        $webUrl = 'https://deaeath.github.io/3dx-world-editor/'

        $report = {
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
                if ($cfg.warnIfMissing) {
                    $ctx.LogWarn("3DX World Editor is not installed. Use Install on the Mods tab, run mods\world-editor\bootstrap\Install-WorldEditor.ps1, or use it online at $webUrl")
                }
                return
            }
            $version = 'unknown version'
            $versionFile = Join-Path $dir 'version.txt'
            if (Test-Path -LiteralPath $versionFile) { $version = 'v' + (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }
            $running = @(Get-Process -Name '3DXWorldEditor' -ErrorAction SilentlyContinue).Count -gt 0
            $ctx.Log("3DX World Editor $version is installed ($exe) and $(if ($running) { 'running' } else { 'not running' }).")
            if (Test-Path -LiteralPath $cache -PathType Leaf) {
                $ctx.Log("Game models read on $((Get-Item -LiteralPath $cache).LastWriteTime.ToString('yyyy-MM-dd')); delete $(Split-Path -Parent $cache) after a big game update to read them again.")
            } else {
                $ctx.Log('3DX World Editor has not read the game models yet - it does that the first time you open it (about two minutes).')
            }

            if ($cfg.launchWithGame -and -not $running -and $ctx.GetGamePid() -gt 0) {
                if ($ctx.StartCompanion($exe)) {
                    $ctx.Log('Started 3DX World Editor (launchWithGame is on).')
                } else {
                    $ctx.LogWarn("Could not start 3DX World Editor from $exe.")
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
