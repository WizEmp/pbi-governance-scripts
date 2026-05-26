# ============================================================
# Script 14 — Capacity Inventory and Workspace Assignment
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Maps all capacities to their assigned workspaces.
.PARAMETER OutputPath
    Folder for the output CSV.
#>
param(
    [string]$OutputPath = "C:\PBIAdmin\exports"
    # --- Authentication (same in every script; see Connect-PBIAccount function) ---
    [ValidateSet("Interactive","ServicePrincipalSecret","ServicePrincipalCert","ManagedIdentity")]
    [string]$AuthMode       = "Interactive",          # "Interactive" opens a browser for sign-in (manual use)
                                                       # "ServicePrincipalSecret" = schedulable, no browser needed
                                                       # "ServicePrincipalCert" = schedulable, most secure
                                                       # "ManagedIdentity" = for Azure Automation only
    [string]$TenantId       = "",                     # Entra ID tenant GUID — find in Azure Portal -> AAD -> Overview
    [string]$ClientId       = "",                     # App registration client ID — find in App registrations
    [string]$ClientSecret   = $env:PBI_CLIENT_SECRET, # Secret value — read from environment variable
    [string]$CertThumbprint = ""                      # Certificate thumbprint (cert-based auth only)
)

#region CONFIG
$today      = Get-Date -Format 'yyyy-MM-dd'
$outputFile = Join-Path $OutputPath "capacity-map-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# $capacities — all capacity objects (F-SKU, P-SKU, EM, Trial)
$capacities    = Get-PowerBICapacity -Scope Organization
$allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All

# Build capacity name map for quick lookup
$capacityMap = @{}
foreach ($cap in $capacities) {
    $capacityMap[$cap.Id] = [PSCustomObject]@{
        Name   = $cap.DisplayName   # e.g. "Contoso F64"
        Sku    = $cap.Sku           # F2, F64, P1, EM3, etc.
        Region = $cap.Region        # Azure region name
        State  = $cap.State         # Active / Suspended
    }
}

$results = [System.Collections.Generic.List[object]]::new()

# Workspaces ON dedicated capacity
foreach ($ws in ($allWorkspaces | Where-Object { $_.IsOnDedicatedCapacity -eq $true })) {
    $cap = $capacityMap[$ws.CapacityId]
    $results.Add([PSCustomObject]@{
        WorkspaceId      = $ws.Id
        WorkspaceName    = $ws.Name
        WorkspaceType    = $ws.Type
        WorkspaceState   = $ws.State
        CapacityId       = $ws.CapacityId
        CapacityName     = if ($cap) { $cap.Name }   else { "Unknown" }
        CapacitySku      = if ($cap) { $cap.Sku }    else { "Unknown" }
        CapacityRegion   = if ($cap) { $cap.Region } else { "Unknown" }
        CapacityState    = if ($cap) { $cap.State }  else { "Unknown" }
        OnSharedCapacity = $false
    })
}

# Workspaces NOT on dedicated capacity (shared/Pro)
foreach ($ws in ($allWorkspaces | Where-Object { -not $ws.IsOnDedicatedCapacity })) {
    $results.Add([PSCustomObject]@{
        WorkspaceId      = $ws.Id
        WorkspaceName    = $ws.Name
        WorkspaceType    = $ws.Type
        WorkspaceState   = $ws.State
        CapacityId       = ""
        CapacityName     = "Shared (Pro)"
        CapacitySku      = "Pro"
        CapacityRegion   = ""
        CapacityState    = "N/A"
        OnSharedCapacity = $true
    })
}

$results | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== CAPACITY MAP ===" -ForegroundColor Green
Write-Host "Capacities found     : $($capacities.Count)"
foreach ($cap in $capacities) {
    $wsCount = ($results | Where-Object CapacityId -eq $cap.Id).Count
    Write-Host "  $($cap.DisplayName) ($($cap.Sku), $($cap.Region)): $wsCount workspace(s)"
}
Write-Host "On shared (Pro) cap. : $(($results | Where-Object OnSharedCapacity -eq $true).Count)"
Write-Host "Report: $outputFile"
