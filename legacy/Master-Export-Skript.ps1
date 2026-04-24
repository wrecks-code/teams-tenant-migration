# Master-Export-Skript.ps1

#!!Connect-MgGraph nciht vergessen
param (
    [Parameter(Mandatory = $true)]
    [string]$TeamName,

    [string]$OutRoot = "$env:USERPROFILE\Documents\Teams-Migration"
)

# Importiere beide Funktionen
. .\Export-Teams-Blueprint.ps1
. .\Export-Teams-Files.ps1

# Führe beide Exporte aus
Export-TeamBlueprint -Team $TeamName -OutFolder "$OutRoot\_Blueprints"
Export-TeamFiles     -TeamName $TeamName -DestRoot $OutRoot