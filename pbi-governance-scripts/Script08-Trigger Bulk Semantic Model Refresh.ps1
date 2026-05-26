# ============================================================
# Script 08 — Trigger Bulk Semantic Model Refresh
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Triggers refresh on specified datasets and optionally monitors completion.
.PARAMETER WorkspaceId
    GUID of the workspace containing the datasets. REQUIRED.
.PARAMETER DatasetNames
    Array of dataset display names to refresh. Empty = refresh ALL refreshable datasets.
.PARAMETER WaitForCompletion
    Switch. If set, polls until refresh completes (or times out).
.PARAMETER TimeoutMinutes
    Max wait time when WaitForCompletion is set. Default: 60 minutes.
.PARAMETER PollIntervalSeconds
    How often to check refresh status when waiting. Default: 30 seconds.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,               # Workspace GUID — find in admin portal URL or Script 01

    [string[]]$DatasetNames  = @(),     # Empty = refresh all. Specify names to target specific ones.
    [switch]$WaitForCompletion,         # If set, polls until done
    [int]$TimeoutMinutes     = 60,      # Max wait time in minutes
    [int]$PollIntervalSeconds = 30      # Seconds between status checks
)

#region CONFIG
# POST body options for the refresh API:
# "notifyOption": "NoNotification" — no email sent when done
# "notifyOption": "MailOnFailure"  — email dataset owner only on failure
# "notifyOption": "MailOnCompletion" — email on any completion
$refreshBody = '{"notifyOption": "MailOnFailure"}'
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint

# Get datasets to refresh
$allDatasets = Get-PowerBIDataset -WorkspaceId $WorkspaceId -Scope Organization |
    Where-Object { $_.IsRefreshable -eq $true }

if ($DatasetNames.Count -gt 0) {
    $targetDatasets = $allDatasets | Where-Object { $_.Name -in $DatasetNames }
} else {
    $targetDatasets = $allDatasets
}

Write-Host "Refreshing $($targetDatasets.Count) dataset(s)..." -ForegroundColor Cyan

$refreshTracker = [System.Collections.Generic.List[object]]::new()
foreach ($ds in $targetDatasets) {
    try {
        # ── Daily refresh limit check ─────────────────────────────────────────
        # Shared capacity: 8 refreshes/day max (Premium has higher limits)
        # Exceeding this returns 429 TooManyRequests — check before triggering
        # $top=20: fetch more than 8 to handle datasets that also refreshed yesterday
        # A dataset with 10 scheduled refreshes/day needs >10 to see today's entries
        $today      = (Get-Date).Date
        $histUrl    = "groups/$WorkspaceId/datasets/$($ds.Id)/refreshes?`$top=20"
        $hist       = Invoke-PowerBIRestMethod -Url $histUrl -Method Get | ConvertFrom-Json
        $todayCount = ($hist.value | Where-Object {
            $_.startTime -and ([datetime]$_.startTime).Date -eq $today
        }).Count
        if ($todayCount -ge 8) {
            Write-Warning "Skipped: $($ds.Name) — $todayCount refreshes today (8/day shared cap)"
            $refreshTracker.Add([PSCustomObject]@{
                DatasetId   = $ds.Id; DatasetName = $ds.Name
                Status      = "SKIPPED_DAILY_LIMIT"; StartTime = Get-Date
            })
            continue
        }

        # POST to trigger refresh — returns 202 Accepted (no body if successful)
        Invoke-PowerBIRestMethod `
            -Url "groups/$WorkspaceId/datasets/$($ds.Id)/refreshes" `
            -Method Post `
            -Body $refreshBody
        
        Write-Host "Refresh triggered: $($ds.Name)" -ForegroundColor Green
        $refreshTracker.Add([PSCustomObject]@{
            DatasetId   = $ds.Id
            DatasetName = $ds.Name
            Status      = "Triggered"
            StartTime   = Get-Date
        })
    } catch {
        Write-Warning "Failed to trigger refresh for $($ds.Name): $_"
    }
    Start-Sleep -Milliseconds 200
}

# Optional: wait and monitor
if ($WaitForCompletion -and $refreshTracker.Count -gt 0) {
    $timeout    = (Get-Date).AddMinutes($TimeoutMinutes)  # When we stop waiting
    $pending    = $refreshTracker | Where-Object { $_.Status -eq "Triggered" }

    Write-Host "`nMonitoring refresh completion (timeout: $TimeoutMinutes min)..." -ForegroundColor Cyan

    while ($pending.Count -gt 0 -and (Get-Date) -lt $timeout) {
        Start-Sleep -Seconds $PollIntervalSeconds

        foreach ($item in $pending) {
            $raw    = Invoke-PowerBIRestMethod `
                -Url "groups/$WorkspaceId/datasets/$($item.DatasetId)/refreshes?`$top=1" `
                -Method Get
            $parsed = $raw | ConvertFrom-Json
            $last   = $parsed.value | Select-Object -First 1

            if ($last.status -in @("Completed","Failed","Cancelled","Unknown")) {
                $item.Status = $last.status
                $icon = if ($last.status -eq "Completed") { "✓" } else { "✗" }
                Write-Host "  $icon $($item.DatasetName): $($last.status)"
            }
        }
        $pending = $refreshTracker | Where-Object { $_.Status -eq "Triggered" }
        if ($pending.Count -gt 0) {
            Write-Host "  Still refreshing: $($pending.DatasetName -join ', ')" -ForegroundColor Yellow
        }
    }

    if ((Get-Date) -ge $timeout) {
        Write-Warning "Timeout reached. Still pending: $($pending.DatasetName -join ', ')"
    }

    Write-Host "`nFinal status:"
    $refreshTracker | Format-Table DatasetName, Status -AutoSize
}
