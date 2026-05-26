# ============================================================
# Script 07 — Dataset Refresh Status Report
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Reports the last refresh status for all semantic models across Premium/Fabric workspaces.
.PARAMETER OutputPath
    Folder for the refresh status report.
.PARAMETER CapacityOnly
    Switch. If set, only checks workspaces on dedicated capacity (Premium/Fabric).
    If not set, checks all workspaces including shared capacity.
.PARAMETER FailuresOnly
    Switch. If set, only outputs failed refreshes. Useful for alerting.
#>
param(
    [string]$OutputPath   = "C:\PBIAdmin\exports",
    [switch]$CapacityOnly,                          # Filter to Premium/Fabric workspaces only
    [switch]$FailuresOnly                           # Only output failed refreshes
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
$outputFile = Join-Path $OutputPath "refresh-status-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# Get workspaces
$allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All |
    Where-Object { $_.State -eq "Active" }

if ($CapacityOnly) {
    # $_.IsOnDedicatedCapacity = $true means Premium P-SKU or Fabric F-SKU
    $allWorkspaces = $allWorkspaces | Where-Object { $_.IsOnDedicatedCapacity -eq $true }
}

Write-Host "Checking $($allWorkspaces.Count) workspaces..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[object]]::new()   # O(1) append — use List not @()
$wsCount = 0

foreach ($ws in $allWorkspaces) {
    $wsCount++
    Write-Progress -Activity "Scanning workspaces" -Status "$($ws.Name)" `
        -PercentComplete (($wsCount / $allWorkspaces.Count) * 100)

    # Get all refreshable datasets in this workspace
    $datasets = Get-PowerBIDataset -WorkspaceId $ws.Id -Scope Organization |
        Where-Object { $_.IsRefreshable -eq $true }

    foreach ($ds in $datasets) {
        try {
            # API: GET /v1.0/myorg/groups/{groupId}/datasets/{datasetId}/refreshes?$top=1
            # $top=1 returns only the most recent refresh — faster than getting all history
            $raw    = Invoke-PowerBIRestMethod `
                -Url "groups/$($ws.Id)/datasets/$($ds.Id)/refreshes?`$top=1" `
                -Method Get
            $parsed = $raw | ConvertFrom-Json
            $last   = $parsed.value | Select-Object -First 1   # Most recent refresh entry

            if ($last) {
                $startTime = [datetime]$last.startTime           # When refresh began (UTC)
                $endTime   = if ($last.endTime) { [datetime]$last.endTime } else { $null }
                $duration  = if ($endTime) { [math]::Round(($endTime - $startTime).TotalMinutes, 1) } else { $null }

                $row = [PSCustomObject]@{
                    WorkspaceName  = $ws.Name
                    WorkspaceId    = $ws.Id
                    DatasetName    = $ds.Name
                    DatasetId      = $ds.Id
                    Owner          = $ds.ConfiguredBy            # Email of dataset owner
                    LastStatus     = $last.status                # Completed / Failed / Cancelled / Unknown
                    StartTime      = $startTime.ToString('o')   # ISO 8601 UTC timestamp
                    DurationMin    = $duration                   # Minutes the refresh took
                    RefreshType    = $last.refreshType           # Scheduled / OnDemand / ViaApi / ViaXmla
                    ErrorCode      = if ($last.serviceExceptionJson) {
                                         ($last.serviceExceptionJson | ConvertFrom-Json).errorCode
                                     } else { "" }
                    ErrorMessage   = if ($last.serviceExceptionJson) {
                                         ($last.serviceExceptionJson | ConvertFrom-Json).pbiError.errorCode
                                     } else { "" }
                    OnCapacity     = $ws.IsOnDedicatedCapacity
                    CapacityId     = $ws.CapacityId
                }

                if (-not $FailuresOnly -or $last.status -eq "Failed") {
                    $results.Add($row)   # .Add() is O(1) vs += which copies the array
                }
            }
        } catch {
            if (-not $FailuresOnly) {
                $results.Add([PSCustomObject]@{
                    WorkspaceName = $ws.Name; DatasetName = $ds.Name
                    LastStatus    = "ERROR_READING"; ErrorMessage = $_.Exception.Message
                })
            }
        }
        Start-Sleep -Milliseconds 100
    }
}

$results | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== REFRESH STATUS REPORT ===" -ForegroundColor Green
Write-Host "Datasets checked  : $($results.Count)"
Write-Host "Completed         : $(($results | Where-Object LastStatus -eq 'Completed').Count)"
Write-Host "Failed            : $(($results | Where-Object LastStatus -eq 'Failed').Count)" `
    -ForegroundColor $(if (($results | Where-Object LastStatus -eq 'Failed').Count -gt 0) { "Red" } else { "Green" })
Write-Host "Cancelled         : $(($results | Where-Object LastStatus -eq 'Cancelled').Count)"
Write-Host "Report: $outputFile"
