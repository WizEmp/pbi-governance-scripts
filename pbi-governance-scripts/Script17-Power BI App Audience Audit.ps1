# ============================================================
# Script 17 — Power BI App Audience Audit
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Lists all Power BI Apps in the tenant with their publication audiences.
    Flags apps published to the entire organization.
.PARAMETER OutputPath
    Folder for the app audit CSV.
.NOTES
    Requires Fabric Administrator role.
    Uses the admin/apps REST endpoint — not surfaced in any native cmdlet.
#>
param(
    [string]$OutputPath = "C:\PBIAdmin\exports",

    # --- Authentication ---
    [ValidateSet("Interactive","ServicePrincipalSecret","ServicePrincipalCert","ManagedIdentity")]
    [string]$AuthMode       = "Interactive",
    [string]$TenantId       = "",
    [string]$ClientId       = "",
    [string]$ClientSecret   = $env:PBI_CLIENT_SECRET,
    [string]$CertThumbprint = ""
)

#region CONFIG
$today      = Get-Date -Format 'yyyy-MM-dd'
$outputFile = Join-Path $OutputPath "app-audience-audit-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

Write-Host "Fetching all Power BI Apps in tenant..." -ForegroundColor Cyan

# GET /v1.0/myorg/admin/apps — returns all apps across the tenant
# No native cmdlet exists for this; Invoke-PowerBIRestMethod is required
$response = Invoke-PowerBIRestMethod -Url "admin/apps?`$top=5000" -Method Get |
    ConvertFrom-Json

$apps = $response.value
Write-Host "Apps found: $($apps.Count)"

$results = [System.Collections.Generic.List[object]]::new()

foreach ($app in $apps) {
    # Each app has one or more audiences (groups the app is published to)
    # An empty audiences array means published to entire organization
    $audienceCount = if ($app.users) { $app.users.Count } else { 0 }
    $publishedToAll = ($audienceCount -eq 0)   # No specific audience = everyone

    $results.Add([PSCustomObject]@{
        AppId            = $app.id
        AppName          = $app.name
        WorkspaceId      = $app.workspaceId
        WorkspaceName    = $app.workspaceName
        PublishedBy      = $app.publishedBy        # UPN of publisher
        LastUpdate       = $app.lastUpdate          # ISO 8601 timestamp
        PublishedToAll   = $publishedToAll          # TRUE = visible to entire organization
        AudienceCount    = $audienceCount
        RiskFlag         = if ($publishedToAll) { "HIGH — published to entire org" }
                           elseif ($audienceCount -gt 50) { "MEDIUM — large audience ($audienceCount groups)" }
                           else { "" }
    })
}

$results | Sort-Object PublishedToAll -Descending |
    Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== APP AUDIT ===" -ForegroundColor Green
Write-Host "Total apps          : $($results.Count)"
Write-Host "Published to ALL    : $(($results | Where-Object PublishedToAll -eq $true).Count)" `
    -ForegroundColor $(if (($results | Where-Object PublishedToAll -eq $true).Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "Report: $outputFile"
