<#
 diagnose.ps1 - read-only start diagnostics for the VPS workshop kit (Windows branch).
 Kit 0.1.2-preview.
 ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
 It never changes the system, network, VPN, SSH, keys or settings. It writes only under <kit>\state\.

 Usage:
   powershell -NoProfile -File tools\diagnose.ps1
   powershell -NoProfile -File tools\diagnose.ps1 -Answer vpn=on
   powershell -NoProfile -File tools\diagnose.ps1 -Accept 4 -Source ssh-whoami -Evidence L
   powershell -NoProfile -File tools\diagnose.ps1 -Reset 4
   powershell -NoProfile -File tools\diagnose.ps1 -Claim 4 -Source project-status   (a claim from existing project documents: NOT a PASS)
   powershell -NoProfile -File tools\diagnose.ps1 -Report      (safe summary to paste into a problem report)

 Test-only environment hooks (never needed by participants):
   KIT_PROBE_NO_FALLBACK=1  disable the install-location fallbacks for code/ssh
   KIT_PROBE_HIDE=code,ssh    pretend the named tools are not installed
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
  [switch]$Report
)

$ErrorActionPreference = 'Continue'
$KitVersion = '0.1.2-preview'
$KitRoot  = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $KitRoot 'state'
$TelDir   = Join-Path $StateDir 'telemetry'
$FDiag    = Join-Path $StateDir 'diagnostics.tsv'
$FStages  = Join-Path $StateDir 'stages.tsv'
$FAnswers = Join-Path $StateDir 'answers.tsv'
$FEvents  = Join-Path $TelDir 'events.jsonl'
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
  'neurolab_offer'      = @('shown', 'declined', 'interested')
}
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

# ---------- probes ----------
function Get-Fallbacks([string]$name) {
  $r = @()
  if ($name -eq 'code') {
    if ($env:LOCALAPPDATA) { $r += (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd') }
    if ($env:ProgramFiles) { $r += (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd') }
  }
  if ($name -eq 'ssh') {
    if ($env:SystemRoot) { $r += (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe') }
  }
  return $r
}
function Probe([string]$name, [string[]]$arguments) {
  $res = @{ Status = 'NOT_FOUND'; Lines = @() }
  if ($env:KIT_PROBE_HIDE -and (($env:KIT_PROBE_HIDE -split ",") -contains $name)) { return $res }
  $path = $null
  $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source) { $path = $cmd.Source }
  elseif (-not $env:KIT_PROBE_NO_FALLBACK) {
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
if ($Reset -ne 0) {
  $ctl = $true
  if ($Reset -lt 1 -or $Reset -gt $StageCount) { Fail "stage must be 1..$StageCount" 2 }
  $st = Load-Stages
  Set-Stage $st $Reset 'PENDING' '?' 'reset' 'reset'
  Save-Stages $st
  Write-Host ("STAGE_RESET " + $Reset)
}
if ($ctl) { exit 0 }

# ---------- safe report: kit version, OS label, stage table, check ids/statuses; no paths, addresses, names ----------
if ($Report) {
  $osv = ''
  foreach ($l in (Read-Lines $FDiag)) { $p = $l -split "`t"; if ($p[0] -eq 'os') { $osv = $p[2] } }
  Write-Host ('REPORT kit=' + $KitVersion + ' os=' + $osv)
  foreach ($l in (Read-Lines $FStages)) { if ($l.Trim().Length -gt 0) { Write-Host ('REPORT_STAGE ' + ($l -replace "`t", ' ')) } }
  foreach ($l in (Read-Lines $FDiag)) { $p = $l -split "`t"; if ($p.Count -ge 3) { Write-Host ('REPORT_CHECK ' + $p[0] + ' ' + $p[1] + ' ' + $p[2]) } }
  Write-Host 'REPORT_END (add: stage number, what you saw in your own words WITHOUT passwords, keys, IP addresses, user names, paths)'
  exit 0
}

# ---------- diagnostics ----------
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$hadStages = Test-Path -LiteralPath $FStages
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
  if ($env:OS -eq 'Windows_NT') { return @('PASS', ('windows-' + [Environment]::OSVersion.Version.ToString())) }
  return @('UNKNOWN', 'not-windows; use tools/diagnose.sh')
}
Add-Check 'os' $t.R[0] $t.R[1] 'L' $t.Ms

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
