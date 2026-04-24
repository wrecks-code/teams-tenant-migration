# Import-TeamBlueprint.SIMPLE.ps1
# Creates a Team from a blueprint in the TARGET tenant (mitigate.eco),
# maps internal users to @mitigate.eco, skips guests, creates channels,
# and uses a fixed fallback owner for team and private/shared channels.

param(
  [Parameter(Mandatory=$true)]
  [string]$BlueprintPath
)

# ====== CONFIG (fixed for your case) ======
$TargetDomain   = "mitigate.eco"
$FallbackOwner  = "marius.ladner@mitigate.eco"   # always owner + channel owner
$SkipGuests     = $true                          # change to $false if you later invite B2B guests
# ==========================================

# ---------- Helpers ----------
function Map-UPN([string]$upn) {
    if (-not $upn) { return $null }
    if ($upn -match '#EXT#') { return $null }  # treat as guest => skip
    $parts = $upn.Split('@')
    if ($parts.Count -ne 2) { return $null }
    "$($parts[0])@$TargetDomain"
}

function Sanitize-Channel([string]$s) {
    $pattern = '[#%&*{}\/\\:<>?+|''"]'
    return ($s -replace $pattern, '_').Trim()
}

function Sanitize-MailNick([string]$s) {
    $clean = ($s -replace '[^a-zA-Z0-9._-]', '')
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = "team$(Get-Random -Maximum 99999)" }
    $clean.Substring(0, [Math]::Min(64, $clean.Length))
}

function Wait-UntilTeamHasMember($groupId, $upn, $max=20, $sleep=2) {
    for ($i=0; $i -lt $max; $i++) {
        $ok = Get-TeamUser -GroupId $groupId -ErrorAction SilentlyContinue | Where-Object { $_.User -ieq $upn }
        if ($ok) { return $true }
        Start-Sleep -Seconds $sleep
    }
    return $false
}

function Wait-UntilChannelExists($groupId, $name, $max=30, $sleep=2) {
    for ($i=0; $i -lt $max; $i++) {
        $ch = Get-TeamChannel -GroupId $groupId -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name }
        if ($ch) { return $true }
        Start-Sleep -Seconds $sleep
    }
    return $false
}

function Ensure-TeamMember($groupId, $upn, $role="Member") {
    if (-not $upn) { return }
    try {
        $exists = Get-TeamUser -GroupId $groupId -ErrorAction SilentlyContinue | Where-Object { $_.User -ieq $upn }
        if (-not $exists) { Add-TeamUser -GroupId $groupId -User $upn -Role $role | Out-Null }
        Wait-UntilTeamHasMember $groupId $upn | Out-Null
    } catch {
        Write-Warning "Add-TeamUser '$upn' ($role) failed: $($_.Exception.Message)"
    }
}

# ---------- Start ----------
Import-Module MicrosoftTeams -ErrorAction Stop
try { Get-Team -ErrorAction Stop | Out-Null } catch { Connect-MicrosoftTeams }

if (-not (Test-Path $BlueprintPath)) { throw "Blueprint not found: $BlueprintPath" }

$bp     = Get-Content -Raw -Path $BlueprintPath | ConvertFrom-Json
$teamIn = $bp.Team

$displayName = $teamIn.DisplayName
$visibility  = if ($teamIn.Visibility) { $teamIn.Visibility } else { "Private" }
$mailNick    = if ($teamIn.MailNickName) { $teamIn.MailNickName } else { Sanitize-MailNick $displayName }
$description = $teamIn.Description

Write-Host "Creating Team: $displayName (Vis=$visibility, Alias=$mailNick)" -ForegroundColor Cyan

$newParams = @{
  DisplayName  = $displayName
  Visibility   = $visibility
  MailNickName = $mailNick
}
if ($description) { $newParams["Description"] = $description }

$teamObj = New-Team @newParams
$groupId = $teamObj.GroupId

# Ensure fallback owner
Ensure-TeamMember $groupId $FallbackOwner "Owner"

# Map & add owners/members from blueprint (internal only)
$ownersMapped  = @($bp.Owners  | ForEach-Object { Map-UPN $_.User }) | Where-Object { $_ }
$membersMapped = @($bp.Members | ForEach-Object { Map-UPN $_.User }) | Where-Object { $_ }

foreach ($o in $ownersMapped)  { Ensure-TeamMember $groupId $o "Owner" }
foreach ($m in $membersMapped) { if ($ownersMapped -notcontains $m) { Ensure-TeamMember $groupId $m "Member" } }

# Give backend a breath so private channels don't 404
Start-Sleep -Seconds 5

# Create channels
foreach ($ch in @($bp.Channels)) {
    $name = Sanitize-Channel $ch.DisplayName
    if ($name -match '^(Allgemein|General)$') { continue }

    $params = @{ GroupId=$groupId; DisplayName=$name }
    if ($ch.Description)    { $params["Description"]    = $ch.Description }
    if ($ch.MembershipType) { $params["MembershipType"] = $ch.MembershipType }

    $isPrivOrShared = $ch.MembershipType -and ($ch.MembershipType -ieq "Private" -or $ch.MembershipType -ieq "Shared")
    if ($isPrivOrShared) {
        # channel owner must be internal team member -> fallback owner
        Ensure-TeamMember $groupId $FallbackOwner "Owner"
        $params["Owner"] = $FallbackOwner
    }

    try {
        New-TeamChannel @params | Out-Null
        if (-not (Wait-UntilChannelExists $groupId $name)) {
            Write-Warning "Channel '$name' not visible yet; continuing…"
        }
    } catch {
        Write-Warning "Create channel '$name' failed: $($_.Exception.Message)"
        continue
    }

    # Channel members for Private/Shared: map to @mitigate, skip guests, ensure team member then add to channel
    if ($isPrivOrShared -and $ch.Users) {
        foreach ($u in $ch.Users) {
            $mapped = Map-UPN $u.User
            if (-not $mapped) { continue } # guest or invalid -> skip
            $role = if ($u.Role -and $u.Role -match 'Owner') { 'Owner' } else { 'Member' }

            Ensure-TeamMember $groupId $mapped "Member"
            try {
                Add-TeamChannelUser -GroupId $groupId -DisplayName $name -User $mapped | Out-Null
                if ($role -eq 'Owner') {
                    # promotion must be after member add
                    Add-TeamChannelUser -GroupId $groupId -DisplayName $name -User $mapped -Role Owner | Out-Null
                }
            } catch {
                Write-Warning "Add channel user '$mapped' -> '$name' failed: $($_.Exception.Message)"
            }
        }
    }
}

Write-Host "`nDone. Team:" -ForegroundColor Green
[pscustomobject]@{ DisplayName=$displayName; GroupId=$groupId; Visibility=$visibility; MailNick=$mailNick } | Format-List