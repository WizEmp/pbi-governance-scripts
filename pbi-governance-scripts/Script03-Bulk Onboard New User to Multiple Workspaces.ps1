# ============================================================
# Script 03 — Bulk Onboard New User to Multiple Workspaces
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

<#
.SYNOPSIS
    Adds a new user to multiple workspaces at a specified access level.
.PARAMETER NewUser
    Email address of the user to add. REQUIRED.
.PARAMETER AccessRight
    Role to assign: Admin, Member, Contributor, Viewer. Default: Contributor.
.PARAMETER WorkspaceFilter
    OData filter string to select workspaces. Default: all active workspaces.
    Example: "contains(name,'Finance')" — adds user to ALL workspaces whose name
    contains 'Finance': 'Finance', 'Finance Archive', 'Non-Finance', 'Finance Q1 2024'.
    ⚠️ ALWAYS run with -DryRun first to confirm which workspaces match.
    Use exact match to limit scope: "name eq 'Finance Reporting'"
.PARAMETER WorkspaceIds
    Comma-separated list of specific workspace GUIDs. Overrides WorkspaceFilter.
    Safer than WorkspaceFilter for production use — no pattern-match surprises.
.PARAMETER OutputPath
    Folder for the onboarding log CSV.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$NewUser,                           # e.g. "jane.doe@contoso.com"
    [ValidateSet("Admin","Member","Contributor","Viewer")]
    [string]$AccessRight     = "Contributor",   # Role assigned in every workspace
    [string]$WorkspaceFilter = "",              # OData filter, e.g. "contains(name,'Finance')"
    [string[]]$WorkspaceIds  = @(),             # Specific workspace GUIDs — overrides filter
    [string]$OutputPath      = "C:\PBIAdmin\exports"
)

#region CONFIG
$today = Get-Date -Format 'yyyy-MM-dd'
$logFile = Join-Path $OutputPath "onboard-$($NewUser.Split('@')[0])-$today.csv"
#endregion

. "C:\PBIAdmin\Connect-PBIAccount.ps1"   # Dot-source the shared auth function
Connect-PBIAccount -AuthMode $AuthMode -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertThumbprint $CertThumbprint
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# Determine target workspaces
if ($WorkspaceIds.Count -gt 0) {
    # Specific GUIDs provided — validate each exists
    $targetWorkspaces = $WorkspaceIds | ForEach-Object {
        Get-PowerBIWorkspace -Scope Organization -Id $_
    }
} elseif ($WorkspaceFilter -ne "") {
    $targetWorkspaces = Get-PowerBIWorkspace -Scope Organization -Filter $WorkspaceFilter -All |
        Where-Object { $_.State -eq "Active" }
} else {
    $targetWorkspaces = Get-PowerBIWorkspace -Scope Organization -All |
        Where-Object { $_.State -eq "Active" -and $_.Type -ne "PersonalGroup" }
}

Write-Host "Target workspaces: $($targetWorkspaces.Count)" -ForegroundColor Cyan

$log = [System.Collections.Generic.List[object]]::new()
foreach ($ws in $targetWorkspaces) {
    try {
        Add-PowerBIWorkspaceUser -Scope Organization `
            -Id $ws.Id `
            -UserEmailAddress $NewUser `
            -AccessRight $AccessRight
        
        Write-Host "Added to: $($ws.Name) as $AccessRight" -ForegroundColor Green
        $log.Add([PSCustomObject]@{
            WorkspaceId   = $ws.Id
            WorkspaceName = $ws.Name
            UserEmail     = $NewUser
            AccessRight   = $AccessRight   # Role that was assigned
            Status        = "SUCCESS"
            Timestamp     = (Get-Date -Format 'o')
            Error         = ""
        })
    } catch {
        Write-Warning "Failed for $($ws.Name): $_"
        $log.Add([PSCustomObject]@{
            WorkspaceId   = $ws.Id
            WorkspaceName = $ws.Name
            UserEmail     = $NewUser
            AccessRight   = $AccessRight
            Status        = "FAILED"
            Timestamp     = (Get-Date -Format 'o')
            Error         = $_.Exception.Message
        })
    }
    Start-Sleep -Milliseconds 150
}

$log | Export-Csv $logFile -NoTypeInformation -Encoding UTF8BOM
Write-Host "`nAdded to $( ($log | Where-Object Status -eq 'SUCCESS').Count ) workspaces"
Write-Host "Log: $logFile"
