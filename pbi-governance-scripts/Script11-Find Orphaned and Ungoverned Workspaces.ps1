# ============================================================
# Script 11 — Find Orphaned and Ungoverned Workspaces
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Governance risk report for all workspaces. Uses Scanner API for tenants
    with more workspaces than ScannerThreshold to reduce API call volume.
.PARAMETER OutputPath
    Folder for the risk report CSV.
.PARAMETER MinAdmins
    Flag workspaces with fewer admins than this. Default: 2.
.PARAMETER ScannerThreshold
    Use Scanner API when active workspace count exceeds this. Default: 100.
.PARAMETER AuthMode / TenantId / ClientId / ClientSecret / CertThumbprint
    Standard auth parameters — see Connect-PBIAccount.
#>
param(
    [string]$OutputPath        = "C:\PBIAdmin\exports",
    [int]$MinAdmins            = 2,
    [int]$ScannerThreshold     = 100,

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
$outputFile = Join-Path $OutputPath "workspace-risk-$today.csv"
$isPS7      = ($PSVersionTable.PSVersion.Major -ge 7)
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All |
    Where-Object { $_.State -eq "Active" -and $_.Type -ne "PersonalGroup" }

Write-Host "Workspaces to analyse: $($allWorkspaces.Count)" -ForegroundColor Cyan

# ── Collect member data ────────────────────────────────────────────────────────
# $wsMemberMap: hashtable of WorkspaceId -> @{ MemberCount; AdminCount }
$wsMemberMap = @{}

if ($allWorkspaces.Count -gt $ScannerThreshold) {

    Write-Host "Using Scanner API (large tenant)..." -ForegroundColor Yellow
    $wsIds   = $allWorkspaces.Id
    $batches = [math]::Ceiling($wsIds.Count / 100)

    for ($b = 0; $b -lt $batches; $b++) {
        $batchIds  = $wsIds | Select-Object -Skip ($b * 100) -First 100
        $body      = @{ workspaces = @($batchIds) } | ConvertTo-Json -Compress
        $scanStart = Invoke-PowerBIRestMethod `
            -Url "admin/workspaces/getInfo?lineage=false&datasourceDetails=false&datasetSchema=false" `
            -Method Post -Body $body | ConvertFrom-Json
        $scanId    = $scanStart.id

        $waited = 0
        do {
            Start-Sleep -Seconds 5
            $status = Invoke-PowerBIRestMethod `
                -Url "admin/workspaces/scanStatus/$scanId" -Method Get | ConvertFrom-Json
            $waited++
        } while ($status.status -notin @("Succeeded","Failed") -and $waited -lt 24)

        if ($status.status -ne "Succeeded") {
            Write-Warning "Batch $($b+1) scan failed. Skipping."; continue
        }

        $results = Invoke-PowerBIRestMethod `
            -Url "admin/workspaces/scanResult/$scanId" -Method Get | ConvertFrom-Json

        foreach ($wsResult in $results.workspaces) {
            $users      = $wsResult.users ?? @()   # Scanner returns users array
            $adminCount = ($users | Where-Object groupUserAccessRight -eq "Admin").Count
            $wsMemberMap[$wsResult.id] = @{
                MemberCount = $users.Count
                AdminCount  = $adminCount
            }
        }
        Write-Host "  Batch $($b+1)/$batches processed"
    }

} elseif ($isPS7) {

    Write-Host "Using parallel per-workspace fetch (PS7, ThrottleLimit: 5)..." -ForegroundColor Cyan
    $token = Get-PowerBIAccessToken -AsString

    $parallelData = $allWorkspaces | ForEach-Object -Parallel {
        $ws      = $_
        $headers = @{ Authorization = $using:token }
        try {
            $r = Invoke-RestMethod `
                -Uri "https://api.powerbi.com/v1.0/myorg/admin/groups/$($ws.Id)/users" `
                -Headers $headers -Method Get
            [PSCustomObject]@{
                WorkspaceId  = $ws.Id
                MemberCount  = $r.value.Count
                AdminCount   = ($r.value | Where-Object groupUserAccessRight -eq "Admin").Count
            }
        } catch {
            [PSCustomObject]@{ WorkspaceId = $ws.Id; MemberCount = -1; AdminCount = 0 }
        }
    } -ThrottleLimit 5

    foreach ($item in $parallelData) {
        $wsMemberMap[$item.WorkspaceId] = @{
            MemberCount = $item.MemberCount
            AdminCount  = $item.AdminCount
        }
    }

} else {

    Write-Host "Using sequential loop (PS5.1)..." -ForegroundColor Cyan
    $count = 0
    foreach ($ws in $allWorkspaces) {
        $count++
        Write-Progress -Activity "Fetching members" -Status $ws.Name `
            -PercentComplete (($count / $allWorkspaces.Count) * 100)
        try {
            $parsed  = Invoke-PowerBIRestMethod `
                -Url "admin/groups/$($ws.Id)/users" -Method Get | ConvertFrom-Json
            $members = $parsed.value
            $wsMemberMap[$ws.Id] = @{
                MemberCount = $members.Count
                AdminCount  = ($members | Where-Object groupUserAccessRight -eq "Admin").Count
            }
        } catch {
            $wsMemberMap[$ws.Id] = @{ MemberCount = -1; AdminCount = 0 }
        }
        Start-Sleep -Milliseconds 100
    }
}

# ── Build risk report ──────────────────────────────────────────────────────────
$riskReport = [System.Collections.Generic.List[object]]::new()
foreach ($ws in $allWorkspaces) {
    $data        = $wsMemberMap[$ws.Id]
    $memberCount = if ($data) { $data.MemberCount } else { -1 }
    $adminCount  = if ($data) { $data.AdminCount  } else { 0  }

    $isOrphaned    = ($memberCount -eq 0)
    $noCapacity    = (-not $ws.IsOnDedicatedCapacity)
    $tooFewAdmins  = ($adminCount -lt $MinAdmins -and -not $isOrphaned)
    $fetchFailed   = ($memberCount -eq -1)

    if ($isOrphaned -or $noCapacity -or $tooFewAdmins -or $fetchFailed) {
        $riskReport.Add([PSCustomObject]@{
            WorkspaceId   = $ws.Id
            WorkspaceName = $ws.Name
            MemberCount   = $memberCount
            AdminCount    = $adminCount
            IsOrphaned    = $isOrphaned
            NoCapacity    = $noCapacity
            TooFewAdmins  = $tooFewAdmins
            FetchFailed   = $fetchFailed   # API error during member lookup
            RiskLevel     = if ($isOrphaned -or $fetchFailed) { "HIGH" }
                            elseif ($tooFewAdmins) { "MEDIUM" }
                            else { "LOW" }
        })
    }
}

$methodUsed = if ($allWorkspaces.Count -gt $ScannerThreshold) { "Scanner API" }
              elseif ($isPS7) { "Parallel PS7" }
              else { "Sequential PS5" }

$riskReport | Sort-Object RiskLevel | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== WORKSPACE RISK REPORT ===" -ForegroundColor Green
Write-Host "Method used         : $methodUsed"
Write-Host "Workspaces analysed : $($allWorkspaces.Count)"
Write-Host "HIGH risk           : $(($riskReport | Where-Object RiskLevel -eq 'HIGH').Count)" -ForegroundColor Red
Write-Host "MEDIUM risk         : $(($riskReport | Where-Object RiskLevel -eq 'MEDIUM').Count)" -ForegroundColor Yellow
Write-Host "LOW risk            : $(($riskReport | Where-Object RiskLevel -eq 'LOW').Count)"
Write-Host "Report: $outputFile"
