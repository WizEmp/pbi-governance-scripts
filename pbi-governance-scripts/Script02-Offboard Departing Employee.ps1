# ============================================================
# Script 02 — Offboard Departing Employee
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Removes a departing user from all Power BI workspaces in the tenant.
.PARAMETER LeavingUser
    Email address (UPN) of the departing employee. REQUIRED.
.PARAMETER OutputPath
    Folder for the removal log CSV.
.PARAMETER DryRun
    Switch. If set, shows what WOULD be removed without removing anything.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$LeavingUser,                        # e.g. "john.smith@contoso.com"
    [string]$OutputPath = "C:\PBIAdmin\exports",
    [switch]$DryRun
)

#region CONFIG
$today = Get-Date -Format 'yyyy-MM-dd'
$logFile = Join-Path $OutputPath "offboard-$($LeavingUser.Split('@')[0])-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

Write-Host "Fetching all workspaces for tenant..." -ForegroundColor Cyan
$allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All

# First: find workspaces where the user actually has access (avoid redundant API calls)
Write-Host "Scanning for workspaces where $LeavingUser has access..." -ForegroundColor Cyan
$userWorkspaces = [System.Collections.Generic.List[object]]::new()   # List[object] — O(1) append

foreach ($ws in ($allWorkspaces | Where-Object { $_.State -eq "Active" })) {
    try {
        $parsed = Invoke-PowerBIRestMethod -Url "admin/groups/$($ws.Id)/users" -Method Get |
            ConvertFrom-Json
        $userEntry   = $parsed.value | Where-Object { $_.emailAddress -eq $LeavingUser }
        # Also detect security groups — removing direct access won't remove group access
        $groupCount  = ($parsed.value | Where-Object { $_.principalType -eq "Group" }).Count

        if ($userEntry) {
            # ─── SOLE-ADMIN SAFETY CHECK ──────────────────────────────────────
            # If the leaving user is the ONLY Admin in this workspace, removing
            # them would orphan it. Detect here (we already have $parsed) and
            # carry the flag forward — no extra API call needed in the removal loop.
            $soleAdminRisk = $false
            if ($userEntry.groupUserAccessRight -eq "Admin") {
                $adminCount = ($parsed.value | Where-Object {
                    $_.groupUserAccessRight -eq "Admin" -and
                    $_.principalType        -ne "Group"    # Groups don't count — individual humans only
                }).Count
                if ($adminCount -le 1) { $soleAdminRisk = $true }
            }
            # ──────────────────────────────────────────────────────────────────
            $userWorkspaces.Add([PSCustomObject]@{
                WorkspaceId    = $ws.Id
                WorkspaceName  = $ws.Name
                AccessRight    = $userEntry.groupUserAccessRight  # Their current role
                SoleAdminRisk  = $soleAdminRisk    # ← True = only Admin; removal would orphan workspace
                GroupWarning   = if ($groupCount -gt 0) {
                    # ⚠️ The workspace has security groups — user may retain access via group
                    "VERIFY: $groupCount security group(s) in workspace — check $LeavingUser is not a member"
                } else { "" }
            })
        }
        Start-Sleep -Milliseconds 100
    } catch { }
}

Write-Host "Found $LeavingUser in $($userWorkspaces.Count) workspace(s)" -ForegroundColor Yellow

$log = [System.Collections.Generic.List[object]]::new()   # List[object] for O(1) append
foreach ($entry in $userWorkspaces) {
    if ($DryRun) {
        if ($entry.SoleAdminRisk) {
            Write-Warning "[DRY RUN] SOLE ADMIN: $($entry.WorkspaceName) — would SKIP removal ($LeavingUser is the only Admin; assign a replacement first)"
            $dryRunAction  = "DRY_RUN_WOULD_SKIP_SOLE_ADMIN"
            $dryRunError   = "Sole Admin — manual action required: assign replacement Admin, then re-run"
        } else {
            Write-Host "[DRY RUN] Would remove from: $($entry.WorkspaceName) (role: $($entry.AccessRight))"
            $dryRunAction  = "DRY_RUN_WOULD_REMOVE"
            $dryRunError   = ""
        }
        $log.Add([PSCustomObject]@{
            WorkspaceId   = $entry.WorkspaceId
            WorkspaceName = $entry.WorkspaceName
            PreviousRole  = $entry.AccessRight
            Action        = $dryRunAction
            Timestamp     = (Get-Date -Format 'o')
            Error         = $dryRunError
        })
    } else {
        # ─── SOLE-ADMIN GUARD ────────────────────────────────────────────────
        # Never silently remove the only Admin — that orphans the workspace.
        # Log as SKIPPED_SOLE_ADMIN and surface it clearly so the offboarding
        # operator knows manual action is required before closing the ticket.
        if ($entry.SoleAdminRisk) {
            Write-Warning "SOLE ADMIN SKIPPED: $($entry.WorkspaceName) — $LeavingUser is the only Admin. Assign a replacement Admin before completing offboarding."
            $log.Add([PSCustomObject]@{
                WorkspaceId   = $entry.WorkspaceId
                WorkspaceName = $entry.WorkspaceName
                PreviousRole  = $entry.AccessRight
                Action        = "SKIPPED_SOLE_ADMIN"
                Timestamp     = (Get-Date -Format 'o')
                Error         = "Sole Admin — manual action required: assign replacement Admin, then re-run"
            })
            continue
        }
        # ─────────────────────────────────────────────────────────────────────
        try {
            Remove-PowerBIWorkspaceUser -Scope Organization -Id $entry.WorkspaceId -UserEmailAddress $LeavingUser
            Write-Host "Removed from: $($entry.WorkspaceName)" -ForegroundColor Green
            $log.Add([PSCustomObject]@{
                WorkspaceId   = $entry.WorkspaceId
                WorkspaceName = $entry.WorkspaceName
                PreviousRole  = $entry.AccessRight
                Action        = "REMOVED"
                Timestamp     = (Get-Date -Format 'o')
                Error         = ""
            }
        } catch {
            Write-Warning "Failed: $($entry.WorkspaceName) — $_"
            $log.Add([PSCustomObject]@{
                WorkspaceId   = $entry.WorkspaceId
                WorkspaceName = $entry.WorkspaceName
                PreviousRole  = $entry.AccessRight
                Action        = "FAILED"
                Timestamp     = (Get-Date -Format 'o')
                Error         = $_.Exception.Message
            }
        }
    }
}

$log | Export-Csv $logFile -NoTypeInformation -Encoding UTF8BOM
Write-Host "`nLog saved: $logFile"
