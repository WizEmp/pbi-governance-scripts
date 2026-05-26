# ============================================================
# Script 20 — Sensitivity Label Inventory
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Inventories sensitivity labels across all Power BI items using the Scanner API.
    Identifies unlabelled items and label distribution.
.PARAMETER OutputPath
    Folder for the sensitivity label inventory CSV.
.PARAMETER ScannerThreshold
    Use Scanner API batch mode above this workspace count. Default: 50.
.NOTES
    Sensitivity label data requires the Scanner API with datasetSchema=true.
    Labels are returned in the 'sensitivityLabel' property of each item.
    Requires Fabric Administrator role + Scanner API enabled in tenant settings.
#>
param(
    [string]$OutputPath        = "C:\PBIAdmin\exports",
    [int]$ScannerThreshold     = 50,

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
$outputFile = Join-Path $OutputPath "sensitivity-labels-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All |
    Where-Object { $_.State -eq "Active" -and $_.Type -ne "PersonalGroup" }

Write-Host "Scanning $($allWorkspaces.Count) workspaces for sensitivity labels..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[object]]::new()
$wsIds   = $allWorkspaces.Id
$batches = [math]::Ceiling($wsIds.Count / 100)

for ($b = 0; $b -lt $batches; $b++) {
    $batchIds = $wsIds | Select-Object -Skip ($b * 100) -First 100

    # Scanner API with datasetSchema=true returns sensitivity label metadata
    $body      = @{ workspaces = @($batchIds) } | ConvertTo-Json -Compress
    $scanStart = Invoke-PowerBIRestMethod `
        -Url "admin/workspaces/getInfo?lineage=false&datasourceDetails=false&datasetSchema=true&datasetExpressions=false" `
        -Method Post -Body $body | ConvertFrom-Json
    $scanId    = $scanStart.id

    # Poll for completion
    $waited = 0
    do {
        Start-Sleep -Seconds 5
        $status = Invoke-PowerBIRestMethod `
            -Url "admin/workspaces/scanStatus/$scanId" -Method Get | ConvertFrom-Json
        $waited++
    } while ($status.status -notin @("Succeeded","Failed") -and $waited -lt 24)

    if ($status.status -ne "Succeeded") {
        Write-Warning "Batch $($b+1) failed. Skipping."
        continue
    }

    $scanResult = Invoke-PowerBIRestMethod `
        -Url "admin/workspaces/scanResult/$scanId" -Method Get | ConvertFrom-Json

    foreach ($ws in $scanResult.workspaces) {
        # Helper: extract label info from any item type
        function Get-LabelRow($item, $itemType, $wsName, $wsId) {
            $label   = $item.sensitivityLabel
            $hasLabel = ($null -ne $label -and $label.labelId -ne $null)
            [PSCustomObject]@{
                WorkspaceName = $wsName
                WorkspaceId   = $wsId
                ItemType      = $itemType
                ItemName      = $item.name
                ItemId        = $item.id
                HasLabel      = $hasLabel
                LabelName     = if ($hasLabel) { $label.labelDisplayName } else { "NO LABEL" }
                LabelId       = if ($hasLabel) { $label.labelId } else { "" }
                LabelSetBy    = if ($hasLabel) { $label.setBy } else { "" }
                LabelSetOn    = if ($hasLabel) { $label.setOn } else { "" }
            }
        }

        # Iterate all item types that support sensitivity labels
        foreach ($ds in $ws.datasets)   { $results.Add((Get-LabelRow $ds  "Dataset"   $ws.name $ws.id)) }
        foreach ($rp in $ws.reports)    { $results.Add((Get-LabelRow $rp  "Report"    $ws.name $ws.id)) }
        foreach ($db in $ws.dashboards) { $results.Add((Get-LabelRow $db  "Dashboard" $ws.name $ws.id)) }
        foreach ($df in $ws.dataflows)  { $results.Add((Get-LabelRow $df  "Dataflow"  $ws.name $ws.id)) }
    }
    Write-Host "  Batch $($b+1)/$batches done"
}

$results | Sort-Object HasLabel, WorkspaceName |
    Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

# Label distribution summary
$labelGroups = $results | Group-Object LabelName | Sort-Object Count -Descending

Write-Host "`n=== SENSITIVITY LABEL INVENTORY ===" -ForegroundColor Green
Write-Host "Total items scanned  : $($results.Count)"
Write-Host "Items with NO label  : $(($results | Where-Object HasLabel -eq $false).Count)" `
    -ForegroundColor $(if (($results | Where-Object HasLabel -eq $false).Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "`nLabel distribution:"
$labelGroups | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
Write-Host "`nReport: $outputFile"
