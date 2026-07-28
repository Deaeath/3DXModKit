@{
    RootModule        = '3DXModKit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b4e7c2a1-9f3d-4e58-a6c1-7d2b8e4f1a90'
    Author            = '3DXModKit'
    Description       = 'Client-side-only modular mod framework for 3DXChat (Unity 2021.3.45f2, IL2CPP), with adaptive memory management.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-ModKitInfo'
        'Test-ModKitMods'
        'Invoke-ModKitEmpty'
        'Start-ModKit'
        'Get-ModKitCapabilityCatalog'
        'Get-ModKitMods'
        'Resolve-ModKitLoadOrder'
        'ConvertTo-ModKitManifest'
        'Test-ModKitManifest'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('3DXChat','Unity','IL2CPP','BepInEx','Memory','Modding')
            ReleaseNotes = 'Initial release: capability-gated mod loader, adaptive memory governor, BepInEx 6 IL2CPP runtime tier.'
        }
    }
}
