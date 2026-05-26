# ============================================================
# Script 19 — Scheduled Refresh Configuration Audit
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Audits the refresh schedule configuration for all semantic models.
    Identifies missing schedules, peak-hour conflicts, and disabled schedules.
.PARAMETER OutputPath
    Folder for the schedule audit CSV.
.PARAMETER PeakHourStart / PeakHourEnd
    Define business hours (24h format) to flag schedules that run during peak.
    Default: 08-18 (8am to 6pm). Schedules in this window get a PeakHour flag.
#>
param(
    [string]$OutputPath    = "C:\PBIAdmin\exports",
    [int]$PeakHourStart    = 8,    # 8am — schedules starting here get flagged
    [int]$PeakHourEnd      = 18,   # 6pm

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
$outputFile = Join-Path $OutputPath "refresh-schedule-audit-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All |
    Where-Object { $_.State -eq "Active" -and $_.Type -ne "PersonalGroup" }

Write-Host "Auditing refresh schedules across $($allWorkspaces.Count) workspaces..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[object]]::new()
$count   = 0

foreach ($ws in $allWorkspaces) {
    $count++
    Write-Progress -Activity "Auditing schedules" -Status $ws.Name `
        -PercentComplete (($count / $allWorkspaces.Count) * 100)

    # Get all refreshable datasets in this workspace
    $datasets = Get-PowerBIDataset -WorkspaceId $ws.Id -Scope Organization |
        Where-Object { $_.IsRefreshable -eq $true }

    foreach ($ds in $datasets) {
        try {
            # GET /v1.0/myorg/groups/{groupId}/datasets/{datasetId}/refreshSchedule
            # Returns: enabled flag, days, times, timezone, localTimeZoneId
            $schedule = Invoke-PowerBIRestMethod `
                -Url "groups/$($ws.Id)/datasets/$($ds.Id)/refreshSchedule" `
                -Method Get | ConvertFrom-Json

            # Check if any scheduled time falls in peak hours
            $peakHourConflict = $false
            if ($schedule.times) {
                $peakHourConflict = $schedule.times | ForEach-Object {
                    $hour = [int]($_.Split(':')[0])
                    $hour -ge $PeakHourStart -and $hour -lt $PeakHourEnd
                } | Where-Object { $_ -eq $true } | Select-Object -First 1
            }

            $results.Add([PSCustomObject]@{
                WorkspaceName    = $ws.Name
                WorkspaceId      = $ws.Id
                DatasetName      = $ds.Name
                DatasetId        = $ds.Id
                Owner            = $ds.ConfiguredBy
                ScheduleEnabled  = $schedule.enabled       # FALSE = schedule exists but paused
                Frequency        = $schedule.frequency     # Daily / Weekly
                Days             = ($schedule.days -join ", ")      # Mon, Wed, Fri etc.
                Times            = ($schedule.times -join ", ")     # 06:00, 14:00 etc.
                Timezone         = $schedule.localTimeZoneId
                NoSchedule       = (-not $schedule.times -or $schedule.times.Count -eq 0)
                PeakHourConflict = [bool]$peakHourConflict
                OnCapacity       = $ws.IsOnDedicatedCapacity
            })
        } catch {
            # Dataset may not have a refresh schedule configured (imported with no schedule)
            $results.Add([PSCustomObject]@{
                WorkspaceName = $ws.Name; DatasetName = $ds.Name
                Owner = $ds.ConfiguredBy; ScheduleEnabled = $false
                NoSchedule = $true; OnCapacity = $ws.IsOnDedicatedCapacity
            })
        }
        Start-Sleep -Milliseconds 80
    }
}

$results | Sort-Object NoSchedule -Descending, WorkspaceName |
    Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== REFRESH SCHEDULE AUDIT ===" -ForegroundColor Green
Write-Host "Datasets audited     : $($results.Count)"
Write-Host "No schedule          : $(($results | Where-Object NoSchedule -eq $true).Count)" -ForegroundColor Yellow
Write-Host "Schedule disabled    : $(($results | Where-Object { $_.ScheduleEnabled -eq $false -and -not $_.NoSchedule }).Count)"
Write-Host "Peak hour conflict   : $(($results | Where-Object PeakHourConflict -eq $true).Count)" -ForegroundColor Yellow
Write-Host "Report: $outputFile"
