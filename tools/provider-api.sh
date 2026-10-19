#!/usr/bin/env bash
# Fixed-purpose helper for the OneDash provider API (adapter 1). It is NOT a general HTTP client.
# The person enters the API key once, locally, in a window the agent does not read (set-key); it lives in the OS secret
# store (macOS Keychain via `security`, Linux libsecret via `secret-tool`), never in a file of the kit or a project.
# If no secret store exists the helper refuses; it never falls back to a plain file.
# Residual risk, stated plainly: the OS store is bound to the USER, not to this process, so another command run by the
# same user (including an agent) could read the key. Protective layers: the key whitelist at the provider, a read-only key
# where the provider offers one, and the tool-permission prompt on every call.
# There is no command for credentials, password change, reinstall, renewal, tariff change or delete.
# Results pass an ALLOW-LIST sanitizer (only known harmless fields survive). A purchase needs a preview, a confirmation
# code SHOWN ONLY TO THE PERSON (the state keeps only its hash), an atomic claim, and a state record BEFORE the request;
# an uncertain result is reconciled by order identity and attributes, never repeated blindly; ambiguity stops for a human.
# Commands: set-key key-status clear-key auth-check balance list orders readonly-check
#           egress [--window|--copy|--show]   (exact address is shown to the person only, never in the agent output)
#           reference --what locations|systems|tariffs [--location L --processor P]
#           ssh-bind --vps-id ID --alias A --user U --identity-file PATH
#           order-preview --location L --processor P --tariff T --system S --period D [--count N] [--show]
#           order-create --confirm CODE | order-status | order-resolve --order-id IDS (the person types the code) | order-clear | order-unlock
set -u
umask 077
API_BASE="https://api.rdp-onedash.ru/api"
ECHO_URL="https://api.ipify.org"
ECHO_URL6="https://api6.ipify.org"
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$HERE/.." && pwd)"
STATE="$KIT_ROOT/state"
PEND="$STATE/provider-order.tsv"
LOCKD="$STATE/provider-order.lock"
ORDERS_FLAG="$STATE/provider-orders-enabled"
ANSWERS_FILE="$STATE/answers.tsv"
EGR="$STATE/provider-egress.tsv"
SSH_CONFIG="$HOME/.ssh/config"
SVC="neuro-lab-vps-onedash"
TAB="$(printf '\t')"
WORK="$(mktemp -d)"
HAVE_LOCK=0

say() { printf '%s\n' "$*"; }
cleanup() { rm -rf "$WORK"; [ "$HAVE_LOCK" -eq 1 ] && rmdir "$LOCKD" 2> /dev/null; HAVE_LOCK=0; }
trap cleanup EXIT
die() { say "PROVIDER_ERROR $1 $2"; exit "${3:-2}"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
shafull() { { sha256sum 2> /dev/null || shasum -a 256; } | cut -d' ' -f1; }

# ---- validation by whole-string pattern matching (never line-by-line grep): a line break can never pass ----
only_chars() { # usage: only_chars VALUE KIND ; empty or any other character => fail
  case "$2" in
    code) case "$1" in ''|*[!A-Za-z0-9_.+-]*) return 1 ;; esac ;;
    word) case "$1" in ''|-*|*[!A-Za-z0-9_-]*) return 1 ;; esac ;;
    user) case "$1" in ''|[!a-z_]*|*[!a-z0-9_-]*) return 1 ;; esac ;;
    hex8) case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 8 ] || return 1 ;;
    ids) case "$1" in ''|*[!A-Za-z0-9_,-]*|,*|*,) return 1 ;; esac ;;
    path) case "$1" in ''|*[!A-Za-z0-9_./:~\\-]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  [ "${#1}" -le 260 ]
}
chk() { [ -z "$2" ] || { only_chars "$2" code && [ "${#2}" -le 40 ]; } || die BAD_PARAMETER "$1 must be a short code"; }
valid_ipv4() { # four decimal octets 0-255
  case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
  oldifs="$IFS"; IFS=.; set -- $1; IFS="$oldifs"; [ $# -eq 4 ] || return 1
  for o in "$@"; do [ "${#o}" -le 3 ] && [ "$o" -le 255 ] || return 1; done; return 0
}
valid_address() {
  a="$1"; [ "${#a}" -le 253 ] || return 1
  valid_ipv4 "$a" && return 0
  case "$a" in *:*) case "$a" in *[!0-9A-Fa-f:.]*) return 1 ;; esac; [ "${#a}" -ge 2 ] && return 0 ;; esac
  case "$a" in ''|*[!A-Za-z0-9.-]*|.*|-*|*.|*-) return 1 ;; esac
  case "$a" in *.*) return 0 ;; esac
  return 1
}

# ---- the paid route is OFF by default and is never switched on by the helper or by an agent on its own ----
# The kit cannot enforce the engine's per-call confirmation (Claude Manual mode / Codex confirmations are engine settings).
# It therefore (1) keeps order-preview/order-create/order-resolve disabled until the PERSON enables them in a terminal,
# and (2) refuses order-preview/order-create/order-resolve/ssh-bind unless a SAFE permission mode (Claude manual / Codex default) is recorded in the state answers (allow-list).
permission_gate() { # allow-list: at least one RECORDED safe mode (Claude manual, Codex default) and no recorded unsafe one
  m=""; ok=""
  if [ -f "$ANSWERS_FILE" ]; then
    m="$(awk -F'\t' '($1=="claude_permission" || $1=="codex_confirmations") && ($2=="bypass" || $2=="none") {print $2; exit}' "$ANSWERS_FILE")"
    ok="$(awk -F'\t' '($1=="claude_permission" && $2=="manual") || ($1=="codex_confirmations" && $2=="default") {print "ok"; exit}' "$ANSWERS_FILE")"
  fi
  [ -z "$m" ] || die PERMISSION_MODE_UNSAFE "the recorded engine permission mode is $m; sensitive provider commands need a per-call confirmation; switch the mode back first"
  [ -n "$ok" ] || die PERMISSION_MODE_UNKNOWN "no safe engine permission mode (Claude manual / Codex default confirmations) is recorded in the state answers; the participant records it with the diagnostics first. This is a check of a recorded answer, not of the engine itself"
}
# a step that only a person at a terminal can do (the agent's tool calls have redirected input); result in $ANS
person_input() { # prompt
  # PERSON_INPUT_HOOK
  [ -t 0 ] || die INTERACTIVE_ONLY "this step must be done by the person in a normal terminal window"
  printf '%s: ' "$1"; read -r ANS
}
orders_gate() {
  permission_gate
  [ -f "$ORDERS_FLAG" ] || die ORDERS_DISABLED "the paid-order route is switched off (default). Only the person can switch it on, in a terminal: provider-api.sh orders-enable. Until then use the provider panel"
}

# ---- secret store ----
store_kind() {
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v security > /dev/null 2>&1; then echo keychain
  elif command -v secret-tool > /dev/null 2>&1; then echo libsecret
  else echo none; fi
}
key_present() {
  case "$(store_kind)" in
    keychain) security find-generic-password -s "$SVC" -a "$(id -un)" > /dev/null 2>&1 ;;
    libsecret) [ -n "$(secret-tool lookup service "$SVC" 2> /dev/null)" ] ;;
    *) return 1 ;;
  esac
}
key_text() {
  case "$(store_kind)" in
    keychain) security find-generic-password -s "$SVC" -a "$(id -un)" -w 2> /dev/null ;;
    libsecret) secret-tool lookup service "$SVC" 2> /dev/null ;;
  esac
}

# ---- JSON via JSON::PP (core perl on macOS and Linux). Sanitizer = ALLOW-LIST. ----
sanitize() { # stdin = JSON ; stdout = compact sanitized JSON
  perl -MJSON::PP -e '
    my %safe = map { $_ => 1 } qw(type data id order_id vps_id status state name title price cost currency balance location system os period tariff tariff_id processor cpu cores ram disk count created_at updated_at expires_at ends_at);
    sub rt { my $v = shift; return "[redacted]" if $v =~ /bearer\s+\S+|https?:\/\/\S+|(\d{1,3}\.){3}\d{1,3}|([0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}|[A-Za-z0-9-]+\.[A-Za-z]{2,}|[A-Za-z0-9+\/_=-]{24,}/i; return length($v) > 80 ? substr($v, 0, 80) : $v; }
    sub cl { my ($v, $n) = @_;
      return undef unless defined $v;
      return "[redacted]" if length($n) && !$safe{lc $n};
      if (ref $v eq "HASH") { my %o; my $i = 0; for my $k (sort keys %$v) { if ($safe{lc $k}) { $o{$k} = cl($v->{$k}, $k) } else { $i++; $o{"redacted_field_$i"} = "[redacted]" } } return \%o }
      if (ref $v eq "ARRAY") { return [ map { cl($_, $n) } @$v ] }
      if (ref $v eq "JSON::PP::Boolean") { return $v }
      return $v if !ref $v && $v =~ /\A-?\d+(\.\d+)?\z/;
      return rt("$v");
    }
    local $/; my $t = <STDIN>; my $d = eval { decode_json($t) }; if (!defined $d) { print "{\"error\":\"unparsable answer\"}"; exit 0 }
    my $o = JSON::PP->new->canonical->encode(cl($d, "")); print length($o) > 6000 ? substr($o, 0, 6000) . "...[truncated]" : $o;'
}
# top-level data items as lines: id|tariff|location|system|period|created|address (a non-blank separator, so empty fields survive read)
items_tsv() {
  perl -MJSON::PP -e '
    local $/; my $t = <STDIN>; my $d = eval { decode_json($t) }; exit 0 unless ref $d eq "HASH" && ref $d->{data} eq "ARRAY";
    sub p { my ($o, @k) = @_; for my $k (@k) { return $o->{$k} if defined $o->{$k} && !ref $o->{$k} && length $o->{$k} } return "" }
    for my $o (@{ $d->{data} }) { next unless ref $o eq "HASH"; my $id = p($o, qw(id order_id vps_id)); next unless length $id;
      my @f = ($id, p($o, qw(tariff_id tariff)), p($o, qw(location)), p($o, qw(system os)), p($o, qw(period)), p($o, qw(created_at created date_create)), p($o, qw(ip ipv4 ip_address main_ip host address)));
      s/[\t\r\n|]/ /g for @f; print join("|", @f), "\n"; }'
}
body_type_true() { perl -MJSON::PP -e 'local $/; my $t = <STDIN>; my $d = eval { decode_json($t) }; exit(ref $d eq "HASH" && defined $d->{type} && $d->{type} == 1 ? 0 : 1)' < "$1"; }

# ---- show something to the PERSON only (separate window); never through the output or a command line ----
show_to_person() { # title file-with-text
  # PERSON_HOOK
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v osascript > /dev/null 2>&1; then
    tf="$(mktemp)"; chmod 600 "$tf"; cat "$2" > "$tf"
    if osascript -e "tell application \"Terminal\" to do script \"clear; cat '$tf'; rm -f '$tf'; echo; read -p 'Press Enter to close' x; exit\"" > /dev/null 2>&1; then
      for _i in 1 2 3 4 5 6 7 8; do [ -f "$tf" ] || return 0; sleep 1; done
    fi
    rm -f "$tf"
  fi
  return 1
}

# ---- the only request path (fixed method/path allowlist, https only, no redirects); key goes to curl through stdin ----
call_api() { # method path [json-body] [query]  -> HTTP status in $STATUS, body in $BODY_FILE
  m="$1"; p="$2"; body="${3:-}"; q="${4:-}"
  case "$m $p" in
    "GET /auth/check"|"GET /balance"|"GET /vps"|"GET /orders"|"GET /locations"|"GET /systems"|"GET /tariffs"|"POST /vps/create") ;;
    *) die NOT_ALLOWED "operation is not part of this helper: $m $p" ;;
  esac
  key_present || die NO_KEY "no API key stored; the person runs: provider-api.sh set-key"
  k="$(key_text)"
  case "$k" in ''|*[!A-Za-z0-9._~+/=-]*) die NO_KEY_FORMAT "the stored key has an unexpected format; the person runs set-key again" ;; esac
  BODY_FILE="$WORK/body.$RANDOM"; HDR_FILE="$WORK/hdr.$RANDOM"
  if [ "$m" = "POST" ]; then
    STATUS="$({ printf 'header = "Authorization: Bearer %s"\n' "$k"; } | curl -sS --config - --proto '=https' --proto-redir '=https' -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}' --max-time 60 \
      -H 'Accept: application/json' -H 'Content-Type: application/json' -X POST --data "$body" "$API_BASE$p$q" 2> /dev/null)" || STATUS=0
  else
    STATUS="$({ printf 'header = "Authorization: Bearer %s"\n' "$k"; } | curl -sS --config - --proto '=https' --proto-redir '=https' -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}' --max-time 30 \
      -H 'Accept: application/json' "$API_BASE$p$q" 2> /dev/null)" || STATUS=0
  fi
  k=""
  case "$STATUS" in ''|*[!0-9]*) STATUS=0 ;; esac
  [ "$STATUS" = "000" ] && STATUS=0
  [ -f "$BODY_FILE" ] || : > "$BODY_FILE"
  [ -f "$HDR_FILE" ] || : > "$HDR_FILE"
}
report_status() { # what -> 0 when 2xx
  case "$STATUS" in
    2??) return 0 ;;
    0) say "PROVIDER_RESULT $1 status=UNREACHABLE (network or VPN path; the VPN stays on; not repeated blindly)" ;;
    401) say "PROVIDER_RESULT $1 status=KEY_REJECTED (the stored key is not accepted; the person runs set-key again)" ;;
    403) say "PROVIDER_RESULT $1 status=IP_NOT_ALLOWED (the address of this environment is not in the key whitelist; run egress --window, the person updates the list; no bypass)" ;;
    429) ra="$(tr -d '\r' < "$HDR_FILE" | awk -F': ' 'tolower($1)=="retry-after"{print $2; exit}')"; case "$ra" in ''|*[!0-9]*) ra=unparsable ;; esac; [ "${#ra}" -le 6 ] || ra=unparsable; say "PROVIDER_RESULT $1 status=RATE_LIMITED retry_after=$ra" ;;
    *) say "PROVIDER_RESULT $1 status=HTTP_$STATUS" ;;
  esac
  return 1
}

# ---- order state: atomic claim, fail-closed reads, atomic writes ----
lock_enter() {
  mkdir -p "$STATE"
  stale=""
  if [ -d "$LOCKD" ]; then
    mt="$(stat -c %Y "$LOCKD" 2> /dev/null)"; case "$mt" in ''|*[!0-9]*) mt="$(stat -f %m "$LOCKD" 2> /dev/null)" ;; esac
    case "$mt" in ''|*[!0-9]*) mt=$(date +%s) ;; esac
    [ $(( $(date +%s) - mt )) -gt 180 ] && stale=" The lock is older than 3 minutes: a helper probably died; the person runs order-unlock in a terminal (the lock is never taken over automatically)."
  fi
  mkdir "$LOCKD" 2> /dev/null || die ORDER_BUSY "another order operation holds the lock; nothing was sent; wait and run order-status.$stale" 8
  HAVE_LOCK=1
}
# pending file: code_hash state expiry canon before_count nonce before_ids matched_ids wrong_codes submitted_at
pend_load() { # returns 1 when there is no file; dies (fail-closed) when the file is damaged
  P_CH=""; P_ST=""; P_EXP=""; P_CANON=""; P_BC=0; P_NONCE=""; P_IDS=""; P_MATCH=""; P_WRONG=0; P_SUB=""
  [ -f "$PEND" ] || return 1
  P_CH="$(head -n1 "$PEND" | cut -f1)"; P_ST="$(head -n1 "$PEND" | cut -f2)"; P_EXP="$(head -n1 "$PEND" | cut -f3)"; P_CANON="$(head -n1 "$PEND" | cut -f4)"; P_BC="$(head -n1 "$PEND" | cut -f5)"
  P_NONCE="$(head -n1 "$PEND" | cut -f6)"; P_IDS="$(head -n1 "$PEND" | cut -f7)"; P_MATCH="$(head -n1 "$PEND" | cut -f8)"; P_WRONG="$(head -n1 "$PEND" | cut -f9)"; P_SUB="$(head -n1 "$PEND" | cut -f10)"
  case "$P_ST" in previewed|submitted|accepted|rejected|uncertain|ambiguous|void) ;; *) die STATE_INVALID "the order state file is damaged or unknown; this is treated as BLOCKING. The person checks the provider panel and then runs order-clear in a terminal" 7 ;; esac
  [ "${#P_CH}" -eq 64 ] && [ -n "$P_NONCE" ] && [ -n "$P_CANON" ] || die STATE_INVALID "the order state file is damaged or unknown; this is treated as BLOCKING. The person checks the provider panel and then runs order-clear in a terminal" 7
  [ -n "$P_WRONG" ] || P_WRONG=0
  return 0
}
pend_save() { # state [matched] [wrong] [submitted_at]
  mkdir -p "$STATE"; m="${2:-$P_MATCH}"; w="${3:-$P_WRONG}"; sa="${4:-$P_SUB}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$P_CH" "$1" "$P_EXP" "$P_CANON" "$P_BC" "$P_NONCE" "$P_IDS" "$m" "$w" "$sa" > "$PEND.tmp" && mv -f "$PEND.tmp" "$PEND" || {
    if [ "${REQ_SENT:-0}" = 1 ]; then die STATE_WRITE_FAILED_AFTER_REQUEST "the request WAS sent but the state could not be updated; the previous blocking state stays; run order-status and do NOT order again" 4
    else die STATE_WRITE_FAILED "the order state could not be written; nothing was sent" 7; fi
  }
  P_ST="$1"; P_MATCH="$m"; P_WRONG="$w"; P_SUB="$sa"
}
code_ok() { only_chars "$1" hex8 && [ "$(printf '%s' "$1|$P_NONCE" | shafull)" = "$P_CH" ]; }
wrong_code() {
  n=$((P_WRONG + 1))
  if [ "$P_ST" = "ambiguous" ]; then
    pend_save ambiguous "" "$n"
    if [ "$n" -ge 3 ]; then die RESOLVE_LOCKED "three wrong codes: resolving is locked; the state stays ambiguous and no new purchase is possible; the person checks the panel and runs order-clear in a terminal"; fi
    die CONFIRM_MISMATCH "the confirmation code does not match; attempts left $((3 - n))"
  fi
  if [ "$n" -ge 3 ]; then pend_save void "" "$n"; die CONFIRM_MISMATCH "three wrong codes: this preview is void; nothing was sent; run order-preview again"; fi
  pend_save "$P_ST" "" "$n"; die CONFIRM_MISMATCH "the confirmation code does not match; nothing was sent; attempts left $((3 - n))"
}

CMD="${1:-}"; [ $# -gt 0 ] && shift
WHAT=""; LOC=""; PROC=""; TARIFF=""; SYS=""; PERIOD=""; COUNT=1; CONFIRM=""; SHOW=0; WIN=0; COPY=0
ORDER_ID=""; VPS_ID=""; ALIAS=""; SSHUSER=""; IDFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --what) shift; WHAT="${1:-}" ;;
    --location) shift; LOC="${1:-}" ;;
    --processor) shift; PROC="${1:-}" ;;
    --tariff) shift; TARIFF="${1:-}" ;;
    --system) shift; SYS="${1:-}" ;;
    --period) shift; PERIOD="${1:-}" ;;
    --count) shift; COUNT="${1:-1}" ;;
    --confirm) shift; CONFIRM="${1:-}" ;;
    --order-id) shift; ORDER_ID="${1:-}" ;;
    --vps-id) shift; VPS_ID="${1:-}" ;;
    --alias) shift; ALIAS="${1:-}" ;;
    --user) shift; SSHUSER="${1:-}" ;;
    --identity-file) shift; IDFILE="${1:-}" ;;
    --show) SHOW=1 ;;
    --window) WIN=1 ;;
    --copy) COPY=1 ;;
    *) die BAD_PARAMETER "unknown option" ;;
  esac
  shift
done

case "$CMD" in
  set-key)
    [ -t 0 ] || die INTERACTIVE_ONLY "set-key must be run by the person in a normal terminal window (input is redirected)"
    case "$(store_kind)" in
      keychain) security add-generic-password -U -s "$SVC" -a "$(id -un)" -w && say "KEY_STORED store=macos_keychain (the key was not displayed and is not in the project)" ;;
      libsecret) secret-tool store --label="$SVC" service "$SVC" && say "KEY_STORED store=libsecret (the key was not displayed and is not in the project)" ;;
      *) die NO_SECURE_STORE "no OS secret store found (macOS Keychain or libsecret); nothing stored; use the provider panel route" ;;
    esac ;;
  key-status) if key_present; then say "KEY_PRESENT store=$(store_kind)"; else say "KEY_ABSENT"; fi ;;
  clear-key)
    case "$(store_kind)" in
      keychain) security delete-generic-password -s "$SVC" -a "$(id -un)" > /dev/null 2>&1 && say KEY_REMOVED || say KEY_ABSENT ;;
      libsecret) secret-tool clear service "$SVC" > /dev/null 2>&1; if key_present; then say "KEY_REMOVE_FAILED the key is still stored; remove it with the system key manager"; exit 3; else say KEY_REMOVED; fi ;;
      *) say KEY_ABSENT ;;
    esac ;;
  auth-check) call_api GET /auth/check; if report_status auth-check; then say "PROVIDER_RESULT auth-check status=OK"; sanitize < "$BODY_FILE"; echo; fi ;;
  balance) call_api GET /balance; if report_status balance; then say "PROVIDER_RESULT balance status=OK"; sanitize < "$BODY_FILE"; echo; fi ;;
  list) call_api GET /vps; if report_status list; then say "PROVIDER_RESULT list status=OK"; sanitize < "$BODY_FILE"; echo; fi ;;
  orders) call_api GET /orders; if report_status orders; then say "PROVIDER_RESULT orders status=OK"; sanitize < "$BODY_FILE"; echo; fi ;;
  reference)
    case "$WHAT" in locations|systems|tariffs) ;; *) die BAD_PARAMETER "--what must be locations, systems or tariffs" ;; esac
    chk Location "$LOC"; chk Processor "$PROC"
    q=""; if [ "$WHAT" = "tariffs" ] && [ -n "$LOC" ]; then q="?location=$LOC"; [ -n "$PROC" ] && q="$q&processor=$PROC"; fi
    call_api GET "/$WHAT" "" "$q"; if report_status "reference-$WHAT"; then say "PROVIDER_RESULT reference-$WHAT status=OK"; sanitize < "$BODY_FILE"; echo; fi ;;
  egress)
    v4="$(curl -4 -sS --proto '=https' --max-time 15 "$ECHO_URL" 2> /dev/null | tr -d '\r\n ')"; v6="$(curl -6 -sS --proto '=https' --max-time 15 "$ECHO_URL6" 2> /dev/null | tr -d '\r\n ')"
    valid_ipv4 "$v4" || v4=""
    case "$v6" in *:*) case "$v6" in *[!0-9A-Fa-f:]*) v6="" ;; esac ;; *) v6="" ;; esac
    [ -n "$v4" ] || [ -n "$v6" ] || die ECHO_UNREACHABLE "could not determine any address; nothing changed" 3
    hsh="$(printf '%s' "$v4|$v6" | shafull)"
    prev=""; [ -f "$EGR" ] && prev="$(cut -f1 "$EGR" | head -n1)"
    mkdir -p "$STATE"; printf '%s\t%s\n' "$hsh" "$(now)" > "$EGR"
    st="FIRST_SEEN"; if [ -n "$prev" ]; then [ "$prev" = "$hsh" ] && st="UNCHANGED" || st="CHANGED"; fi
    m4=none; [ -n "$v4" ] && m4="$(printf '%s' "$v4" | cut -d. -f1-2).*.*"
    m6=none; [ -n "$v6" ] && m6="$(printf '%s' "$v6" | cut -d: -f1-2):*"
    r4=no; r6=no
    [ "$(curl -4 -s --proto '=https' -o /dev/null --max-time 8 -w '%{http_code}' "$API_BASE/ping" 2> /dev/null)" != "000" ] && r4=yes
    [ "$(curl -6 -s --proto '=https' -o /dev/null --max-time 8 -w '%{http_code}' "$API_BASE/ping" 2> /dev/null)" != "000" ] && r6=yes
    need=ipv4; if [ "$r4" = no ] && [ "$r6" = yes ]; then need=ipv6; elif [ "$r4" = yes ] && [ "$r6" = yes ] && [ -n "$v6" ]; then need=both_v4_and_v6; fi
    say "EGRESS $st ipv4=$m4 ipv6=$m6 provider_reachable_ipv4=$r4 provider_reachable_ipv6=$r6 add_to_whitelist=$need (measured from THIS process and network path, the one that makes the API requests; the VPN stays on; no address is written to the project or printed in full here)"
    txt=""; [ -n "$v4" ] && txt="IPv4: $v4"; [ -n "$v6" ] && txt="$txt${txt:+
}IPv6: $v6"
    if [ "$WIN" -eq 1 ]; then
      printf 'Add the address(es) below to the API key whitelist in the provider panel (add_to_whitelist=%s):\n\n%s\n' "$need" "$txt" > "$WORK/win.txt"
      if show_to_person "API key whitelist" "$WORK/win.txt"; then say "EGRESS_WINDOW_OPENED the exact address is shown only in the new window"; else say "EGRESS_WINDOW_UNSUPPORTED no window mechanism on this system; use --copy or --show in a terminal"; fi
    fi
    if [ "$COPY" -eq 1 ]; then
      cp_ok=0
      if command -v pbcopy > /dev/null 2>&1; then printf '%s' "$txt" | pbcopy && cp_ok=1
      elif command -v wl-copy > /dev/null 2>&1; then printf '%s' "$txt" | wl-copy && cp_ok=1
      elif command -v xclip > /dev/null 2>&1; then printf '%s' "$txt" | xclip -selection clipboard && cp_ok=1
      elif command -v clip.exe > /dev/null 2>&1; then printf '%s' "$txt" | clip.exe && cp_ok=1; fi
      if [ "$cp_ok" -eq 1 ]; then say "EGRESS_COPIED the address(es) are in the clipboard; clear it after use; the clipboard is readable by other local programs"; else say "EGRESS_COPY_FAILED no clipboard tool; use --window or --show in a terminal"; fi
    fi
    if [ "$SHOW" -eq 1 ]; then if [ -t 1 ]; then printf '%s\n' "$txt" | sed 's/^/EGRESS_FULL /'; else say "EGRESS_SHOW_REFUSED output is redirected; use --window"; fi; fi ;;
  readonly-check)
    key_present || { say "READONLY_CHECK RESULT NOT_TESTED reason=no_key (the person runs set-key; nothing was requested)"; exit 3; }
    call_api GET /auth/check; report_status readonly-auth || { say "READONLY_CHECK RESULT FAIL step=authorization (see the status above; later steps not run)"; exit 3; }
    say "READONLY_CHECK step=authorization PASS"
    v4="$(curl -4 -sS --proto '=https' --max-time 15 "$ECHO_URL" 2> /dev/null | tr -d '\r\n ')"; v6="$(curl -6 -sS --proto '=https' --max-time 15 "$ECHO_URL6" 2> /dev/null | tr -d '\r\n ')"
    if [ -n "$v4" ] || [ -n "$v6" ]; then say "READONLY_CHECK step=egress PASS families=$([ -n "$v4" ] && echo ipv4 || echo -),$([ -n "$v6" ] && echo ipv6 || echo -) (exact address: run egress --window)"; else say "READONLY_CHECK step=egress FAIL echo_unreachable"; fi
    for w in locations systems tariffs; do
      call_api GET "/$w"; if report_status "readonly-$w"; then say "READONLY_CHECK step=catalog_$w PASS items=$(items_tsv < "$BODY_FILE" | wc -l | tr -d ' ')"; else say "READONLY_CHECK step=catalog_$w FAIL"; fi
    done
    call_api GET /vps; if report_status readonly-vps; then say "READONLY_CHECK step=existing_servers PASS items=$(items_tsv < "$BODY_FILE" | wc -l | tr -d ' ') (contents not shown)"; else say "READONLY_CHECK step=existing_servers FAIL"; fi
    say "READONLY_CHECK RESULT DONE (read-only; shape of the real answers is what this check confirms)" ;;
  ssh-bind)
    permission_gate
    [ -n "$VPS_ID" ] && [ -n "$ALIAS" ] && [ -n "$SSHUSER" ] && [ -n "$IDFILE" ] || die MISSING_PARAMETER "--vps-id --alias --user --identity-file are required"
    only_chars "$VPS_ID" word && [ "${#VPS_ID}" -le 40 ] || die BAD_PARAMETER "vps id must be a short id"
    only_chars "$ALIAS" word && [ "${#ALIAS}" -le 40 ] || die BAD_PARAMETER "alias must be 1-40 chars of A-Za-z0-9_- and must not start with -"
    only_chars "$SSHUSER" user && [ "${#SSHUSER}" -le 32 ] || die BAD_PARAMETER "user must be a plain lowercase account name"
    only_chars "$IDFILE" path || die BAD_PARAMETER "identity file must be a plain path without spaces, quotes, % or # (copy the key to such a path)"
    [ -f "$IDFILE" ] || die IDENTITY_NOT_FOUND "the key file does not exist (nothing written)"
    call_api GET /vps; report_status ssh-bind || exit 3
    line="$(items_tsv < "$BODY_FILE" | awk -F'|' -v id="$VPS_ID" '$1==id{print; exit}')"
    [ -n "$line" ] || die VPS_NOT_FOUND "no server with this id in the list; nothing written" 3
    addr="$(printf '%s' "$line" | cut -d'|' -f7)"
    [ -n "$addr" ] || die ADDRESS_FIELD_NOT_FOUND "the list answer has no known address field (shape not confirmed); use the provider panel; nothing written" 3
    valid_address "$addr" || die ADDRESS_INVALID "the address field is not a plain IP or host name; nothing written (no config injection)" 3
    mkdir -p "$(dirname "$SSH_CONFIG")"
    had=0; [ -f "$SSH_CONFIG" ] && had=1; warn=""
    if [ "$had" -eq 1 ]; then
      case "$(head -c2 "$SSH_CONFIG" | od -An -tx1 | tr -d ' \n')" in fffe|feff) die CONFIG_ENCODING_UNSUPPORTED "the SSH config is UTF-16; it is not modified; convert it to UTF-8 first" ;; esac
      if perl -pe 's/^\xEF\xBB\xBF// if $. == 1' "$SSH_CONFIG" | tr -d '\r' | tr '"=' '  ' | awk -v a="$ALIAS" 'tolower($1)=="host" { for (i = 2; i <= NF; i++) { t = $i; if (t == "*" || substr(t, 1, 1) == "!" || t !~ /[*?]/) continue; gsub(/[.+^$(){}|\\[\]]/, "\\&", t); gsub(/\*/, ".*", t); gsub(/\?/, ".", t); if (tolower(a) ~ ("^" tolower(t) "$")) f = 1 } } END { exit f ? 0 : 1 }'; then die ALIAS_COVERED_BY_PATTERN "an existing Host pattern already covers this alias; no entry is modified; choose another alias"; fi
      if perl -pe 's/^\xEF\xBB\xBF// if $. == 1' "$SSH_CONFIG" | tr -d '\r' | tr '"=' '  ' | awk -v a="$ALIAS" 'tolower($1)=="host" { for (i = 2; i <= NF; i++) if (tolower($i) == tolower(a)) f = 1 } END { exit f ? 0 : 1 }'; then die ALIAS_EXISTS "an entry with this alias already exists; no existing entry is modified; choose another alias"; fi
      grep -Eiq '^[[:space:]]*Include[[:space:]]' "$SSH_CONFIG" && warn="$warn note=config_has_Include_check_alias_in_included_files"
      grep -Eiq '^[[:space:]]*Match[[:space:]]' "$SSH_CONFIG" && warn="$warn note=config_has_Match_blocks_check_order"
      perl -pe 's/^\xEF\xBB\xBF// if $. == 1' "$SSH_CONFIG" | tr -d '\r' | tr '"=' '  ' | awk 'BEGIN{g=1} tolower($1)=="host" {g=($2=="*"); next} tolower($1)=="match" {g=0; next} g && tolower($1)=="stricthostkeychecking" && (tolower($2)=="no" || tolower($2)=="accept-new") {f=1} END{exit f?0:1}' && warn="$warn warning=global_Host_star_StrictHostKeyChecking_may_override_ask"
    fi
    bk=no; before_size=0; before_hash=""
    if [ "$had" -eq 1 ]; then cp "$SSH_CONFIG" "$SSH_CONFIG.neuro-lab-backup-$(date -u +%Y%m%d%H%M%S)" || die BACKUP_FAILED "the backup copy of the SSH config was not created; nothing written" 4; bk=yes
      if [ -s "$SSH_CONFIG" ] && [ "$(tail -c1 "$SSH_CONFIG" | od -An -c | tr -d ' ')" != '\n' ]; then printf '\n' >> "$SSH_CONFIG"; fi
      before_hash="$(shafull < "$SSH_CONFIG")"; before_size="$(wc -c < "$SSH_CONFIG" | tr -d ' ')"
    fi
    { printf '# neuro-lab-vps begin %s\nHost %s\n    HostName %s\n    User %s\n    Port 22\n    IdentityFile %s\n    IdentitiesOnly yes\n    StrictHostKeyChecking ask\n# neuro-lab-vps end %s\n' "$ALIAS" "$ALIAS" "$addr" "$SSHUSER" "$IDFILE" "$ALIAS"; } >> "$SSH_CONFIG"
    if [ "$had" -eq 1 ]; then [ "$(head -c "$before_size" "$SSH_CONFIG" | shafull)" = "$before_hash" ] || die VERIFY_FAILED "the config check after writing failed; restore from the backup" 4; fi
    grep -qx "Host $ALIAS" "$SSH_CONFIG" || die VERIFY_FAILED "the entry is missing after writing; restore from the backup" 4
    addr=""
    say "SSH_CONFIG_BOUND alias=$ALIAS user=$SSHUSER address=written_not_shown backup=$bk existing_entries=unchanged host_key=NOT_ACCEPTED (known_hosts untouched; the person compares the fingerprint with the provider panel at stage 4 before the first connection)$warn" ;;
  orders-enable)
    [ -t 0 ] || die INTERACTIVE_ONLY "orders-enable must be run by the person in a normal terminal window"
    permission_gate
    printf 'Type ENABLE to switch on the EXPERIMENTAL paid-order route (every order-create still needs the engine confirmation of each call): '; read -r ans
    [ "$ans" = "ENABLE" ] || die CANCELLED "nothing changed"
    mkdir -p "$STATE"; now > "$ORDERS_FLAG"
    say "ORDERS_ENABLED (experimental; the real provider API is not verified; switch off with orders-disable)" ;;
  orders-disable) rm -f "$ORDERS_FLAG"; say "ORDERS_DISABLED_NOW" ;;
  order-preview)
    orders_gate
    [ -n "$LOC" ] && [ -n "$PROC" ] && [ -n "$TARIFF" ] && [ -n "$SYS" ] && [ -n "$PERIOD" ] || die MISSING_PARAMETER "--location --processor --tariff --system --period are required"
    chk Location "$LOC"; chk Processor "$PROC"; chk Tariff "$TARIFF"; chk System "$SYS"; chk Period "$PERIOD"
    case "$COUNT" in ''|*[!0-9]*) die BAD_PARAMETER "count must be 1..10" ;; esac
    [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 10 ] || die BAD_PARAMETER "count must be 1..10"
    lock_enter
    if pend_load; then case "$P_ST" in submitted|uncertain|ambiguous) die ORDER_UNRECONCILED "a previous order is submitted, uncertain or ambiguous; run order-status first; never a second purchase blindly" ;; esac; fi
    call_api GET /tariffs "" "?location=$LOC&processor=$PROC"; report_status order-preview || exit 3
    items_tsv < "$BODY_FILE" | awk -F'|' -v id="$TARIFF" '$1==id{f=1} END{exit f?0:1}' || die TARIFF_NOT_FOUND "the tariff id is not offered for this location and processor; nothing prepared" 3
    tariff_json="$(perl -MJSON::PP -e 'local $/; my $t = <STDIN>; my $d = eval { decode_json($t) }; for my $o (@{ $d->{data} || [] }) { if ("$o->{id}" eq $ARGV[0]) { print encode_json({ data => [$o] }); exit } }' "$TARIFF" < "$BODY_FILE" | sanitize)"
    canon="$LOC|$PROC|$TARIFF|$SYS|$PERIOD|$COUNT"
    nonce="$(od -An -N4 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')"; [ -n "$nonce" ] || nonce="$$$(date +%s)"
    code="$(od -An -N8 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n' | shafull | cut -c1-8)"
    only_chars "$code" hex8 || code="$(printf '%s' "$canon$nonce$$$(date +%s)" | shafull | cut -c1-8)"
    call_api GET /orders; [ "$STATUS" = "200" ] || die BASELINE_UNAVAILABLE "the order list could not be read, so a later reconciliation would be impossible; nothing prepared" 3
    ids="$(items_tsv < "$BODY_FILE" | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"; before="$(items_tsv < "$BODY_FILE" | wc -l | tr -d ' ')"
    exp="$(date -u -d '+15 minutes' +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -v+15M +%Y-%m-%dT%H:%M:%SZ)"
    P_CH="$(printf '%s' "$code|$nonce" | shafull)"; P_EXP="$exp"; P_CANON="$canon"; P_BC="$before"; P_NONCE="$nonce"; P_IDS="$ids"; P_MATCH=""; P_WRONG=0; P_SUB=""
    pend_save previewed
    printf '%s\n' "ORDER TO CONFIRM (real spending when confirmed):" "  provider=onedash location=$LOC processor=$PROC system=$SYS period=$PERIOD count=$COUNT" "  tariff: $tariff_json" "" "  CONFIRMATION CODE: $code" "  valid until $exp" "" "Say this code to the agent only if you want exactly this order." > "$WORK/pv.txt"
    if [ "$SHOW" -eq 1 ] && [ -t 1 ]; then cat "$WORK/pv.txt"
    elif ! show_to_person "Order confirmation" "$WORK/pv.txt"; then pend_save void; die CODE_NOT_SHOWN "could not open a window for the person; the preview is void; run order-preview --show in a normal terminal window yourself" 3; fi
    say "ORDER_PREVIEW (nothing was ordered, nothing was charged)"
    say "  provider=onedash location=$LOC processor=$PROC system=$SYS period=$PERIOD count=$COUNT"
    say "  tariff: $tariff_json"
    say "  orders_before=$before valid_until=$exp"
    say "  CONFIRM_CODE=shown_to_the_person_only (a window shows the order and the code; the state stores only a hash; the agent cannot read the code and must not invent one)" ;;
  order-create)
    orders_gate
    lock_enter
    pend_load || die NO_PREVIEW "run order-preview first"
    [ "$P_ST" = "previewed" ] || die ORDER_NOT_PREVIEWED "state is $P_ST; reconcile with order-status; no second purchase blindly"
    [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \< "$P_EXP" ] || die PREVIEW_EXPIRED "preview expired; run order-preview again"
    code_ok "$CONFIRM" || wrong_code
    # one-time redemption: a marker created atomically and NEVER deleted, so one code can start at most one request even if the lock is lost
    mkdir "$STATE/redeemed-$(printf '%s' "$P_CH" | cut -c1-16)" 2> /dev/null || die CODE_ALREADY_REDEEMED "this confirmation code was already used to start a request; nothing was sent; run order-status and never repeat" 8
    pend_save submitted "" 0 "$(now)"
    REQ_SENT=1
    oldifs="$IFS"; IFS='|'; set -- $P_CANON; IFS="$oldifs"; cl="$1"; cp="$2"; ct="$3"; cs="$4"; cd="$5"; cc="$6"
    call_api POST /vps/create "{\"period\":\"$cd\",\"tariff_id\":\"$ct\",\"location\":\"$cl\",\"processor\":\"$cp\",\"system\":\"$cs\",\"count\":$cc,\"confirm\":true}"
    type_ok=0; body_type_true "$BODY_FILE" && type_ok=1
    case "$STATUS" in
      2??) if [ "$type_ok" -eq 1 ]; then pend_save accepted; say "ORDER_ACCEPTED (asynchronous; reconcile with order-status, do not repeat)"; sanitize < "$BODY_FILE"; echo
           else pend_save uncertain; say "ORDER_UNCERTAIN status=$STATUS (2xx without type=true; run order-status to reconcile; do NOT order again)"; exit 4; fi ;;
      400|401|402|403|404|422) pend_save rejected; say "ORDER_REJECTED status=HTTP_$STATUS (the provider refused; nothing was created; a new preview is needed)"; exit 6 ;;
      *) pend_save uncertain; say "ORDER_UNCERTAIN status=$STATUS (the result is unknown, including 3xx, 409 and 5xx; run order-status to reconcile; do NOT order again)"; exit 4 ;;
    esac ;;
  order-status)
    lock_enter
    pend_load || { say "ORDER_STATUS none (no preview or order recorded)"; exit 0; }
    call_api GET /orders; report_status order-status || exit 3
    items_tsv < "$BODY_FILE" > "$WORK/all.tsv"
    now_n="$(wc -l < "$WORK/all.tsv" | tr -d ' ')"
    : > "$WORK/new.tsv"
    while IFS='|' read -r oid otar oloc osys oper ocre oaddr; do
      case ",$P_IDS," in *",$oid,"*) ;; *) printf '%s|%s|%s|%s|%s|%s\n' "$oid" "$otar" "$oloc" "$osys" "$oper" "$ocre" >> "$WORK/new.tsv" ;; esac
    done < "$WORK/all.tsv"
    new_n="$(wc -l < "$WORK/new.tsv" | tr -d ' ')"
    oldifs="$IFS"; IFS='|'; set -- $P_CANON; IFS="$oldifs"; cl="$1"; cp="$2"; ct="$3"; cs="$4"; cd="$5"; cc="$6"
    before_n=0; [ -n "$P_IDS" ] && before_n="$(printf '%s' "$P_IDS" | tr ',' '\n' | wc -l | tr -d ' ')"
    say "ORDER_STATUS local_state=$P_ST orders_before=$before_n orders_now=$now_n new_orders=$new_n expected=$cc"
    case "$P_ST" in uncertain|submitted|ambiguous)
      if [ "$new_n" -eq 0 ]; then
        say "ORDER_UNRESOLVED no new order is visible yet; wait and check again (bounded), or look in the provider panel; do NOT order again until this is resolved by the person"
      else
        verdict=match; unver=0
        sub_cut=""; [ -n "$P_SUB" ] && sub_cut="$(date -u -d "$P_SUB -2 minutes" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -j -v-2M -f %Y-%m-%dT%H:%M:%SZ "$P_SUB" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null)"
        if [ "$new_n" -ne "$cc" ]; then verdict=count_differs
        else
          while IFS='|' read -r oid otar oloc osys oper ocre; do
            known=0
            [ -n "$otar" ] && { known=$((known + 1)); [ "$otar" = "$ct" ] || verdict=attribute_differs; }
            [ -n "$oloc" ] && { known=$((known + 1)); [ "$oloc" = "$cl" ] || verdict=attribute_differs; }
            [ -n "$osys" ] && { known=$((known + 1)); [ "$osys" = "$cs" ] || verdict=attribute_differs; }
            [ -n "$oper" ] && { known=$((known + 1)); [ "$oper" = "$cd" ] || verdict=attribute_differs; }
            case "$ocre" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) if [ -n "$sub_cut" ] && [ "${ocre%Z}" \< "${sub_cut%Z}" ]; then verdict=created_before_submission; fi ;; esac
            [ "$known" -lt 2 ] && unver=$((unver + 1))
          done < "$WORK/new.tsv"
          [ "$verdict" = "match" ] && [ "$unver" -gt 0 ] && verdict=attributes_unverifiable
        fi
        nids="$(cut -d'|' -f1 "$WORK/new.tsv" | tr '\n' ',' | sed 's/,$//')"
        if [ "$P_ST" = "ambiguous" ]; then say "ORDER_STILL_AMBIGUOUS current_view=$verdict candidate_ids=$nids : order-status never changes this state; only the person can leave it (order-resolve or order-clear in a terminal)"; exit 5; fi
        if [ "$verdict" = "match" ]; then pend_save accepted "$nids"; say "ORDER_RECONCILED accepted: $new_n new order(s) match the confirmed operation by identity and attributes (ids $nids); an identical order made elsewhere in the same window cannot be told apart: check the provider panel once; do not order again"
        else pend_save ambiguous; say "ORDER_AMBIGUOUS reason=$verdict candidate_ids=$nids : not chosen automatically. The person checks these orders in the provider panel and names the right ones: order-resolve --order-id <ids> in a terminal (the person types the code at the prompt; never put the code on a command line). No new purchase until then."; exit 5; fi
      fi ;;
    esac ;;
  order-resolve)
    orders_gate
    only_chars "$ORDER_ID" ids || die BAD_PARAMETER "--order-id must be a comma-separated list of order ids"
    person_input "Type the confirmation code from the order window (the person does this; the agent cannot)"; TYPED="$ANS"
    lock_enter
    pend_load && [ "$P_ST" = "ambiguous" ] || die NOT_AMBIGUOUS "there is no ambiguous order to resolve"
    [ "${P_WRONG:-0}" -lt 3 ] || die RESOLVE_LOCKED "resolving is locked after three wrong codes; the person checks the panel and runs order-clear in a terminal"
    code_ok "$TYPED" || wrong_code
    call_api GET /orders; report_status order-resolve || exit 3
    items_tsv < "$BODY_FILE" | cut -d'|' -f1 > "$WORK/ids.txt"
    for i in $(printf '%s' "$ORDER_ID" | tr ',' ' '); do
      grep -qxF -- "$i" "$WORK/ids.txt" && ! { printf '%s' ",$P_IDS," | grep -qF -- ",$i,"; } || die NOT_A_CANDIDATE "an id is not among the new orders since the preview; nothing changed"
    done
    pend_save accepted "$ORDER_ID"; say "ORDER_RESOLVED accepted by the person: ids $ORDER_ID; do not order again" ;;
  order-clear)
    person_input "Type CLEAR if you checked the provider panel and want to void the stored order state"
    [ "$ANS" = "CLEAR" ] || die CANCELLED "nothing changed"
    lock_enter
    [ -f "$PEND" ] || { say "ORDER_CLEAR nothing to clear"; exit 0; }
    mv "$PEND" "$PEND.cleared-$(date -u +%Y%m%d%H%M%S)"; say "ORDER_CLEARED the old state was moved aside (kept for review); a new order-preview is possible" ;;
  order-unlock)
    person_input "Type UNLOCK to remove a lock left behind by a helper that died (check that no helper is running)"
    [ "$ANS" = "UNLOCK" ] || die CANCELLED "nothing changed"
    if [ -d "$LOCKD" ]; then rmdir "$LOCKD" && say LOCK_REMOVED; else say NO_LOCK; fi ;;
  *) say "usage: provider-api.sh <orders-enable|orders-disable|set-key|key-status|clear-key|auth-check|egress|readonly-check|balance|list|orders|reference|ssh-bind|order-preview|order-create|order-status|order-resolve|order-clear|order-unlock>"; exit 2 ;;
esac
