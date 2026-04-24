# teams-tenant-migration

PowerShell scripts for migrating Microsoft Teams (structure + files) between two M365 tenants.

## What it does

1. Exports a Team's structure (channels, members, settings) as a JSON blueprint
2. Exports all files from the Team's SharePoint drive
3. Recreates the Team in the destination tenant from the blueprint
4. Uploads all files via PnP PowerShell

## Requirements

- [Microsoft Teams PowerShell module](https://learn.microsoft.com/en-us/microsoftteams/teams-powershell-install)
- [PnP.PowerShell](https://pnp.github.io/powershell/)
- [Microsoft.Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/installation)
- An Azure AD App Registration in each tenant with appropriate permissions

## Usage

Run the orchestrator script and follow the prompts:

```powershell
.\src\Start-TeamsMigration.ps1
```

You will be asked for:
- Team display name
- Source and destination tenant (short name, e.g. `contoso`)
- Azure AD App IDs for both tenants
- Local export root path

## Structure

```
src/        # Current version (v2)
legacy/     # Earlier version (v1, kept for reference)
```

## Notes

- The script connects interactively to both tenants — no credentials are stored
- Only run modules (`Import-*`, `Export-*`) can also be called standalone
- Exported blueprints and files are local only and excluded from this repo via `.gitignore`
