<#
 diagnose.ps1 - read-only start diagnostics for the VPS workshop kit (Windows branch).
 Kit 0.2.0-preview.
 ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
 It never changes the system, network, VPN, SSH, keys or settings. It writes only under <kit>\state\.

 Usage:
   powershell -NoProfile -File tools\diagnose.ps1
   powershell -NoProfile -File tools\diagnose.ps1 -Answer vpn=on
   powershell -NoProfile -File tools\diagnose.ps1 -Accept 4 -Source ssh-whoami -Evidence L
   powershell -NoProfile -File tools\diagnose.ps1 -Reset 4
   powershell -NoProfile -File tools\diagnose.ps1 -Claim 4 -Source project-status   (a claim from existing project documents: NOT a PASS)
   powershell -NoProfile -File tools\diagnose.ps1 -Report      (safe summary to paste into a problem report)
   powershell -NoProfile -File tools\diagnose.ps1 -Fact KEY_LOGIN=PASS -Source agent-whoami -Evidence L   (one finer fact; see tools\README.md)
   powershell -NoProfile -File tools\diagnose.ps1 -NewServer -Source owner-message   (a NEW server: new generation, old server facts do not carry over)
   powershell -NoProfile -File tools\diagnose.ps1 -Migrate    (idempotent state migration to schema 2; also done on a normal run)
   powershell -NoProfile -File tools\diagnose.ps1 -Summary    (five separate results: workspace, app, reconnect, security, training)

#>
[CmdletBinding()]
param(
  [string[]]$Answer = @(),
  [int]$Accept = 0,
  [string]$Source = '',
  [string]$Evidence = '',
  [string]$Note = '',
  [int]$Reset = 0,
  [int]$Claim = 0,
  [string[]]$Fact = @(),
  [switch]$NewServer,
  [switch]$Migrate,
  [switch]$Summary,
  [switch]$Report
)

$ErrorActionPreference = 'Continue'
$KitVersion = '0.2.0-preview'
$KitRoot  = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $KitRoot 'state'
$TelDir   = Join-Path $StateDir 'telemetry'
$FDiag    = Join-Path $StateDir 'diagnostics.tsv'
$FStages  = Join-Path $StateDir 'stages.tsv'
$FAnswers = Join-Path $StateDir 'answers.tsv'
$FEvents  = Join-Path $TelDir 'events.jsonl'
$FMeta    = Join-Path $StateDir 'meta.tsv'
$FFacts   = Join-Path $StateDir 'facts.tsv'
$FHist    = Join-Path $StateDir 'history.tsv'
$FOffer   = Join-Path $KitRoot 'config\neurolab-offer.json'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Tab = "`t"
$StageCount = 12

function NowUtc { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Fail([string]$msg, [int]$code) { [Console]::Error.WriteLine('ERROR ' + $msg); exit $code }
function Clean([string]$s, [int]$max) {
  if ($null -eq $s) { return '' }
  $t = ($s -replace '[\t\r\n]', ' ').Trim()
  if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }
  return $t
}

function Read-Lines([string]$path) {
  if (Test-Path -LiteralPath $path) { return [System.IO.File]::ReadAllLines($path, $Utf8) }
  return @()
}
function Write-Lines([string]$path, [string[]]$lines) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllLines($path, $lines, $Utf8)
}
function Append-Line([string]$path, [string]$line) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::AppendAllText($path, $line + "`n", $Utf8)
}

# ---------- state: stages ----------
function Load-Stages {
  $h = @{}
  foreach ($l in (Read-Lines $FStages)) {
    if ($l.Trim().Length -eq 0) { continue }
    $p = $l -split "`t"
    if ($p.Count -ge 6) { $h[[int]$p[0]] = $p }
  }
  for ($i = 1; $i -le $StageCount; $i++) {
    if (-not $h.ContainsKey($i)) { $h[$i] = @("$i", 'NOT_RUN', '?', 'none', '-', 'init') }
  }
  return $h
}
function Save-Stages($h) {
  $out = @()
  for ($i = 1; $i -le $StageCount; $i++) { $out += ($h[$i] -join $Tab) }
  Write-Lines $FStages $out
}
function Set-Stage($h, [int]$n, [string]$status, [string]$label, [string]$src, [string]$note) {
  $h[$n] = @("$n", $status, $label, $src, (NowUtc), $note)
}

# ---------- state: answers (human-provided, whitelisted values only) ----------
$AllowedAnswers = @{
  'vpn'                 = @('on', 'off', 'unknown');
  'claude_permission'   = @('manual', 'other', 'bypass', 'none', 'unknown');
  'codex_confirmations' = @('default', 'other', 'bypass', 'none', 'unknown');
  'workspace_selected'  = @('yes', 'no');
  'map_ready'           = @('yes', 'no');
  'project_link'        = @('parent', 'standalone');
  'neurolab_offer'      = @('shown', 'declined', 'interested', 'already_member');
  'neurolab_member'     = @('yes', 'no', 'unknown');
  'entry_mode'          = @('gpt_guide', 'vscode_direct');
  'server_state'        = @('none', 'existing_active', 'replaced', 'unknown');
  'purchase_profile'    = @('base', 'recommended', 'existing', 'undecided');
  'engine_mode'         = @('claude_only', 'codex_only', 'both', 'undecided');
  'exec_place'          = @('laptop_windows', 'laptop_macos', 'remote_linux', 'local_linux', 'wsl', 'unknown');
  'account_state'       = @('new', 'existing', 'unknown');
  'region_state'        = @('available', 'unavailable', 'unknown');
  'panel_access'        = @('ok', 'unreachable_via_vpn', 'other');
  'cheat_sheet_local'   = @('yes', 'no');
  'admin_sudo_actor'    = @('working_ssh_user', 'other_account', 'untested');
  'admin_sudo_result'   = @('ok', 'auth_failed', 'no_sudo_rights', 'no_interactive_input', 'agent_context_unavailable', 'other', 'untested');
  'admin_candidate'     = @('none', 'current_user_in_sudo_group', 'other_account_in_sudo_group', 'unknown');
  'admin_context'       = @('human_terminal', 'agent_channel', 'none')
}
$ServerAnswers = @('server_state', 'purchase_profile', 'region_state', 'panel_access', 'account_state', 'admin_sudo_actor', 'admin_sudo_result', 'admin_candidate', 'admin_context')
function Load-Answers {
  $h = @{}
  foreach ($l in (Read-Lines $FAnswers)) {
    $p = $l -split "`t"
    if ($p.Count -ge 2) { $h[$p[0]] = $p[1] }
  }
  return $h
}
function Save-Answers($h) {
  $out = @()
  foreach ($k in ($h.Keys | Sort-Object)) { $out += ($k + $Tab + $h[$k] + $Tab + (NowUtc)) }
  Write-Lines $FAnswers $out
}


# ---------- state schema 2: finer facts, server generation ----------
# facts.tsv: fact, status, label, source, date, generation.  meta.tsv: schema, target_id, generation, created, migrated_from.
$FactNames = @('SERVER_PURCHASED', 'SERVER_ACTIVE', 'HOST_IDENTITY', 'KEY_READY', 'KEY_INSTALLED', 'KEY_LOGIN', 'PREFLIGHT', 'ADMIN_READY', 'UFW', 'SSH_HARDENING',
               'ENGINE_READY', 'TEAM_LOADED', 'QA', 'APP_BROWSER', 'RECONNECT',
               'TRAIN_REMOTE_WINDOW', 'TRAIN_OPEN_PROJECT', 'TRAIN_NEW_PROJECT', 'TRAIN_SESSION', 'TRAIN_TASK', 'TRAIN_PORTS', 'TRAIN_DISK', 'TRAIN_RESUME', 'TRAINING')
$TrainNames = @('TRAIN_REMOTE_WINDOW', 'TRAIN_OPEN_PROJECT', 'TRAIN_NEW_PROJECT', 'TRAIN_SESSION', 'TRAIN_TASK', 'TRAIN_PORTS', 'TRAIN_DISK', 'TRAIN_RESUME')
$FactStatuses = @('PASS', 'OPEN', 'BLOCKED', 'NOT_RUN', 'UNVERIFIED', 'ACCEPTED_RISK', 'SKIPPED')
$LocalEvidenceFacts = @('KEY_LOGIN', 'ADMIN_READY', 'UFW', 'SSH_HARDENING')
$StageNeeds = @{
  3 = @('SERVER_PURCHASED', 'SERVER_ACTIVE'); 4 = @('HOST_IDENTITY', 'KEY_READY', 'KEY_INSTALLED', 'KEY_LOGIN'); 5 = @('PREFLIGHT');
  6 = @('ADMIN_READY', 'UFW', 'SSH_HARDENING'); 7 = @('ENGINE_READY'); 9 = @('TEAM_LOADED'); 10 = @('QA'); 11 = @('APP_BROWSER'); 12 = @('RECONNECT')
}
$StageToFacts = $StageNeeds
function Load-Facts {
  $h = @{}
  foreach ($l in (Read-Lines $FFacts)) {
    if ($l.Trim().Length -eq 0) { continue }
    $p = $l -split "`t"
    if ($p.Count -ge 6) { $h[$p[0]] = $p }
  }
  return $h
}
function Save-Facts($h) {
  $out = @()
  foreach ($k in $FactNames) { if ($h.ContainsKey($k)) { $out += ($h[$k] -join $Tab) } }
  Write-Lines $FFacts $out
}
function Fact-Status($h, [string]$n) {
  if ($h.ContainsKey($n)) { return $h[$n][1] }
  return 'NOT_RUN'
}
function Fact-Ok($h, [string]$n) {
  $s = Fact-Status $h $n
  if ($s -eq 'PASS') { return $true }
  if ($n -eq 'HOST_IDENTITY' -and $s -eq 'ACCEPTED_RISK') { return $true }
  return $false
}
function Load-Meta {
  $h = @{}
  foreach ($l in (Read-Lines $FMeta)) { $p = $l -split "`t"; if ($p.Count -ge 2) { $h[$p[0]] = $p[1] } }
  return $h
}
function Save-Meta($h) {
  $out = @()
  foreach ($k in @('schema', 'target_id', 'generation', 'created', 'migrated_from')) { if ($h.ContainsKey($k)) { $out += ($k + $Tab + $h[$k]) } }
  Write-Lines $FMeta $out
}
function New-TargetId { return ([guid]::NewGuid().ToString('N')).Substring(0, 8) }
# Creates meta.tsv when absent. Old (schema 1) state is backed up and its PASS stages are mapped to facts. Idempotent.
function Ensure-Meta {
  if (Test-Path -LiteralPath $FMeta) { return $false }
  $had = Test-Path -LiteralPath $FStages
  $m = @{ schema = '2'; target_id = (New-TargetId); generation = '1'; created = (NowUtc); migrated_from = 'none' }
  if ($had) {
    $m['migrated_from'] = 'schema1'
    $bk = Join-Path $StateDir 'backup-schema1'
    if (-not (Test-Path -LiteralPath $bk)) { New-Item -ItemType Directory -Path $bk -Force | Out-Null }
    foreach ($f in @($FStages, $FAnswers)) { if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $bk -Force } }
    $st = Load-Stages
    $facts = Load-Facts
    foreach ($n in $StageToFacts.Keys) {
      if ($st[[int]$n][1] -eq 'PASS') {
        foreach ($fn in $StageToFacts[$n]) {
          if (($LocalEvidenceFacts -contains $fn) -and ($st[[int]$n][2] -notmatch 'L')) { continue }   # a person's word alone is not carried over as a security fact
          if (-not $facts.ContainsKey($fn)) { $facts[$fn] = @($fn, 'PASS', $st[[int]$n][2], 'migrated', (NowUtc), '1') }
        }
      }
    }
    Save-Facts $facts
  }
  Save-Meta $m
  return $true
}
function Is-Persistent([string]$n) { return (($n -eq 'KEY_READY') -or ($TrainNames -contains $n) -or ($n -eq 'TRAINING')) }

function Offer-Config {
  $r = @{ Ready = $false; Reason = 'config_missing' }
  if (-not (Test-Path -LiteralPath $FOffer)) { return $r }
  try {
    $j = [System.IO.File]::ReadAllText($FOffer, $Utf8) | ConvertFrom-Json
    if ($j.cta_enabled -ne $true) { $r.Reason = 'cta_disabled'; return $r }
    if (-not ($j.cta_url -match '^https:[/][/][A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$')) { $r.Reason = 'cta_url_missing_or_not_https'; return $r }
    if (-not $j.cta_label) { $r.Reason = 'cta_label_missing'; return $r }
    $r.Ready = $true; $r.Reason = 'ok'
  } catch { $r.Reason = 'config_unreadable' }
  return $r
}

# ---------- probes ----------
function Get-Fallbacks([string]$name) {
  $r = @()
  if ($name -eq 'code') {
    $la = [Environment]::GetFolderPath('LocalApplicationData')
    if ($la) { $r += (Join-Path $la 'Programs\Microsoft VS Code\bin\code.cmd') }
    $pf = [Environment]::GetFolderPath('ProgramFiles')
    if ($pf) { $r += (Join-Path $pf 'Microsoft VS Code\bin\code.cmd') }
  }
  if ($name -eq 'ssh') {
    $sysd = [Environment]::GetFolderPath('System')
    if ($sysd) { $r += (Join-Path $sysd 'OpenSSH\ssh.exe') }
  }
  return $r
}
function Probe([string]$name, [string[]]$arguments) {
  $res = @{ Status = 'NOT_FOUND'; Lines = @() }
  $path = $null
  $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source) { $path = $cmd.Source }
  else {
    foreach ($c in (Get-Fallbacks $name)) { if (Test-Path -LiteralPath $c) { $path = $c; break } }
  }
  if (-not $path) { return $res }
  try {
    $out = & $path @arguments 2>&1
    $code = $LASTEXITCODE
    $lines = @()
    foreach ($o in $out) { $s = ([string]$o).Trim(); if ($s.Length -gt 0) { $lines += $s } }
    $res.Lines = $lines
    if ($code -eq 0 -and $lines.Count -gt 0) { $res.Status = 'PASS' } else { $res.Status = 'UNKNOWN' }
  } catch {
    $msg = $_.Exception.Message
    if (($_.Exception -is [System.UnauthorizedAccessException]) -or ($msg -match 'denied|not permitted|blocked|0xc0000142')) {
      $res.Status = 'BLOCKED_BY_LOCAL_PERMISSION'
    } else { $res.Status = 'UNKNOWN' }
  }
  return $res
}

# ---------- check bookkeeping ----------
$Checks = New-Object System.Collections.ArrayList
$Questions = New-Object System.Collections.ArrayList
$RunId = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
$RunWatch = [Diagnostics.Stopwatch]::StartNew()
function Add-Check([string]$id, [string]$status, [string]$value, [string]$label, [long]$ms) {
  [void]$Checks.Add(@{ Id = $id; Status = $status; Value = (Clean $value 60); Label = $label; Ms = $ms })
  Write-Host ('CHECK ' + $id + ' ' + $status + ' ' + (Clean $value 60))
}
function Timed([scriptblock]$sb) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = & $sb
  $sw.Stop()
  return @{ R = $r; Ms = [long]$sw.ElapsedMilliseconds }
}
function Ask([string]$key, [string]$text) {
  [void]$Questions.Add($key)
  Write-Host ('QUESTION ' + $key + ' ' + $text)
}
function Get-Status([string]$id) {
  foreach ($c in $Checks) { if ($c.Id -eq $id) { return $c.Status } }
  return 'NOT_RUN'
}

# ---------- subcommands that do not run diagnostics ----------
foreach ($tok in @($Source, $Note)) {
  if ($tok -match '(^|[^0-9])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}($|[^0-9])') { Fail 'source and note must not look like an IP address' 2 }
}
$ctl = $false
if ($Answer.Count -gt 0) {
  $ctl = $true
  $ans = Load-Answers
  foreach ($a in $Answer) {
    $i = $a.IndexOf('=')
    if ($i -lt 1) { Fail "answer must be key=value" 2 }
    $k = $a.Substring(0, $i).Trim().ToLower()
    $v = $a.Substring($i + 1).Trim().ToLower()
    if (-not $AllowedAnswers.ContainsKey($k)) { Fail "answer key not allowed: $k" 2 }
    if ($AllowedAnswers[$k] -notcontains $v) { Fail "answer value not allowed for $k" 2 }
    $ans[$k] = $v
  }
  Save-Answers $ans
  Write-Host 'ANSWERS_SAVED'
}
if ($Accept -ne 0) {
  $ctl = $true
  if ($Accept -lt 1 -or $Accept -gt $StageCount) { Fail "stage must be 1..$StageCount" 2 }
  if ($Source -notmatch '^[A-Za-z0-9_.+-]{1,40}$') { Fail 'PASS needs -Source (evidence source, 1-40 chars of A-Za-z0-9_.+-)' 2 }
  if (@('L', 'U', 'LU') -notcontains $Evidence) { Fail 'PASS needs -Evidence L (checked locally), U (reported by the person) or LU' 2 }
  if ($Note -and $Note -notmatch '^[A-Za-z0-9_.+-]{0,40}$') { Fail 'note must match A-Za-z0-9_.+- (no free text, no secrets)' 2 }
  [void](Ensure-Meta)
  if ($StageNeeds.ContainsKey([int]$Accept)) {
    $facts = Load-Facts
    $miss = @()
    foreach ($fn in $StageNeeds[[int]$Accept]) { if (-not (Fact-Ok $facts $fn)) { $miss += $fn } }
    if ($miss.Count -gt 0) { Fail ('ACCEPT_NEEDS_FACTS stage=' + $Accept + ' missing=' + ($miss -join ',') + ' (record each fact with -Fact NAME=PASS -Source ... -Evidence ...)') 2 }
  }
  $st = Load-Stages
  $noteVal = 'accepted'; if ($Note) { $noteVal = $Note }
  Set-Stage $st $Accept 'PASS' $Evidence $Source $noteVal
  Save-Stages $st
  Write-Host ("STAGE_ACCEPTED " + $Accept)
}
if ($Claim -ne 0) {
  # A claim records that existing project documents SAY a stage is done. It is never a PASS: the stage must still be verified
  # (-Accept with a source and L/U evidence). An already accepted stage is not touched.
  $ctl = $true
  if ($Claim -lt 1 -or $Claim -gt $StageCount) { Fail "stage must be 1..$StageCount" 2 }
  if ($Source -notmatch '^[A-Za-z0-9_.+-]{1,40}$') { Fail 'a claim needs -Source (where it is claimed, 1-40 chars of A-Za-z0-9_.+-)' 2 }
  $st = Load-Stages
  if ($st[$Claim][1] -eq 'PASS') { Write-Host ('CLAIM_IGNORED ' + $Claim + ' (already PASS)') }
  else {
    Set-Stage $st $Claim 'CLAIMED' '?' $Source 'needs_verification'
    Save-Stages $st
    Write-Host ('STAGE_CLAIMED ' + $Claim + ' (not a PASS: verify it, then -Accept)')
  }
}

if ($Fact.Count -gt 0) {
  $ctl = $true
  if ($Source -notmatch '^[A-Za-z0-9_.+-]{1,40}$') { Fail 'a fact needs -Source (evidence source, 1-40 chars of A-Za-z0-9_.+-)' 2 }
  $ev = $Evidence; if (-not $ev) { $ev = '?' }
  if (@('L', 'U', 'LU', '?') -notcontains $ev) { Fail 'evidence must be L, U, LU or ?' 2 }
  [void](Ensure-Meta)
  $gen = (Load-Meta)['generation']
  $facts = Load-Facts
  $todo = @()
  foreach ($f in $Fact) {
    $i = $f.IndexOf('=')
    if ($i -lt 1) { Fail 'fact must be NAME=STATUS' 2 }
    $name = $f.Substring(0, $i).Trim().ToUpper()
    $stt = $f.Substring($i + 1).Trim().ToUpper()
    if ($FactNames -notcontains $name) { Fail ('fact not allowed: ' + $name) 2 }
    if ($FactStatuses -notcontains $stt) { Fail ('fact status not allowed: ' + $stt) 2 }
    if ($name -eq 'TRAINING' -and $stt -eq 'PASS') { Fail 'TRAINING_IS_COMPUTED: training is complete only when all TRAIN_* facts are PASS; a skip is recorded as TRAINING=SKIPPED' 2 }
    if (($stt -eq 'ACCEPTED_RISK' -or $stt -eq 'UNVERIFIED') -and $name -ne 'HOST_IDENTITY') { Fail ($stt + ' is allowed only for HOST_IDENTITY') 2 }
    if ($stt -eq 'SKIPPED' -and -not (($TrainNames -contains $name) -or $name -eq 'TRAINING')) { Fail 'SKIPPED is allowed only for TRAIN_* and TRAINING' 2 }
    if ($stt -eq 'PASS') {
      if ($ev -eq '?') { Fail 'PASS needs -Evidence L, U or LU' 2 }
      if (($LocalEvidenceFacts -contains $name) -and ($ev -eq 'U')) { Fail ($name + ' PASS needs evidence that includes L: a statement of the person alone is not enough') 2 }
      if ($name -eq 'HOST_IDENTITY' -and $ev -eq 'L') { Fail 'HOST_IDENTITY PASS needs the person to confirm the independent comparison (evidence U or LU)' 2 }
    }
    if ($stt -eq 'ACCEPTED_RISK' -and $ev -ne 'U') { Fail 'ACCEPTED_RISK is the owner decision: evidence U' 2 }
    if ($name -eq 'ADMIN_READY' -and $stt -eq 'PASS') {
      $aa = Load-Answers
      if (($aa['admin_context'] -ne 'agent_channel') -or ($aa['admin_sudo_result'] -ne 'ok')) { Fail 'ADMIN_READY PASS needs the answers admin_context=agent_channel and admin_sudo_result=ok, recorded from a real administrative command in the agent channel' 2 }
    }
    $todo += ,@($name, $stt)
  }
  foreach ($t in $todo) { $facts[$t[0]] = @($t[0], $t[1], $ev, $Source, (NowUtc), $gen) }
  Save-Facts $facts
  foreach ($t in $todo) { Write-Host ('FACT_SET ' + $t[0] + ' ' + $t[1]) }
}
if ($NewServer) {
  $ctl = $true
  if ($Source -notmatch '^[A-Za-z0-9_.+-]{1,40}$') { Fail 'a new server needs -Source (why, 1-40 chars of A-Za-z0-9_.+-)' 2 }
  [void](Ensure-Meta)
  $m = Load-Meta
  $oldGen = [int]$m['generation']
  $oldTid = $m['target_id']
  $m['generation'] = [string]($oldGen + 1)
  $m['target_id'] = (New-TargetId)
  Save-Meta $m
  $facts = Load-Facts
  $kept = @{}
  $retired = 0
  foreach ($k in @($facts.Keys)) {
    if (Is-Persistent $k) { $kept[$k] = $facts[$k] }
    else { $retired++; Append-Line $FHist ('fact_retired' + $Tab + $oldGen + $Tab + $oldTid + $Tab + $k + $Tab + $facts[$k][1] + $Tab + (NowUtc)) }
  }
  Save-Facts $kept
  Append-Line $FHist ('generation_retired' + $Tab + $oldGen + $Tab + $oldTid + $Tab + $Source + $Tab + '-' + $Tab + (NowUtc))
  $st = Load-Stages
  for ($i = 3; $i -le $StageCount; $i++) { Set-Stage $st $i 'PENDING' '?' 'new_server' ('generation_' + $m['generation']) }
  Save-Stages $st
  $ans = Load-Answers
  foreach ($k in $ServerAnswers) { if ($ans.ContainsKey($k)) { $ans.Remove($k) } }
  Save-Answers $ans
  Write-Host ('NEW_SERVER generation=' + $m['generation'] + ' retired_facts=' + $retired + ' stages_reset=3..' + $StageCount + ' kept=stages_1_2,interview,map,key_ready,training')
}
if ($Migrate) {
  $ctl = $true
  $did = Ensure-Meta
  if ($did) { Write-Host 'STATE_MIGRATED schema=2' } else { Write-Host 'STATE_ALREADY_CURRENT schema=2' }
}
if ($Reset -ne 0) {
  $ctl = $true
  if ($Reset -lt 1 -or $Reset -gt $StageCount) { Fail "stage must be 1..$StageCount" 2 }
  $st = Load-Stages
  Set-Stage $st $Reset 'PENDING' '?' 'reset' 'reset'
  Save-Stages $st
  Write-Host ("STAGE_RESET " + $Reset)
}
if ($ctl) { exit 0 }


# ---------- summary: five separate results, never one general PASS from partial facts ----------
if ($Summary) {
  [void](Ensure-Meta)
  $st = Load-Stages
  $facts = Load-Facts
  $ans = Load-Answers
  $ws = @(); if ($st[5][1] -ne 'PASS') { $ws += 'STAGE_5' }; if ($st[7][1] -ne 'PASS') { $ws += 'STAGE_7' }
  foreach ($n in @('KEY_LOGIN', 'ENGINE_READY')) { if (-not (Fact-Ok $facts $n)) { $ws += $n } }
  $app = @(); if ($st[11][1] -ne 'PASS') { $app += 'STAGE_11' }; if (-not (Fact-Ok $facts 'APP_BROWSER')) { $app += 'APP_BROWSER' }
  $rec = @(); if ($st[12][1] -ne 'PASS') { $rec += 'STAGE_12' }; if (-not (Fact-Ok $facts 'RECONNECT')) { $rec += 'RECONNECT' }
  $sec = @(); if ($st[6][1] -ne 'PASS') { $sec += 'STAGE_6' }; foreach ($n in @('ADMIN_READY', 'UFW', 'SSH_HARDENING')) { if (-not (Fact-Ok $facts $n)) { $sec += $n } }
  $trPass = 0; foreach ($n in $TrainNames) { if ((Fact-Status $facts $n) -eq 'PASS') { $trPass++ } }
  $trSkipped = ((Fact-Status $facts 'TRAINING') -eq 'SKIPPED')
  $wsOk = ($ws.Count -eq 0); $appOk = ($app.Count -eq 0); $recOk = ($rec.Count -eq 0); $secOk = ($sec.Count -eq 0)
  $trOk = ($trPass -eq $TrainNames.Count)
  if ($wsOk) { Write-Host 'SUMMARY WORKSPACE READY' } else { Write-Host ('SUMMARY WORKSPACE OPEN missing=' + ($ws -join ',')) }
  if ($appOk) { Write-Host 'SUMMARY APP VERIFIED' } else { Write-Host ('SUMMARY APP OPEN missing=' + ($app -join ',')) }
  if ($recOk) { Write-Host 'SUMMARY RECONNECT VERIFIED' } else { Write-Host ('SUMMARY RECONNECT OPEN missing=' + ($rec -join ',')) }
  if ($secOk) { Write-Host 'SUMMARY SECURITY COMPLETE' } else { Write-Host ('SUMMARY SECURITY OPEN missing=' + ($sec -join ',')) }
  # administrator access: a candidate (an account in the sudo group) is never ADMIN_READY; the last sudo outcome is kept apart
  $aRes = 'untested'; if ($ans.ContainsKey('admin_sudo_result')) { $aRes = $ans['admin_sudo_result'] }
  $aAct = 'untested'; if ($ans.ContainsKey('admin_sudo_actor')) { $aAct = $ans['admin_sudo_actor'] }
  $aCan = 'unknown'; if ($ans.ContainsKey('admin_candidate')) { $aCan = $ans['admin_candidate'] }
  $aCtx = 'none'; if ($ans.ContainsKey('admin_context')) { $aCtx = $ans['admin_context'] }
  if (Fact-Ok $facts 'ADMIN_READY') { Write-Host ('SUMMARY ADMIN READY confirmed_in=' + $aCtx) }
  elseif (($aCan -eq 'current_user_in_sudo_group') -or ($aCan -eq 'other_account_in_sudo_group')) { Write-Host ('SUMMARY ADMIN CANDIDATE_ONLY candidate=' + $aCan + ' last_sudo_actor=' + $aAct + ' last_sudo_result=' + $aRes + ' (not confirmed administrative access)') }
  else { Write-Host ('SUMMARY ADMIN NOT_PROVEN candidate=' + $aCan + ' last_sudo_actor=' + $aAct + ' last_sudo_result=' + $aRes) }
  if ($trOk) { Write-Host 'SUMMARY TRAINING COMPLETE' }
  elseif ($trSkipped) { Write-Host ('SUMMARY TRAINING SKIPPED done=' + $trPass + '/' + $TrainNames.Count) }
  else { Write-Host ('SUMMARY TRAINING OPEN done=' + $trPass + '/' + $TrainNames.Count) }
  $hid = Fact-Status $facts 'HOST_IDENTITY'
  if ($hid -ne 'PASS') { Write-Host ('SUMMARY NOTE host_identity=' + $hid + ' (not independently verified)') }
  if ($wsOk -and $appOk -and $recOk -and $secOk -and $trOk -and ($hid -eq 'PASS')) { Write-Host 'SUMMARY OVERALL FULL_PASS' } else { Write-Host 'SUMMARY OVERALL PARTIAL' }
  # the optional Neuro-lab offer: after the result and the training decision, independent of security; shown once
  if ($ans.ContainsKey('neurolab_offer')) { Write-Host ('SUMMARY OFFER not_eligible reason=already_' + $ans['neurolab_offer']) }
  elseif ($appOk -and $recOk -and ($trOk -or $trSkipped)) {
    $br = 'ask_member'
    if ($ans.ContainsKey('neurolab_member')) { if ($ans['neurolab_member'] -eq 'yes') { $br = 'resident' } elseif ($ans['neurolab_member'] -eq 'no') { $br = 'new' } }
    $oc = Offer-Config
    $cta = 'hidden'; if ($oc.Ready) { $cta = 'ready' }
    Write-Host ('SUMMARY OFFER eligible branch=' + $br + ' cta=' + $cta + ' (' + $oc.Reason + ')')
  } else { Write-Host 'SUMMARY OFFER not_eligible reason=result_or_training_not_done' }
  Write-Host ('SUMMARY GENERATION ' + (Load-Meta)['generation'])
  exit 0
}

# ---------- safe report: kit version, OS label, stage table, check ids/statuses; no paths, addresses, names ----------
if ($Report) {
  $osv = ''
  foreach ($l in (Read-Lines $FDiag)) { $p = $l -split "`t"; if ($p[0] -eq 'os') { $osv = $p[2] } }
  Write-Host ('REPORT kit=' + $KitVersion + ' os=' + $osv)
  foreach ($l in (Read-Lines $FStages)) { if ($l.Trim().Length -gt 0) { Write-Host ('REPORT_STAGE ' + ($l -replace "`t", ' ')) } }
  foreach ($l in (Read-Lines $FFacts)) { if ($l.Trim().Length -gt 0) { Write-Host ('REPORT_FACT ' + ($l -replace "`t", ' ')) } }
  $rm = Load-Meta
  if ($rm.ContainsKey('generation')) { Write-Host ('REPORT_GENERATION ' + $rm['generation']) }
  foreach ($l in (Read-Lines $FDiag)) { $p = $l -split "`t"; if ($p.Count -ge 3) { Write-Host ('REPORT_CHECK ' + $p[0] + ' ' + $p[1] + ' ' + $p[2]) } }
  Write-Host 'REPORT_END (add: stage number, what you saw in your own words WITHOUT passwords, keys, IP addresses, user names, paths)'
  exit 0
}

# ---------- diagnostics ----------
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$hadStages = Test-Path -LiteralPath $FStages
$migratedNow = Ensure-Meta
if ($migratedNow -and $hadStages) { Write-Host 'STATE_MIGRATED schema=2 (backup in state\backup-schema1)' }
$answers = Load-Answers
Append-Line $FEvents ('{"v":1,"ts":"' + (NowUtc) + '","run":"' + $RunId + '","ev":"run_start","exec_ms":null,"wait_ms":null}')

# kit identity
$t = Timed {
  $ver = ''
  $vf = Join-Path $KitRoot 'VERSION'
  if (Test-Path -LiteralPath $vf) { $ver = ([System.IO.File]::ReadAllText($vf, $Utf8)).Trim() }
  $mf = Join-Path $KitRoot 'MANIFEST.sha256'
  if (-not (Test-Path -LiteralPath $mf)) { return @('UNKNOWN', ("version " + $ver + "; manifest not found")) }
  $total = 0; $missing = 0; $changed = 0
  foreach ($l in (Read-Lines $mf)) {
    if ($l.Trim().Length -eq 0) { continue }
    $hash = $l.Substring(0, 64).ToLower()
    $rel = $l.Substring(66)
    $total++
    $full = Join-Path $KitRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { $missing++; continue }
    $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $hash) { $changed++ }
  }
  if ($ver -ne $KitVersion) { return @('FAIL', ("version " + $ver + " != script " + $KitVersion)) }
  if ($missing -eq 0 -and $changed -eq 0) { return @('PASS', ("version " + $ver + "; " + $total + " files match manifest")) }
  return @('FAIL', ("version " + $ver + "; missing=" + $missing + " changed=" + $changed))
}
Add-Check 'kit' $t.R[0] $t.R[1] 'L' $t.Ms

# os
$t = Timed {
  if ([Environment]::OSVersion.Platform -eq 'Win32NT') { return @('PASS', ('windows-' + [Environment]::OSVersion.Version.ToString())) }
  return @('UNKNOWN', 'not-windows; use tools/diagnose.sh')
}
Add-Check 'os' $t.R[0] $t.R[1] 'L' $t.Ms

# place of execution: host OS, shell and the VPS are different things
if ([Environment]::OSVersion.Platform -eq 'Win32NT') { Add-Check 'exec_place' 'PASS' 'laptop_windows' 'L' 0 }
else { Add-Check 'exec_place' 'UNKNOWN' 'not-windows' '?' 0 }

# VS Code and extensions
$t = Timed { Probe 'code' @('--version') }
$codeStatus = $t.R.Status
if ($codeStatus -eq 'PASS') {
  $vline = 'unparsed'
  foreach ($vl in $t.R.Lines) { if ($vl -match '^[0-9]+\.[0-9]+(\.[0-9]+)?$') { $vline = $vl; break } }
  Add-Check 'vscode' 'PASS' ('version ' + $vline) 'L' $t.Ms
}
elseif ($codeStatus -eq 'NOT_FOUND') {
  Add-Check 'vscode' 'UNKNOWN' 'code command not on PATH' '?' $t.Ms
  Ask 'vscode_installed' 'VS Code may be installed without the code command; ask the participant to open VS Code and use Help > About (read the version aloud).'
} else { Add-Check 'vscode' $codeStatus 'code command did not run' 'L' $t.Ms }

$extIds = @(
  @('ext_remote_ssh', 'ms-vscode-remote.remote-ssh'),
  @('ext_claude', 'anthropic.claude-code'),
  @('ext_codex', 'openai.chatgpt')
)
if ($codeStatus -eq 'PASS') {
  $t = Timed { Probe 'code' @('--list-extensions', '--show-versions') }
  if ($t.R.Status -eq 'PASS') {
    foreach ($e in $extIds) {
      $found = ''
      foreach ($l in $t.R.Lines) { if ($l.ToLower().StartsWith($e[1] + '@')) { $found = $l.Substring($e[1].Length + 1) } }
      if ($found) { Add-Check $e[0] 'PASS' ('local version ' + $found) 'L' $t.Ms }
      else { Add-Check $e[0] 'NOT_FOUND' 'not installed locally' 'L' $t.Ms }
    }
  } else { foreach ($e in $extIds) { Add-Check $e[0] $t.R.Status 'extension list not read' 'L' $t.Ms } }
} else { foreach ($e in $extIds) { Add-Check $e[0] 'NOT_RUN' 'VS Code CLI not available' '?' 0 } }

# SSH client
$t = Timed { Probe 'ssh' @('-V') }
if ($t.R.Status -eq 'PASS') { Add-Check 'ssh_client' 'PASS' (Clean $t.R.Lines[0] 40) 'L' $t.Ms }
elseif ($t.R.Status -eq 'NOT_FOUND') { Add-Check 'ssh_client' 'NOT_FOUND' 'ssh not found' 'L' $t.Ms }
else { Add-Check 'ssh_client' $t.R.Status 'ssh did not run' 'L' $t.Ms }

# previous state, map, workspace
$prevPass = 0
foreach ($kv in (Load-Stages).GetEnumerator()) { if ($kv.Value[1] -eq 'PASS') { $prevPass++ } }
if ($hadStages) { Add-Check 'prev_state' 'PASS' ('previous state found; stages PASS=' + $prevPass) 'L' 0 }
else { Add-Check 'prev_state' 'NOT_FOUND' 'no previous run' 'L' 0 }
if (Test-Path -LiteralPath (Join-Path $StateDir 'map.md')) { Add-Check 'map' 'PASS' 'state/map.md present' 'L' 0 }
else { Add-Check 'map' 'NOT_FOUND' 'no state/map.md' 'L' 0 }
if ($answers.ContainsKey('workspace_selected')) { Add-Check 'workspace' 'PASS' ('selected=' + $answers['workspace_selected']) 'U' 0 }
else { Add-Check 'workspace' 'UNKNOWN' 'not asked' '?' 0; Ask 'workspace_selected' 'Is a working folder already chosen and open in VS Code? (yes/no)' }

# facts the script cannot see: ask, never guess
if ($answers.ContainsKey('vpn')) { Add-Check 'vpn' 'PASS' ('reported ' + $answers['vpn']) 'U' 0 }
else { Add-Check 'vpn' 'UNKNOWN' 'not detectable by script' '?' 0; Ask 'vpn' 'Is the VPN on right now? (on/off/unknown)' }
foreach ($pm in @(@('perm_claude', 'claude_permission', 'Claude permission mode before admin operations (manual/other/bypass/none/unknown)'),
                  @('perm_codex', 'codex_confirmations', 'Codex confirmations (default/other/bypass/none/unknown)'))) {
  if ($answers.ContainsKey($pm[1])) {
    $v = $answers[$pm[1]]
    if ($v -eq 'bypass') { Add-Check $pm[0] 'FAIL' 'bypass reported; kit policy forbids it' 'U' 0 }
    elseif ($v -eq 'manual' -or $v -eq 'default' -or $v -eq 'none') { Add-Check $pm[0] 'PASS' ('reported ' + $v) 'U' 0 }
    else { Add-Check $pm[0] 'UNKNOWN' ('reported ' + $v) 'U' 0 }
  } else { Add-Check $pm[0] 'UNKNOWN' 'not detectable by script' '?' 0; Ask $pm[1] $pm[2] }
}

foreach ($q in @(@('entry_mode', 'How to continue: gpt_guide (recommended for newcomers) or vscode_direct?'),
                 @('server_state', 'Server state: none, existing_active, replaced or unknown?'),
                 @('engine_mode', 'Engines: claude_only, codex_only, both or undecided?'))) {
  if (-not $answers.ContainsKey($q[0])) { Ask $q[0] $q[1] }
}

# ---------- write diagnostics (latest run only: replaced, not appended) ----------
$diag = @()
foreach ($c in $Checks) { $diag += ($c.Id + $Tab + $c.Status + $Tab + $c.Value + $Tab + $c.Label + $Tab + (NowUtc)) }
Write-Lines $FDiag $diag

# ---------- stage plan (accepted stages are kept, never duplicated) ----------
$stages = Load-Stages
$s1 = ($stages[1][1] -eq 'PASS')
if (-not $s1) {
  if ((Get-Status 'os') -eq 'PASS' -and (Get-Status 'kit') -eq 'PASS') { Set-Stage $stages 1 'PASS' 'L' 'diagnose' 'stage_plan_written' }
  else { Set-Stage $stages 1 'PENDING' 'L' 'diagnose' 'checks_incomplete' }
}
if ($stages[2][1] -ne 'PASS') {
  $vpnOn = ($answers.ContainsKey('vpn') -and $answers['vpn'] -eq 'on')
  if ((Get-Status 'vscode') -eq 'PASS' -and (Get-Status 'ssh_client') -eq 'PASS' -and $vpnOn) {
    Set-Stage $stages 2 'PASS' 'LU' 'diagnose+vpn_answer' 'vscode_ssh_vpn'
  } elseif ($stages[2][1] -eq 'NOT_RUN') { Set-Stage $stages 2 'PENDING' '?' 'diagnose' 'not_all_facts' }
}
Save-Stages $stages

$plan = @()
for ($i = 1; $i -le $StageCount; $i++) {
  $mode = 'RUN'; if ($stages[$i][1] -eq 'PASS') { $mode = 'SKIP' }
  $plan += ("" + $i + ':' + $mode + '(' + $stages[$i][1] + ')')
}
Write-Host ('STAGE_PLAN ' + ($plan -join ' '))

# ---------- local telemetry (closed schema; no commands, paths, addresses, names or secrets; no network) ----------
foreach ($c in $Checks) {
  Append-Line $FEvents ('{"v":1,"ts":"' + (NowUtc) + '","run":"' + $RunId + '","ev":"check","id":"' + $c.Id + '","st":"' + $c.Status + '","exec_ms":' + $c.Ms + ',"wait_ms":null}')
}
$RunWatch.Stop()
Append-Line $FEvents ('{"v":1,"ts":"' + (NowUtc) + '","run":"' + $RunId + '","ev":"run_end","exec_ms":' + [long]$RunWatch.ElapsedMilliseconds + ',"wait_ms":null}')
Write-Host 'DIAG_DONE'
exit 0
