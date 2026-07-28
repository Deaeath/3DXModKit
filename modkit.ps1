<#
.SYNOPSIS
    3DXModKit command line.

.EXAMPLE
    .\modkit.ps1 status
    .\modkit.ps1 list
    .\modkit.ps1 validate
    .\modkit.ps1 caps
    .\modkit.ps1 empty -Target Game
    .\modkit.ps1 run -Profile default
    .\modkit.ps1 watch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status','list','validate','caps','empty','run','watch','profiles','help')]
    [string]$Command = 'help',

    [string]$ProfileName = 'default',

    [ValidateSet('Game','All','WorkingSets','SystemWorkingSet','ModifiedList','Standby','LowPriorityStandby')]
    [string]$Target = 'Game',

    [int]$TickSeconds = 5,

    [ValidateSet('Debug','Info','Warn','Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '3DXModKit.psm1') -Force

function Show-Banner {
    Write-Host ''
    Write-Host '  3DXModKit' -ForegroundColor Cyan -NoNewline
    Write-Host '  client-side mod framework for 3DXChat' -ForegroundColor DarkGray
    Write-Host ''
}

switch ($Command) {

    'status' {
        Show-Banner
        $i = Get-ModKitInfo
        Write-Host '  Environment' -ForegroundColor White
        Write-Host "    modkit     : v$($i.ModKitVersion)  $($i.ModKitRoot)"
        Write-Host "    elevated   : $($i.Elevated)" -ForegroundColor $(if ($i.Elevated) { 'Green' } else { 'Yellow' })
        if (-not $i.Elevated) {
            Write-Host '                 (per-process trimming works; system-wide purges need admin)' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '  Memory' -ForegroundColor White
        $col = if ($i.AvailPercent -lt 15) { 'Red' } elseif ($i.AvailPercent -lt 30) { 'Yellow' } else { 'Green' }
        Write-Host "    total      : $($i.TotalRamGB) GB"
        Write-Host "    available  : $($i.AvailRamGB) GB ($($i.AvailPercent)%)" -ForegroundColor $col
        Write-Host "    load       : $($i.MemoryLoad)%"
        Write-Host ''
        Write-Host '  Game' -ForegroundColor White
        if ($i.GameRunning) {
            $m = [ThreeDX.ModKit.Native.MemOps]::GetProcessMemory($i.GamePid)
            Write-Host "    running    : yes (pid $($i.GamePid))" -ForegroundColor Green
            Write-Host "    workingset : $($m.WorkingSetMB) MB   (peak $($m.PeakWorkingSetMB) MB)"
            Write-Host "    private    : $($m.PrivateMB) MB"
        } else {
            Write-Host '    running    : no' -ForegroundColor DarkGray
        }
        Write-Host ''
        $pipe = Test-Path '\\.\pipe\3dxmodkit-runtime'
        Write-Host "  In-process runtime : $(if ($pipe) { 'connected' } else { 'not present' })" -ForegroundColor $(if ($pipe) { 'Green' } else { 'DarkGray' })
        Write-Host ''
    }

    'list' {
        Show-Banner
        Test-ModKitMods | Format-Table Id, Version, Tier, Valid -AutoSize
    }

    'validate' {
        Show-Banner
        $any = $false
        foreach ($m in Test-ModKitMods) {
            $c = if ($m.Valid) { 'Green' } else { 'Red' }
            Write-Host ("  {0,-18} {1,-8} {2}" -f $m.Id, $m.Version, $(if ($m.Valid) { 'ok' } else { 'INVALID' })) -ForegroundColor $c
            if ($m.Errors)   { Write-Host "      $($m.Errors)"   -ForegroundColor Red;    $any = $true }
            if ($m.Warnings) { Write-Host "      $($m.Warnings)" -ForegroundColor Yellow }
        }
        Write-Host ''
        if (-not $any) { Write-Host '  All mods valid.' -ForegroundColor Green; Write-Host '' }
    }

    'caps' {
        Show-Banner
        $cat = Get-ModKitCapabilityCatalog
        Write-Host '  Grantable capabilities' -ForegroundColor White
        foreach ($k in ($cat.Grantable.Keys | Sort-Object)) {
            Write-Host ("    {0,-22} {1}" -f $k, $cat.Grantable[$k]) -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host '  Refused unconditionally (client-side-only policy)' -ForegroundColor White
        foreach ($p in $cat.ForbiddenPrefixes) {
            Write-Host "    $p*" -ForegroundColor Red
        }
        Write-Host ''
        Write-Host '  Namespaces the in-process guard refuses to patch' -ForegroundColor White
        Write-Host ("    " + ($cat.ForbiddenNamespaces -join ', ')) -ForegroundColor DarkGray
        Write-Host ''
    }

    'profiles' {
        Show-Banner
        Get-ChildItem (Join-Path $PSScriptRoot 'profiles') -Filter *.json | ForEach-Object {
            $p = Get-Content $_.FullName -Raw | ConvertFrom-Json
            Write-Host ("  {0,-14} {1}" -f $_.BaseName, ($p.enabled -join ', ')) -ForegroundColor White
            Write-Host "                 $($p.description)" -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    'empty' {
        Show-Banner
        Write-Host "  Target: $Target" -ForegroundColor White
        Write-Host ''
        Invoke-ModKitEmpty -Target $Target | Format-Table Operation, Success, FreedMB, Ms, Error -AutoSize
    }

    'run' {
        Show-Banner
        Start-ModKit -ProfileName $ProfileName -TickSeconds $TickSeconds -LogLevel $LogLevel
    }

    'watch' {
        Show-Banner
        Write-Host '  Live memory view - Ctrl+C to stop' -ForegroundColor DarkGray
        Write-Host ''
        try {
            while ($true) {
                $s = [ThreeDX.ModKit.Native.MemOps]::GetSystemMemory()
                $g = @(Get-Process -Name '3DXChat' -ErrorAction SilentlyContinue)
                $line = "  {0}  sys {1,6} GB free ({2,5}%)" -f (Get-Date -Format 'HH:mm:ss'), $s.AvailPhysGB, $s.AvailPercent
                if ($g.Count -gt 0) {
                    $m = [ThreeDX.ModKit.Native.MemOps]::GetProcessMemory($g[0].Id)
                    $line += "   game WS {0,7} MB  private {1,7} MB" -f $m.WorkingSetMB, $m.PrivateMB
                } else {
                    $line += '   game not running'
                }
                $col = if ($s.AvailPercent -lt 15) { 'Red' } elseif ($s.AvailPercent -lt 30) { 'Yellow' } else { 'Green' }
                Write-Host $line -ForegroundColor $col
                Start-Sleep -Seconds 2
            }
        } catch [System.Management.Automation.PipelineStoppedException] { }
    }

    default {
        Show-Banner
        Write-Host '  Commands' -ForegroundColor White
        Write-Host '    status              environment, memory, and game state'
        Write-Host '    list                installed mods'
        Write-Host '    validate            validate every mod manifest'
        Write-Host '    caps                capability catalog and refusal policy'
        Write-Host '    profiles            available modpack profiles'
        Write-Host '    empty  -Target X    fire a RAMMap Empty operation now'
        Write-Host '    run    -ProfileName X   load a profile and run the governor'
        Write-Host '    watch               live memory readout'
        Write-Host ''
        Write-Host '  Examples' -ForegroundColor White
        Write-Host '    .\modkit.ps1 status' -ForegroundColor DarkGray
        Write-Host '    .\modkit.ps1 empty -Target Game' -ForegroundColor DarkGray
        Write-Host '    .\modkit.ps1 run -ProfileName default' -ForegroundColor DarkGray
        Write-Host '    .\modkit.ps1 run -ProfileName aggressive -LogLevel Debug' -ForegroundColor DarkGray
        Write-Host ''
    }
}
