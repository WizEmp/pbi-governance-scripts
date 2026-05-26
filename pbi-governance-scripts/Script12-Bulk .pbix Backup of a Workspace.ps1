# ============================================================
# Script 12 — Bulk .pbix Backup of a Workspace
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Exports all reports from a workspace as .pbix backup files.
.PARAMETER WorkspaceId
    GUID of the source workspace. REQUIRED.
.PARAMETER BackupRoot
    Root folder for backups. A sub-folder with today's date is created automatically.
.PARAMETER SkipLiveConnection
    Switch. Skips reports bound to live/SSAS connections (they often fail export).
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,              # Source workspace GUID
    [string]$BackupRoot = "C:\PBIAdmin\backups",
    [switch]$SkipLiveConnection
)

#region CONFIG
$today      = Get-Date -Format 'yyyy-MM-dd'
$backupPath = Join-Path $BackupRoot $today   # Daily sub-folder: C:\PBIAdmin\backups\2026-05-25\
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $backupPath | Out-Null

Write-Host "Fetching reports in workspace $WorkspaceId..." -ForegroundColor Cyan
$reports = Get-PowerBIReport -WorkspaceId $WorkspaceId -Scope Organization |
    Where-Object { $_.ReportType -eq "PowerBIReport" }  # Skip paginated — cannot export as .pbix

Write-Host "Found $($reports.Count) report(s) to back up" -ForegroundColor Cyan

$results = [System.Collections.Generic.List[object]]::new()
foreach ($report in $reports) {
    # Sanitise filename — remove characters illegal in Windows file paths
    $safeName = $report.Name -replace '[\\/:*?"<>|]', '_'
    $outFile  = Join-Path $backupPath "$safeName.pbix"

    try {
        Export-PowerBIReport -Id $report.Id -WorkspaceId $WorkspaceId -OutFile $outFile
        $size = [math]::Round((Get-Item $outFile).Length / 1MB, 2)  # File size in MB
        Write-Host "  ✓ $($report.Name) ($size MB)" -ForegroundColor Green
        $results.Add([PSCustomObject]@{
            ReportName = $report.Name
            FileName   = "$safeName.pbix"
            SizeMB     = $size
            Status     = "SUCCESS"
            Path       = $outFile
        })
    } catch {
        Write-Warning "  ✗ $($report.Name): $_"
        $results.Add([PSCustomObject]@{
            ReportName = $report.Name
            FileName   = ""
            SizeMB     = 0
            Status     = "FAILED"
            Path       = $_.Exception.Message
        })
    }
    Start-Sleep -Milliseconds 200
}

$logFile = Join-Path $backupPath "backup-log.csv"
$results | Export-Csv $logFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== BACKUP COMPLETE ===" -ForegroundColor Green
Write-Host "Exported     : $(($results | Where-Object Status -eq 'SUCCESS').Count)"
Write-Host "Failed       : $(($results | Where-Object Status -eq 'FAILED').Count)"
Write-Host "Backup path  : $backupPath"
