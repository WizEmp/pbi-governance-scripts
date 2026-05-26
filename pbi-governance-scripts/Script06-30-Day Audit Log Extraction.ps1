# ============================================================
# Script 06 — 30-Day Audit Log Extraction
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Extracts Power BI activity log events for a date range.
.PARAMETER DaysBack
    Number of days to extract (from today backwards). Max practical: 90. Default: 30.
.PARAMETER OutputPath
    Folder for the extracted log CSV.
.PARAMETER FilterActivity
    Comma-separated list of activity types to include. Empty = all activities.
    Example: "ExportReport,ShareReport,PublishToWebReport"
#>
param(
    [int]$DaysBack          = 30,               # Go back this many days from today
    [string]$OutputPath     = "C:\PBIAdmin\exports",
    [string]$FilterActivity = ""                # Empty = all; comma-separated activity names to filter
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
$today     = Get-Date -Format 'yyyy-MM-dd'
$startDate = (Get-Date).AddDays(-$DaysBack).Date   # DateTime at midnight $DaysBack ago
$endDate   = (Get-Date).Date                        # DateTime at midnight today
$outputFile = Join-Path $OutputPath "activity-log-$($DaysBack)d-$today.csv"

# Parse activity filter into array
$activityFilter = [System.Collections.Generic.List[object]]::new()
if ($FilterActivity -ne "") {
    $activityFilter = $FilterActivity.Split(',') | ForEach-Object { $_.Trim() }
}
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$allEvents = [System.Collections.Generic.List[object]]::new()  # Efficient for large datasets

# Loop one day at a time — API hard limit: one calendar day per call
Write-Host "Extracting $DaysBack days of activity events..." -ForegroundColor Cyan
for ($date = $startDate; $date -lt $endDate; $date = $date.AddDays(1)) {
    # Format: ISO 8601 with time component — required by the API
    $start = $date.ToString("yyyy-MM-ddT00:00:00")  # Midnight start
    $end   = $date.ToString("yyyy-MM-ddT23:59:59")  # Last second of the day

    try {
        # Get-PowerBIActivityEvent returns a JSON string — must ConvertFrom-Json
        $raw    = Get-PowerBIActivityEvent -StartDateTime $start -EndDateTime $end
        $events = $raw | ConvertFrom-Json   # $events is now an array of activity objects

        # Optional filter by activity type
        if ($activityFilter.Count -gt 0) {
            $events = $events | Where-Object { $_.Activity -in $activityFilter }
        }

        foreach ($e in $events) { $allEvents.Add($e) }
        Write-Host "  $($date.ToString('yyyy-MM-dd')): $($events.Count) events" -ForegroundColor Gray

    } catch {
        Write-Warning "Failed for $start — $_"
    }

    Start-Sleep -Milliseconds 300   # Throttle: respect API rate limits
}

# Export
$allEvents | Select-Object `
    Id, CreationTime, Activity,    # Core fields: unique ID, UTC timestamp, event type
    UserId,                         # UPN of user who performed the action
    WorkSpaceName, WorkspaceId,     # Where it happened
    ReportName, ReportId,           # Report involved (if applicable)
    DatasetName, DatasetId,         # Dataset/semantic model involved
    DashboardName, DashboardId,     # Dashboard involved
    AppName,                        # App involved
    Operation,                      # Lower-level operation name
    IsSuccess,                      # Boolean — did it succeed?
    RequestId                       # Unique request GUID — use for support tickets
    | Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== AUDIT LOG EXTRACTION ===" -ForegroundColor Green
Write-Host "Date range : $($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))"
Write-Host "Total events: $($allEvents.Count)"
Write-Host "Output: $outputFile"
