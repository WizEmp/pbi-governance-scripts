# ============================================================
# Script 01 — Full Tenant Workspace Inventory with Members
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Exports a full workspace inventory including members. Auto-selects Scanner API
    for large tenants (>100 workspaces) to stay within API rate limits.
.PARAMETER OutputPath
    Folder where CSV files are saved.
.PARAMETER ScannerThreshold
    Workspace count above which Scanner API is used instead of per-workspace calls.
    Default: 100. Lower this to always use Scanner API.
.PARAMETER AuthMode
    Interactive | ServicePrincipalSecret | ServicePrincipalCert | ManagedIdentity
.PARAMETER TenantId / ClientId / ClientSecret / CertThumbprint
    Credentials for non-interactive modes.
#>
param(
    [string]$OutputPath         = "C:\PBIAdmin\exports",
    [int]$ScannerThreshold      = 100,   # Use Scanner API when active workspace count exceeds this

    # --- Authentication ---
    [ValidateSet("Interactive","ServicePrincipalSecret","ServicePrincipalCert","ManagedIdentity")]
    [string]$AuthMode       = "Interactive",
    [string]$TenantId       = "",
    [string]$ClientId       = "",
    [string]$ClientSecret   = $env:PBI_CLIENT_SECRET,
    [string]$CertThumbprint = ""
)

#region CONFIG
$today         = Get-Date -Format 'yyyy-MM-dd'
$workspaceFile = Join-Path $OutputPath "workspaces-$today.csv"
$membersFile   = Join-Path $OutputPath "workspace-members-$today.csv"
$isPS7         = ($PSVersionTable.PSVersion.Major -ge 7)
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# ── Step 1: Get all workspaces (fast — single call) ───────────────────────────
Write-Host "Fetching workspace list..." -ForegroundColor Cyan
$allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All
$activeWs      = $allWorkspaces | Where-Object { $_.State -eq "Active" }

Write-Host "Total workspaces: $($allWorkspaces.Count) | Active: $($activeWs.Count)"

# ── Step 2: Workspace summary CSV ─────────────────────────────────────────────
$allWorkspaces | Select-Object `
    @{N="WorkspaceId";E={$_.Id}},
    @{N="WorkspaceName";E={$_.Name}},
    Type, State,
    @{N="OnDedicatedCapacity";E={$_.IsOnDedicatedCapacity}},
    CapacityId, IsReadOnly |
    Export-Csv $workspaceFile -NoTypeInformation -Encoding UTF8BOM

# ── Step 3: Member list — Scanner API for large tenants ───────────────────────
$memberReport = [System.Collections.Generic.List[object]]::new()

if ($activeWs.Count -gt $ScannerThreshold) {

    Write-Host "Large tenant detected ($($activeWs.Count) workspaces > $ScannerThreshold threshold)." -ForegroundColor Yellow
    Write-Host "Using Scanner API (batch mode — ~$([math]::Ceiling($activeWs.Count/100)) API calls)..." -ForegroundColor Cyan

    # Scanner API processes up to 100 workspace IDs per POST
    $wsIds   = $activeWs.Id
    $batches = [math]::Ceiling($wsIds.Count / 100)

    for ($b = 0; $b -lt $batches; $b++) {
        $batchIds = $wsIds | Select-Object -Skip ($b * 100) -First 100

        # POST: start async scan for this batch
        $body      = @{ workspaces = @($batchIds) } | ConvertTo-Json -Compress
        $scanStart = Invoke-PowerBIRestMethod `
            -Url "admin/workspaces/getInfo?lineage=false&datasourceDetails=false&datasetSchema=false&datasetExpressions=false" `
            -Method Post -Body $body | ConvertFrom-Json
        $scanId    = $scanStart.id   # Job ID to poll

        # Poll until scan completes (usually 10–30 seconds)
        $maxWaits = 24   # 24 × 5s = max 2 minutes per batch
        $waited   = 0
        do {
            Start-Sleep -Seconds 5
            $status = Invoke-PowerBIRestMethod `
                -Url "admin/workspaces/scanStatus/$scanId" -Method Get | ConvertFrom-Json
            $waited++
        } while ($status.status -notin @("Succeeded","Failed") -and $waited -lt $maxWaits)

        if ($status.status -ne "Succeeded") {
            Write-Warning "Batch $($b+1)/$batches scan did not succeed (status: $($status.status)). Skipping."
            continue
        }

        # GET: retrieve results (includes workspace users)
        $scanResult = Invoke-PowerBIRestMethod `
            -Url "admin/workspaces/scanResult/$scanId" -Method Get | ConvertFrom-Json

        foreach ($wsResult in $scanResult.workspaces) {
            # $wsResult.users — array of workspace members returned by Scanner API
            foreach ($user in $wsResult.users) {
                $memberReport.Add([PSCustomObject]@{
                    WorkspaceId   = $wsResult.id
                    WorkspaceName = $wsResult.name
                    UserEmail     = $user.emailAddress
                    DisplayName   = $user.displayName
                    AccessRight   = $user.groupUserAccessRight
                    PrincipalType = $user.principalType
                })
            }
        }
        Write-Host "  Batch $($b+1)/$batches done ($($batchIds.Count) workspaces, $($memberReport.Count) members so far)"
    }

} else {
    # Small tenant: per-workspace loop
    Write-Host "Using per-workspace loop ($($activeWs.Count) workspaces)..." -ForegroundColor Cyan

    if ($isPS7) {
        # PowerShell 7+: parallel fetch (faster, uses pre-fetched token)
        Write-Host "PowerShell 7+ detected — using parallel fetch (ThrottleLimit: 5)..." -ForegroundColor Gray
        $token = Get-PowerBIAccessToken -AsString

        $parallelResults = $activeWs | ForEach-Object -Parallel {
            $ws      = $_
            $headers = @{ Authorization = $using:token }
            try {
                $r = Invoke-RestMethod `
                    -Uri "https://api.powerbi.com/v1.0/myorg/admin/groups/$($ws.Id)/users" `
                    -Headers $headers -Method Get
                foreach ($u in $r.value) {
                    [PSCustomObject]@{
                        WorkspaceId   = $ws.Id
                        WorkspaceName = $ws.Name
                        UserEmail     = $u.emailAddress
                        DisplayName   = $u.displayName
                        AccessRight   = $u.groupUserAccessRight
                        PrincipalType = $u.principalType
                    }
                }
            } catch { }
        } -ThrottleLimit 5   # Max 5 concurrent threads — respects rate limits

        foreach ($r in $parallelResults) { $memberReport.Add($r) }

    } else {
        # PowerShell 5.1: sequential loop
        Write-Host "PowerShell 5.1 — using sequential loop..." -ForegroundColor Gray
        $count = 0
        foreach ($ws in $activeWs) {
            $count++
            Write-Progress -Activity "Fetching members" -Status $ws.Name `
                -PercentComplete (($count / $activeWs.Count) * 100)
            try {
                $parsed = Invoke-PowerBIRestMethod `
                    -Url "admin/groups/$($ws.Id)/users" -Method Get | ConvertFrom-Json
                foreach ($u in $parsed.value) {
                    $memberReport.Add([PSCustomObject]@{
                        WorkspaceId   = $ws.Id
                        WorkspaceName = $ws.Name
                        UserEmail     = $u.emailAddress
                        DisplayName   = $u.displayName
                        AccessRight   = $u.groupUserAccessRight
                        PrincipalType = $u.principalType
                    })
                }
            } catch { Write-Warning "Failed: $($ws.Name)" }
            Start-Sleep -Milliseconds 200
        }
    }
}

$memberReport | Export-Csv $membersFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== SUMMARY ===" -ForegroundColor Green
Write-Host "Total workspaces   : $($allWorkspaces.Count)"
Write-Host "Active             : $($activeWs.Count)"
Write-Host "Orphaned           : $(($allWorkspaces | Where-Object State -eq 'Orphaned').Count)"
Write-Host "Deleted            : $(($allWorkspaces | Where-Object State -eq 'Deleted').Count)"
Write-Host "On dedicated cap.  : $(($allWorkspaces | Where-Object IsOnDedicatedCapacity -eq $true).Count)"
Write-Host "Total members      : $($memberReport.Count)"
Write-Host "Method used        : $(if ($activeWs.Count -gt $ScannerThreshold) { 'Scanner API (batch)' } elseif ($isPS7) { 'Parallel loop (PS7)' } else { 'Sequential loop (PS5)' })"
Write-Host "Workspace file     : $workspaceFile"
Write-Host "Members file       : $membersFile"
