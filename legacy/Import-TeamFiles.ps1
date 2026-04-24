param(
  [Parameter(Mandatory)][string]$TeamName
)

# ===== FIXED CONFIG =====
$SourceRoot  = "$env:USERPROFILE\Documents\Teams-Migration"
$TenantShort = "YOUR-DEST-TENANT"
$AppId       = "00000000-0000-0000-0000-000000000002"
# ========================

# ===== BEHAVIOR TOGGLES =====
$IncludeSiteLibraries = $true
$SkipStandardIfSiteDocumentsPresent = $true
$ShowProgress = $true
# ===========================

Import-Module PnP.PowerShell -ErrorAction Stop
Import-Module Microsoft.Graph.Groups  -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.Teams   -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'

# ---------------------------
# Helpers: filesystem & text
# ---------------------------
function Ensure-Dir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Lokaler Pfad fehlt: $p" }
}
function To-SPSegment([string]$s){
  $x = $s.Trim() -replace '[^0-9A-Za-z\- _.]','' -replace '\s+','-' -replace '-{2,}','-'
  return $x
}

# ---------------------------
# Helpers: Graph resolution
# ---------------------------
function Retry([scriptblock]$a){
  for($i=0;$i -lt 6;$i++){
    try { return & $a } catch {
      if($i -eq 5){ throw }
      Start-Sleep -Seconds ([math]::Min(60,[math]::Pow(2,$i)))
    }
  }
}

function Ensure-Graph(){
  try { $null = Get-MgContext } catch {
    Write-Host "[GRAPH] Connecting…" -ForegroundColor Cyan
    # add basic team/channel scopes so channel listing & file-folder works reliably
    Connect-MgGraph -Scopes "Group.Read.All","Sites.Read.All","Team.ReadBasic.All","Channel.ReadBasic.All" -ErrorAction Stop
  }
}

function Get-GroupByTeamName([string]$name){
  Ensure-Graph
  $groups = Retry { Get-MgGroup -Filter "displayName eq '$name' and resourceProvisioningOptions/Any(x:x eq 'Team')" -All }
  if(-not $groups){ throw "Team '$name' nicht gefunden (Graph)." }
  if($groups -is [System.Array]){ return $groups[0] } else { return $groups }
}

function Get-TeamRootSiteWebUrl([string]$groupId){
  Ensure-Graph
  $site = Retry { Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/sites/root?`$select=id,webUrl" }
  if(-not $site.webUrl){ throw "Root-Site WebUrl nicht ermittelbar (GroupId=$groupId)." }
  return $site.webUrl
}

function Get-ChannelSiteMap([string]$teamId){
  # Returns hashtable: DisplayName -> @{ membershipType=<standard|private|shared>; webUrl=<site url or $null for standard> }
  Ensure-Graph
  $map = @{}
  $channels = Retry { Get-MgTeamChannel -TeamId $teamId -All }
  foreach($c in $channels){
    $kind = if($c.membershipType){ $c.membershipType } else { 'standard' }
    if($kind -in @('private','shared')){
      try{
        $ff = Retry { Get-MgTeamChannelFileFolder -TeamId $teamId -ChannelId $c.Id -ErrorAction Stop }
        $siteId = $ff.ParentReference.SiteId
        if($siteId){
          $s = Retry { Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/sites/$siteId?`$select=webUrl" }
          $map[$c.displayName] = @{ membershipType = $kind; webUrl = $s.webUrl }
          continue
        }
      } catch {}
    }
    # standard or fallback
    $map[$c.displayName] = @{ membershipType = 'standard'; webUrl = $null }
  }
  return $map
}

# ---------------------------
# Helpers: PnP connection
# ---------------------------
function Connect-PnP-Interactive([string]$siteUrl) {
  $tenantId = "$TenantShort.onmicrosoft.com"
  Write-Host "[CONNECT] $siteUrl" -ForegroundColor Cyan
  try{
    Connect-PnPOnline -Url $siteUrl -ClientId $AppId -Tenant $tenantId -Interactive -ErrorAction Stop
  } catch {
    Write-Host "[RETRY] Using PnP Management Shell app…" -ForegroundColor DarkCyan
    $pnpShellAppId = "31359c7f-bd7e-475c-86db-fdb8c937548e"
    Connect-PnPOnline -Url $siteUrl -ClientId $pnpShellAppId -Tenant $tenantId -Interactive -ErrorAction Stop
  }
  try { $null = Get-PnPWeb -ErrorAction Stop } catch {
    throw "Get-PnPWeb failed on $siteUrl :: $($_.Exception.Message)"
  }
}

# ---------------------------
# Helpers: SPO structures
# ---------------------------
function Get-DocumentsRootRelUrl(){
  $candidates = @("Dokumente","Documents","Shared Documents","Freigegebene Dokumente")
  foreach($name in $candidates){
    try { return (Get-PnPList -Identity $name).RootFolder.ServerRelativeUrl.TrimEnd('/') } catch {}
  }
  $libs = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden }
  if($libs.Count -eq 1){ return $libs[0].RootFolder.ServerRelativeUrl.TrimEnd('/') }
  $preferred = $libs | Where-Object { $_.RootFolder.ServerRelativeUrl -match '/(Shared|Freigegebene|Dokumente)(\b|/)' } | Select-Object -First 1
  if($preferred){ return $preferred.RootFolder.ServerRelativeUrl.TrimEnd('/') }
  throw "Keine passende Dokumentbibliothek gefunden."
}

function Resolve-GeneralFolderName([string]$docsRoot){
  $genServer = "$docsRoot/General"
  $allServer = "$docsRoot/Allgemein"
  try { Get-PnPFolder -Url $genServer | Out-Null; return 'General' } catch {}
  try { Get-PnPFolder -Url $allServer | Out-Null; return 'Allgemein' } catch {}
  return 'General'
}

function Ensure-PnPFolderPath([string]$webRelFolder){
  $webRel = (Get-PnPWeb).ServerRelativeUrl.TrimEnd('/')
  $parts = $webRelFolder -split '/'
  $accum = ""
  foreach($p in $parts){
    if([string]::IsNullOrWhiteSpace($p)){ continue }
    $accum = ($accum ? "$accum/$p" : $p)
    $serverCheck = "$webRel/$accum"
    try { Get-PnPFolder -Url $serverCheck | Out-Null }
    catch {
      $parent = ($accum.Contains('/') ? $accum.Substring(0, $accum.LastIndexOf('/')) : "")
      try { Add-PnPFolder -Folder $parent -Name $p | Out-Null } catch {
        Write-Host "[WARN] Ordner konnte nicht angelegt werden: $parent/$p :: $($_.Exception.Message)" -ForegroundColor DarkYellow
      }
    }
  }
}

function Upload-FilePnP([string]$localFile, [string]$targetWebRel){
  $fileName = [IO.Path]::GetFileName($localFile)
  $webRel   = (Get-PnPWeb).ServerRelativeUrl.TrimEnd('/')
  $serverRel = "$webRel/$($targetWebRel.Trim('/') + '/' + $fileName)"
  try { Get-PnPFile -Url $serverRel | Out-Null; Write-Host "SKIP  $localFile (exists)" -ForegroundColor Yellow; return $true } catch {}
  try {
    Add-PnPFile -Path $localFile -Folder $targetWebRel | Out-Null
    Write-Host "PUT   $localFile -> $targetWebRel" -ForegroundColor Green
    return $true
  } catch {
    Write-Host "[FAIL] $localFile -> $targetWebRel :: $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}

# ---- Libraries ----
function Get-LibraryServerRelUrl([string]$displayName){
  try {
    $lst = Get-PnPList -Identity $displayName -ErrorAction Stop
    return $lst.RootFolder.ServerRelativeUrl.TrimEnd('/')
  } catch {}

  if($displayName -match '^(Documents|Shared Documents|Dokumente|Freigegebene Dokumente)$'){
    try { return (Get-DocumentsRootRelUrl) } catch {}
  }

  $lists = Get-PnPList
  $match = $lists | Where-Object { $_.Title -ieq $displayName } | Select-Object -First 1
  if($match){ return $match.RootFolder.ServerRelativeUrl.TrimEnd('/') }

  return $null
}

function Ensure-DocLibrary([string]$displayName){
  $existing = Get-LibraryServerRelUrl $displayName
  if($existing){ return $existing }

  if($displayName -match '^(Site Pages|Websiteseiten)$'){
    throw "Spezialbibliothek '$displayName' nicht gefunden. Bitte manuell anlegen (Site Pages)."
  }

  Write-Host "[CREATE] Dokumentbibliothek: $displayName" -ForegroundColor Cyan
  try{
    Add-PnPList -Title $displayName -Template DocumentLibrary | Out-Null
    $lst = Get-PnPList -Identity $displayName -ErrorAction Stop
    return $lst.RootFolder.ServerRelativeUrl.TrimEnd('/')
  } catch {
    throw "Konnte Dokumentbibliothek '$displayName' nicht anlegen: $($_.Exception.Message)"
  }
}

# ---------------------------
# Progress-aware upload
# ---------------------------
function Get-LocalFilesRecursive([string]$root){
  return Get-ChildItem -LiteralPath $root -Recurse -File
}

function Upload-UnitFiles(
  [string]$localRoot,
  [string]$baseTargetWebRel,
  [string]$displayName,
  [int]$overallId,
  [ref]$overallProcessed,
  [int]$overallTotal
){
  $files = @(Get-LocalFilesRecursive $localRoot)
  $unitTotal = $files.Count
  $unitProcessed = 0
  $unitId = 9100 + (Get-Random -Minimum 1 -Maximum 800)

  $ensured = New-Object 'System.Collections.Generic.HashSet[string]'

  foreach($f in $files){
    $relFromRoot = $f.FullName.Substring($localRoot.Length).TrimStart('\','/')
    $relDir      = Split-Path -Parent $relFromRoot
    $targetWebRel = if([string]::IsNullOrWhiteSpace($relDir)){
      $baseTargetWebRel.Trim('/')
    } else {
      ($baseTargetWebRel.Trim('/') + '/' + ($relDir -replace '\\','/'))
    }

    if(-not $ensured.Contains($targetWebRel)){
      Ensure-PnPFolderPath $targetWebRel
      $null = $ensured.Add($targetWebRel)
    }

    # ---- FIXED LINE (correct param name + closing paren) ----
    [void](Upload-FilePnP -localFile $f.FullName -targetWebRel $targetWebRel)

    $unitProcessed++
    $overallProcessed.Value++

    if($ShowProgress){
      $pctUnit    = if($unitTotal -gt 0){ $unitProcessed * 100.0 / $unitTotal } else { 100 }
      $pctOverall = if($overallTotal -gt 0){ $overallProcessed.Value * 100.0 / $overallTotal } else { 100 }

      Write-Progress -Id $overallId -Activity "Overall upload" -Status "$($overallProcessed.Value) / $overallTotal files" -PercentComplete $pctOverall
      Write-Progress -Id $unitId    -ParentId $overallId -Activity "Uploading: $displayName" -Status "$unitProcessed / $unitTotal files" -PercentComplete $pctUnit
    }
  }

  if($ShowProgress){
    Write-Progress -Id $unitId -Activity "Uploading: $displayName" -Completed
  }
}

# ---------------------------
# MAIN
# ---------------------------
$teamPath = Join-Path $SourceRoot $TeamName
Ensure-Dir $teamPath

# Resolve actual Team & sites from Graph
$grp = Get-GroupByTeamName -name $TeamName
$teamId = $grp.Id
$rootSiteUrl = Get-TeamRootSiteWebUrl -groupId $teamId
$chanMap = Get-ChannelSiteMap -teamId $teamId   # displayName -> @{membershipType; webUrl}

# Enumerate local content
$allDirs       = Get-ChildItem $teamPath -Directory
$siteLibDirs   = @($allDirs | Where-Object { $_.Name -match '^Site\s-\s(.+)$' })
$channelDirs   = @($allDirs | Where-Object { $_.Name -match '^(Standard|Private|Shared)\s-\s(.+)$' })

# Detect presence of Site - Documents to skip Standard duplicates
$hasSiteDocuments = $false
foreach($dir in $siteLibDirs){
  if($dir.Name -match '^Site\s-\s(.+)$'){
    $libDisplay = $Matches[1].Trim()
    if($libDisplay -match '^(Documents|Shared Documents|Dokumente|Freigegebene Dokumente)$'){ $hasSiteDocuments = $true }
  }
}

$plannedChannelDirs = @()
foreach($dir in $channelDirs){
  if($dir.Name -match '^(Standard|Private|Shared)\s-\s(.+)$'){
    $kind = $Matches[1]
    if($SkipStandardIfSiteDocumentsPresent -and $hasSiteDocuments -and $kind -eq 'Standard'){ continue }
    $plannedChannelDirs += $dir
  }
}

# Count total files for progress
function Count-Files([System.IO.DirectoryInfo]$d){
  return (Get-ChildItem -LiteralPath $d.FullName -Recurse -File | Measure-Object).Count
}
$overallTotal = 0
foreach($d in $siteLibDirs){ $overallTotal += (Count-Files $d) }
foreach($d in $plannedChannelDirs){ $overallTotal += (Count-Files $d) }

$overallId = 9000
$overallProcessed = [ref]0
if($ShowProgress){ Write-Progress -Id $overallId -Activity "Overall upload" -Status "Starting…" -PercentComplete 0 }

# (A) Site libraries -> Team root site (Graph-resolved)
if($IncludeSiteLibraries -and $siteLibDirs.Count -gt 0){
  Connect-PnP-Interactive $rootSiteUrl
  $webRelRoot = (Get-PnPWeb).ServerRelativeUrl.TrimEnd('/')

  foreach($dir in $siteLibDirs){
    if($dir.Name -notmatch '^Site\s-\s(.+)$'){
      Write-Host "[SKIP] Unbekanntes Site-Ordnerformat: $($dir.FullName)" -ForegroundColor Yellow
      continue
    }
    $libDisplay = $Matches[1].Trim()

    Write-Host ""
    Write-Host "==== UPLOAD (Site) -> $TeamName | Library: $libDisplay ====" -ForegroundColor Cyan

    $libServerRel = $null
    try { $libServerRel = Ensure-DocLibrary $libDisplay } catch {
      Write-Host "[WARN] $($_.Exception.Message)" -ForegroundColor Yellow
      $libServerRel = Get-LibraryServerRelUrl $libDisplay
      if(-not $libServerRel){
        Write-Host "[SKIP] Bibliothek '$libDisplay' nicht verfügbar. Überspringe." -ForegroundColor DarkGray
        continue
      }
    }

    $libRel = $libServerRel.Substring($webRelRoot.Length).TrimStart('/')
    Upload-UnitFiles -localRoot $dir.FullName -baseTargetWebRel $libRel -displayName ("Site - $libDisplay") -overallId $overallId -overallProcessed $overallProcessed -overallTotal $overallTotal
  }
}

# (B) Channels -> respective sites (Graph-resolved)
$currentSiteUrl = $null
foreach($dir in $plannedChannelDirs){
  if($dir.Name -notmatch '^(Standard|Private|Shared)\s-\s(.+)$'){
    Write-Host "[SKIP] Unbekanntes Ordnerformat: $($dir.FullName)" -ForegroundColor Yellow
    continue
  }
  $kind     = $Matches[1]
  $chanName = $Matches[2]

  $chanKey = ($chanMap.Keys | Where-Object { $_ -ieq $chanName } | Select-Object -First 1)
  if(-not $chanKey){
    Write-Host "[WARN] Channel '$chanName' wurde in Graph nicht gefunden. Verwende Root-Site." -ForegroundColor Yellow
  }
  $chanInfo = if($chanKey){ $chanMap[$chanKey] } else { @{ membershipType = 'standard'; webUrl = $null } }

  $siteUrl = if($chanInfo.membershipType -eq 'standard'){ $rootSiteUrl } else { $chanInfo.webUrl }
  if([string]::IsNullOrWhiteSpace($siteUrl)){ $siteUrl = $rootSiteUrl }

  if($siteUrl -ne $currentSiteUrl){
    Connect-PnP-Interactive $siteUrl
    $currentSiteUrl = $siteUrl
  }

  try {
    $docsRoot = Get-DocumentsRootRelUrl
  } catch {
    Write-Host "[FAIL] Documents-Library nicht gefunden auf $siteUrl :: $($_.Exception.Message)" -ForegroundColor Red
    continue
  }

  $webRel = (Get-PnPWeb).ServerRelativeUrl.TrimEnd('/')
  $libRel = $docsRoot.Substring($webRel.Length).TrimStart('/')
  $channelFolder = if($chanName -ieq 'General'){ Resolve-GeneralFolderName $docsRoot } else { $chanName }
  $targetWebRel = "$libRel/$channelFolder" -replace '^/', ''

  Write-Host ""
  Write-Host "==== UPLOAD -> $TeamName | $kind | $chanName ====" -ForegroundColor Cyan
  Upload-UnitFiles -localRoot $dir.FullName -baseTargetWebRel $targetWebRel -displayName ("$kind - $chanName") -overallId $overallId -overallProcessed $overallProcessed -overallTotal $overallTotal
}

if($ShowProgress){
  Write-Progress -Id $overallId -Activity "Overall upload" -Completed
}

Write-Host "`nDONE (PnP Import) from $teamPath" -ForegroundColor Green
