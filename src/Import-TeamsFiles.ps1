param(
    [Parameter(Mandatory)][string]$TeamName,      # z.B. MigrationTestTeam
    [Parameter(Mandatory)][string]$SourceRoot,    # z.B. $env:USERPROFILE\Documents\Teams-Migration
    [Parameter(Mandatory)][string]$TenantShort,   # z.B. YOUR-DEST-TENANT
    [Parameter(Mandatory)][string]$AppId          # deine eigene Entra App (delegated)
)

Import-Module PnP.PowerShell -ErrorAction Stop
$ErrorActionPreference = 'Stop'

function Ensure-Dir([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Lokaler Pfad fehlt: $p" }
}

function To-SPSegment([string]$s){
  $x = $s.Trim()
  $x = $x -replace '[^0-9A-Za-z\- _.]',''
  $x = $x -replace '\s+','-'
  $x = $x -replace '-{2,}','-'
  return $x
}

function Connect-PnP-Interactive([string]$siteUrl) {
    $tenantId = "$TenantShort.onmicrosoft.com"
    Write-Host ("[CONNECT] {0}" -f $siteUrl) -ForegroundColor Cyan
    Connect-PnPOnline -Url $siteUrl -ClientId $AppId -Tenant $tenantId -Interactive -ErrorAction Stop
}

function Get-DocumentsRootRelUrl(){
  $candidates = @("Dokumente","Documents","Shared Documents","Freigegebene Dokumente")
  foreach($name in $candidates){
    try {
      $l = Get-PnPList -Identity $name -ErrorAction Stop
      return $l.RootFolder.ServerRelativeUrl.TrimEnd('/')
    } catch {}
  }
  $libs = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden }
  if($libs.Count -eq 1){ return $libs[0].RootFolder.ServerRelativeUrl.TrimEnd('/') }
  $preferred = $libs | Where-Object {
    $_.RootFolder.ServerRelativeUrl -match '/(Shared|Freigegebene|Dokumente)(\b|/)'
  } | Select-Object -First 1
  if($preferred){ return $preferred.RootFolder.ServerRelativeUrl.TrimEnd('/') }

  $listDump = ($libs | Select-Object Title,@{n='Url';e={$_.RootFolder.ServerRelativeUrl}} | Out-String).Trim()
  throw ("Konnte die Dokumentbibliothek nicht zuverlässig ermitteln. Verfügbare Bibliotheken:`n{0}" -f $listDump)
}

function Resolve-GeneralFolderName([string]$docsRoot){
    $genServer = ($docsRoot.Trim('/') + '/General')
    $allServer = ($docsRoot.Trim('/') + '/Allgemein')
    try { Get-PnPFolder -Url $genServer -ErrorAction Stop | Out-Null; return 'General' } catch {}
    try { Get-PnPFolder -Url $allServer -ErrorAction Stop | Out-Null; return 'Allgemein' } catch {}
    return 'General'
}

# -Folder erwartet web-relative Pfade (z. B. "Freigegebene Dokumente/General") – keine "/sites/..."
# Quelle: Cmdlet-Doku/Beispiele zu Add-PnPFile/Add-PnPFolder
function Ensure-PnPFolderPath([string]$webRelFolder){
  $webRel = (Get-PnPWeb).ServerRelativeUrl.TrimEnd('/')   # "/sites/<Site>"
  $parts = $webRelFolder -split '/'
  $accum = ""

  foreach($p in $parts){
    if([string]::IsNullOrWhiteSpace($p)){ continue }
    $accum = ($accum ? "$accum/$p" : $p)                  # web-relativ
    $serverCheck = ($webRel + '/' + $accum)               # server-relativ für Get-PnPFolder
    try { Get-PnPFolder -Url $serverCheck -ErrorAction Stop | Out-Null }
    catch {
      $parent = ($accum.Contains('/') ? $accum.Substring(0, $accum.LastIndexOf('/')) : "")
      try {
        Add-PnPFolder -Folder $parent -Name $p -ErrorAction Stop | Out-Null
      } catch {
        Write-Host ("[WARN] Ordner konnte nicht angelegt werden: {0}/{1} :: {2}" -f $parent, $p, $_.Exception.Message) -ForegroundColor DarkYellow
      }
    }
  }
}

function Upload-FilePnP([string]$localFile, [string]$targetWebRel){
  $fileName = [IO.Path]::GetFileName($localFile)
  $webRel   = (Get-PnPWeb).ServerRelativeUrl.TrimEnd('/')         # "/sites/<Site>"
  $serverRel = ($webRel + '/' + ($targetWebRel.Trim('/') + '/' + $fileName))

  # Existenz prüfen -> skip
  $exists = $false
  try { Get-PnPFile -Url $serverRel -ErrorAction Stop | Out-Null; $exists = $true } catch {}
  if($exists){
    Write-Host ("SKIP  {0} (exists)" -f $localFile) -ForegroundColor Yellow
    return
  }

  try{
    Add-PnPFile -Path $localFile -Folder $targetWebRel -ErrorAction Stop | Out-Null
    Write-Host ("PUT   {0} -> {1}" -f $localFile, $targetWebRel) -ForegroundColor Green
  } catch {
    Write-Host ("[FAIL] {0} -> {1} :: {2}" -f $localFile, $targetWebRel, $_.Exception.Message) -ForegroundColor Red
  }
}

function Upload-FolderPnP([string]$localFolder, [string]$targetWebRel){
  Ensure-PnPFolderPath -webRelFolder $targetWebRel
  Get-ChildItem -LiteralPath $localFolder -Directory | ForEach-Object {
    Upload-FolderPnP -localFolder $_.FullName -targetWebRel "$targetWebRel/$($_.Name)"
  }
  Get-ChildItem -LiteralPath $localFolder -File | ForEach-Object {
    Upload-FilePnP -localFile $_.FullName -targetWebRel $targetWebRel
  }
}

# ===== Main ===================================================================

$teamPath   = Join-Path $SourceRoot $TeamName
Ensure-Dir $teamPath

$teamSeg    = To-SPSegment $TeamName
$tenantFqdn = "$TenantShort.sharepoint.com"

Get-ChildItem -LiteralPath $teamPath -Directory | ForEach-Object {
  if($_.Name -notmatch '^(Standard|Private|Shared)\s-\s(.+)$'){
    Write-Host ("[SKIP] Unbekanntes Ordnerformat: {0}" -f $_.FullName) -ForegroundColor Yellow
    return
  }
  $kind     = $Matches[1]
  $chanName = $Matches[2]
  $chanSeg  = To-SPSegment $chanName

  # Site-URL
  if($kind -eq 'Standard'){
    $siteUrl = "https://$tenantFqdn/sites/$teamSeg"
    $channelFolder = if($chanName -ieq 'General'){ '__GENERAL_PLACEHOLDER__' } else { $chanName }
  } else {
    $siteUrl = "https://$tenantFqdn/sites/$teamSeg-$chanSeg"
    $channelFolder = $chanName
  }

  try {
    Connect-PnP-Interactive -siteUrl $siteUrl
  } catch {
    Write-Host ("[FAIL] Connect {0} :: {1}" -f $siteUrl, $_.Exception.Message) -ForegroundColor Red
    return
  }

  # DocLib (serverrelativ) + Web-relativer Library-Pfad
  try {
    $docsRoot = Get-DocumentsRootRelUrl
  } catch {
    Write-Host ("[FAIL] Documents-Library nicht gefunden auf {0} :: {1}" -f $siteUrl, $_.Exception.Message) -ForegroundColor Red
    return
  }
  $webRel = (Get-PnPWeb).ServerRelativeUrl.TrimEnd('/')
  $libRel = $docsRoot.Substring($webRel.Length).TrimStart('/')

  # "General"/"Allgemein" auflösen
  if($channelFolder -eq '__GENERAL_PLACEHOLDER__'){
    $channelFolder = Resolve-GeneralFolderName -docsRoot $docsRoot
  }

  # Ziel **web-relativ**
  $targetWebRel = ($libRel.Trim('/') + '/' + $channelFolder) -replace '^/',''
  Write-Host ("==== UPLOAD -> {0} | {1} | {2} ====" -f $TeamName, $kind, $chanName) -ForegroundColor Cyan
  Upload-FolderPnP -localFolder $_.FullName -targetWebRel $targetWebRel
}

Write-Host ("`nDONE (PnP Import) from {0}" -f $teamPath) -ForegroundColor Green