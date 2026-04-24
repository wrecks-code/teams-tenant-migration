# === FULL TEAM DOWNLOAD (RECURSIVE, WITH RETRY & DELTA-SKIP) ===
$TeamName = 'YOUR-TEAM-NAME'
$DestRoot = '$env:USERPROFILE\Documents\Teams-Migration'

Import-Module Microsoft.Graph.Groups -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.Teams  -ErrorAction SilentlyContinue

# --- helpers ---
function Ensure-Dir([string]$p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }
function Sanitize([string]$n){ $bad=[IO.Path]::GetInvalidFileNameChars() -join ''; ($n -replace "[$([regex]::Escape($bad))]",'_').Trim() }
function Retry([scriptblock]$a){ for($i=0;$i -lt 6;$i++){ try{ return & $a } catch{ if($i -eq 5){throw}; Start-Sleep -Seconds ([math]::Min(60,[math]::Pow(2,$i))) } } }

function Get-ChildrenPage([string]$driveId,[string]$itemId){
  $url = "https://graph.microsoft.com/v1.0/drives/$driveId/items/$itemId/children?`$top=200"
  $resp = Retry { Invoke-MgGraphRequest -Method GET -Uri $url }
  return $resp
}
function Get-AllChildren([string]$driveId,[string]$itemId){
  $resp = Get-ChildrenPage -driveId $driveId -itemId $itemId
  foreach($i in @($resp.value)){ $i }
  $next = $resp.'@odata.nextLink'
  while($next){
    $resp = Retry { Invoke-MgGraphRequest -Method GET -Uri $next }
    foreach($i in @($resp.value)){ $i }
    $next = $resp.'@odata.nextLink'
  }
}
function Download-Tree([string]$driveId,[string]$itemId,[string]$targetPath){
  # hole Einträge des Ordners und laufe rekursiv
  foreach($child in (Get-AllChildren -driveId $driveId -itemId $itemId)){
    $name = Sanitize $child.name
    $out  = Join-Path $targetPath $name

    if($child.folder){
      Ensure-Dir $out
      Download-Tree -driveId $driveId -itemId $child.id -targetPath $out
    }
    elseif($child.file){
      # Delta-Skip anhand Größe
      $expected = $child.size
      if(Test-Path $out){
        try{
          $fi = Get-Item $out -ErrorAction Stop
          if([int64]$fi.Length -eq [int64]$expected){
            Write-Host "SKIP  $out  (size matches)" -ForegroundColor DarkGray
            continue
          }
        } catch {}
      }

      $dl = $child.'@microsoft.graph.downloadUrl'
      if(-not $dl){ $dl = "https://graph.microsoft.com/v1.0/drives/$driveId/items/$($child.id)/content" }
      Write-Host "GET   $out"
      Retry { Invoke-WebRequest -Uri $dl -OutFile $out -UseBasicParsing -MaximumRedirection 3 -ErrorAction Stop } | Out-Null
    }
  }
}

# --- main ---
$group = Retry { Get-MgGroup -Filter "displayName eq '$TeamName' and resourceProvisioningOptions/Any(x:x eq 'Team')" -All }
if(-not $group){ throw "Team '$TeamName' nicht gefunden." }
$teamId = $group.Id

$teamBase = Join-Path $DestRoot (Sanitize $TeamName)
Ensure-Dir $teamBase

$channels = Retry { Get-MgTeamChannel -TeamId $teamId -All }

foreach($c in $channels){
  try{
    $ff = Retry { Get-MgTeamChannelFileFolder -TeamId $teamId -ChannelId $c.Id -ErrorAction Stop }
  } catch {
    Write-Host "[SKIP] $($c.displayName): FilesFolder nicht erreichbar ($($_.Exception.Message))" -ForegroundColor Yellow
    continue
  }

  $kind = switch ($c.membershipType) { 'private'{'Private'} 'shared'{'Shared'} default{'Standard'} }
  $chanOut = Join-Path $teamBase ("$kind - " + (Sanitize $c.displayName))
  Ensure-Dir $chanOut

  $driveId = $ff.ParentReference.DriveId
  $rootId  = $ff.Id

  Write-Host ""
  Write-Host "==== $TeamName | $kind | $($c.displayName) ====" -ForegroundColor Cyan
  Download-Tree -driveId $driveId -itemId $rootId -targetPath $chanOut
}

Write-Host ""
Write-Host "DONE  -> $teamBase" -ForegroundColor Green
