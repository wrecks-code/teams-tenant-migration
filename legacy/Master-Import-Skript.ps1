param (
    [Parameter(Mandatory = $true)]
    [string]$TeamName
)

# Feste Werte
$BlueprintPath = "$env:USERPROFILE\Documents\Teams-Migration\_Blueprints\$TeamName\TeamBlueprint.json"
$SourceRoot    = "$env:USERPROFILE\Documents\Teams-Migration"
$TenantShort   = "YOUR-DEST-TENANT"
$AppId         = "00000000-0000-0000-0000-000000000002"
$TenantId      = "$TenantShort.onmicrosoft.com"
$MainSiteUrl   = "https://$TenantShort.sharepoint.com"

# Verbindungen herstellen
Import-Module MicrosoftTeams -ErrorAction Stop
try { Get-Team -ErrorAction Stop | Out-Null } catch { Connect-MicrosoftTeams }

Import-Module PnP.PowerShell -ErrorAction Stop
Connect-PnPOnline -Url $MainSiteUrl -ClientId $AppId -Tenant $TenantId -Interactive

# Funktionen laden
. .\Import-TeamBlueprint.ps1
. .\Import-TeamFiles.ps1

# Team erstellen
Import-TeamBlueprint.ps1 -TeamName $TeamName

# Dateien hochladen
Import-TeamFiles.ps1 -TeamName $TeamName