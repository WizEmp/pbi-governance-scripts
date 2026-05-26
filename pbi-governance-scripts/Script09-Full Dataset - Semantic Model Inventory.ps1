# ============================================================
# Script 09 — Full Dataset / Semantic Model Inventory
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Exports a complete semantic model inventory with data source and governance metadata.
.PARAMETER OutputPath
    Folder for the inventory CSV.
.PARAMETER IncludeDatasources
    Switch. If set, calls the datasource API per dataset (slower but more complete).
#>
param(
    [string]$OutputPath        = "C:\PBIAdmin\exports",
    [switch]$IncludeDatasources   # Adds data source type, server, database columns
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
$outputFile = Join-Path $OutputPath "dataset-inventory-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

Write-Host "Fetching all datasets (org scope)..." -ForegroundColor Cyan
$allDatasets = Get-PowerBIDataset -Scope Organization   # All datasets, all workspaces

# Get workspace map for name lookup (dataset object includes WorkspaceId but not name)
$workspaceMap = @{}
Get-PowerBIWorkspace -Scope Organization -All | ForEach-Object { $workspaceMap[$_.Id] = $_.Name }

$results = @()
$count = 0

foreach ($ds in $allDatasets) {
    $count++
    Write-Progress -Activity "Building dataset inventory" -Status $ds.Name `
        -PercentComplete (($count / $allDatasets.Count) * 100)

    $row = [PSCustomObject]@{
        DatasetId              = $ds.Id
        DatasetName            = $ds.Name
        WorkspaceId            = $ds.WorkspaceId
        WorkspaceName          = $workspaceMap[$ds.WorkspaceId]    # Resolved via map
        Owner                  = $ds.ConfiguredBy                  # Owner email (UPN)
        IsRefreshable          = $ds.IsRefreshable                 # Can it be scheduled?
        IsOnPremGatewayRequired = $ds.IsOnPremGatewayRequired      # Requires gateway?
        IsEffectiveIdentityRequired = $ds.IsEffectiveIdentityRequired # RLS enforced?
        IsEffectiveIdentityRolesRequired = $ds.IsEffectiveIdentityRolesRequired # RLS roles required?
        TargetStorageMode      = $ds.TargetStorageMode             # Abf / PremiumFiles
        DatasourceType         = ""
        DatasourceServer       = ""
        DatasourceDatabase     = ""
    }

    if ($IncludeDatasources) {
        try {
            $sources = Get-PowerBIDatasource -DatasetId $ds.Id `
                -WorkspaceId $ds.WorkspaceId -Scope Organization
            if ($sources) {
                # Take first datasource (most datasets have one primary source)
                $primary = $sources | Select-Object -First 1
                $row.DatasourceType     = $primary.DatasourceType     # Sql, SharePoint, File, etc.
                $row.DatasourceServer   = $primary.ConnectionDetails.server
                $row.DatasourceDatabase = $primary.ConnectionDetails.database
            }
        } catch { }
        Start-Sleep -Milliseconds 100
    }

    $results += $row
}

$results | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== DATASET INVENTORY ===" -ForegroundColor Green
Write-Host "Total datasets           : $($results.Count)"
Write-Host "Refreshable              : $(($results | Where-Object IsRefreshable -eq $true).Count)"
Write-Host "Requires gateway         : $(($results | Where-Object IsOnPremGatewayRequired -eq $true).Count)"
Write-Host "RLS enforced             : $(($results | Where-Object IsEffectiveIdentityRequired -eq $true).Count)"
Write-Host "Report: $outputFile"
