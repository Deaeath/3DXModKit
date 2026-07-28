# 3DXModKit - Mod discovery, dependency resolution, and load ordering
#
# Load order is a topological sort of the dependency graph, with LoadPriority
# and then Id used as a deterministic tie-break so the same mod set always
# produces the same order on every machine.

Set-StrictMode -Version Latest

function Get-ModKitMods {
    <#
    .SYNOPSIS
        Discovers and validates every mod under a mods directory.
    .OUTPUTS
        Validation objects (Manifest, IsValid, Errors, Warnings) - valid and invalid alike.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModsPath
    )

    if (-not (Test-Path -LiteralPath $ModsPath)) {
        Write-Warning "Mods directory not found: $ModsPath"
        return @()
    }

    $results = New-Object System.Collections.Generic.List[psobject]

    Get-ChildItem -LiteralPath $ModsPath -Directory | ForEach-Object {
        $manifestPath = Join-Path $_.FullName 'mod.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            Write-Verbose "Skipping '$($_.Name)': no mod.json"
            return
        }
        try {
            $manifest = ConvertTo-ModKitManifest -Path $manifestPath
            $results.Add((Test-ModKitManifest -Manifest $manifest))
        } catch {
            # A manifest that will not even parse still needs to be reported.
            $results.Add([pscustomobject]@{
                Manifest = [pscustomobject]@{
                    Id = $_.Name; Name = $_.Name; Version = '0.0.0'
                    Tier = 'host'; Capabilities = @(); Dependencies = @()
                    Conflicts = @(); LoadPriority = 100
                    Root = $_.FullName; ManifestPath = $manifestPath
                }
                IsValid  = $false
                Errors   = @("manifest unreadable: $($_.Exception.Message)")
                Warnings = @()
            })
        }
    }

    return $results.ToArray()
}

function Resolve-ModKitLoadOrder {
    <#
    .SYNOPSIS
        Produces a deterministic load order for a set of mods.
    .DESCRIPTION
        Kahn's algorithm over the dependency graph. Reports missing dependencies,
        declared conflicts, and dependency cycles as structured errors rather
        than throwing, so the caller can present all problems at once.
    .PARAMETER Manifests
        Manifest objects (not validation wrappers) to order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Manifests
    )

    $errors   = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($Manifests.Count -eq 0) {
        return [pscustomobject]@{
            Order = @(); Errors = @(); Warnings = @('no mods to load')
        }
    }

    # Index by id, catching duplicates.
    $byId = @{}
    foreach ($m in $Manifests) {
        if ($byId.ContainsKey($m.Id)) {
            $errors.Add("duplicate mod id '$($m.Id)' (in $($m.Root) and $($byId[$m.Id].Root))")
            continue
        }
        $byId[$m.Id] = $m
    }

    # Conflicts are symmetric: if either side declares it, refuse both.
    foreach ($m in $byId.Values) {
        foreach ($c in $m.Conflicts) {
            if ($byId.ContainsKey($c)) {
                $errors.Add("'$($m.Id)' conflicts with '$c' - both are enabled")
            }
        }
    }

    # Build edges dep -> dependent, and in-degree per node.
    $inDegree = @{}
    $edges    = @{}
    foreach ($id in $byId.Keys) {
        $inDegree[$id] = 0
        $edges[$id] = New-Object System.Collections.Generic.List[string]
    }

    foreach ($m in $byId.Values) {
        foreach ($dep in $m.Dependencies) {
            # Accept "id" or "id@>=1.2.0"; version constraints are advisory for now.
            $depId = ($dep -split '@')[0].Trim()
            if (-not $byId.ContainsKey($depId)) {
                $errors.Add("'$($m.Id)' depends on '$depId', which is not installed or not enabled")
                continue
            }
            $edges[$depId].Add($m.Id)
            $inDegree[$m.Id] = $inDegree[$m.Id] + 1
        }
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Order = @(); Errors = $errors.ToArray(); Warnings = $warnings.ToArray()
        }
    }

    # Kahn's algorithm. The ready set is drained in a stable order
    # (LoadPriority, then Id) so output is reproducible.
    $ready = New-Object System.Collections.Generic.List[string]
    foreach ($id in $inDegree.Keys) {
        if ($inDegree[$id] -eq 0) { $ready.Add($id) }
    }

    $ordered = New-Object System.Collections.Generic.List[psobject]

    while ($ready.Count -gt 0) {
        $sorted = @($ready | Sort-Object @{ Expression = { $byId[$_].LoadPriority } }, @{ Expression = { $_ } })
        $next = $sorted[0]
        [void]$ready.Remove($next)
        $ordered.Add($byId[$next])

        foreach ($dependent in $edges[$next]) {
            $inDegree[$dependent] = $inDegree[$dependent] - 1
            if ($inDegree[$dependent] -eq 0) { $ready.Add($dependent) }
        }
    }

    if ($ordered.Count -ne $byId.Count) {
        $stuck = @($byId.Keys | Where-Object { $inDegree[$_] -gt 0 })
        $errors.Add("dependency cycle among: $($stuck -join ', ')")
        return [pscustomobject]@{
            Order = @(); Errors = $errors.ToArray(); Warnings = $warnings.ToArray()
        }
    }

    [pscustomobject]@{
        Order    = $ordered.ToArray()
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
    }
}
