# ============================================================
# Script 13 — Find Datasets with No Recent Refresh (Stale Data)
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Identifies datasets that have not refreshed successfully within a threshold.
.PARAMETER StaleThresholdDays
    Datasets with no successful refresh in this many days are flagged. Default: 7.
.PARAMETER OutputPath
    Folder for the report.
#>
param(
    [int]$StaleThresholdDays = 7,       # Flag if no success in this many days
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
$today       = Get-Date -Format 'yyyy-MM-dd'
$outputFile  = Join-Path $OutputPath "stale-datasets-$today.csv"
$cutoffDate  = (Get-Date).AddDays(-$StaleThresholdDays)   # DateTime threshold
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$workspaceMap = @{}
Get-PowerBIWorkspace -Scope Organization -All | ForEach-Object { $workspaceMap[$_.Id] = $_.Name }

$allDatasets = Get-PowerBIDataset -Scope Organization |
    Where-Object { $_.IsRefreshable -eq $true }

Write-Host "Checking $($allDatasets.Count) refreshable datasets..." -ForegroundColor Cyan
$stale = [System.Collections.Generic.List[object]]::new()

foreach ($ds in $allDatasets) {
    try {
        # Get last 5 refreshes — check if any succeeded recently
        $raw    = Invoke-PowerBIRestMethod `
            -Url "groups/$($ds.WorkspaceId)/datasets/$($ds.Id)/refreshes?`$top=5" `
            -Method Get
        $parsed = $raw | ConvertFrom-Json
        $refreshes = $parsed.value   # Array of refresh history, most recent first

        $lastSuccess = $refreshes | Where-Object { $_.status -eq "Completed" } | Select-Object -First 1

        $lastSuccessDate = if ($lastSuccess) { [datetime]$lastSuccess.endTime } else { $null }

        # Flag if: no success ever, OR last success older than threshold
        $isStale = (-not $lastSuccess) -or ($lastSuccessDate -lt $cutoffDate)

        if ($isStale) {
            $stale.Add([PSCustomObject]@{
                WorkspaceName     = $workspaceMap[$ds.WorkspaceId]
                WorkspaceId       = $ds.WorkspaceId
                DatasetName       = $ds.Name
                DatasetId         = $ds.Id
                Owner             = $ds.ConfiguredBy
                LastSuccessDate   = if ($lastSuccessDate) { $lastSuccessDate.ToString('yyyy-MM-dd') } else { "NEVER" }
                DaysSinceSuccess  = if ($lastSuccessDate) { [math]::Round(((Get-Date) - $lastSuccessDate).TotalDays, 0) } else { 9999 }
                LastRefreshStatus = if ($refreshes.Count -gt 0) { $refreshes[0].status } else { "NO_HISTORY" }
            })
        }
    } catch { }
    Start-Sleep -Milliseconds 80
}

$stale | Sort-Object DaysSinceSuccess -Descending | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== STALE DATASET REPORT ===" -ForegroundColor Green
Write-Host "Threshold     : $StaleThresholdDays days"
Write-Host "Stale datasets: $($stale.Count)" -ForegroundColor $(if ($stale.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "Never refreshed: $(($stale | Where-Object LastSuccessDate -eq 'NEVER').Count)"
Write-Host "Report: $outputFile"
