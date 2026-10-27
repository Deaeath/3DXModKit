@{
    RootModule        = '3DXModKit.psm1'
    ModuleVersion     = '1.6.0'
    GUID              = 'b4e7c2a1-9f3d-4e58-a6c1-7d2b8e4f1a90'
    Author            = '3DXModKit'
    Description       = 'Client-side-only modular mod framework for 3DXChat (Unity 2021.3.45f2, IL2CPP), with adaptive memory management.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-ModKitCompanions'
        'Get-ModKitInfo'
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('3DXChat','Unity','IL2CPP','BepInEx','Memory','Modding')
            ReleaseNotes = 'Frees memory as soon as it can: apps you have left are trimmed 30 seconds after you leave them (again as they grow back, less often for ones that take it straight back), and while you are away 3dxGC sweeps the whole PC like RAMMap''s Empty menu, except emptying standby, which already counts as free. Caps: an app''s processes share its cap by what each needs, so a busy tab no longer pages at a fixed slice. Installs like a regular Windows app: 3dxGC-Setup (per user, no admin) adds Start menu and desktop shortcuts, Start with Windows, an Apps & Features entry and an uninstaller that asks about your settings, and brings settings over from a copy run from the zip. 3dxGC.exe opens the panel with no console window, and the panel has its own icon on the taskbar and in the tray. 1.5.1: Caps that settle: each capped app''s ceiling finds what it actually uses (room when it pages hard, a step lower when it sits quiet), the keep-free squeeze holds when it frees nothing and backs off when capped apps churn - 1.5.0 could squeeze everything to the floor and page two million times a second for nothing. Fixes a crash that stopped the governor''s tick once an app passed 2 GB. Process list from the kernel instead of WMI (40 ms, not a second). The Caps tab shows exactly what is happening to each app. Warns when the system drive runs low. 1.5.0: RAM caps: background apps get a hard RAM ceiling Windows enforces, plus low memory priority, lifted the moment you switch to them; always keep X GB free (caps tighten until you have it); per-app caps, Never cap and the keep-free target on the control panel''s new Caps tab, applied live. Replaces trimming background apps every few minutes, which they simply pulled back. The game''s periodic trim backs off when the game takes its memory straight back. 1.4.1: Fewer restart questions: 3dxGC asks about an app only when trimming is not enough (RAM or commit really short), at most once a day, never in the first half hour, and remembers across restarts; Not now waits three days, and a new Don''t ask again button stops it for that app. Cards show friendly names. No trimming in the first five minutes after start. 1.4.0: Background apps give their RAM back without being closed: every ten minutes 3dxGC trims Explorer, Discord, browsers, Steam and other heavy apps you have not used for five minutes (never the window in front, never anything playing sound). 3dxGC never restarts an app, a service or Windows by itself any more - not even Armoury Crate: it asks with its own prompt card (Restart / Not now, in the corner, never takes focus, not hidden by Do Not Disturb), and only pressing Restart restarts anything. The leak test now waits four minutes before deciding, so a watcher that briefly holds new processes no longer reads as a leak. 1.3.1: only one control panel runs at a time. 1.3.0: leak watch - exited processes a driver is still holding, apps and services that only grow, rival memory optimisers.'
        }
    }
}
