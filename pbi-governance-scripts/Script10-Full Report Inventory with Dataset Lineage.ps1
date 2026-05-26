# ============================================================
# Script 10 — Full Report Inventory with Dataset Lineage
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Exports all reports and maps them to their source semantic models.
.PARAMETER OutputPath
    Folder for the inventory CSV.
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
$outputFile = Join-Path $OutputPath "report-inventory-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

Write-Host "Fetching all reports (org scope)..." -ForegroundColor Cyan
$allReports = Get-PowerBIReport -Scope Organization    # All reports in tenant

# Build workspace name map
$workspaceMap = @{}
Get-PowerBIWorkspace -Scope Organization -All | ForEach-Object { $workspaceMap[$_.Id] = $_.Name }

# Build dataset name map
$datasetMap = @{}
Get-PowerBIDataset -Scope Organization | ForEach-Object { $datasetMap[$_.Id] = $_.Name }

$results = $allReports | ForEach-Object {
    [PSCustomObject]@{
        ReportId       = $_.Id
        ReportName     = $_.Name
        WorkspaceId    = $_.WorkspaceId
        WorkspaceName  = $workspaceMap[$_.WorkspaceId]    # Workspace display name
        DatasetId      = $_.DatasetId                     # Source semantic model GUID
        DatasetName    = $datasetMap[$_.DatasetId]        # Source semantic model name
        DatasetWorkspaceId = $_.DatasetWorkspaceId        # May differ from report workspace (cross-ws model)
        WebUrl         = $_.WebUrl                        # Browser URL
        EmbedUrl       = $_.EmbedUrl                      # Embed URL
        ReportType     = $_.ReportType                    # PowerBIReport / PaginatedReport
    }
}

$results | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== REPORT INVENTORY ===" -ForegroundColor Green
Write-Host "Total reports      : $($results.Count)"
Write-Host "Paginated reports  : $(($results | Where-Object ReportType -eq 'PaginatedReport').Count)"
Write-Host "Cross-ws models    : $(($results | Where-Object { $_.WorkspaceId -ne $_.DatasetWorkspaceId }).Count)"
Write-Host "Report: $outputFile"
