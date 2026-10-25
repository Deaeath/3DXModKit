@{
    RootModule        = '3DXModKit.psm1'
    ModuleVersion     = '1.4.1'
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
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('3DXChat','Unity','IL2CPP','BepInEx','Memory','Modding')
            ReleaseNotes = 'Fewer restart questions: 3dxGC asks about an app only when trimming is not enough (RAM or commit really short), at most once a day, never in the first half hour, and remembers across restarts; Not now waits three days, and a new Don''t ask again button stops it for that app. Cards show friendly names. No trimming in the first five minutes after start. 1.4.0: Background apps give their RAM back without being closed: every ten minutes 3dxGC trims Explorer, Discord, browsers, Steam and other heavy apps you have not used for five minutes (never the window in front, never anything playing sound). 3dxGC never restarts an app, a service or Windows by itself any more - not even Armoury Crate: it asks with its own prompt card (Restart / Not now, in the corner, never takes focus, not hidden by Do Not Disturb), and only pressing Restart restarts anything. The leak test now waits four minutes before deciding, so a watcher that briefly holds new processes no longer reads as a leak. 1.3.1: only one control panel runs at a time. 1.3.0: leak watch - exited processes a driver is still holding, apps and services that only grow, rival memory optimisers.'
        }
    }
}
