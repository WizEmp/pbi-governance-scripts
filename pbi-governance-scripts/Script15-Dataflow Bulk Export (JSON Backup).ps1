# ============================================================
# Script 15 — Dataflow Bulk Export (JSON Backup)
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Exports all dataflow definitions to JSON backup files.
.PARAMETER WorkspaceId
    GUID of specific workspace. If empty, exports from ALL workspaces.
.PARAMETER OutputPath
    Folder for JSON exports.
#>
param(
    [string]$WorkspaceId = "",    # Leave empty to export from all workspaces
    [string]$OutputPath  = "C:\PBIAdmin\dataflow-backups"
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
$backupPath = Join-Path $OutputPath $today
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $backupPath | Out-Null

if ($WorkspaceId -ne "") {
    $targetWorkspaces = Get-PowerBIWorkspace -Scope Organization -Id $WorkspaceId
} else {
    $targetWorkspaces = Get-PowerBIWorkspace -Scope Organization -All |
        Where-Object { $_.State -eq "Active" -and $_.Type -ne "PersonalGroup" }
}

$exported = 0
$failed   = 0

foreach ($ws in $targetWorkspaces) {
    $dataflows = Get-PowerBIDataflow -WorkspaceId $ws.Id -Scope Organization
    if (-not $dataflows) { continue }

    $wsFolder = Join-Path $backupPath ($ws.Name -replace '[\\/:*?"<>|]', '_')
    New-Item -ItemType Directory -Force -Path $wsFolder | Out-Null

    foreach ($df in $dataflows) {
        $safeName = $df.Name -replace '[\\/:*?"<>|]', '_'
        $outFile  = Join-Path $wsFolder "$safeName.json"
        try {
            Export-PowerBIDataflow -Id $df.Id -WorkspaceId $ws.Id -OutFile $outFile
            Write-Host "Exported: $($ws.Name) / $($df.Name)" -ForegroundColor Green
            $exported++
        } catch {
            Write-Warning "Failed: $($ws.Name) / $($df.Name) — $_"
            $failed++
        }
        Start-Sleep -Milliseconds 150
    }
}

Write-Host "`n=== DATAFLOW BACKUP COMPLETE ===" -ForegroundColor Green
Write-Host "Exported : $exported"
Write-Host "Failed   : $failed"
Write-Host "Path     : $backupPath"
