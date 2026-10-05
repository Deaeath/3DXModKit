# Profile Studio - companion status for 3DX Profile Studio.
# Never installs anything - that's bootstrap\Install-ProfileStudio.ps1, run
# explicitly (the control panel's Open Profile Studio button runs it too).
#
# Client-side only: Profile Studio is one local web page. It edits text the
# player copies and pastes into the game by hand. This mod only checks that the
# page is installed and can open it in the browser.

@{
    Initialize = {
        param($ctx)

        $cfg = $ctx.Config
        $dir = Join-Path $env:LOCALAPPDATA 'Programs\3DX Profile Studio'
        $page = Join-Path $dir '3DX Profile Studio.html'
        $webUrl = 'https://deaeath.github.io/3dx-profile-studio/'

        $report = {
            if (-not (Test-Path -LiteralPath $page -PathType Leaf)) {
                if ($cfg.warnIfMissing) {
                    $ctx.LogWarn("3DX Profile Studio is not installed. Use Open Profile Studio on the Mods tab, run mods\profile-studio\bootstrap\Install-ProfileStudio.ps1, or use it online at $webUrl")
                }
                return
            }
            $version = 'unknown version'
            $versionFile = Join-Path $dir 'version.txt'
            if (Test-Path -LiteralPath $versionFile) { $version = 'v' + (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }
            $ctx.Log("3DX Profile Studio $version is installed: $page")

            if ($cfg.openWithGame -and $ctx.GetGamePid() -gt 0) {
                if ($ctx.OpenCompanionPage($page)) {
                    $ctx.Log('Opened 3DX Profile Studio in your browser (openWithGame is on).')
                } else {
                    $ctx.LogWarn("Could not open $page")
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
