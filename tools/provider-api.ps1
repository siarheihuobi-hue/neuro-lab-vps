<#
.SYNOPSIS
  Fixed-purpose helper for the OneDash provider API (adapter 1). It is NOT a general HTTP client.
.DESCRIPTION
  The person enters the API key once, locally, in a window the agent does not read (set-key).
  The key is kept in the Windows user store (DPAPI, bound to this Windows user) outside the kit and outside any project.
  Every other command is a fixed operation; its result is passed through an ALLOW-LIST sanitizer (only known harmless
  fields survive; passwords, keys, addresses, logins, links never do). There is no command for credentials, password
  change, reinstall, renewal, tariff change or delete.
  Residual risk, stated plainly: the key store is bound to the Windows USER, not to this process, so another command run
  by the same user (including an agent) could read it. The protective layers are the key whitelist at the provider, a
  read-only key where the provider offers one, and the tool-permission prompt on every call.
  A purchase needs a preview, a confirmation code SHOWN ONLY TO THE PERSON (the state keeps only its hash), an atomic
  claim, and a state record BEFORE the request. An uncertain result is reconciled by order identity and attributes and
  is never repeated blindly; ambiguity stops for a human decision.
  Commands:
    set-key        the person enters the key (secret prompt; refuses redirected input)
    key-status, clear-key
    auth-check, balance, list, orders, reference (-What locations|systems|tariffs [-Location -Processor])
    egress         external address(es) of THIS environment, masked; -Window shows the exact address to the person in a
                   separate window, -Copy puts it into the clipboard for 120 s; neither prints it to the agent output
    readonly-check key, authorization, egress families, catalog, existing servers; no purchase, no write
    ssh-bind       writes a Host block for an existing server into the user SSH config; the address is never printed
    order-preview  builds the concrete order; the confirmation code is shown to the person only
    order-create   -Confirm CODE : executes the previewed order once (real spending; separate confirmation required)
    order-status   reconciles by order identity; ambiguity stops
    order-resolve  -OrderId IDS : the person (interactive terminal, types the code) names the order(s) after an ambiguous reconciliation
    order-clear    the person (interactive terminal) declares a stuck uncertain/submitted order void after checking the panel
    order-unlock   the person (interactive terminal) removes a lock left behind by a helper that died
#>
param(
  [Parameter(Position = 0)][string]$Command = '',
  [string]$What = '',
  [string]$Location = '',
  [string]$Processor = '',
  [string]$Tariff = '',
  [string]$System = '',
  [string]$Period = '',
  [int]$Count = 1,
  [string]$Confirm = '',
  [string]$OrderId = '',
  [string]$VpsId = '',
  [string]$Alias = '',
  [string]$User = '',
  [string]$IdentityFile = '',
  [switch]$Show,
  [switch]$Window,
  [switch]$Copy
)
$ErrorActionPreference = 'Stop'
$ApiBase = 'https://api.rdp-onedash.ru/api'
$EchoUrl = 'https://api.ipify.org'
$EchoUrl6 = 'https://api6.ipify.org'
$HereDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitRoot = Split-Path -Parent $HereDir
$StateDir = Join-Path $KitRoot 'state'
$PendFile = Join-Path $StateDir 'provider-order.tsv'
$LockFile = Join-Path $StateDir 'provider-order.lock'
$OrdersFlag = Join-Path $StateDir 'provider-orders-enabled'
$AnswersFile = Join-Path $StateDir 'answers.tsv'
$EgressFile = Join-Path $StateDir 'provider-egress.tsv'
$KeyDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'neuro-lab-vps'
$KeyFile = Join-Path $KeyDir 'provider-key.dat'
$SshConfig = Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh') 'config'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Tab = [string][char]9
$HaveLock = $false
$ReqSent = $false

# ---- exits go through exceptions so that the lock is always released ----
function Out-Line([string]$s) { Write-Host $s }
function Die([string]$code, [string]$msg, [int]$rc = 2) { throw ('DIE|' + $rc + '|' + $code + ' ' + $msg) }
function Fin([int]$rc) { throw ('EXIT|' + $rc) }
function NowUtc { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
# whole-string matching (\A..\z): a trailing or embedded line break can never pass
function Is-Match([string]$v, [string]$re) { return ($v -cmatch ('\A(?:' + $re + ')\z')) }
function Chk-Code([string]$v, [string]$what) {
  if ($v -and -not (Is-Match $v '[A-Za-z0-9_.+-]{1,40}')) { Die 'BAD_PARAMETER' ($what + ' must be a short code') }
}
function Sha([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }))
}

# ---- atomic claim of the order state: only one process at a time may decide a purchase ----
function Lock-Enter {
  if (-not (Test-Path -LiteralPath $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir) }
  $stale = ''
  if (Test-Path -LiteralPath $LockFile) {
    if (((Get-Date) - (Get-Item -LiteralPath $LockFile).LastWriteTime).TotalSeconds -gt 180) { $stale = ' The lock is older than 3 minutes: a helper probably died; the person runs order-unlock in a terminal (the lock is never taken over automatically).' }
  }
  try {
    $fs = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.Close()
    $script:HaveLock = $true
  } catch { Die 'ORDER_BUSY' ('another order operation holds the lock; nothing was sent; wait and run order-status.' + $stale) 8 }
}
function Lock-Leave {
  if ($script:HaveLock) { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue; $script:HaveLock = $false }
}

# ---- the paid route is OFF by default and is never switched on by the helper or by an agent on its own ----
# The kit cannot enforce the engine's per-call confirmation (Claude Manual mode / Codex confirmations are engine settings).
# It therefore (1) keeps order-preview/order-create/order-resolve disabled until the PERSON enables them in a terminal,
# and (2) refuses order-preview/order-create/order-resolve/ssh-bind unless a SAFE permission mode (Claude manual / Codex default) is recorded in the state answers (allow-list).
function Permission-Gate {
  # allow-list: at least one RECORDED safe mode (Claude manual, Codex default) and no recorded unsafe one
  $okMode = $false
  if (Test-Path -LiteralPath $AnswersFile) {
    foreach ($ln in [System.IO.File]::ReadAllLines($AnswersFile, $Utf8)) {
      $p = $ln.Split($Tab[0])
      if ($p.Length -lt 2 -or (@('claude_permission', 'codex_confirmations') -notcontains $p[0])) { continue }
      if (@('bypass', 'none') -contains $p[1]) { Die 'PERMISSION_MODE_UNSAFE' ('the recorded engine permission mode is ' + $p[1] + '; sensitive provider commands need a per-call confirmation; switch the mode back first') 2 }
      if (($p[0] -eq 'claude_permission' -and $p[1] -eq 'manual') -or ($p[0] -eq 'codex_confirmations' -and $p[1] -eq 'default')) { $okMode = $true }
    }
  }
  if (-not $okMode) { Die 'PERMISSION_MODE_UNKNOWN' 'no safe engine permission mode (Claude manual / Codex default confirmations) is recorded in the state answers; the participant records it with the diagnostics first. This is a check of a recorded answer, not of the engine itself' 2 }
}
# a step that only a person at a terminal can do (the agent's tool calls have redirected input)
function Person-Input([string]$prompt) {
  # PERSON_INPUT_HOOK
  if ([Console]::IsInputRedirected) { Die 'INTERACTIVE_ONLY' 'this step must be done by the person in a normal terminal window' }
  return (Read-Host -Prompt $prompt)
}
function Orders-Gate {
  Permission-Gate
  if (-not (Test-Path -LiteralPath $OrdersFlag)) { Die 'ORDERS_DISABLED' 'the paid-order route is switched off (default). Only the person can switch it on, in a terminal: provider-api.ps1 orders-enable. Until then use the provider panel' 2 }
}

# ---- secret store (Windows: DPAPI, current user) ----
function Has-Key { return (Test-Path -LiteralPath $KeyFile) }
function Get-KeyText {
  if (-not (Has-Key)) { Die 'NO_KEY' 'no API key stored; the person runs: provider-api.ps1 set-key' }
  $sec = ConvertTo-SecureString -String ([System.IO.File]::ReadAllText($KeyFile, $Utf8).Trim())
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $k = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
  if (-not (Is-Match $k '[A-Za-z0-9._~+/=-]{8,512}')) { Die 'NO_KEY_FORMAT' 'the stored key has an unexpected format; the person runs set-key again' }
  return $k
}

# ---- sanitizing: ALLOW-LIST. Only these field names keep their value; everything else becomes [redacted] ----
$SafeKeys = @('type', 'data', 'id', 'order_id', 'vps_id', 'status', 'state', 'name', 'title', 'price', 'cost', 'currency', 'balance',
  'location', 'system', 'os', 'period', 'tariff', 'tariff_id', 'processor', 'cpu', 'cores', 'ram', 'disk', 'count', 'created_at', 'updated_at', 'expires_at', 'ends_at')
function Redact-Text([string]$v) {
  if ($v -match '(?i)bearer\s+\S+|https?://\S+|([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4}|[A-Za-z0-9-]+\.[A-Za-z]{2,}|[A-Za-z0-9+/_=-]{24,}') { return '[redacted]' }
  if ($v.Length -gt 80) { return $v.Substring(0, 80) }
  return $v
}
function Clean-Value($v, [string]$name) {
  if ($null -eq $v) { return $null }
  if ($name -and ($SafeKeys -notcontains $name.ToLowerInvariant())) { return '[redacted]' }
  if ($v -is [string]) { return (Redact-Text $v) }
  if ($v -is [System.Management.Automation.PSCustomObject]) {
    $o = [ordered]@{}; $ri = 0
    foreach ($p in $v.PSObject.Properties) {
      if ($SafeKeys -contains $p.Name.ToLowerInvariant()) { $o[$p.Name] = Clean-Value $p.Value $p.Name } else { $ri++; $o['redacted_field_' + $ri] = '[redacted]' }
    }
    return $o
  }
  if (($v -is [System.Collections.IEnumerable]) -and -not ($v -is [string])) {
    $a = @(); foreach ($x in $v) { $a += , (Clean-Value $x $name) }
    return ,$a
  }
  if ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return $v }
  return '[redacted]'
}
function Show-Clean($obj) {
  $c = Clean-Value $obj ''
  $t = ($c | ConvertTo-Json -Depth 8 -Compress)
  if ($t.Length -gt 6000) { $t = $t.Substring(0, 6000) + '...[truncated]' }
  Out-Line $t
}
function Prop($o, [string[]]$names) {
  foreach ($n in $names) { $p = $o.PSObject.Properties[$n]; if ($p -and $null -ne $p.Value -and ([string]$p.Value).Length -gt 0) { return [string]$p.Value } }
  return ''
}

# ---- show something to the PERSON only: a separate window; the text never goes through the command line or this output ----
function Show-ToPerson([string]$title, [string[]]$lines) {
  # PERSON_HOOK
  try {
    $tf = [System.IO.Path]::GetTempFileName()
    $acl = Get-Acl -LiteralPath $tf
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($ar in @($acl.Access)) { [void]$acl.RemoveAccessRule($ar) }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $tf -AclObject $acl
    [System.IO.File]::WriteAllText($tf, ($lines -join [Environment]::NewLine), $Utf8)
    $code = '$p = ''' + ($tf -replace "'", "''") + '''; $t = Get-Content -LiteralPath $p -Raw; Remove-Item -LiteralPath $p -Force; $Host.UI.RawUI.WindowTitle = ''' + ($title -replace "'", "''") + '''; Write-Host $t; Write-Host ''''; Read-Host ''Press Enter to close this window'' | Out-Null'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    [void](Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-EncodedCommand', $enc))
    for ($i = 0; $i -lt 10; $i++) { if (-not (Test-Path -LiteralPath $tf)) { return $true }; Start-Sleep -Seconds 1 }
    Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
    return $false
  } catch { return $false }
}

# ---- the only request path (fixed method/path allowlist, no redirects) ----
$Allowed = @(
  'GET /auth/check', 'GET /balance', 'GET /vps', 'GET /orders', 'GET /locations', 'GET /systems', 'GET /tariffs',
  'POST /vps/create'
)
function Call-Api([string]$method, [string]$path, $body = $null, [string]$query = '') {
  if ($Allowed -notcontains ($method + ' ' + $path)) { Die 'NOT_ALLOWED' ('operation is not part of this helper: ' + $method + ' ' + $path) }
  $key = Get-KeyText
  $h = @{ Authorization = ('Bearer ' + $key); Accept = 'application/json' }
  $uri = $ApiBase + $path + $query
  $key = $null
  try {
    if ($method -eq 'POST') {
      $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $h -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress -Depth 5) -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0
    } else {
      $r = Invoke-WebRequest -Uri $uri -Method Get -Headers $h -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0
    }
    $j = $null; try { $j = $r.Content | ConvertFrom-Json } catch { }
    return @{ Status = [int]$r.StatusCode; Json = $j }
  } catch {
    $resp = $_.Exception.Response
    if ($null -eq $resp) { return @{ Status = 0; Json = $null; Err = 'PROVIDER_UNREACHABLE' } }
    $st = [int]$resp.StatusCode
    $ra = ''; try { $ra = [string]$resp.Headers['Retry-After'] } catch { }
    return @{ Status = $st; Json = $null; Err = 'HTTP_' + $st; RetryAfter = $ra }
  }
}
function Report-Status($r, [string]$what) {
  if ($r.Status -ge 200 -and $r.Status -lt 300) { return $true }
  switch ($r.Status) {
    0 { Out-Line ('PROVIDER_RESULT ' + $what + ' status=UNREACHABLE (network or VPN path; the VPN stays on; not repeated blindly)') }
    401 { Out-Line ('PROVIDER_RESULT ' + $what + ' status=KEY_REJECTED (the stored key is not accepted; the person runs set-key again)') }
    403 { Out-Line ('PROVIDER_RESULT ' + $what + ' status=IP_NOT_ALLOWED (the address of this environment is not in the key whitelist; run egress -Window, the person updates the list; no bypass)') }
    429 { $ra = [string]$r.RetryAfter; if (-not (Is-Match $ra '[0-9]{1,6}')) { $ra = 'unparsable' }; Out-Line ('PROVIDER_RESULT ' + $what + ' status=RATE_LIMITED retry_after=' + $ra) }
    default { Out-Line ('PROVIDER_RESULT ' + $what + ' status=HTTP_' + $r.Status) }
  }
  return $false
}

# ---- orders by identity ----
function Get-OrderList($json) {
  $out = @()
  foreach ($x in @($json.data)) {
    $id = Prop $x @('id', 'order_id')
    if (-not $id) { continue }
    $out += , @{ Id = $id; Tariff = (Prop $x @('tariff_id', 'tariff')); Location = (Prop $x @('location')); System = (Prop $x @('system', 'os')); Period = (Prop $x @('period')); Created = (Prop $x @('created_at', 'created', 'date_create')) }
  }
  return $out
}
# pending file: 0 code_hash, 1 state, 2 expiry, 3 canon, 4 before_count, 5 nonce, 6 before_ids, 7 matched_ids, 8 wrong_codes, 9 submitted_at
$PendStates = @('previewed', 'submitted', 'accepted', 'rejected', 'uncertain', 'ambiguous', 'void')
function Pend-Read {
  if (-not (Test-Path -LiteralPath $PendFile)) { return $null }
  $f = ([System.IO.File]::ReadAllText($PendFile, $Utf8)).Trim().Split($Tab[0])
  if ($f.Length -lt 6 -or ($PendStates -notcontains $f[1]) -or -not (Is-Match $f[0] '[0-9a-f]{64}')) {
    Die 'STATE_INVALID' 'the order state file is damaged or unknown; this is treated as BLOCKING. The person checks the provider panel and then runs order-clear in a console' 7
  }
  $o = @('', '', '', '', '0', '', '', '', '0', '')
  for ($i = 0; $i -lt [Math]::Min($f.Length, 10); $i++) { $o[$i] = $f[$i] }
  return $o
}
function Pend-Save($f, [string]$state, [string]$matched = '', [string]$wrong = '', [string]$subAt = '') {
  if (-not (Test-Path -LiteralPath $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir) }
  $m = $f[7]; if ($matched) { $m = $matched }
  $w = $f[8]; if ($wrong -ne '') { $w = $wrong }
  $sa = $f[9]; if ($subAt) { $sa = $subAt }
  $f[1] = $state; $f[7] = $m; $f[8] = $w; $f[9] = $sa
  $tmp = $PendFile + '.tmp'
  try {
    [System.IO.File]::WriteAllText($tmp, (@($f[0], $state, $f[2], $f[3], $f[4], $f[5], $f[6], $m, $w, $sa) -join $Tab), $Utf8)
    if (Test-Path -LiteralPath $PendFile) { [System.IO.File]::Replace($tmp, $PendFile, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $PendFile) }
  } catch {
    if ($script:ReqSent) { Die 'STATE_WRITE_FAILED_AFTER_REQUEST' 'the request WAS sent but the state could not be updated; the previous blocking state stays; run order-status and do NOT order again' 4 }
    Die 'STATE_WRITE_FAILED' 'the order state could not be written; nothing was sent' 7
  }
}
function Code-Ok($f, [string]$code) {
  return ($code -and (Is-Match $code '[0-9a-f]{8}') -and ((Sha ($code + '|' + $f[5])) -eq $f[0]))
}
function Wrong-Code($f) {
  $n = [int]$f[8] + 1
  if ($f[1] -eq 'ambiguous') {
    Pend-Save $f 'ambiguous' '' ([string]$n)
    if ($n -ge 3) { Die 'RESOLVE_LOCKED' 'three wrong codes: resolving is locked; the state stays ambiguous and no new purchase is possible; the person checks the panel and runs order-clear in a terminal' 2 }
    Die 'CONFIRM_MISMATCH' ('the confirmation code does not match; attempts left ' + (3 - $n)) 2
  }
  if ($n -ge 3) { Pend-Save $f 'void' '' ([string]$n); Die 'CONFIRM_MISMATCH' 'three wrong codes: this preview is void; nothing was sent; run order-preview again' 2 }
  Pend-Save $f $f[1] '' ([string]$n)
  Die 'CONFIRM_MISMATCH' ('the confirmation code does not match; nothing was sent; attempts left ' + (3 - $n)) 2
}
function Valid-Address([string]$a) {
  if (Is-Match $a '(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])') { return $true }
  if ((Is-Match $a '[0-9A-Fa-f:.]{2,45}') -and $a.Contains(':')) { return $true }
  if ((Is-Match $a '[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?') -and $a.Contains('.')) { return $true }
  return $false
}

# ---- egress: both families, the real environment of the API requests ----
function Get-Echo([string]$url) {
  try { return ([string](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0).Content).Trim() } catch { return '' }
}
function Mask4([string]$ip) { $p = $ip.Split('.'); return ($p[0] + '.' + $p[1] + '.*.*') }
function Mask6([string]$ip) { $p = $ip.Split(':'); return ($p[0] + ':' + $p[1] + ':*') }

# ---- commands ----
try {
switch ($Command) {
  'set-key' {
    if ([Console]::IsInputRedirected) { Die 'INTERACTIVE_ONLY' 'set-key must be run by the person in a normal terminal window (input is redirected)' }
    $sec = Read-Host -Prompt 'OneDash API key (not shown, not stored in the project)' -AsSecureString
    if ($sec.Length -lt 8) { Die 'KEY_TOO_SHORT' 'nothing stored' }
    if (-not (Test-Path -LiteralPath $KeyDir)) { [void](New-Item -ItemType Directory -Path $KeyDir) }
    [System.IO.File]::WriteAllText($KeyFile, (ConvertFrom-SecureString $sec), $Utf8)
    Out-Line 'KEY_STORED store=windows_dpapi_current_user (the key was not displayed and is not in the project)'
  }
  'key-status' {
    if (Has-Key) { Out-Line 'KEY_PRESENT store=windows_dpapi_current_user' } else { Out-Line 'KEY_ABSENT' }
  }
  'clear-key' {
    if (Has-Key) { Remove-Item -LiteralPath $KeyFile -Force; Out-Line 'KEY_REMOVED' } else { Out-Line 'KEY_ABSENT' }
  }
  'auth-check' {
    $r = Call-Api 'GET' '/auth/check'
    if (Report-Status $r 'auth-check') { Out-Line 'PROVIDER_RESULT auth-check status=OK'; Show-Clean $r.Json }
  }
  'balance' {
    $r = Call-Api 'GET' '/balance'
    if (Report-Status $r 'balance') { Out-Line 'PROVIDER_RESULT balance status=OK'; Show-Clean $r.Json }
  }
  'list' {
    $r = Call-Api 'GET' '/vps'
    if (Report-Status $r 'list') { Out-Line 'PROVIDER_RESULT list status=OK'; Show-Clean $r.Json }
  }
  'orders' {
    $r = Call-Api 'GET' '/orders'
    if (Report-Status $r 'orders') { Out-Line 'PROVIDER_RESULT orders status=OK'; Show-Clean $r.Json }
  }
  'reference' {
    if (@('locations', 'systems', 'tariffs') -notcontains $What) { Die 'BAD_PARAMETER' '-What must be locations, systems or tariffs' }
    Chk-Code $Location 'Location'; Chk-Code $Processor 'Processor'
    $q = ''; if ($What -eq 'tariffs' -and $Location) { $q = '?location=' + $Location; if ($Processor) { $q += '&processor=' + $Processor } }
    $r = Call-Api 'GET' ('/' + $What) $null $q
    if (Report-Status $r ('reference-' + $What)) { Out-Line ('PROVIDER_RESULT reference-' + $What + ' status=OK'); Show-Clean $r.Json }
  }
  'egress' {
    $v4 = Get-Echo $EchoUrl; $v6 = Get-Echo $EchoUrl6
    if ($v4 -and -not (Is-Match $v4 '([0-9]{1,3}\.){3}[0-9]{1,3}')) { $v4 = '' }
    if ($v6 -and -not (Is-Match $v6 '[0-9A-Fa-f:]{2,45}')) { $v6 = '' }
    if (-not $v4 -and -not $v6) { Die 'ECHO_UNREACHABLE' 'could not determine any address; nothing changed' 3 }
    $hash = Sha ($v4 + '|' + $v6)
    $prev = ''; if (Test-Path -LiteralPath $EgressFile) { $prev = ([System.IO.File]::ReadAllText($EgressFile, $Utf8)).Trim().Split($Tab[0])[0] }
    if (-not (Test-Path -LiteralPath $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir) }
    [System.IO.File]::WriteAllText($EgressFile, ($hash + $Tab + (NowUtc)), $Utf8)
    $state = 'FIRST_SEEN'; if ($prev) { if ($prev -eq $hash) { $state = 'UNCHANGED' } else { $state = 'CHANGED' } }
    $m4 = 'none'; if ($v4) { $m4 = Mask4 $v4 }
    $m6 = 'none'; if ($v6) { $m6 = Mask6 $v6 }
    $dns = 'unresolved'
    try {
      $ad = [System.Net.Dns]::GetHostAddresses(([uri]$ApiBase).Host)
      $has4 = @($ad | Where-Object { $_.AddressFamily -eq 'InterNetwork' }).Count -gt 0
      $has6 = @($ad | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' }).Count -gt 0
      if ($has4 -and $has6) { $dns = 'dual_stack' } elseif ($has4) { $dns = 'ipv4_only' } elseif ($has6) { $dns = 'ipv6_only' }
    } catch { }
    $proxy = 'direct'
    try { $pu = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy([uri]$ApiBase); if ($pu.AbsoluteUri -ne ([uri]$ApiBase).AbsoluteUri) { $proxy = 'system_proxy' } } catch { }
    $need = 'ipv4'
    if ($dns -eq 'ipv6_only') { $need = 'ipv6' } elseif ($dns -eq 'dual_stack' -and $v6) { $need = 'both_v4_and_v6' }
    Out-Line ('EGRESS ' + $state + ' ipv4=' + $m4 + ' ipv6=' + $m6 + ' provider_dns=' + $dns + ' proxy=' + $proxy + ' add_to_whitelist=' + $need + ' (measured from THIS process and network path, the one that makes the API requests; the VPN stays on; no address is written to the project or printed in full here)')
    $lines = @(); if ($v4) { $lines += ('IPv4: ' + $v4) }; if ($v6) { $lines += ('IPv6: ' + $v6) }
    if ($Window) {
      $wl = @(('Add the address(es) below to the API key whitelist in the provider panel (add_to_whitelist=' + $need + '):'), '') + $lines
      if (Show-ToPerson 'API key whitelist' $wl) { Out-Line 'EGRESS_WINDOW_OPENED the exact address is shown only in the new window; it is not in this output or any log' } else { Out-Line 'EGRESS_WINDOW_FAILED could not open a window; use -Copy' }
    }
    if ($Copy) {
      $cl = ($lines -join [Environment]::NewLine)
      try {
        Set-Clipboard -Value $cl
        $clr = '$t = ''' + ($cl -replace "'", "''") + '''; Start-Sleep -Seconds 120; try { if ((Get-Clipboard -Raw).Trim() -eq $t.Trim()) { Set-Clipboard -Value '' '' } } catch { }'
        $enc2 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($clr))
        [void](Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc2))
        Out-Line 'EGRESS_COPIED the address(es) are in the clipboard for 120 s and are then cleared if unchanged; the clipboard AND the hidden clearing process (its command line holds the address for 120 s) are readable by other local programs of the same user: prefer -Window'
      } catch { Out-Line 'EGRESS_COPY_FAILED no clipboard available; use -Window' }
    }
    if ($Show) {
      if ([Console]::IsOutputRedirected) { Out-Line 'EGRESS_SHOW_REFUSED output is redirected; use -Window' } else { foreach ($l in $lines) { Out-Line ('EGRESS_FULL ' + $l) } }
    }
  }
  'readonly-check' {
    # authorization, external address, catalog, existing servers. No purchase, no write, no POST.
    if (-not (Has-Key)) { Out-Line 'READONLY_CHECK RESULT NOT_TESTED reason=no_key (the person runs set-key; nothing was requested)'; Fin 3 }
    $a = Call-Api 'GET' '/auth/check'
    if (-not (Report-Status $a 'readonly-auth')) { Out-Line 'READONLY_CHECK RESULT FAIL step=authorization (see the status above; later steps not run)'; Fin 3 }
    Out-Line 'READONLY_CHECK step=authorization PASS'
    $v4 = Get-Echo $EchoUrl; $v6 = Get-Echo $EchoUrl6
    if ($v4 -or $v6) { Out-Line ('READONLY_CHECK step=egress PASS families=' + $(if ($v4) { 'ipv4' } else { '-' }) + ',' + $(if ($v6) { 'ipv6' } else { '-' }) + ' (exact address: run egress -Window)') } else { Out-Line 'READONLY_CHECK step=egress FAIL echo_unreachable' }
    foreach ($w in @('locations', 'systems', 'tariffs')) {
      $c = Call-Api 'GET' ('/' + $w) $null ''
      if (Report-Status $c ('readonly-' + $w)) { Out-Line ('READONLY_CHECK step=catalog_' + $w + ' PASS items=' + @($c.Json.data).Count) } else { Out-Line ('READONLY_CHECK step=catalog_' + $w + ' FAIL') }
    }
    $l = Call-Api 'GET' '/vps'
    if (Report-Status $l 'readonly-vps') { Out-Line ('READONLY_CHECK step=existing_servers PASS items=' + @($l.Json.data).Count + ' (contents not shown)') } else { Out-Line 'READONLY_CHECK step=existing_servers FAIL' }
    Out-Line 'READONLY_CHECK RESULT DONE (read-only; shape of the real answers is what this check confirms)'
  }
  'ssh-bind' {
    Permission-Gate
    if (-not $VpsId -or -not $Alias -or -not $User -or -not $IdentityFile) { Die 'MISSING_PARAMETER' '-VpsId -Alias -User -IdentityFile are required' }
    if (-not (Is-Match $VpsId '[A-Za-z0-9_-]{1,40}')) { Die 'BAD_PARAMETER' 'VpsId must be a short id' }
    if (-not (Is-Match $Alias '[A-Za-z0-9_][A-Za-z0-9_-]{0,39}')) { Die 'BAD_PARAMETER' 'Alias must be 1-40 chars of A-Za-z0-9_- and must not start with -' }
    if (-not (Is-Match $User '[a-z_][a-z0-9_-]{0,31}')) { Die 'BAD_PARAMETER' 'User must be a plain lowercase account name' }
    if (-not (Is-Match $IdentityFile '[A-Za-z0-9_./:\\~-]{1,260}')) { Die 'BAD_PARAMETER' 'IdentityFile must be a plain path without spaces, quotes, % or # (copy the key to such a path)' }
    if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { Die 'IDENTITY_NOT_FOUND' 'the key file does not exist (nothing written)' }
    $r = Call-Api 'GET' '/vps'
    if (-not (Report-Status $r 'ssh-bind')) { Fin 3 }
    $item = $null; foreach ($x in @($r.Json.data)) { if ((Prop $x @('id', 'vps_id')) -ceq $VpsId) { $item = $x } }
    if ($null -eq $item) { Die 'VPS_NOT_FOUND' 'no server with this id in the list; nothing written' 3 }
    $addr = Prop $item @('ip', 'ipv4', 'ip_address', 'main_ip', 'host', 'address')
    if (-not $addr) { Die 'ADDRESS_FIELD_NOT_FOUND' 'the list answer has no known address field (shape not confirmed); use the provider panel; nothing written' 3 }
    if (-not (Valid-Address $addr)) { Die 'ADDRESS_INVALID' 'the address field is not a plain IP or host name; nothing written (no config injection)' 3 }
    $dir = Split-Path -Parent $SshConfig
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $old = ''; $had = Test-Path -LiteralPath $SshConfig; $warn = ''
    if ($had) {
      $bytes = [System.IO.File]::ReadAllBytes($SshConfig)
      if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { Die 'CONFIG_ENCODING_UNSUPPORTED' 'the SSH config is UTF-16; it is not modified; convert it to UTF-8 first' }
      $old = [System.IO.File]::ReadAllText($SshConfig, $Utf8)
      $norm = ($old -replace '"', ' ' -replace '=', ' ')
      if ($norm -match ('(?im)^\s*Host\s+(.*\s)?' + [regex]::Escape($Alias) + '(\s.*)?$')) { Die 'ALIAS_EXISTS' 'an entry with this alias already exists; no existing entry is modified; choose another alias' }
      if ($old -match '(?im)^\s*Include\s') { $warn += ' note=config_has_Include_check_alias_in_included_files' }
      foreach ($ln in ($old -split "`n")) {
        $hw = (($ln -replace '["=]', ' ').Trim() -split '\s+')
        if ($hw.Length -ge 2 -and $hw[0] -ieq 'Host') {
          foreach ($pt in $hw[1..($hw.Length - 1)]) {
            if ($pt -eq '*' -or $pt.StartsWith('!') -or ($pt -notmatch '[*?]')) { continue }
            $rx = '\A' + ([regex]::Escape($pt).Replace('\*', '.*').Replace('\?', '.')) + '\z'
            if ($Alias -imatch $rx) { Die 'ALIAS_COVERED_BY_PATTERN' 'an existing Host pattern already covers this alias; no entry is modified; choose another alias' }
          }
        }
      }
      $inStar = $true
      if ($old -match '(?im)^\s*Match\s') { $warn += ' note=config_has_Match_blocks_check_order' }
      foreach ($ln in ($old -split "`n")) {
        $w = (($ln -replace '["=]', ' ').Trim() -split '\s+')
        if ($w.Length -ge 2 -and $w[0] -ieq 'Host') { $inStar = ($w[1] -ceq '*') }
        elseif ($w.Length -ge 2 -and $w[0] -ieq 'Match') { $inStar = $false }
        elseif ($inStar -and $w.Length -ge 2 -and $w[0] -ieq 'StrictHostKeyChecking' -and (@('no', 'accept-new') -contains $w[1].ToLowerInvariant())) { $warn += ' warning=global_Host_star_StrictHostKeyChecking_may_override_ask'; break }
      }
    }
    $bk = 'no'
    if ($had) { $bkf = $SshConfig + '.neuro-lab-backup-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'); Copy-Item -LiteralPath $SshConfig -Destination $bkf; if (-not (Test-Path -LiteralPath $bkf)) { Die 'BACKUP_FAILED' 'the backup copy of the SSH config was not created; nothing written' 4 }; $bk = 'yes' }
    $nl = [Environment]::NewLine
    $blk = ''
    if ($old.Length -gt 0 -and -not $old.EndsWith("`n")) { $blk += $nl }
    $blk += ('# neuro-lab-vps begin ' + $Alias + $nl + 'Host ' + $Alias + $nl + '    HostName ' + $addr + $nl + '    User ' + $User + $nl + '    Port 22' + $nl + '    IdentityFile ' + $IdentityFile + $nl + '    IdentitiesOnly yes' + $nl + '    StrictHostKeyChecking ask' + $nl + '# neuro-lab-vps end ' + $Alias + $nl)
    [System.IO.File]::AppendAllText($SshConfig, $blk, $Utf8)
    $new = [System.IO.File]::ReadAllText($SshConfig, $Utf8)
    if (-not $new.StartsWith($old) -or -not $new.Contains('Host ' + $Alias)) { Die 'VERIFY_FAILED' 'the config check after writing failed; restore from the backup if present' 4 }
    $addr = $null
    Out-Line ('SSH_CONFIG_BOUND alias=' + $Alias + ' user=' + $User + ' address=written_not_shown backup=' + $bk + ' existing_entries=unchanged host_key=NOT_ACCEPTED (known_hosts untouched; the person compares the fingerprint with the provider panel at stage 4 before the first connection)' + $warn)
  }
  'orders-enable' {
    if ([Console]::IsInputRedirected) { Die 'INTERACTIVE_ONLY' 'orders-enable must be run by the person in a normal terminal window' }
    Permission-Gate
    $a = Read-Host -Prompt 'Type ENABLE to switch on the EXPERIMENTAL paid-order route (every order-create still needs the engine confirmation of each call)'
    if ($a -cne 'ENABLE') { Die 'CANCELLED' 'nothing changed' }
    if (-not (Test-Path -LiteralPath $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir) }
    [System.IO.File]::WriteAllText($OrdersFlag, (NowUtc), $Utf8)
    Out-Line 'ORDERS_ENABLED (experimental; the real provider API is not verified; switch off with orders-disable)'
  }
  'orders-disable' {
    if (Test-Path -LiteralPath $OrdersFlag) { Remove-Item -LiteralPath $OrdersFlag -Force }
    Out-Line 'ORDERS_DISABLED_NOW'
  }
  'order-preview' {
    Orders-Gate
    foreach ($p in @(@($Location, 'Location'), @($Processor, 'Processor'), @($Tariff, 'Tariff'), @($System, 'System'), @($Period, 'Period'))) {
      if (-not $p[0]) { Die 'MISSING_PARAMETER' ('-' + $p[1] + ' is required') }
      Chk-Code $p[0] $p[1]
    }
    if ($Count -lt 1 -or $Count -gt 10) { Die 'BAD_PARAMETER' 'Count must be 1..10' }
    Lock-Enter
    $old = Pend-Read
    if ($old -and (@('submitted', 'uncertain', 'ambiguous') -contains $old[1])) { Die 'ORDER_UNRECONCILED' 'a previous order is submitted, uncertain or ambiguous; run order-status first; never a second purchase blindly' }
    $t = Call-Api 'GET' '/tariffs' $null ('?location=' + $Location + '&processor=' + $Processor)
    if (-not (Report-Status $t 'order-preview')) { Fin 3 }
    $match = $null
    foreach ($x in @($t.Json.data)) { if ((Prop $x @('id')) -ceq $Tariff) { $match = $x } }
    if ($null -eq $match) { Die 'TARIFF_NOT_FOUND' 'the tariff id is not offered for this location and processor; nothing prepared' 3 }
    $canon = @($Location, $Processor, $Tariff, $System, $Period, [string]$Count) -join '|'
    $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $code = (Sha ([Guid]::NewGuid().ToString('N') + $canon + $nonce)).Substring(0, 8)
    $br = Call-Api 'GET' '/orders'
    if (-not (Report-Status $br 'order-preview')) { Die 'BASELINE_UNAVAILABLE' 'the order list could not be read, so a later reconciliation would be impossible; nothing prepared' 3 }
    $ids = @(Get-OrderList $br.Json | ForEach-Object { $_.Id })
    $exp = (Get-Date).ToUniversalTime().AddMinutes(15).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $price = Clean-Value $match ''
    $pl = @('ORDER TO CONFIRM (real spending when confirmed):', ('  provider=onedash location=' + $Location + ' processor=' + $Processor + ' system=' + $System + ' period=' + $Period + ' count=' + $Count), ('  tariff: ' + ($price | ConvertTo-Json -Compress -Depth 4)), '', ('  CONFIRMATION CODE: ' + $code), ('  valid until ' + $exp), '', 'Say this code to the agent only if you want exactly this order.')
    Pend-Save @((Sha ($code + '|' + $nonce)), 'previewed', $exp, $canon, [string]$ids.Count, $nonce, ($ids -join ','), '', '0', '') 'previewed'
    if ($Show -and -not [Console]::IsOutputRedirected) { foreach ($l in $pl) { Out-Line $l } }
    elseif (-not (Show-ToPerson 'Order confirmation' $pl)) { $f0 = Pend-Read; Pend-Save $f0 'void'; Die 'CODE_NOT_SHOWN' 'could not open a window for the person; the preview is void; run order-preview -Show in a normal console window yourself' 3 }
    Out-Line 'ORDER_PREVIEW (nothing was ordered, nothing was charged)'
    Out-Line ('  provider=onedash location=' + $Location + ' processor=' + $Processor + ' system=' + $System + ' period=' + $Period + ' count=' + $Count)
    Out-Line '  tariff:'; Show-Clean $match
    Out-Line ('  orders_before=' + $ids.Count + ' valid_until=' + $exp)
    Out-Line '  CONFIRM_CODE=shown_to_the_person_only (a window shows the order and the code; the state stores only a hash; the agent cannot read the code and must not invent one)'
  }
  'order-create' {
    Orders-Gate
    Lock-Enter
    $f = Pend-Read
    if ($null -eq $f) { Die 'NO_PREVIEW' 'run order-preview first' }
    if ($f[1] -ne 'previewed') { Die 'ORDER_NOT_PREVIEWED' ('state is ' + $f[1] + '; reconcile with order-status; no second purchase blindly') }
    if ([datetime]::Parse($f[2]).ToUniversalTime() -lt (Get-Date).ToUniversalTime()) { Die 'PREVIEW_EXPIRED' 'preview expired; run order-preview again' }
    if (-not (Code-Ok $f $Confirm)) { Wrong-Code $f }
    # one-time redemption: a marker that is created atomically and NEVER deleted, so one code can start at most one request even if the lock is lost
    $mk = Join-Path $StateDir ('redeemed-' + $f[0].Substring(0, 16))
    try { $mfs = [System.IO.File]::Open($mk, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None); $mfs.Close() } catch { Die 'CODE_ALREADY_REDEEMED' 'this confirmation code was already used to start a request; nothing was sent; run order-status and never repeat' 8 }
    # state is recorded BEFORE the request: a crash or timeout can never lead to a blind second purchase
    Pend-Save $f 'submitted' '' '0' (NowUtc)
    $script:ReqSent = $true
    $c = $f[3].Split('|')
    $body = @{ period = $c[4]; tariff_id = $c[2]; location = $c[0]; processor = $c[1]; system = $c[3]; count = [int]$c[5]; confirm = $true }
    $r = Call-Api 'POST' '/vps/create' $body
    $typeOk = $false; if ($r.Json -and $r.Json.PSObject.Properties['type'] -and ($r.Json.type -eq $true)) { $typeOk = $true }
    if ($r.Status -ge 200 -and $r.Status -lt 300 -and $typeOk) {
      Pend-Save $f 'accepted'
      Out-Line 'ORDER_ACCEPTED (asynchronous; reconcile with order-status, do not repeat)'; Show-Clean $r.Json
    } elseif (@(400, 401, 402, 403, 404, 422) -contains $r.Status) {
      Pend-Save $f 'rejected'
      Out-Line ('ORDER_REJECTED status=HTTP_' + $r.Status + ' (the provider refused; nothing was created; a new preview is needed)')
      Fin 6
    } else {
      Pend-Save $f 'uncertain'
      Out-Line ('ORDER_UNCERTAIN status=' + $r.Status + ' (the result is unknown, including a 2xx without type=true, 3xx, 409 and 5xx; run order-status to reconcile; do NOT order again)')
      Fin 4
    }
  }
  'order-status' {
    Lock-Enter
    $f = Pend-Read
    if ($null -eq $f) { Out-Line 'ORDER_STATUS none (no preview or order recorded)'; break }
    $r = Call-Api 'GET' '/orders'
    if (-not (Report-Status $r 'order-status')) { Fin 3 }
    $list = @(Get-OrderList $r.Json)
    $beforeIds = @(); if ($f[6]) { $beforeIds = $f[6].Split(',') }
    $newOnes = @($list | Where-Object { $beforeIds -cnotcontains $_.Id })
    $c = $f[3].Split('|'); $want = [int]$c[5]
    Out-Line ('ORDER_STATUS local_state=' + $f[1] + ' orders_before=' + $beforeIds.Count + ' orders_now=' + $list.Count + ' new_orders=' + $newOnes.Count + ' expected=' + $want)
    if (@('uncertain', 'submitted', 'ambiguous') -contains $f[1]) {
      if ($newOnes.Count -eq 0) {
        Out-Line 'ORDER_UNRESOLVED no new order is visible yet; wait and check again (bounded), or look in the provider panel; do NOT order again until this is resolved by the person'
      } else {
        $verdict = 'match'; $unver = 0
        if ($newOnes.Count -ne $want) { $verdict = 'count_differs' }
        else {
          $subAt = $null; if ($f[9]) { try { $subAt = [datetime]::Parse($f[9]).ToUniversalTime().AddMinutes(-2) } catch { } }
          foreach ($o in $newOnes) {
            $known = 0
            if ($o.Tariff) { $known++; if ($o.Tariff -cne $c[2]) { $verdict = 'attribute_differs' } }
            if ($o.Location) { $known++; if ($o.Location -cne $c[0]) { $verdict = 'attribute_differs' } }
            if ($o.System) { $known++; if ($o.System -cne $c[3]) { $verdict = 'attribute_differs' } }
            if ($o.Period) { $known++; if ($o.Period -cne $c[4]) { $verdict = 'attribute_differs' } }
            if ($o.Created -and $subAt) { try { if ([datetime]::Parse($o.Created).ToUniversalTime() -lt $subAt) { $verdict = 'created_before_submission' } } catch { } }
            if ($known -lt 2) { $unver++ }
          }
          if ($verdict -eq 'match' -and $unver -gt 0) { $verdict = 'attributes_unverifiable' }
        }
        $ids = ($newOnes | ForEach-Object { $_.Id }) -join ','
        if ($f[1] -eq 'ambiguous') {
          Out-Line ('ORDER_STILL_AMBIGUOUS current_view=' + $verdict + ' candidate_ids=' + $ids + ' : order-status never changes this state; only the person can leave it (order-resolve or order-clear in a terminal)')
          Fin 5
        }
        if ($verdict -eq 'match') {
          Pend-Save $f 'accepted' $ids
          Out-Line ('ORDER_RECONCILED accepted: ' + $newOnes.Count + ' new order(s) match the confirmed operation by identity and attributes (ids ' + $ids + '); an identical order made elsewhere in the same window cannot be told apart: check the provider panel once; do not order again')
        } else {
          Pend-Save $f 'ambiguous'
          Out-Line ('ORDER_AMBIGUOUS reason=' + $verdict + ' candidate_ids=' + $ids + ' : not chosen automatically. The person checks these orders in the provider panel and names the right ones: order-resolve -OrderId <ids> in a terminal (the person types the code at the prompt; never put the code on a command line). No new purchase until then.')
          Fin 5
        }
      }
    }
  }
  'order-resolve' {
    Orders-Gate
    if (-not (Is-Match $OrderId '[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*')) { Die 'BAD_PARAMETER' '-OrderId must be a comma-separated list of order ids' }
    $typed = Person-Input 'Type the confirmation code from the order window (the person does this; the agent cannot)'
    Lock-Enter
    $f = Pend-Read
    if ($null -eq $f -or $f[1] -ne 'ambiguous') { Die 'NOT_AMBIGUOUS' 'there is no ambiguous order to resolve' }
    if ([int]$f[8] -ge 3) { Die 'RESOLVE_LOCKED' 'resolving is locked after three wrong codes; the person checks the panel and runs order-clear in a terminal' 2 }
    if (-not (Code-Ok $f $typed)) { Wrong-Code $f }
    $r = Call-Api 'GET' '/orders'
    if (-not (Report-Status $r 'order-resolve')) { Fin 3 }
    $beforeIds = @(); if ($f[6]) { $beforeIds = $f[6].Split(',') }
    $cand = @(Get-OrderList $r.Json | Where-Object { $beforeIds -cnotcontains $_.Id } | ForEach-Object { $_.Id })
    foreach ($i in $OrderId.Split(',')) { if ($cand -cnotcontains $i) { Die 'NOT_A_CANDIDATE' 'an id is not among the new orders since the preview; nothing changed' } }
    Pend-Save $f 'accepted' $OrderId
    Out-Line ('ORDER_RESOLVED accepted by the person: ids ' + $OrderId + '; do not order again')
  }
  'order-clear' {
    # the way out of a stuck or damaged state: the PERSON checked the provider panel and found no order (or accepts the risk)
    $a = Person-Input 'Type CLEAR if you checked the provider panel and want to void the stored order state'
    if ($a -cne 'CLEAR') { Die 'CANCELLED' 'nothing changed' }
    Lock-Enter
    if (-not (Test-Path -LiteralPath $PendFile)) { Out-Line 'ORDER_CLEAR nothing to clear'; break }
    $keep = $PendFile + '.cleared-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    Move-Item -LiteralPath $PendFile -Destination $keep
    Out-Line 'ORDER_CLEARED the old state was moved aside (kept for review); a new order-preview is possible'
  }
  'order-unlock' {
    $a = Person-Input 'Type UNLOCK to remove a lock left behind by a helper that died (check that no helper is running)'
    if ($a -cne 'UNLOCK') { Die 'CANCELLED' 'nothing changed' }
    if (Test-Path -LiteralPath $LockFile) { Remove-Item -LiteralPath $LockFile -Force; Out-Line 'LOCK_REMOVED' } else { Out-Line 'NO_LOCK' }
  }
  default {
    Out-Line 'usage: provider-api.ps1 <orders-enable|orders-disable|set-key|key-status|clear-key|auth-check|egress|readonly-check|balance|list|orders|reference|ssh-bind|order-preview|order-create|order-status|order-resolve|order-clear|order-unlock>'
    Fin 2
  }
}
} catch {
  $m = [string]$_.Exception.Message
  if ($m.StartsWith('DIE|')) { $p = $m.Split('|', 3); Write-Host ('PROVIDER_ERROR ' + $p[2]); $rc = [int]$p[1] }
  elseif ($m.StartsWith('EXIT|')) { $rc = [int]$m.Substring(5) }
  else { Write-Host ('PROVIDER_ERROR UNEXPECTED an internal error occurred (' + $_.Exception.GetType().Name + ' at line ' + $_.InvocationInfo.ScriptLineNumber + '); nothing further was done; the message text is not printed because it may contain request data'); $rc = 9 }
  Lock-Leave
  exit $rc
} finally {
  Lock-Leave
}
