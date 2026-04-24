param(
  [Parameter(Mandatory=$true)]
  [string]$TeamName
)

# ====== FIXED CONFIGURATION ======
$TargetDomain   = "mitigate.eco"
$FallbackOwner  = "marius.ladner@mitigate.eco"
$BlueprintPath  = "$env:USERPROFILE\Documents\Teams-Migration\_Blueprints\$TeamName\TeamBlueprint.json"
# =================================

# ---------- Load Blueprint ----------
Import-Module MicrosoftTeams -ErrorAction Stop
try { Get-Team -ErrorAction Stop | Out-Null } catch { Connect-MicrosoftTeams }

if (-not (Test-Path $BlueprintPath)) { throw "Blueprint not found: $BlueprintPath" }

$bp     = Get-Content -Raw -Path $BlueprintPath | ConvertFrom-Json
$teamIn = $bp.Team

# ---------- Create Team ----------
$displayName = $teamIn.DisplayName
$visibility  = $teamIn.Visibility ?? "Private"
$mailNick    = $teamIn.MailNickName ?? "team$((Get-Random -Maximum 99999))"
$description = $teamIn.Description

Write-Host "Creating Team: $displayName" -ForegroundColor Cyan

$newParams = @{
  DisplayName  = $displayName
  Visibility   = $visibility
  MailNickName = $mailNick
}
if ($description) { $newParams["Description"] = $description }

$teamObj = New-Team @newParams
$groupId = $teamObj.GroupId

# ---------- Add Members ----------
function Map-UPN($upn) {
    if (-not $upn -or $upn -match '#EXT#') { return $null }
    return "$($upn.Split('@')[0])@$TargetDomain"
}

function Ensure-TeamMember($groupId, $upn, $role="Member") {
    if (-not $upn) { return }
    try {
        $exists = Get-TeamUser -GroupId $groupId | Where-Object { $_.User -ieq $upn }
        if (-not $exists) { Add-TeamUser -GroupId $groupId -User $upn -Role $role }
    } catch {
        Write-Warning "Add-TeamUser '$upn' failed: $($_.Exception.Message)"
    }
}

Ensure-TeamMember $groupId $FallbackOwner "Owner"

$owners  = $bp.Owners  | ForEach-Object { Map-UPN $_.User } | Where-Object { $_ }
$members = $bp.Members | ForEach-Object { Map-UPN $_.User } | Where-Object { $_ }

foreach ($o in $owners)  { Ensure-TeamMember $groupId $o "Owner" }
foreach ($m in $members) { if ($owners -notcontains $m) { Ensure-TeamMember $groupId $m "Member" } }

# ---------- Create Channels ----------
Start-Sleep -Seconds 5

foreach ($ch in $bp.Channels) {
    $name = ($ch.DisplayName -replace '[#%&*{}\/\\:<>\?+|''"]', '_').Trim()
    if ($name -match '^(Allgemein|General)$') { continue }

    $params = @{ GroupId=$groupId; DisplayName=$name }
    if ($ch.Description)    { $params["Description"]    = $ch.Description }
    if ($ch.MembershipType) { $params["MembershipType"] = $ch.MembershipType }

    if ($params["MembershipType"] -in @("Private", "Shared")) {
        Ensure-TeamMember $groupId $FallbackOwner "Owner"
        $params["Owner"] = $FallbackOwner
    }

    try {
        New-TeamChannel @params
    } catch {
        Write-Warning "Channel '$name' creation failed: $($_.Exception.Message)"
    }
}

Write-Host "`nDone. Team created: $displayName" -ForegroundColor Green