# ============================================================
# Script 18 — User Access Report (What Does This Person Have Access To?)
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Finds every Power BI workspace where a given user has access.
    The user-centric complement to Script 01 (workspace-centric inventory).
.PARAMETER UserEmail
    UPN of the user to audit. e.g. "jane.smith@contoso.com". REQUIRED.
.PARAMETER OutputPath
    Folder for the user access report CSV.
.PARAMETER IncludePersonalWorkspaces
    Switch. If set, includes the user's own My Workspace in results.
.PARAMETER FullScan
    Switch. Forces a full scan of all workspaces even if -User pre-filter returns results.
    Use when the user may have access via security groups (group membership is not
    returned by the -User pre-filter — it only finds direct workspace assignments).
    Slower on large tenants but complete. Default: fast path via -User, with warning.
.NOTES
    Loops through all active workspaces checking member lists.
    On large tenants (1000+ workspaces) use the -UseCache switch
    or pre-populate $allWorkspaces from Script 01 output.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$UserEmail,                                  # Required — UPN to audit
    [string]$OutputPath                 = "C:\PBIAdmin\exports",
    [switch]$IncludePersonalWorkspaces,                  # Include My Workspace entries
    [switch]$FullScan,                                    # Force full scan (catches group-based access)

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
$safeUser   = $UserEmail.Split('@')[0] -replace '[^a-zA-Z0-9]', '_'
$outputFile = Join-Path $OutputPath "user-access-$safeUser-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

Write-Host "Building user access report for: $UserEmail" -ForegroundColor Cyan

# Use -User parameter to pre-filter workspaces where this user has ANY role
# Much faster than fetching all workspaces and scanning each one
# Note: -User returns workspaces where the user has direct access only
# Group-based access requires the full scan below — use -FullScan switch to force it
$preFiltered = Get-PowerBIWorkspace -Scope Organization -User $UserEmail -All |
    Where-Object { $_.State -eq "Active" -and
                  ($IncludePersonalWorkspaces -or $_.Type -ne "PersonalGroup") }

if ($preFiltered.Count -gt 0 -and -not $FullScan) {
    # Fast path: -User found workspaces — use these (direct access only)
    $allWorkspaces = $preFiltered
    Write-Host "Pre-filtered to $($allWorkspaces.Count) workspaces via -User parameter" -ForegroundColor Cyan
    Write-Host "(Note: group-based access not included — use -FullScan for complete audit)" -ForegroundColor Yellow
} else {
    # Full scan: fetch all workspaces and check member lists individually
    # Required when user has access via security groups, or -FullScan is set
    $allWorkspaces = Get-PowerBIWorkspace -Scope Organization -All |
        Where-Object { $_.State -eq "Active" -and
                      ($IncludePersonalWorkspaces -or $_.Type -ne "PersonalGroup") }
    Write-Host "Full scan: $($allWorkspaces.Count) workspaces (includes group-based access)" -ForegroundColor Cyan
}

$access  = [System.Collections.Generic.List[object]]::new()
$count   = 0

foreach ($ws in $allWorkspaces) {
    $count++
    Write-Progress -Activity "Scanning for $UserEmail" -Status $ws.Name `
        -PercentComplete (($count / $allWorkspaces.Count) * 100)

    try {
        # Get all users in this workspace via admin API
        $parsed  = Invoke-PowerBIRestMethod `
            -Url "admin/groups/$($ws.Id)/users" -Method Get | ConvertFrom-Json
        
        # Case-insensitive match on email (UPNs can vary in case)
        $userEntry = $parsed.value |
            Where-Object { $_.emailAddress -ieq $UserEmail }

        if ($userEntry) {
            $access.Add([PSCustomObject]@{
                WorkspaceName    = $ws.Name
                WorkspaceId      = $ws.Id
                WorkspaceType    = $ws.Type               # Workspace / Group / PersonalGroup
                WorkspaceState   = $ws.State
                UserRole         = $userEntry.groupUserAccessRight   # Admin/Member/Contributor/Viewer
                PrincipalType    = $userEntry.principalType          # User / Group / App
                OnCapacity       = $ws.IsOnDedicatedCapacity
                CapacityId       = $ws.CapacityId
            })
        }
    } catch { }
    Start-Sleep -Milliseconds 100   # Rate limit protection
}

if ($access.Count -eq 0) {
    Write-Host "No workspace access found for $UserEmail" -ForegroundColor Yellow
} else {
    $access | Sort-Object UserRole, WorkspaceName |
        Export-Csv $outputFile -NoTypeInformation -Encoding UTF8BOM
    
    Write-Host "`n=== USER ACCESS REPORT ===" -ForegroundColor Green
    Write-Host "User        : $UserEmail"
    Write-Host "Workspaces  : $($access.Count)"
    Write-Host "Admin roles : $(($access | Where-Object UserRole -eq 'Admin').Count)"
    Write-Host "Member roles: $(($access | Where-Object UserRole -eq 'Member').Count)"
    Write-Host "Report: $outputFile"
}
