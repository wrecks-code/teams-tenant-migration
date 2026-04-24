# === FULL TEAM DOWNLOAD (RECURSIVE, WITH RETRY & DELTA-SKIP) ===
$TeamName = 'P0122-AY Schwandorf'
$DestRoot = '$env:USERPROFILE\Documents\Teams-Migration'

# Toggle: also pull ALL document libraries from the Team's SharePoint site
$IncludeTeamSiteAllLibraries      = $true
# Toggle: if site libraries were downloaded, skip Standard channels to avoid duplicates
$SkipStandardChannelIfSiteDownloaded = $true

Import-Module Microsoft.Graph.Groups -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.Teams  -ErrorAction SilentlyContinue

# --- helpers ---
function Ensure-Dir([string]$p){ if(-not (Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }
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
      if(Test-Path -LiteralPath $out){
        try{
          $fi = Get-Item -LiteralPath $out -ErrorAction Stop
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

# --- NEW: Team site/library helpers ---
function Get-GroupRootSiteId([string]$groupId){
  $site = Retry { Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/sites/root" }
  return $site.id
}
function Get-SiteDrives([string]$siteId){
  $url = "https://graph.microsoft.com/v1.0/sites/$siteId/drives?`$top=200"
  $resp = Retry { Invoke-MgGraphRequest -Method GET -Uri $url }
  foreach($d in @($resp.value)){ $d }
  $next = $resp.'@odata.nextLink'
  while($next){
    $resp = Retry { Invoke-MgGraphRequest -Method GET -Uri $next }
    foreach($d in @($resp.value)){ $d }
    $next = $resp.'@odata.nextLink'
  }
}
function Get-DriveRootItemId([string]$driveId){
  $root = Retry { Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/drives/$driveId/root" }
  return $root.id
}
function Download-Drive([string]$driveId,[string]$targetPath){
  Ensure-Dir $targetPath
  $rootId = Get-DriveRootItemId -driveId $driveId
  Download-Tree -driveId $driveId -itemId $rootId -targetPath $targetPath
}

# --- main ---
$group = Retry { Get-MgGroup -Filter "displayName eq '$TeamName' and resourceProvisioningOptions/Any(x:x eq 'Team')" -All }
if(-not $group){ throw "Team '$TeamName' nicht gefunden." }
$teamId = $group.Id

$teamBase = Join-Path $DestRoot (Sanitize $TeamName)
Ensure-Dir $teamBase

# (A) NEW: Download ALL document libraries from the Team's root SharePoint site
if($IncludeTeamSiteAllLibraries){
  try{
    $rootSiteId = Get-GroupRootSiteId -groupId $teamId
    $drives = @(Get-SiteDrives -siteId $rootSiteId)

    Write-Host ""
    Write-Host "==== $TeamName | Team Site | Alle Dokumentbibliotheken ====" -ForegroundColor Cyan

    foreach($drv in $drives){
      $libName = Sanitize $drv.name
      $libOut  = Join-Path $teamBase ("Site - " + $libName)
      Write-Host "---- Library: $($drv.name) ----" -ForegroundColor Magenta
      Download-Drive -driveId $drv.id -targetPath $libOut
    }
  } catch {
    Write-Host "[WARN] Konnte Team-SharePoint-Site/Libraries nicht abrufen: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# (B) Channels (optionally skip Standard to avoid duplicates)
$channels = Retry { Get-MgTeamChannel -TeamId $teamId -All }

foreach($c in $channels){
  $kind = switch ($c.membershipType) { 'private'{'Private'} 'shared'{'Shared'} default{'Standard'} }

  if($IncludeTeamSiteAllLibraries -and $SkipStandardChannelIfSiteDownloaded -and $kind -eq 'Standard'){
    Write-Host "[SKIP] $($c.displayName): Standardkanal ist in der Site-Bibliothek 'Documents' enthalten." -ForegroundColor DarkGray
    continue
  }

  try{
    $ff = Retry { Get-MgTeamChannelFileFolder -TeamId $teamId -ChannelId $c.Id -ErrorAction Stop }
  } catch {
    Write-Host "[SKIP] $($c.displayName): FilesFolder nicht erreichbar ($($_.Exception.Message))" -ForegroundColor Yellow
    continue
  }

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
``