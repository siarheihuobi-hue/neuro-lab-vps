#!/usr/bin/env bash
# diagnose.sh - read-only start diagnostics for the VPS workshop kit (macOS branch; also runs in the remote Linux window).
# Kit 0.1.2-preview. macOS and Linux branches are UNVERIFIED on a real machine of that kind (see README).
# It never changes the system, network, VPN, SSH, keys or settings. It writes only under <kit>/state/.
#
# Usage:
#   bash tools/diagnose.sh
#   bash tools/diagnose.sh --answer vpn=on
#   bash tools/diagnose.sh --accept 4 --source ssh-whoami --evidence L
#   bash tools/diagnose.sh --reset 4
#   bash tools/diagnose.sh --claim 4 --source project-status   (a claim from existing project documents: NOT a PASS)
#   bash tools/diagnose.sh --report      (safe summary to paste into a problem report)
#
# Test-only hooks (never needed by participants):
#   KIT_PROBE_NO_FALLBACK=1   disable install-location fallbacks for code
#   KIT_PROBE_HIDE=code,ssh   pretend the named tools are not installed
#   KIT_OS_OVERRIDE=macos     label the OS (test of the macOS branch on another OS)
# bash 3.2 compatible (macOS default): no associative arrays, no ${var,,}.

set -u
KIT_VERSION="0.1.2-preview"
KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$KIT_ROOT/state"
TEL="$STATE/telemetry"
F_DIAG="$STATE/diagnostics.tsv"
F_STAGES="$STATE/stages.tsv"
F_ANS="$STATE/answers.tsv"
F_EV="$TEL/events.jsonl"
TAB="$(printf '\t')"
STAGE_COUNT=12

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fail() { echo "ERROR $1" >&2; exit "${2:-2}"; }
clean() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-"${2:-60}" | sed 's/^ *//; s/ *$//'; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
ensure_state() { mkdir -p "$STATE" "$TEL"; }

init_stages() {
  if [ ! -f "$F_STAGES" ]; then
    : > "$F_STAGES"
    i=1
    while [ "$i" -le "$STAGE_COUNT" ]; do
      printf '%s\tNOT_RUN\t?\tnone\t-\tinit\n' "$i" >> "$F_STAGES"
      i=$((i + 1))
    done
  fi
}
stage_status() { awk -F'\t' -v n="$1" '$1==n{print $2}' "$F_STAGES"; }
set_stage() { # n status label source note
  tmp="$F_STAGES.tmp.$$"
  awk -F'\t' -v OFS='\t' -v n="$1" -v s="$2" -v l="$3" -v src="$4" -v u="$(now)" -v note="$5" \
    '$1==n{print n,s,l,src,u,note; next}{print}' "$F_STAGES" > "$tmp" && mv "$tmp" "$F_STAGES"
}
get_answer() { [ -f "$F_ANS" ] && awk -F'\t' -v k="$1" '$1==k{print $2}' "$F_ANS" || true; }
set_answer() {
  tmp="$F_ANS.tmp.$$"
  { [ -f "$F_ANS" ] && awk -F'\t' -v k="$1" '$1!=k' "$F_ANS"; printf '%s\t%s\t%s\n' "$1" "$2" "$(now)"; } > "$tmp" && mv "$tmp" "$F_ANS"
}
allowed_answer() { # key value -> 0 if allowed
  case "$1:$2" in
    vpn:on|vpn:off|vpn:unknown) return 0 ;;
    claude_permission:manual|claude_permission:other|claude_permission:bypass|claude_permission:none|claude_permission:unknown) return 0 ;;
    codex_confirmations:default|codex_confirmations:other|codex_confirmations:bypass|codex_confirmations:none|codex_confirmations:unknown) return 0 ;;
    workspace_selected:yes|workspace_selected:no) return 0 ;;
    map_ready:yes|map_ready:no) return 0 ;;
    project_link:parent|project_link:standalone) return 0 ;;
    neurolab_offer:shown|neurolab_offer:declined|neurolab_offer:interested) return 0 ;;
  esac
  return 1
}

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else echo "NOHASH"; fi
}

# ---------- control subcommands (do not run diagnostics) ----------
ACCEPT=""; SOURCE=""; EVIDENCE=""; NOTE=""; RESET=""; ANSWERS=""; REPORT=0; CLAIM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --answer) shift; [ $# -gt 0 ] || fail "--answer needs key=value"; ANSWERS="$ANSWERS $1" ;;
    --accept) shift; ACCEPT="${1:-}" ;;
    --source) shift; SOURCE="${1:-}" ;;
    --evidence) shift; EVIDENCE="${1:-}" ;;
    --note) shift; NOTE="${1:-}" ;;
    --reset) shift; RESET="${1:-}" ;;
    --claim) shift; CLAIM="${1:-}" ;;
    --report) REPORT=1 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

CTL=0
if [ -n "$ANSWERS" ]; then
  CTL=1; ensure_state
  for a in $ANSWERS; do
    case "$a" in *=*) ;; *) fail "answer must be key=value" ;; esac
    k="$(lower "${a%%=*}")"; v="$(lower "${a#*=}")"
    allowed_answer "$k" "$v" || fail "answer not allowed: $k"
    set_answer "$k" "$v"
  done
  echo "ANSWERS_SAVED"
fi
if [ -n "$ACCEPT" ]; then
  CTL=1; ensure_state; init_stages
  case "$ACCEPT" in ''|*[!0-9]*) fail "stage must be 1..$STAGE_COUNT" ;; esac
  [ "$ACCEPT" -ge 1 ] && [ "$ACCEPT" -le "$STAGE_COUNT" ] || fail "stage must be 1..$STAGE_COUNT"
  printf '%s' "$SOURCE" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "PASS needs --source (1-40 chars of A-Za-z0-9_.+-)"
  case "$EVIDENCE" in L|U|LU) ;; *) fail "PASS needs --evidence L (checked locally), U (reported by the person) or LU" ;; esac
  if [ -n "$NOTE" ]; then printf '%s' "$NOTE" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "note must match A-Za-z0-9_.+- (no free text, no secrets)"; else NOTE="accepted"; fi
  set_stage "$ACCEPT" PASS "$EVIDENCE" "$SOURCE" "$NOTE"
  echo "STAGE_ACCEPTED $ACCEPT"
fi
if [ -n "$CLAIM" ]; then
  # A claim records that existing project documents SAY a stage is done. It is never a PASS: verify it, then --accept.
  CTL=1; ensure_state; init_stages
  case "$CLAIM" in ''|*[!0-9]*) fail "stage must be 1..$STAGE_COUNT" ;; esac
  [ "$CLAIM" -ge 1 ] && [ "$CLAIM" -le "$STAGE_COUNT" ] || fail "stage must be 1..$STAGE_COUNT"
  printf '%s' "$SOURCE" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "a claim needs --source (1-40 chars of A-Za-z0-9_.+-)"
  if [ "$(stage_status "$CLAIM")" = "PASS" ]; then echo "CLAIM_IGNORED $CLAIM (already PASS)"
  else set_stage "$CLAIM" CLAIMED '?' "$SOURCE" needs_verification; echo "STAGE_CLAIMED $CLAIM (not a PASS: verify it, then --accept)"; fi
fi
if [ -n "$RESET" ]; then
  CTL=1; ensure_state; init_stages
  case "$RESET" in ''|*[!0-9]*) fail "stage must be 1..$STAGE_COUNT" ;; esac
  [ "$RESET" -ge 1 ] && [ "$RESET" -le "$STAGE_COUNT" ] || fail "stage must be 1..$STAGE_COUNT"
  set_stage "$RESET" PENDING '?' reset reset
  echo "STAGE_RESET $RESET"
fi
[ "$CTL" -eq 1 ] && exit 0

# ---------- safe report: kit version, OS label, stage table, check ids/statuses; no paths, addresses, names ----------
if [ "$REPORT" -eq 1 ]; then
  osv=""; [ -f "$F_DIAG" ] && osv="$(awk -F'	' '$1=="os"{print $3}' "$F_DIAG")"
  echo "REPORT kit=$KIT_VERSION os=$osv"
  [ -f "$F_STAGES" ] && awk -F'	' '{print "REPORT_STAGE " $1 " " $2 " " $3 " " $4 " " $5 " " $6}' "$F_STAGES"
  [ -f "$F_DIAG" ] && awk -F'	' '{print "REPORT_CHECK " $1 " " $2 " " $3}' "$F_DIAG"
  echo "REPORT_END (add: stage number, what you saw in your own words WITHOUT passwords, keys, IP addresses, user names, paths)"
  exit 0
fi

# ---------- diagnostics ----------
ensure_state
HAD_STAGES=0; [ -f "$F_STAGES" ] && HAD_STAGES=1
init_stages
RUN_ID="$(printf '%08x' $(( ($(date +%s) * 31 + $$) & 4294967295 )))"
RUN_START="$(date +%s)"
CHECKS="$STATE/.checks.$$"; : > "$CHECKS"
DIAG_TMP="$STATE/.diag.$$"; : > "$DIAG_TMP"
printf '{"v":1,"ts":"%s","run":"%s","ev":"run_start","exec_ms":null,"wait_ms":null}\n' "$(now)" "$RUN_ID" >> "$F_EV"

add_check() { # id status value label ms
  v="$(clean "$3" 60)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$5" "$v" "$4" >> "$CHECKS"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$v" "$4" "$(now)" >> "$DIAG_TMP"
  echo "CHECK $1 $2 $v"
}
status_of() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$CHECKS"; }
ask() { echo "QUESTION $1 $2"; }

fallbacks() {
  if [ "$1" = "code" ]; then
    printf '%s\n' "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" "/usr/local/bin/code" "/usr/bin/code"
  fi
}
P_STATUS=""; P_OUT=""
probe() { # name args...
  name="$1"; shift
  P_STATUS="NOT_FOUND"; P_OUT=""
  case ",${KIT_PROBE_HIDE:-}," in *",$name,"*) return 0 ;; esac
  path="$(command -v "$name" 2>/dev/null || true)"
  if [ -z "$path" ] && [ -z "${KIT_PROBE_NO_FALLBACK:-}" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] && [ -x "$c" ] && { path="$c"; break; }
    done <<EOF
$(fallbacks "$name")
EOF
  fi
  [ -n "$path" ] || return 0
  P_OUT="$("$path" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$P_OUT" ]; then P_STATUS="PASS"
  elif [ "$rc" -eq 126 ]; then P_STATUS="BLOCKED_BY_LOCAL_PERMISSION"
  else P_STATUS="UNKNOWN"; fi
}
secs_ms() { echo $(( ($2 - $1) * 1000 )); }

# kit identity
t0="$(date +%s)"
ver=""; [ -f "$KIT_ROOT/VERSION" ] && ver="$(tr -d '\r\n ' < "$KIT_ROOT/VERSION")"
if [ ! -f "$KIT_ROOT/MANIFEST.sha256" ]; then
  kst="UNKNOWN"; kval="version $ver; manifest not found"
else
  total=0; missing=0; changed=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    h="$(printf '%s' "$line" | cut -c1-64)"; rel="$(printf '%s' "$line" | cut -c67-)"
    total=$((total + 1))
    if [ ! -f "$KIT_ROOT/$rel" ]; then missing=$((missing + 1)); continue; fi
    [ "$(hash_of "$KIT_ROOT/$rel")" = "$h" ] || changed=$((changed + 1))
  done < "$KIT_ROOT/MANIFEST.sha256"
  if [ "$ver" != "$KIT_VERSION" ]; then kst="FAIL"; kval="version $ver != script $KIT_VERSION"
  elif [ "$missing" -eq 0 ] && [ "$changed" -eq 0 ]; then kst="PASS"; kval="version $ver; $total files match manifest"
  else kst="FAIL"; kval="version $ver; missing=$missing changed=$changed"; fi
fi
add_check kit "$kst" "$kval" L "$(secs_ms "$t0" "$(date +%s)")"

# os
t0="$(date +%s)"
if [ -n "${KIT_OS_OVERRIDE:-}" ]; then un="$KIT_OS_OVERRIDE"; else un="$(uname -s 2>/dev/null || echo unknown)"; fi
case "$(lower "$un")" in
  darwin|macos) ost="PASS"; ver_os="$(sw_vers -productVersion 2>/dev/null || echo unknown)"; osval="macos-$ver_os"; OSFAM="macos" ;;
  linux) ost="PASS"; osval="linux (remote window or Linux host)"; OSFAM="linux" ;;
  mingw*|msys*|cygwin*) ost="UNKNOWN"; osval="windows-shell; use tools/diagnose.ps1"; OSFAM="windows" ;;
  *) ost="UNKNOWN"; osval="unrecognized"; OSFAM="other" ;;
esac
add_check os "$ost" "$osval" L "$(secs_ms "$t0" "$(date +%s)")"

# VS Code and extensions (laptop checks do not apply inside the Linux remote window)
CODE_STATUS="NOT_RUN"
if [ "$OSFAM" = "linux" ]; then
  add_check vscode NOT_RUN "remote Linux window: laptop checks not applicable" ? 0
  for e in ext_remote_ssh ext_claude ext_codex; do add_check "$e" NOT_RUN "remote window: check extensions in the remote VS Code UI" ? 0; done
else
  t0="$(date +%s)"; probe code --version; CODE_STATUS="$P_STATUS"
  if [ "$CODE_STATUS" = "PASS" ]; then
    vline="$(printf '%s
' "$P_OUT" | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | head -n1)"; [ -n "$vline" ] || vline="unparsed"
    add_check vscode PASS "version $vline" L "$(secs_ms "$t0" "$(date +%s)")"
  elif [ "$CODE_STATUS" = "NOT_FOUND" ]; then
    add_check vscode UNKNOWN "code command not on PATH" ? "$(secs_ms "$t0" "$(date +%s)")"
    ask vscode_installed "VS Code may be installed without the code command; ask the participant to open VS Code and read the version in Code > About."
  else add_check vscode "$CODE_STATUS" "code command did not run" L "$(secs_ms "$t0" "$(date +%s)")"; fi
  if [ "$CODE_STATUS" = "PASS" ]; then
    t0="$(date +%s)"; probe code --list-extensions --show-versions; ms="$(secs_ms "$t0" "$(date +%s)")"
    if [ "$P_STATUS" = "PASS" ]; then
      for pair in "ext_remote_ssh:ms-vscode-remote.remote-ssh" "ext_claude:anthropic.claude-code" "ext_codex:openai.chatgpt"; do
        id="${pair%%:*}"; ext="${pair#*:}"
        found="$(printf '%s\n' "$P_OUT" | tr 'A-Z' 'a-z' | grep -E "^$ext@" | head -n1 | sed "s/^$ext@//")"
        if [ -n "$found" ]; then add_check "$id" PASS "local version $found" L "$ms"; else add_check "$id" NOT_FOUND "not installed locally" L "$ms"; fi
      done
    else
      for id in ext_remote_ssh ext_claude ext_codex; do add_check "$id" "$P_STATUS" "extension list not read" L "$ms"; done
    fi
  else
    for id in ext_remote_ssh ext_claude ext_codex; do add_check "$id" NOT_RUN "VS Code CLI not available" ? 0; done
  fi
fi

# SSH client
if [ "$OSFAM" = "linux" ]; then
  add_check ssh_client NOT_RUN "remote window: laptop ssh check not applicable" ? 0
else
  t0="$(date +%s)"; probe ssh -V; ms="$(secs_ms "$t0" "$(date +%s)")"
  case "$P_STATUS" in
    PASS) add_check ssh_client PASS "$(printf '%s' "$P_OUT" | head -n1 | cut -c1-40)" L "$ms" ;;
    NOT_FOUND) add_check ssh_client NOT_FOUND "ssh not found" L "$ms" ;;
    *) add_check ssh_client "$P_STATUS" "ssh did not run" L "$ms" ;;
  esac
fi

# previous state, map, workspace
prev_pass="$(awk -F'\t' '$2=="PASS"{c++} END{print c+0}' "$F_STAGES")"
if [ "$HAD_STAGES" -eq 1 ]; then add_check prev_state PASS "previous state found; stages PASS=$prev_pass" L 0; else add_check prev_state NOT_FOUND "no previous run" L 0; fi
if [ -f "$STATE/map.md" ]; then add_check map PASS "state/map.md present" L 0; else add_check map NOT_FOUND "no state/map.md" L 0; fi
a="$(get_answer workspace_selected)"
if [ -n "$a" ]; then add_check workspace PASS "selected=$a" U 0; else add_check workspace UNKNOWN "not asked" ? 0; ask workspace_selected "Is a working folder already chosen and open in VS Code? (yes/no)"; fi

# facts the script cannot see: ask, never guess
a="$(get_answer vpn)"
if [ -n "$a" ]; then add_check vpn PASS "reported $a" U 0; else add_check vpn UNKNOWN "not detectable by script" ? 0; ask vpn "Is the VPN on right now? (on/off/unknown)"; fi
for trip in "perm_claude:claude_permission:Claude permission mode before admin operations (manual/other/bypass/none/unknown)" \
            "perm_codex:codex_confirmations:Codex confirmations (default/other/bypass/none/unknown)"; do
  id="${trip%%:*}"; rest="${trip#*:}"; key="${rest%%:*}"; text="${rest#*:}"
  a="$(get_answer "$key")"
  if [ -n "$a" ]; then
    case "$a" in
      bypass) add_check "$id" FAIL "bypass reported; kit policy forbids it" U 0 ;;
      manual|default|none) add_check "$id" PASS "reported $a" U 0 ;;
      *) add_check "$id" UNKNOWN "reported $a" U 0 ;;
    esac
  else add_check "$id" UNKNOWN "not detectable by script" ? 0; ask "$key" "$text"; fi
done

# diagnostics: latest run only (replaced, not appended)
mv "$DIAG_TMP" "$F_DIAG"

# stage plan (accepted stages are kept, never duplicated)
if [ "$(stage_status 1)" != "PASS" ]; then
  if [ "$(status_of os)" = "PASS" ] && [ "$(status_of kit)" = "PASS" ]; then set_stage 1 PASS L diagnose stage_plan_written
  else set_stage 1 PENDING L diagnose checks_incomplete; fi
fi
if [ "$(stage_status 2)" != "PASS" ]; then
  if [ "$(status_of vscode)" = "PASS" ] && [ "$(status_of ssh_client)" = "PASS" ] && [ "$(get_answer vpn)" = "on" ]; then
    set_stage 2 PASS LU diagnose+vpn_answer vscode_ssh_vpn
  elif [ "$(stage_status 2)" = "NOT_RUN" ]; then set_stage 2 PENDING '?' diagnose not_all_facts; fi
fi
plan=""
i=1
while [ "$i" -le "$STAGE_COUNT" ]; do
  s="$(stage_status "$i")"; m="RUN"; [ "$s" = "PASS" ] && m="SKIP"
  plan="$plan $i:$m($s)"
  i=$((i + 1))
done
echo "STAGE_PLAN$plan"

# local telemetry (closed schema; no commands, paths, addresses, names or secrets; no network)
while IFS="$TAB" read -r id st ms v l; do
  [ -n "$id" ] || continue
  printf '{"v":1,"ts":"%s","run":"%s","ev":"check","id":"%s","st":"%s","exec_ms":%s,"wait_ms":null}\n' "$(now)" "$RUN_ID" "$id" "$st" "$ms" >> "$F_EV"
done < "$CHECKS"
printf '{"v":1,"ts":"%s","run":"%s","ev":"run_end","exec_ms":%s,"wait_ms":null}\n' "$(now)" "$RUN_ID" "$(secs_ms "$RUN_START" "$(date +%s)")" >> "$F_EV"
rm -f "$CHECKS"
echo "DIAG_DONE"
exit 0
