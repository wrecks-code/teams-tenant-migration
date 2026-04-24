<#
.SYNOPSIS
  Orchestriert Teams-Migration: Export (Blueprint, Files) -> Import (Blueprint, Files)
#>

[CmdletBinding()]
param(
  [string]$DefaultExportRoot = "$env:USERPROFILE\Documents\Teams-Migration",
  [string]$DefaultSourceTenantShort = "YOUR-SOURCE-TENANT",
  [string]$DefaultDestTenantShort   = "YOUR-DEST-TENANT",
  [string]$DefaultSourceAppId = "00000000-0000-0000-0000-000000000001",
  [string]$DefaultDestAppId   = "00000000-0000-0000-0000-000000000002"
)

#region UI helpers
function Write-Section($Text){ Write-Host ("".PadLeft(80,"─")) -ForegroundColor DarkGray; Write-Host ("§ {0}" -f $Text) -ForegroundColor Cyan }
function Write-Step($Text){ Write-Host ("→ {0}" -f $Text) -ForegroundColor Yellow }
function Write-Ok($Text){  Write-Host ("✔ {0}" -f $Text) -ForegroundColor Green }
function Write-Err($Text){ Write-Host ("✘ {0}" -f $Text) -ForegroundColor Red }
function Pause-IfError($Err){ if($Err){ Write-Err $Err; Read-Host "Press ENTER to continue (or Ctrl+C to abort)" | Out-Null } }
#endregion

#region utils
function Join-PathSafe([string]$a,[string]$b){ [System.IO.Path]::GetFullPath((Join-Path $a $b)) }
function Ensure-Dir([string]$p){ if(-not (Test-Path -LiteralPath $p)){ New-Item -Type Directory -Path $p | Out-Null } }

# Param-Synonyme → echte Keys des Zielskripts
$GLOBAL:ParamSynonyms = @{
  'TeamName'   = @('Team','Group','GroupName','TeamName')
  'Team'       = @('Team','Group','GroupName','TeamName')
  'Group'      = @('Group','Team','GroupName','TeamName')

  'TenantShort'= @('TenantShort','Tenant','TenantName','TenantDomain','TenantId')
  'Tenant'     = @('Tenant','TenantShort','TenantName','TenantDomain','TenantId')

  'AppId'      = @('AppId','ClientId','ApplicationId')
  'ClientId'   = @('ClientId','AppId','ApplicationId')

  # Export-Ziel
  'DestRoot'   = @('DestRoot','OutDir','OutputDir','ExportRoot','ExportDir','Path','Destination','DestinationPath')
  'OutDir'     = @('OutDir','OutputDir','ExportRoot','ExportDir','DestRoot','Path')

  # Import-Quelle
  'SourceRoot' = @('SourceRoot','InDir','InputDir','ImportRoot','ImportDir','Path')
  'InDir'      = @('InDir','InputDir','SourceRoot','ImportRoot','ImportDir','Path')

  # generisch
  'Path'       = @('Path','OutDir','InDir')
}

function Get-ScriptParams([string]$ScriptPath){
  try{
    $cmd = Get-Command -ErrorAction Stop -CommandType ExternalScript -Name $ScriptPath
    return @($cmd.Parameters.Keys)
  } catch {
    return @()
  }
}

function Map-Params([string]$ScriptPath, [hashtable]$Input){
  $allowed = Get-ScriptParams $ScriptPath
  $allowedCI = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $null = $allowed | ForEach-Object { $allowedCI.Add($_) } | Out-Null

  $mapped = @{}
  $logs = @()

  foreach($k in $Input.Keys){
    $v = $Input[$k]
    if($null -eq $v -or $v -eq ''){ continue }

    if($allowedCI.Contains($k)){
      $mapped[$k] = $v
      $logs += ("  = {0} -> {0}" -f $k)
      continue
    }

    $cands = $GLOBAL:ParamSynonyms[$k]; if(-not $cands){ $cands = @($k) }
    $applied = $false
    foreach($cand in $cands){
      if($allowedCI.Contains($cand)){
        $mapped[$cand] = $v
        $logs += ("  ≈ {0} -> {1}" -f $k,$cand)
        $applied = $true; break
      }
    }
    if(-not $applied){ $logs += ("  x {0} verworfen (unbekannt)" -f $k) }
  }

  # Duplikate sinnvoll auffüllen
  if($mapped.ContainsKey('DestRoot')){
    if($allowedCI.Contains('OutDir') -and -not $mapped.ContainsKey('OutDir')){ $mapped['OutDir'] = $mapped['DestRoot']; $logs += "  + DestRoot gespiegelt nach OutDir" }
    if($allowedCI.Contains('ExportRoot') -and -not $mapped.ContainsKey('ExportRoot')){ $mapped['ExportRoot'] = $mapped['DestRoot']; $logs += "  + DestRoot gespiegelt nach ExportRoot" }
  }
  if($mapped.ContainsKey('SourceRoot')){
    if($allowedCI.Contains('InDir') -and -not $mapped.ContainsKey('InDir')){ $mapped['InDir'] = $mapped['SourceRoot']; $logs += "  + SourceRoot gespiegelt nach InDir" }
    if($allowedCI.Contains('ImportRoot') -and -not $mapped.ContainsKey('ImportRoot')){ $mapped['ImportRoot'] = $mapped['SourceRoot']; $logs += "  + SourceRoot gespiegelt nach ImportRoot" }
  }

  [PSCustomObject]@{ Params = $mapped; Log = $logs }
}

function Show-ParamPreview([hashtable]$sp){
  if(-not $sp -or $sp.Count -eq 0){ return "(no params)" }
  $sp.GetEnumerator() | Sort-Object Key | ForEach-Object {
    $v = $_.Value; if($v -is [string]){ $v = $v -replace '"','\"' }
    "-$($_.Key) `"$v`""
  } | Out-String
}

function Invoke-ScriptSafe([string]$ScriptName, [hashtable]$Params){
  $path = Join-Path $PSScriptRoot $ScriptName
  if(-not (Test-Path -LiteralPath $path)){
    throw "Skript nicht gefunden: $ScriptName (erwartet im gleichen Ordner wie dieses Orchestrator-Skript)"
  }

  $m = Map-Params -ScriptPath $path -Input $Params
  $sp = [hashtable]$m.Params   # <- explizit Hashtable-Variable
  $preview = (Show-ParamPreview $sp).Trim()

  Write-Step ("{0}`n    with: {1}" -f $ScriptName, $preview)
  if($m.Log.Count){ Write-Host ("    map:`n{0}" -f ($m.Log -join "`n")) -ForegroundColor DarkGray }

  & $path @sp                  # <- korrektes Splatting (Variable, nicht Property)
  if($LASTEXITCODE -ne 0){ throw "$ScriptName meldete ExitCode $LASTEXITCODE" }
}


function Try-ConnectMgGraph([string]$TenantShort,[string[]]$Scopes){
  if(-not (Get-Module -ListAvailable Microsoft.Graph.Authentication -ErrorAction SilentlyContinue)){ 
    Write-Host "(Microsoft.Graph Modul nicht gefunden – Überspringe Komfort-Auth.)" -ForegroundColor DarkGray; return
  }
  $domain = "$TenantShort.onmicrosoft.com"
  try{
    Write-Step ("Connect-MgGraph → {0}" -f $domain)
    Connect-MgGraph -TenantId $domain -Scopes $Scopes -NoWelcome
    $ctx = Get-MgContext; if($ctx){ Write-Ok ("Graph verbunden: {0}" -f $ctx.Tenant) }
  } catch { Write-Host "(Graph-Auth fehlgeschlagen – Einzelskripte fragen ggf. interaktiv.)" -ForegroundColor DarkGray }
}
#endregion

# ========= Eingaben =========
Write-Section "Input sammeln"
$teamName = Read-Host "Team/Group DisplayName (z.B. '00159-BP Rheintalautobahn')"
if([string]::IsNullOrWhiteSpace($teamName)){ throw "TeamName darf nicht leer sein." }

$exportRoot = Read-Host ("Export-Root (ENTER = {0})" -f $DefaultExportRoot); if([string]::IsNullOrWhiteSpace($exportRoot)){ $exportRoot = $DefaultExportRoot }
$sourceTenant = Read-Host ("Source Tenant short (ENTER = {0})" -f $DefaultSourceTenantShort); if([string]::IsNullOrWhiteSpace($sourceTenant)){ $sourceTenant = $DefaultSourceTenantShort }
$destTenant   = Read-Host ("Destination Tenant short (ENTER = {0})" -f $DefaultDestTenantShort); if([string]::IsNullOrWhiteSpace($destTenant)){ $destTenant = $DefaultDestTenantShort }
$sourceAppId  = Read-Host ("Source AppId (ENTER = {0})" -f $DefaultSourceAppId); if([string]::IsNullOrWhiteSpace($sourceAppId)){ $sourceAppId = $DefaultSourceAppId }
$destAppId    = Read-Host ("Destination AppId (ENTER = {0})" -f $DefaultDestAppId); if([string]::IsNullOrWhiteSpace($destAppId)){ $destAppId = $DefaultDestAppId }

$teamFolder = Join-PathSafe $exportRoot $teamName; Ensure-Dir $teamFolder

# ========= Export =========
Write-Host ""
Write-Section "1) OPTIONAL: Auth im SOURCE-Tenant (Graph)"
Try-ConnectMgGraph -TenantShort $sourceTenant -Scopes @("Group.Read.All","Files.Read.All","Sites.Read.All","User.Read")

Write-Section "2) EXPORT – Blueprint"
try{
  Invoke-ScriptSafe "Export-TeamsBlueprint.ps1" @{
    TeamName     = $teamName
    TenantShort  = $sourceTenant
    AppId        = $sourceAppId
    DestRoot     = $exportRoot
    OutDir       = $teamFolder
  }
  Write-Ok "Blueprint exportiert."
} catch { Write-Err $_.Exception.Message; Pause-IfError $_.Exception.Message }

Write-Section "3) EXPORT – Files"
try{
  Invoke-ScriptSafe "Export-TeamsFiles.ps1" @{
    TeamName     = $teamName
    TenantShort  = $sourceTenant
    AppId        = $sourceAppId
    DestRoot     = $exportRoot
    OutDir       = $teamFolder
  }
  Write-Ok "Files exportiert."
} catch { Write-Err $_.Exception.Message; Pause-IfError $_.Exception.Message }

# ========= Import =========
Write-Host ""
Write-Section "4) OPTIONAL: Auth im DESTINATION-Tenant (Graph)"
try{ if(Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue){ Disconnect-MgGraph -ErrorAction SilentlyContinue } } catch {}
Try-ConnectMgGraph -TenantShort $destTenant -Scopes @("Group.ReadWrite.All","Files.ReadWrite.All","Sites.ReadWrite.All","User.Read")

Write-Section "5) IMPORT – Team Blueprint"
try{
  Invoke-ScriptSafe "Import-TeamsBlueprint.ps1" @{
    TeamName     = $teamName
    TenantShort  = $destTenant
    AppId        = $destAppId
    SourceRoot   = $exportRoot
    InDir        = $teamFolder
  }
  Write-Ok "Team (Blueprint) angelegt/konfiguriert."
} catch { Write-Err $_.Exception.Message; Pause-IfError $_.Exception.Message }

Write-Section "6) IMPORT – Files (PnP, interaktiv erlaubt)"
try{
  Invoke-ScriptSafe "Import-TeamsFiles.ps1" @{
    TeamName    = $teamName
    SourceRoot  = $exportRoot
    TenantShort = $destTenant
    AppId       = $destAppId
  }
  Write-Ok "Files importiert."
} catch { Write-Err $_.Exception.Message; Pause-IfError $_.Exception.Message }

Write-Section "Fertig"
Write-Ok ("Migration für '{0}' durchgelaufen." -f $teamName)
Write-Host ("Export-Ordner: {0}" -f $teamFolder) -ForegroundColor DarkGray
