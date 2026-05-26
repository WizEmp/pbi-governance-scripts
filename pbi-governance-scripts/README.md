# Power BI Admin PowerShell Governance Scripts

**Companion repository to *The Power BI Admin PowerShell Field Guide*** by Dr. Laurent "Noah" MARC · Founder, WizEmp · [wizemp.com](https://wizemp.com)

21 production-ready scripts for Power BI tenant governance automation.

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.6 LTS (`pwsh.exe`) — [install guide](https://github.com/PowerShell/PowerShell/releases/latest) |
| Module | `MicrosoftPowerBIMgmt` v1.3.83+ — `Install-Module MicrosoftPowerBIMgmt -Scope CurrentUser` |
| Auth | Service principal (recommended) or interactive login — see `Connect-PBIAccount.ps1` |
| Role | Fabric Administrator role required for `-Scope Organization` operations |

---

## Quick start

```powershell
# 1. Clone the repo
git clone https://github.com/wizemp/pbi-governance-scripts.git
cd pbi-governance-scripts

# 2. Set your credentials as environment variables (machine-level, persists across reboots)
[System.Environment]::SetEnvironmentVariable("PBI_TENANT_ID",     "your-tenant-guid",   "Machine")
[System.Environment]::SetEnvironmentVariable("PBI_CLIENT_ID",     "your-client-id",     "Machine")
[System.Environment]::SetEnvironmentVariable("PBI_CLIENT_SECRET", "your-client-secret", "Machine")

# 3. Run the inventory script (dry-safe, read-only)
pwsh -File "Script01-Full Tenant Workspace Inventory with Members.ps1"
```

---

## Script index

| # | File | What it does |
|---|---|---|
| 01 | `Script01-Full Tenant Workspace Inventory with Members.ps1` | Full tenant workspace + member inventory via Scanner API |
| 02 | `Script02-Offboard Departing Employee.ps1` | Remove user from all workspaces — sole-admin safe |
| 03 | `Script03-Bulk Onboard New User to Multiple Workspaces.ps1` | Add user to workspaces by filter or explicit ID list |
| 04 | `Script04-Audit Active Publish to Web Embed Codes.ps1` | Find all active Publish to Web embed codes |
| 05 | `Script05-Tenant Settings Snapshot and Change Detection.ps1` | Snapshot tenant settings + diff against previous run |
| 06 | `Script06-30-Day Audit Log Extraction.ps1` | Extract 27-day activity log (safe cap) |
| 07 | `Script07-Dataset Refresh Status Report.ps1` | Refresh status across all semantic models |
| 08 | `Script08-Trigger Bulk Semantic Model Refresh.ps1` | Trigger refresh on multiple datasets |
| 09 | `Script09-Full Dataset - Semantic Model Inventory.ps1` | Full dataset / semantic model inventory |
| 10 | `Script10-Full Report Inventory with Dataset Lineage.ps1` | Report inventory with dataset lineage |
| 11 | `Script11-Find Orphaned and Ungoverned Workspaces.ps1` | Detect orphaned, single-admin, stale workspaces |
| 12 | `Script12-Bulk .pbix Backup of a Workspace.ps1` | Bulk export `.pbix` files from a workspace |
| 13 | `Script13-Find Datasets with No Recent Refresh (Stale Data).ps1` | Find stale datasets by configurable threshold |
| 14 | `Script14-Capacity Inventory and Workspace Assignment.ps1` | Capacity inventory and workspace assignments |
| 15 | `Script15-Dataflow Bulk Export (JSON Backup).ps1` | Bulk export dataflow definitions as JSON |
| 17 | `Script17-Power BI App Audience Audit.ps1` | Audit Power BI app audiences and access |
| 18 | `Script18-User Access Report (What Does This Person Have Access To-).ps1` | Full access report for a given user |
| 19 | `Script19-Scheduled Refresh Configuration Audit.ps1` | Audit scheduled refresh configurations |
| 20 | `Script20-Sensitivity Label Inventory.ps1` | Inventory sensitivity labels across tenant |
| 21 | `Script21-Workspace Capacity Assignment (Bulk Move).ps1` | Bulk-move workspaces to a capacity |
| — | `Connect-PBIAccount.ps1` | **Shared auth function** — dot-sourced by all scripts |

---

## Authentication

All scripts dot-source `Connect-PBIAccount.ps1`. Place it in `C:\PBIAdmin\` or update the path in each script.

**Supported auth modes** (pass `-AuthMode` parameter):

| Mode | Use for |
|---|---|
| `Interactive` | Local testing — opens browser login |
| `ServicePrincipalSecret` | Scheduled tasks — client ID + secret |
| `ServicePrincipalCert` | Production — certificate thumbprint |

---

## Validation status

Scripts are logic-validated and cross-checked against Microsoft documentation and community error reports.  
**Live API validation against a test tenant is in progress** — see the Known Limitations section of the guide for per-script status.

---

## License

MIT — see [LICENSE](LICENSE)

© 2026 WizEmp · [wizemp.com](https://wizemp.com)
