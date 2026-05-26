# ============================================================
# Script 04 — Audit Active Publish to Web Embed Codes
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Audits all active Publish to Web embed codes and flags stale ones.
.PARAMETER StaleThresholdDays
    Number of days after which a code is flagged as stale. Default: 90.
.PARAMETER OutputPath
    Folder for the audit report CSV.
#>
param(
    [int]$StaleThresholdDays = 90,    # Codes older than this are flagged for review
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
$today = Get-Date -Format 'yyyy-MM-dd'
$outputFile = Join-Path $OutputPath "embed-codes-audit-$today.csv"
$cutoffDate = (Get-Date).AddDays(-$StaleThresholdDays)
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# API: GET /v1.0/myorg/admin/embeds/publishedItems
$response  = Invoke-PowerBIRestMethod -Url "admin/embeds/publishedItems" -Method Get
$parsed    = $response | ConvertFrom-Json

# $parsed.publishedItems — array of all embed codes (active and inactive)
$allCodes  = $parsed.publishedItems

$report = $allCodes | ForEach-Object {
    $publishedDate = [datetime]$_.publishedDate   # When the embed code was created
    $ageDays = ((Get-Date) - $publishedDate).Days  # How many days old

    [PSCustomObject]@{
        ReportName     = $_.reportName
        WorkspaceName  = $_.workspaceName
        PublishedBy    = $_.publishedBy            # UPN of creator
        PublishedDate  = $publishedDate.ToString('yyyy-MM-dd')
        AgeDays        = $ageDays
        Status         = $_.status                 # Enabled / Disabled
        IsStale        = ($ageDays -gt $StaleThresholdDays -and $_.status -eq "Enabled")
        EmbedUrl       = $_.reportUrl              # The actual public URL
    }
}

$report | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

# Console summary
$active = $report | Where-Object { $_.Status -eq "Enabled" }
$stale  = $report | Where-Object { $_.IsStale -eq $true }

Write-Host "`n=== EMBED CODE AUDIT ===" -ForegroundColor Green
Write-Host "Total codes    : $($report.Count)"
Write-Host "Active (public): $($active.Count)"
Write-Host "Stale (>$StaleThresholdDays days): $($stale.Count)" -ForegroundColor $(if ($stale.Count -gt 0) { "Red" } else { "Green" })

if ($stale.Count -gt 0) {
    Write-Host "`nSTALE CODES REQUIRING REVIEW:" -ForegroundColor Red
    $stale | Select-Object ReportName, WorkspaceName, PublishedBy, AgeDays | Format-Table -AutoSize
}

Write-Host "Report: $outputFile"
