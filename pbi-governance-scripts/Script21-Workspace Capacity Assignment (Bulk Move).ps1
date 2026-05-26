# ============================================================
# Script 21 — Workspace Capacity Assignment (Bulk Move)
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Bulk-assigns workspaces to a specified capacity, or removes them from capacity.
    IMPORTANT: Always run with -DryRun first. Capacity reassignment affects
    data refresh scheduling and XMLA connectivity for all affected workspaces.
.PARAMETER TargetCapacityId
    GUID of the target capacity. Find it with Get-PowerBICapacity.
    Pass "00000000-0000-0000-0000-000000000000" to REMOVE from capacity (return to shared).
.PARAMETER WorkspaceFilter
    OData filter for workspace names. e.g. "contains(name,'Finance')"
    If not provided, WorkspaceIds must be specified.
.PARAMETER WorkspaceIds
    Array of workspace GUIDs to process directly (bypasses filter).
.PARAMETER DryRun
    ALWAYS USE THIS FIRST. Shows what would change without changing anything.
.NOTES
    Moving a workspace OFF dedicated capacity:
    - Disables scheduled refresh for datasets requiring > 1GB memory
    - Disables XMLA endpoint connectivity
    - Disables large dataset format (if enabled)
    Review these implications before removing workspaces from Premium/Fabric.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetCapacityId,           # Use Get-PowerBICapacity to find the ID
    [string]$WorkspaceFilter    = "",    # OData filter — e.g. "contains(name,'Finance')"
    [string[]]$WorkspaceIds     = @(),   # Alternative: pass GUIDs directly
    [switch]$DryRun,                     # ALWAYS test with this first
    [string]$OutputPath         = "C:\PBIAdmin\exports",

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
$logFile    = Join-Path $OutputPath "capacity-assignment-$today.csv"
$removingFromCapacity = ($TargetCapacityId -eq "00000000-0000-0000-0000-000000000000")
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# ── Identify target workspaces ────────────────────────────────────────────────
if ($WorkspaceIds.Count -gt 0) {
    # Direct GUID list — fetch details for each
    $targetWorkspaces = $WorkspaceIds | ForEach-Object {
        Get-PowerBIWorkspace -Scope Organization -Id $_
    }
} elseif ($WorkspaceFilter) {
    $targetWorkspaces = Get-PowerBIWorkspace -Scope Organization -Filter $WorkspaceFilter -All
} else {
    throw "Provide either -WorkspaceFilter or -WorkspaceIds. Both cannot be empty."
}

# ── Show what was matched ─────────────────────────────────────────────────────
Write-Host "`nMatched $($targetWorkspaces.Count) workspace(s):" -ForegroundColor Cyan
$targetWorkspaces | Format-Table Name, State, @{N="CurrentCapacity";E={$_.CapacityId}} -AutoSize

if (-not $DryRun) {
    if ($removingFromCapacity) {
        Write-Warning "You are about to REMOVE these workspaces from dedicated capacity."
        Write-Warning "This may disable scheduled refresh and XMLA access."
    }
    $confirm = Read-Host "`nType YES to proceed"
    if ($confirm -ne "YES") { Write-Host "Aborted."; exit 0 }
}

# ── Execute ───────────────────────────────────────────────────────────────────
$log = [System.Collections.Generic.List[object]]::new()

foreach ($ws in $targetWorkspaces) {
    $previousCapacity = $ws.CapacityId

    if ($DryRun) {
        Write-Host "[DRY RUN] Would assign '$($ws.Name)' to capacity: $TargetCapacityId" -ForegroundColor Cyan
        $log.Add([PSCustomObject]@{
            WorkspaceName      = $ws.Name
            WorkspaceId        = $ws.Id
            PreviousCapacityId = $previousCapacity
            TargetCapacityId   = $TargetCapacityId
            Action             = "DRY_RUN"
            Timestamp          = (Get-Date -Format 'o')
            Error              = ""
        })
    } else {
        try {
            # Set-PowerBIWorkspace with CapacityId moves the workspace
            # All-zeros GUID removes from capacity (returns to shared)
            $ws.CapacityId = $TargetCapacityId
            Set-PowerBIWorkspace -Scope Organization -Workspace $ws

            Write-Host "Assigned: $($ws.Name)" -ForegroundColor Green
            $log.Add([PSCustomObject]@{
                WorkspaceName      = $ws.Name
                WorkspaceId        = $ws.Id
                PreviousCapacityId = $previousCapacity
                TargetCapacityId   = $TargetCapacityId
                Action             = if ($removingFromCapacity) { "REMOVED_FROM_CAPACITY" } else { "ASSIGNED" }
                Timestamp          = (Get-Date -Format 'o')
                Error              = ""
            })
        } catch {
            Write-Warning "Failed: $($ws.Name) — $_"
            $log.Add([PSCustomObject]@{
                WorkspaceName = $ws.Name; WorkspaceId = $ws.Id
                Action = "FAILED"; Timestamp = (Get-Date -Format 'o')
                Error = $_.Exception.Message
            })
        }
    }
    Start-Sleep -Milliseconds 200
}

$log | Export-Csv $logFile -NoTypeInformation -Encoding UTF8BOM

Write-Host "`n=== CAPACITY ASSIGNMENT LOG ===" -ForegroundColor Green
Write-Host "Assigned/moved : $(($log | Where-Object Action -notin @('FAILED','DRY_RUN')).Count)"
Write-Host "Failed         : $(($log | Where-Object Action -eq 'FAILED').Count)" -ForegroundColor Red
Write-Host "Log: $logFile"
