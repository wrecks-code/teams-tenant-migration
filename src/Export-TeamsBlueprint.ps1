<#
  Export-TeamBlueprint.ps1
  Exportiert Team-Metadaten, Owner/Members/Guests, Channels (inkl. MembershipType)
  und – sofern verfügbar – Channel-Mitglieder (Private/Shared) in eine JSON-Datei.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Team,                 # DisplayName ODER GroupId (GUID)

    [string]$OutFolder = "$env:USERPROFILE\Documents\Teams-Migration\_Blueprints"
)

# --- Hilfen ---
function Sanitize([string]$name) { ($name -replace '[\\/:*?"<>|]', '_').Trim() }

# --- Module / Login ---
Import-Module MicrosoftTeams -ErrorAction Stop
Connect-MicrosoftTeams  # Interaktiv anmelden

# --- Team auflösen (DisplayName -> GroupId oder direkt GroupId) ---
$teamObj = $null
if ($Team -match '^[0-9a-fA-F-]{36}$') {
    $teamObj = Get-Team -GroupId $Team
} else {
    # Get-Team ist ein Filter; wir erzwingen eine exakte Übereinstimmung wenn möglich
    $candidates = Get-Team -DisplayName $Team
    $teamObj = $candidates | Where-Object { $_.DisplayName -eq $Team } | Select-Object -First 1
    if (-not $teamObj) { $teamObj = $candidates | Select-Object -First 1 }
}

if (-not $teamObj) { throw "Team '$Team' nicht gefunden." }

$groupId = $teamObj.GroupId

# --- Owner/Members (Team-weit) ---
$owners  = Get-TeamUser -GroupId $groupId -Role Owner  | Select-Object Name, User, Role   # Owner-Liste  [4](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/?view=teams-ps)
$members = Get-TeamUser -GroupId $groupId -Role Member | Select-Object Name, User, Role   # Member-Liste [4](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/?view=teams-ps)
# Gäste pragmatisch über #EXT#-UPNs erkennen (klassisches Muster)
$guests  = $members | Where-Object { $_.User -match '#EXT#' } | Select-Object Name, User, Role

# --- Channels (Standard/Private/Shared) ---
$channels = Get-TeamChannel -GroupId $groupId                                            # [2](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamchannel?view=teams-ps)

# Prüfen, ob Get-TeamChannelUser verfügbar ist (Public Preview-Cmdlet)
$hasChannelUserCmd = $null -ne (Get-Command Get-TeamChannelUser -ErrorAction SilentlyContinue)

$channelObjs = @()
foreach ($ch in $channels) {
    $chanUsers = @()
    if ($hasChannelUserCmd) {
        try {
            # Liefert Mitglieder/Owner eines Channels (sinnvoll v. a. für Private/Shared)
            $chanUsers = Get-TeamChannelUser -GroupId $groupId -DisplayName $ch.DisplayName |
                         Select-Object Name, User, Role                                    # [3](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamchanneluser?view=teams-ps)
        } catch { } # wenn kein Zugriff/kein privater Kanal -> leer lassen
    }

    $channelObjs += [pscustomobject]@{
        Id             = $ch.Id
        DisplayName    = $ch.DisplayName
        Description    = $ch.Description
        MembershipType = $ch.MembershipType   # Standard / Private / Shared (je nach Modulstand) [2](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamchannel?view=teams-ps)
        Users          = $chanUsers
    }
}

# --- Exportobjekt bauen ---
$export = [pscustomobject]@{
    ExportedAt = (Get-Date).ToString("s")
    Team       = [pscustomobject]@{
        GroupId      = $teamObj.GroupId
        DisplayName  = $teamObj.DisplayName
        Visibility   = $teamObj.Visibility
        Archived     = $teamObj.Archived
        MailNickName = $teamObj.MailNickName
    }
    Owners   = $owners
    Members  = $members
    Guests   = $guests
    Channels = $channelObjs
}

# --- Schreiben ---
$teamFolder = Join-Path $OutFolder (Sanitize $teamObj.DisplayName)
if (-not (Test-Path $teamFolder)) { New-Item -ItemType Directory -Path $teamFolder -Force | Out-Null }

$outFile = Join-Path $teamFolder "TeamBlueprint.json"
$export | ConvertTo-Json -Depth 12 | Out-File -FilePath $outFile -Encoding UTF8

Write-Host "Export gespeichert in: $outFile" -ForegroundColor Green