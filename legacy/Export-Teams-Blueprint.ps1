function Export-TeamBlueprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Team,  # DisplayName ODER GroupId (GUID)

        [string]$OutFolder = "$env:USERPROFILE\Documents\Teams-Migration\_Blueprints"
    )

    # --- Hilfen ---
    function Sanitize([string]$name) { ($name -replace '[\\/:*?"<>|]', '_').Trim() }

    # --- Module / Login ---
    Import-Module MicrosoftTeams -ErrorAction Stop
    Connect-MicrosoftTeams  # Interaktiv anmelden

    # --- Team auflösen ---
    $teamObj = $null
    if ($Team -match '^[0-9a-fA-F-]{36}$') {
        $teamObj = Get-Team -GroupId $Team
    } else {
        $candidates = Get-Team -DisplayName $Team
        $teamObj = $candidates | Where-Object { $_.DisplayName -eq $Team } | Select-Object -First 1
        if (-not $teamObj) { $teamObj = $candidates | Select-Object -First 1 }
    }

    if (-not $teamObj) { throw "Team '$Team' nicht gefunden." }

    $groupId = $teamObj.GroupId

    # --- Owner/Members ---
    $owners  = Get-TeamUser -GroupId $groupId -Role Owner  | Select-Object Name, User, Role
    $members = Get-TeamUser -GroupId $groupId -Role Member | Select-Object Name, User, Role
    $guests  = $members | Where-Object { $_.User -match '#EXT#' } | Select-Object Name, User, Role

    # --- Channels ---
    $channels = Get-TeamChannel -GroupId $groupId
    $hasChannelUserCmd = $null -ne (Get-Command Get-TeamChannelUser -ErrorAction SilentlyContinue)

    $channelObjs = @()
    foreach ($ch in $channels) {
        $chanUsers = @()
        if ($hasChannelUserCmd) {
            try {
                $chanUsers = Get-TeamChannelUser -GroupId $groupId -DisplayName $ch.DisplayName |
                             Select-Object Name, User, Role
            } catch { }
        }

        $channelObjs += [pscustomobject]@{
            Id             = $ch.Id
            DisplayName    = $ch.DisplayName
            Description    = $ch.Description
            MembershipType = $ch.MembershipType
            Users          = $chanUsers
        }
    }

    # --- Exportobjekt ---
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
}