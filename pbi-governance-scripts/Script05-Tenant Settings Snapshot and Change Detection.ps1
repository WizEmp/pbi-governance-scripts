# ============================================================
# Script 05 — Tenant Settings Snapshot and Change Detection
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Snapshots all tenant settings and detects changes vs previous snapshot.
.PARAMETER SnapshotPath
    Folder where snapshots are stored. Filenames include date automatically.
.PARAMETER AlertOnChange
    Switch. If set, writes a WARNING for every changed setting found.
#>
param(
    [string]$SnapshotPath = "C:\PBIAdmin\snapshots",
    [switch]$AlertOnChange
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
$snapshotFile  = Join-Path $SnapshotPath "tenant-settings-$today.csv"
$previousFiles = Get-ChildItem -Path $SnapshotPath -Filter "tenant-settings-*.csv" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 -First 1
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $SnapshotPath | Out-Null

# API: GET /v1.0/myorg/admin/tenantsettings
$response  = Invoke-PowerBIRestMethod -Url "admin/tenantsettings" -Method Get
$parsed    = $response | ConvertFrom-Json

# $parsed.tenantSettings — array of all settings
$snapshot = $parsed.tenantSettings | ForEach-Object {
    [PSCustomObject]@{
        SettingName            = $_.settingName       # Internal API name of the setting
        Enabled                = $_.enabled           # $true or $false
        CanSpecifyGroups       = $_.canSpecifySecurityGroups  # Whether group scoping is configured
        EnabledGroups          = ($_.enabledSecurityGroups.name -join " | ")   # Groups it's enabled FOR
        ExcludedGroups         = ($_.excludedSecurityGroups.name -join " | ")  # Groups it's excluded FROM
        SnapshotDate           = $today
    }
}

$snapshot | Export-Csv $snapshotFile -NoTypeInformation -Encoding UTF8BOM
Write-Host "Snapshot saved: $snapshotFile ($($snapshot.Count) settings)"

# Change detection — compare against previous snapshot
if ($previousFiles) {
    Write-Host "`nComparing against: $($previousFiles.Name)" -ForegroundColor Cyan
    $previous = Import-Csv $previousFiles.FullName

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($current in $snapshot) {
        # $currentSetting.SettingName is the unique key
        $prev = $previous | Where-Object { $_.SettingName -eq $current.SettingName }
        if ($prev) {
            # Compare: Enabled state and group configuration
            if ($prev.Enabled -ne $current.Enabled -or
                $prev.EnabledGroups -ne $current.EnabledGroups -or
                $prev.ExcludedGroups -ne $current.ExcludedGroups) {
                
                $changes.Add([PSCustomObject]@{
                    SettingName        = $current.SettingName
                    PreviousEnabled    = $prev.Enabled
                    CurrentEnabled     = $current.Enabled
                    PreviousGroups     = $prev.EnabledGroups
                    CurrentGroups      = $current.EnabledGroups
                    ChangeDate         = $today
                })
                if ($AlertOnChange) {
                    Write-Warning "CHANGED: $($current.SettingName) | Was: $($prev.Enabled) -> Now: $($current.Enabled)"
                }
            }
        } else {
            # New setting — appeared since last snapshot (Microsoft added it)
            $changes.Add([PSCustomObject]@{
                SettingName     = $current.SettingName
                PreviousEnabled = "NEW_SETTING"
                CurrentEnabled  = $current.Enabled
                PreviousGroups  = ""
                CurrentGroups   = $current.EnabledGroups
                ChangeDate      = $today
            })
        }
    }

    Write-Host "`n=== CHANGE REPORT ===" -ForegroundColor $(if ($changes.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "Settings changed: $($changes.Count)"
    if ($changes.Count -gt 0) {
        $changes | Format-Table -AutoSize
        $changesFile = Join-Path $SnapshotPath "settings-changes-$today.csv"
        $changes | Export-Csv $changesFile -NoTypeInformation -Encoding UTF8BOM
        Write-Host "Changes saved: $changesFile"
    }
} else {
    Write-Host "No previous snapshot found — this is the baseline." -ForegroundColor Yellow
}
