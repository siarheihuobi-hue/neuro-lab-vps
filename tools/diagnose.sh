#!/usr/bin/env bash
# diagnose.sh - read-only start diagnostics for the VPS workshop kit (macOS branch; also runs in the remote Linux window).
# Kit 0.3.0-preview. macOS and Linux branches are UNVERIFIED on a real machine of that kind (see README).
# It never changes the system, network, VPN, SSH, keys or settings. It writes only under <kit>/state/.
#
# Usage:
#   bash tools/diagnose.sh
#   bash tools/diagnose.sh --answer vpn=on
#   bash tools/diagnose.sh --accept 4 --source ssh-whoami --evidence L
#   bash tools/diagnose.sh --reset 4
#   bash tools/diagnose.sh --claim 4 --source project-status   (a claim from existing project documents: NOT a PASS)
#   bash tools/diagnose.sh --report      (safe summary to paste into a problem report)
#   bash tools/diagnose.sh --fact KEY_LOGIN=PASS --source agent-whoami --evidence L   (one finer fact; see tools/README.md)
#   bash tools/diagnose.sh --new-server --source owner-message   (a NEW server: new generation, old server facts do not carry over)
#   bash tools/diagnose.sh --migrate     (idempotent state migration to schema 2; also done on a normal run)
#   bash tools/diagnose.sh --summary     (five separate results: workspace, app, reconnect, security, training)
#   bash tools/diagnose.sh --checkpoints (the four access checkpoints with status, source, scope, blocker, retry condition)
#   bash tools/diagnose.sh --attempt CONSOLE --symptom no-paste --hypothesis focus --action click-field --result same --knowledge no
#   bash tools/diagnose.sh --attempt-check CONSOLE   (ALLOWED or STOP after two attempts without new knowledge)
#   bash tools/diagnose.sh --change CONSOLE --source other_browser --action switch-to-firefox   (a concrete change of conditions; only for a stopped area)
#   bash tools/diagnose.sh --context     (version of THIS installation, OS, window, generation, tools)
#   bash tools/diagnose.sh --export      (safe local export for MANUAL transfer; nothing is sent)
#
# bash 3.2 compatible (macOS default): no associative arrays, no ${var,,}.

set -u
KIT_VERSION="0.3.0-preview"
KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$KIT_ROOT/state"
TEL="$STATE/telemetry"
F_DIAG="$STATE/diagnostics.tsv"
F_STAGES="$STATE/stages.tsv"
F_ANS="$STATE/answers.tsv"
F_EV="$TEL/events.jsonl"
F_META="$STATE/meta.tsv"
F_FACTS="$STATE/facts.tsv"
F_HIST="$STATE/history.tsv"
F_OFFER="$KIT_ROOT/config/neurolab-offer.json"
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
    neurolab_offer:shown|neurolab_offer:declined|neurolab_offer:interested|neurolab_offer:already_member) return 0 ;;
    neurolab_member:yes|neurolab_member:no|neurolab_member:unknown) return 0 ;;
    provider_type:api_available|provider_type:api_limited|provider_type:api_not_found|provider_type:api_not_checked|provider_type:panel_only|provider_type:unknown) return 0 ;;
    entry_mode:gpt_guide|entry_mode:vscode_direct) return 0 ;;
    server_state:none|server_state:existing_active|server_state:replaced|server_state:unknown) return 0 ;;
    purchase_profile:base|purchase_profile:recommended|purchase_profile:existing|purchase_profile:undecided) return 0 ;;
    engine_mode:claude_only|engine_mode:codex_only|engine_mode:both|engine_mode:undecided) return 0 ;;
    exec_place:laptop_windows|exec_place:laptop_macos|exec_place:remote_linux|exec_place:local_linux|exec_place:wsl|exec_place:unknown) return 0 ;;
    account_state:new|account_state:existing|account_state:unknown) return 0 ;;
    region_state:available|region_state:unavailable|region_state:unknown) return 0 ;;
    panel_access:ok|panel_access:unreachable_via_vpn|panel_access:other) return 0 ;;
    cheat_sheet_local:yes|cheat_sheet_local:no) return 0 ;;
    admin_sudo_actor:working_ssh_user|admin_sudo_actor:other_account|admin_sudo_actor:untested) return 0 ;;
    admin_sudo_result:ok|admin_sudo_result:auth_failed|admin_sudo_result:no_sudo_rights|admin_sudo_result:no_interactive_input|admin_sudo_result:agent_context_unavailable|admin_sudo_result:other|admin_sudo_result:untested) return 0 ;;
    admin_candidate:none|admin_candidate:current_user_in_sudo_group|admin_candidate:other_account_in_sudo_group|admin_candidate:unknown) return 0 ;;
    admin_context:human_terminal|admin_context:agent_channel|admin_context:none) return 0 ;;
  esac
  return 1
}

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else echo "NOHASH"; fi
}

# ---------- state schema 2: finer facts, server generation ----------
# facts.tsv: fact, status, label, source, date, generation.  meta.tsv: schema, target_id, generation, created, migrated_from.
FACT_NAMES="SERVER_PURCHASED SERVER_ACTIVE HOST_IDENTITY KEY_READY KEY_INSTALLED KEY_LOGIN SSH_AUTH PREFLIGHT ADMIN_READY RECOVERY UFW SSH_HARDENING ENGINE_READY TEAM_LOADED QA APP_BROWSER RECONNECT TRAIN_REMOTE_WINDOW TRAIN_OPEN_PROJECT TRAIN_NEW_PROJECT TRAIN_SESSION TRAIN_TASK TRAIN_PORTS TRAIN_DISK TRAIN_RESUME TRAINING"
TRAIN_NAMES="TRAIN_REMOTE_WINDOW TRAIN_OPEN_PROJECT TRAIN_NEW_PROJECT TRAIN_SESSION TRAIN_TASK TRAIN_PORTS TRAIN_DISK TRAIN_RESUME"
SERVER_ANSWERS="server_state purchase_profile region_state panel_access account_state admin_sudo_actor admin_sudo_result admin_candidate admin_context"
stage_needs() {
  case "$1" in
    3) echo "SERVER_PURCHASED SERVER_ACTIVE" ;;
    4) echo "HOST_IDENTITY KEY_READY KEY_INSTALLED KEY_LOGIN" ;;
    5) echo "PREFLIGHT" ;;
    6) echo "ADMIN_READY UFW SSH_HARDENING" ;;
    7) echo "ENGINE_READY" ;;
    9) echo "TEAM_LOADED" ;;
    10) echo "QA" ;;
    11) echo "APP_BROWSER" ;;
    12) echo "RECONNECT" ;;
    *) echo "" ;;
  esac
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
fs() { # fact status, NOT_RUN when absent
  s=""; [ -f "$F_FACTS" ] && s="$(awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$F_FACTS")"
  [ -n "$s" ] && echo "$s" || echo NOT_RUN
}
fact_ok() { s="$(fs "$1")"; [ "$s" = "PASS" ] && return 0; [ "$1" = "HOST_IDENTITY" ] && [ "$s" = "ACCEPTED_RISK" ] && return 0; return 1; }
set_fact() { # name status label source gen [scope blocker retry]
  tmp="$F_FACTS.tmp.$$"
  { [ -f "$F_FACTS" ] && awk -F'\t' -v k="$1" '$1!=k' "$F_FACTS"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(now)" "$5" "${6:--}" "${7:--}" "${8:--}"; } > "$tmp" && mv "$tmp" "$F_FACTS"
}
CHANGE_KINDS="other_device other_browser other_network other_account corrected_parameter new_fact new_candidate provider_reply new_generation new_tool owner_decision"
ATTEMPT_AREAS="HOST_IDENTITY SSH_AUTH ADMIN_ACCESS RECOVERY CONSOLE PANEL PROVIDER_API ENGINE PERMISSION TUNNEL MIGRATION OTHER"
F_ATT="$STATE/attempts.tsv"
F_EXPORT="$STATE/export.txt"
# trailing attempts of an area without new knowledge since the last recorded change of conditions
attempt_count() {
  [ -f "$F_ATT" ] || { echo 0; return; }
  awk -F'\t' -v a="$1" 'NF>=9 && $3==a { if ($4=="change") n=0; else if ($4=="attempt") { if ($9=="no") n++; else if ($9=="yes") n=0 } } END { print n+0 }' "$F_ATT"
}
# consecutive polls of an already started asynchronous operation (knowledge=pending); bounded, a result or a change resets
pending_count() {
  [ -f "$F_ATT" ] || { echo 0; return; }
  awk -F'\t' -v a="$1" 'NF>=9 && $3==a { if ($4=="change") p=0; else if ($4=="attempt") { if ($9=="pending") p++; else p=0 } } END { print p+0 }' "$F_ATT"
}
# the same hypothesis+action without new knowledge, whatever the area is called; cleared by a change in the area where it began
pair_count() { # hypothesis action
  [ -f "$F_ATT" ] || { echo 0; return; }
  awk -F'\t' -v h="$1" -v c="$2" 'NF>=9 { k=$6 "|" $7
      if ($4=="change") { for (q in ar) if (ar[q]==$3) { delete n[q]; delete ar[q] } }
      else if ($4=="attempt") { if ($9=="no") { if (!(k in ar)) ar[k]=$3; n[k]++ } else if ($9=="yes") { delete n[k]; delete ar[k] } } }
    END { print n[h "|" c]+0 }' "$F_ATT"
}
attempt_append() { # area kind symptom hypothesis action result knowledge
  c=1; [ -f "$F_ATT" ] && c=$(( $(wc -l < "$F_ATT" | tr -d ' ') + 1 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$(now)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$F_ATT"
}
chk_token() { # value what
  [ -z "$1" ] || printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "$2 must match A-Za-z0-9_.+- (1-40 chars; codes only, no free text, no secrets)"
  if [ -n "$1" ] && printf '%s' "$1" | grep -Eq '[A-Za-z0-9-]+[.][A-Za-z]{2,}'; then fail "$2 must not look like a host name (codes only)"; fi
}
unfinished_ops() {
  u=""
  [ -f "$F_FACTS" ] && u="$(awk -F'\t' '$2=="OPEN"||$2=="BLOCKED"||$2=="DEFERRED"{printf "%s%s=%s", (n++?",":""), $1, $2}' "$F_FACTS")"
  for ar in $ATTEMPT_AREAS; do [ "$(attempt_count "$ar")" -ge 2 ] && u="$u${u:+,}STOPPED_$ar"; done
  [ -n "$u" ] && echo "$u" || echo none
}
# last gate before a file leaves the state folder: nothing that looks like an address, host name, mail, path, URL, long hex/base64 or key block
export_gate() { # file -> 0 when clean
  if grep -Eiq '(^|[^0-9])[0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}($|[^0-9])|[A-Za-z0-9-]+[.][A-Za-z]{2,}([^A-Za-z]|$)|@|[/\]|://|[0-9a-f]{16,}|[A-Za-z0-9+]{32,}|([0-9A-Fa-f]{1,4}:){2,}[0-9A-Fa-f]{1,4}|PRIVATE KEY|passw[o]rd=|toke[n]=' "$1"; then return 1; fi
  return 0
}
# the four independent access checkpoints; old fact names are kept and mapped, not renamed
chk_row() { # NAME -> sets CK_ROW (the facts row) and CK_VIA
  CK_ROW=""; CK_VIA="$1"
  case "$1" in
    SSH_AUTH) CK_ROW="$(awk -F'\t' '$1=="SSH_AUTH"{print; exit}' "$F_FACTS" 2>/dev/null)"
              if [ -z "$CK_ROW" ]; then CK_ROW="$(awk -F'\t' '$1=="KEY_LOGIN"{print; exit}' "$F_FACTS" 2>/dev/null)"; [ -n "$CK_ROW" ] && CK_VIA="KEY_LOGIN(compat)"; fi ;;
    ADMIN_ACCESS) CK_ROW="$(awk -F'\t' '$1=="ADMIN_READY"{print; exit}' "$F_FACTS" 2>/dev/null)"; [ -n "$CK_ROW" ] && CK_VIA="ADMIN_READY(compat)" ;;
    *) CK_ROW="$(awk -F'\t' -v k="$1" '$1==k{print; exit}' "$F_FACTS" 2>/dev/null)" ;;
  esac
}
# a row counts only for the CURRENT target generation; compat rows (old fact names) also need local evidence (label with L)
chk_gate() {
  [ -n "$CK_ROW" ] || return 0
  g="$(meta_get generation)"; rg="$(printf '%s' "$CK_ROW" | cut -f6)"
  if [ -n "$g" ] && [ -n "$rg" ] && [ "$rg" != "$g" ]; then CK_VIA="$CK_VIA(stale_generation_ignored)"; CK_ROW=""; return 0; fi
  case "$CK_VIA" in *"(compat)")
    case "$(printf '%s' "$CK_ROW" | cut -f3)" in *L*) ;; *) CK_VIA="$CK_VIA(needs_local_evidence_ignored)"; CK_ROW="" ;; esac ;;
  esac
}
chk_status() { chk_row "$1"; chk_gate; if [ -n "$CK_ROW" ]; then printf '%s' "$CK_ROW" | cut -f2; else echo NOT_RUN; fi; }
chk_line() { # NAME
  chk_row "$1"; chk_gate
  case "$1" in
    HOST_IDENTITY) purpose="host_key_belongs_to_the_target_server" ;;
    SSH_AUTH) purpose="user_login_by_password_or_client_key" ;;
    ADMIN_ACCESS) purpose="confirmed_user_can_do_administrative_actions" ;;
    *) purpose="verified_backup_channel_and_who_may_use_it" ;;
  esac
  st="NOT_RUN"; src="-"; dt="-"; sc="-"; bl="-"; rt="-"
  if [ -n "$CK_ROW" ]; then
    st="$(printf '%s' "$CK_ROW" | cut -f2)"; src="$(printf '%s' "$CK_ROW" | cut -f4)"; dt="$(printf '%s' "$CK_ROW" | cut -f5)"
    x="$(printf '%s' "$CK_ROW" | cut -f7)"; [ -n "$x" ] && sc="$x"; x="$(printf '%s' "$CK_ROW" | cut -f8)"; [ -n "$x" ] && bl="$x"; x="$(printf '%s' "$CK_ROW" | cut -f9)"; [ -n "$x" ] && rt="$x"
  fi
  ex=""; if [ "$1" = "RECOVERY" ]; then ar_="no"; [ "$st" = "PASS" ] && [ "$sc" = "agent_channel" ] && ar_="yes"; ex=" agent_can_rollback=$ar_"; fi
  echo "CHECKPOINT $1 status=$st purpose=$purpose source=$src date=$dt scope=$sc blocker=$bl retry=$rt via=$CK_VIA$ex"
}

meta_get() { [ -f "$F_META" ] && awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$F_META" || true; }
meta_put() { # key value
  tmp="$F_META.tmp.$$"
  { [ -f "$F_META" ] && awk -F'\t' -v k="$1" '$1!=k' "$F_META"; printf '%s\t%s\n' "$1" "$2"; } > "$tmp" && mv "$tmp" "$F_META"
}
new_target_id() { printf '%08x' $(( (RANDOM * 32768 + RANDOM) & 4294967295 )); }
ENSURED=0
ensure_meta() { # sets ENSURED=1 when meta.tsv was created now
  ENSURED=0
  [ -f "$F_META" ] && return 0
  ENSURED=1
  had=0; [ -f "$F_STAGES" ] && had=1
  mig="none"
  if [ "$had" -eq 1 ]; then
    mig="schema1"
    mkdir -p "$STATE/backup-schema1"
    cp "$F_STAGES" "$STATE/backup-schema1/" 2>/dev/null || true
    [ -f "$F_ANS" ] && cp "$F_ANS" "$STATE/backup-schema1/" 2>/dev/null || true
    for n in 3 4 6 7 9 10 11 12; do
      row="$(awk -F'\t' -v n="$n" '$1==n && $2=="PASS"{print $3}' "$F_STAGES")"
      [ -n "$row" ] || continue
      for fn in $(stage_needs "$n"); do
        case "$fn" in KEY_LOGIN|ADMIN_READY|UFW|SSH_HARDENING) case "$row" in *L*) ;; *) continue ;; esac ;; esac   # a person's word alone is not carried over as a security fact
        [ "$(fs "$fn")" = "NOT_RUN" ] && set_fact "$fn" PASS "$row" migrated 1
      done
    done
  fi
  meta_put schema 2; meta_put target_id "$(new_target_id)"; meta_put generation 1; meta_put created "$(now)"; meta_put migrated_from "$mig"
  return 0
}
is_persistent() { case "$1" in KEY_READY|TRAINING|TRAIN_*) return 0 ;; esac; return 1; }
OFFER_REASON="config_missing"
offer_ready() {
  OFFER_REASON="config_missing"; [ -f "$F_OFFER" ] || return 1
  grep -Eq '"cta_enabled"[[:space:]]*:[[:space:]]*true' "$F_OFFER" || { OFFER_REASON="cta_disabled"; return 1; }
  url="$(sed -n 's/.*"cta_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$F_OFFER" | head -n1)"
  printf '%s' "$url" | grep -Eq '^https:[/][/][A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$' || { OFFER_REASON="cta_url_missing_or_not_https"; return 1; }
  lab="$(sed -n 's/.*"cta_label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$F_OFFER" | head -n1)"
  [ -n "$lab" ] || { OFFER_REASON="cta_label_missing"; return 1; }
  OFFER_REASON="ok"; return 0
}

# ---------- control subcommands (do not run diagnostics) ----------
ACCEPT=""; SOURCE=""; EVIDENCE=""; NOTE=""; RESET=""; ANSWERS=""; REPORT=0; CLAIM=""; FACTS=""; NEWSERVER=0; MIGRATE=0; SUMMARY=0
CHECKPOINTS=0; CONTEXT=0; EXPORT=0; SCOPE=""; BLOCKER=""; RETRY=""; ATTEMPT=""; ATTEMPT_CHECK=""; CHANGE=""; SYMPTOM=""; HYPOTHESIS=""; ACTION=""; RESULT=""; KNOWLEDGE=""
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
    --fact) shift; [ $# -gt 0 ] || fail "--fact needs NAME=STATUS"; FACTS="$FACTS $1" ;;
    --new-server) NEWSERVER=1 ;;
    --migrate) MIGRATE=1 ;;
    --summary) SUMMARY=1 ;;
    --checkpoints) CHECKPOINTS=1 ;;
    --context) CONTEXT=1 ;;
    --export) EXPORT=1 ;;
    --scope) shift; SCOPE="${1:-}" ;;
    --blocker) shift; BLOCKER="${1:-}" ;;
    --retry) shift; RETRY="${1:-}" ;;
    --attempt) shift; ATTEMPT="${1:-}" ;;
    --attempt-check) shift; ATTEMPT_CHECK="${1:-}" ;;
    --change) shift; CHANGE="${1:-}" ;;
    --symptom) shift; SYMPTOM="${1:-}" ;;
    --hypothesis) shift; HYPOTHESIS="${1:-}" ;;
    --action) shift; ACTION="${1:-}" ;;
    --result) shift; RESULT="${1:-}" ;;
    --knowledge) shift; KNOWLEDGE="${1:-}" ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

for tok in "$SOURCE" "$NOTE"; do
  if printf '%s' "$tok" | grep -Eq '(^|[^0-9])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}($|[^0-9])'; then fail "source and note must not look like an IP address"; fi
done
for tok in "$SCOPE" "$BLOCKER" "$RETRY" "$SYMPTOM" "$HYPOTHESIS" "$ACTION" "$RESULT" "$KNOWLEDGE"; do
  if printf '%s' "$tok" | grep -Eq '(^|[^0-9])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}($|[^0-9])'; then fail "codes must not look like an IP address"; fi
done
chk_token "$SOURCE" source; chk_token "$SCOPE" scope; chk_token "$BLOCKER" blocker; chk_token "$RETRY" retry; chk_token "$SYMPTOM" symptom; chk_token "$HYPOTHESIS" hypothesis; chk_token "$ACTION" action; chk_token "$RESULT" result
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
  CTL=1; ensure_state; ensure_meta; init_stages
  case "$ACCEPT" in ''|*[!0-9]*) fail "stage must be 1..$STAGE_COUNT" ;; esac
  [ "$ACCEPT" -ge 1 ] && [ "$ACCEPT" -le "$STAGE_COUNT" ] || fail "stage must be 1..$STAGE_COUNT"
  printf '%s' "$SOURCE" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "PASS needs --source (1-40 chars of A-Za-z0-9_.+-)"
  case "$EVIDENCE" in L|U|LU) ;; *) fail "PASS needs --evidence L (checked locally), U (reported by the person) or LU" ;; esac
  if [ -n "$NOTE" ]; then printf '%s' "$NOTE" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "note must match A-Za-z0-9_.+- (no free text, no secrets)"; else NOTE="accepted"; fi
  miss=""
  for fn in $(stage_needs "$ACCEPT"); do fact_ok "$fn" || miss="$miss${miss:+,}$fn"; done
  [ -z "$miss" ] || fail "ACCEPT_NEEDS_FACTS stage=$ACCEPT missing=$miss (record each fact with --fact NAME=PASS --source ... --evidence ...)"
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
if [ -n "$FACTS" ]; then
  CTL=1; ensure_state; ensure_meta
  printf '%s' "$SOURCE" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "a fact needs --source (evidence source, 1-40 chars of A-Za-z0-9_.+-)"
  ev="$EVIDENCE"; [ -n "$ev" ] || ev="?"
  case "$ev" in L|U|LU|'?') ;; *) fail "evidence must be L, U, LU or ?" ;; esac
  gen="$(meta_get generation)"
  todo=""
  for f in $FACTS; do
    case "$f" in *=*) ;; *) fail "fact must be NAME=STATUS" ;; esac
    name="$(printf '%s' "${f%%=*}" | tr 'a-z' 'A-Z')"; stt="$(printf '%s' "${f#*=}" | tr 'a-z' 'A-Z')"
    in_list "$name" "$FACT_NAMES" || fail "fact not allowed: $name"
    [ "$stt" = "NOT_TESTED" ] && stt="NOT_RUN"
    case "$stt" in PASS|OPEN|BLOCKED|NOT_RUN|UNVERIFIED|ACCEPTED_RISK|SKIPPED|DEFERRED|NOT_APPLICABLE) ;; *) fail "fact status not allowed: $stt" ;; esac
    if [ "$name" = "TRAINING" ] && [ "$stt" = "PASS" ]; then fail "TRAINING_IS_COMPUTED: training is complete only when all TRAIN_* facts are PASS; a skip is recorded as TRAINING=SKIPPED"; fi
    if { [ "$stt" = "ACCEPTED_RISK" ] || [ "$stt" = "UNVERIFIED" ]; } && [ "$name" != "HOST_IDENTITY" ]; then fail "$stt is allowed only for HOST_IDENTITY"; fi
    if [ "$stt" = "SKIPPED" ]; then in_list "$name" "$TRAIN_NAMES TRAINING" || fail "SKIPPED is allowed only for TRAIN_* and TRAINING"; fi
    if [ "$stt" = "PASS" ]; then
      [ "$ev" != "?" ] || fail "PASS needs --evidence L, U or LU"
      if in_list "$name" "KEY_LOGIN ADMIN_READY UFW SSH_HARDENING" && [ "$ev" = "U" ]; then fail "$name PASS needs evidence that includes L: a statement of the person alone is not enough"; fi
      if [ "$name" = "HOST_IDENTITY" ] && [ "$ev" = "L" ]; then fail "HOST_IDENTITY PASS needs the person to confirm the independent comparison (evidence U or LU)"; fi
    fi
    if [ "$stt" = "ACCEPTED_RISK" ] && [ "$ev" != "U" ]; then fail "ACCEPTED_RISK is the owner decision: evidence U"; fi
    if [ "$name" = "RECOVERY" ] && [ "$stt" = "PASS" ]; then
      case "$SCOPE" in agent_channel|human_only) ;; *) fail "RECOVERY PASS needs --scope agent_channel or human_only: who may use the recovery channel" ;; esac
    fi
    if [ "$name" = "ADMIN_READY" ] && [ "$stt" = "PASS" ]; then
      { [ "$(get_answer admin_context)" = "agent_channel" ] && [ "$(get_answer admin_sudo_result)" = "ok" ]; } || fail "ADMIN_READY PASS needs the answers admin_context=agent_channel and admin_sudo_result=ok, recorded from a real administrative command in the agent channel"
    fi
    todo="$todo $name=$stt"
  done
  for t in $todo; do set_fact "${t%%=*}" "${t#*=}" "$ev" "$SOURCE" "$gen" "${SCOPE:--}" "${BLOCKER:--}" "${RETRY:--}"; echo "FACT_SET ${t%%=*} ${t#*=}"; done
fi
if [ "$NEWSERVER" -eq 1 ]; then
  CTL=1; ensure_state; ensure_meta
  printf '%s' "$SOURCE" | grep -Eq '^[A-Za-z0-9_.+-]{1,40}$' || fail "a new server needs --source (why, 1-40 chars of A-Za-z0-9_.+-)"
  old_gen="$(meta_get generation)"; old_tid="$(meta_get target_id)"
  new_gen=$((old_gen + 1))
  meta_put generation "$new_gen"; meta_put target_id "$(new_target_id)"
  retired=0
  if [ -f "$F_FACTS" ]; then
    : > "$F_FACTS.new"
    while IFS="$TAB" read -r fn fst fl fsrc fdate fgen; do
      [ -n "$fn" ] || continue
      if is_persistent "$fn"; then printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$fn" "$fst" "$fl" "$fsrc" "$fdate" "$fgen" >> "$F_FACTS.new"
      else retired=$((retired + 1)); printf 'fact_retired\t%s\t%s\t%s\t%s\t%s\n' "$old_gen" "$old_tid" "$fn" "$fst" "$(now)" >> "$F_HIST"; fi
    done < "$F_FACTS"
    mv "$F_FACTS.new" "$F_FACTS"
  fi
  printf 'generation_retired\t%s\t%s\t%s\t-\t%s\n' "$old_gen" "$old_tid" "$SOURCE" "$(now)" >> "$F_HIST"
  init_stages
  i=3
  while [ "$i" -le "$STAGE_COUNT" ]; do set_stage "$i" PENDING '?' new_server "generation_$new_gen"; i=$((i + 1)); done
  if [ -f "$F_ANS" ]; then for k in $SERVER_ANSWERS; do tmp="$F_ANS.tmp.$$"; awk -F'\t' -v k="$k" '$1!=k' "$F_ANS" > "$tmp" && mv "$tmp" "$F_ANS"; done; fi
  echo "NEW_SERVER generation=$new_gen retired_facts=$retired stages_reset=3..$STAGE_COUNT kept=stages_1_2,interview,map,key_ready,training"
fi
if [ "$MIGRATE" -eq 1 ]; then
  CTL=1; ensure_state; ensure_meta
  if [ "$ENSURED" -eq 1 ]; then echo "STATE_MIGRATED schema=2"; else echo "STATE_ALREADY_CURRENT schema=2"; fi
fi
if [ -n "$RESET" ]; then
  CTL=1; ensure_state; init_stages
  case "$RESET" in ''|*[!0-9]*) fail "stage must be 1..$STAGE_COUNT" ;; esac
  [ "$RESET" -ge 1 ] && [ "$RESET" -le "$STAGE_COUNT" ] || fail "stage must be 1..$STAGE_COUNT"
  set_stage "$RESET" PENDING '?' reset reset
  echo "STAGE_RESET $RESET"
fi
if [ -n "$ATTEMPT_CHECK" ]; then
  CTL=1; ensure_state
  in_list "$ATTEMPT_CHECK" "$ATTEMPT_AREAS" || fail "area not allowed: $ATTEMPT_CHECK"
  n="$(attempt_count "$ATTEMPT_CHECK")"
  if [ "$n" -ge 2 ]; then echo "ATTEMPT_STOP area=$ATTEMPT_CHECK no_new_knowledge=$n next=explain_the_blocker_then_an_independent_check_or_the_support_request"
  else echo "ATTEMPT_ALLOWED area=$ATTEMPT_CHECK no_new_knowledge=$n"; fi
fi
if [ -n "$ATTEMPT" ]; then
  CTL=1; ensure_state
  in_list "$ATTEMPT" "$ATTEMPT_AREAS" || fail "area not allowed: $ATTEMPT"
  [ -n "$SYMPTOM" ] && [ -n "$HYPOTHESIS" ] && [ -n "$ACTION" ] && [ -n "$RESULT" ] || fail "an attempt needs --symptom --hypothesis --action --result (codes)"
  case "$KNOWLEDGE" in yes|no|pending) ;; *) fail "an attempt needs --knowledge yes|no|pending (pending = polling an operation already started, at most 5 polls in a row)" ;; esac
  if [ "$KNOWLEDGE" = "pending" ]; then
    pc="$(pending_count "$ATTEMPT")"
    [ "$pc" -lt 5 ] || fail "WAIT_LIMIT area=$ATTEMPT polls=$pc: record the outcome (--knowledge yes or no) or the blocker; waiting is not repeated without a limit"
  else
    pr="$(pair_count "$HYPOTHESIS" "$ACTION")"
    [ "$pr" -lt 2 ] || fail "ATTEMPT_REPEAT hypothesis=$HYPOTHESIS action=$ACTION: the same attempt already failed twice without new knowledge; another area name does not make it new; record --change with a real change of conditions"
  fi
  n="$(attempt_count "$ATTEMPT")"
  if [ "$n" -ge 2 ]; then fail "ATTEMPT_STOP area=$ATTEMPT no_new_knowledge=$n: do not repeat; explain the blocker, take an independent check or prepare the support request; record --change when the conditions really changed"; fi
  attempt_append "$ATTEMPT" attempt "$SYMPTOM" "$HYPOTHESIS" "$ACTION" "$RESULT" "$KNOWLEDGE"
  n2="$(attempt_count "$ATTEMPT")"
  if [ "$n2" -ge 2 ]; then echo "ATTEMPT_RECORDED area=$ATTEMPT ATTEMPT_STOP_REACHED no_new_knowledge=$n2"; else echo "ATTEMPT_RECORDED area=$ATTEMPT no_new_knowledge=$n2"; fi
fi
if [ -n "$CHANGE" ]; then
  CTL=1; ensure_state
  in_list "$CHANGE" "$ATTEMPT_AREAS" || fail "area not allowed: $CHANGE"
  in_list "$SOURCE" "$CHANGE_KINDS" || fail "a change needs --source from: $CHANGE_KINDS (what really changed)"
  printf '%s' "$ACTION" | grep -Eq '^[A-Za-z0-9_+-]{3,40}$' || fail "a change needs --action (a code that names the concrete change, for example switch-to-firefox)"
  cn_="$(attempt_count "$CHANGE")"
  [ "$cn_" -ge 2 ] || fail "CHANGE_NOT_NEEDED area=$CHANGE: the area is not stopped ($cn_ attempts without new knowledge); a change is recorded to lift a stop, not in advance"
  seen_ch="$(awk -F'	' -v a="$CHANGE" -v c="$ACTION" 'NF>=9 && $3==a && $4=="change" && $7==c { n++ } END { print n+0 }' "$F_ATT")"
  [ "$seen_ch" -eq 0 ] || fail "CHANGE_REPEATED area=$CHANGE: this change was already recorded for the area; name what is actually different"
  attempt_append "$CHANGE" change - - "$ACTION" "$SOURCE" yes
  echo "CONDITIONS_CHANGED area=$CHANGE kind=$SOURCE change=$ACTION"
fi
if [ "$CHECKPOINTS" -eq 1 ]; then
  CTL=1; ensure_state; ensure_meta
  for cn in HOST_IDENTITY SSH_AUTH ADMIN_ACCESS RECOVERY; do chk_line "$cn"; done
fi
if [ "$CONTEXT" -eq 1 ]; then
  CTL=1; ensure_state; ensure_meta
  cv=""; [ -f "$KIT_ROOT/VERSION" ] && cv="$(tr -d '\r\n ' < "$KIT_ROOT/VERSION")"
  case "$(lower "$(uname -s 2>/dev/null || echo unknown)")" in darwin) cos="macos" ;; linux) cos="linux" ;; mingw*|msys*|cygwin*) cos="windows-shell" ;; *) cos="other" ;; esac
  cp_="$(get_answer exec_place)"
  if [ -z "$cp_" ]; then if [ -n "${SSH_CONNECTION:-}" ]; then cp_="remote_linux_hint"; else cp_="unproven"; fi; fi
  cw="local"; case "$cp_" in remote_linux|remote_linux_hint) cw="remote" ;; unproven) cw="unknown" ;; esac
  tsh="not_found"; command -v ssh >/dev/null 2>&1 && tsh="found"; tcd="not_found"; command -v code >/dev/null 2>&1 && tcd="found"
  echo "CONTEXT kit_version=$cv script_version=$KIT_VERSION os=$cos place=$cp_ window=$cw generation=$(meta_get generation) tools_ssh=$tsh tools_code=$tcd unfinished=$(unfinished_ops)"
  echo "CONTEXT note: the version is that of THIS folder; a local copy and a remote copy are separate installations"
fi
if [ "$EXPORT" -eq 1 ]; then
  CTL=1; ensure_state; ensure_meta; init_stages
  xv=""; [ -f "$KIT_ROOT/VERSION" ] && xv="$(tr -d '\r\n ' < "$KIT_ROOT/VERSION")"
  case "$(lower "$(uname -s 2>/dev/null || echo unknown)")" in darwin) xos="macos" ;; linux) xos="linux" ;; mingw*|msys*|cygwin*) xos="windows-shell" ;; *) xos="other" ;; esac
  pt="$(get_answer provider_type)"; [ -n "$pt" ] || pt="unknown"
  case "$pt" in api_available|api_limited|api_not_found|api_not_checked|panel_only|unknown) ;; *) rm -f "$F_EXPORT"; fail "EXPORT_REFUSED: provider_type is not one of the closed values; nothing was written" 3 ;; esac
  cps=""; for cn in HOST_IDENTITY SSH_AUTH ADMIN_ACCESS RECOVERY; do cps="$cps $cn=$(chk_status "$cn")"; done
  sts=""; i=1; while [ "$i" -le "$STAGE_COUNT" ]; do sts="$sts $i:$(stage_status "$i")"; i=$((i + 1)); done
  tot=0; [ -f "$F_ATT" ] && tot="$(wc -l < "$F_ATT" | tr -d ' ')"
  stp=""; for ar in $ATTEMPT_AREAS; do [ "$(attempt_count "$ar")" -ge 2 ] && stp="$stp${stp:+,}$ar"; done; [ -n "$stp" ] || stp="none"
  { echo "EXPORT kit=$xv os=$xos generation=$(meta_get generation) provider_type=$pt"
    echo "EXPORT checkpoints$cps"
    echo "EXPORT stages$sts"
    echo "EXPORT attempts total=$tot stopped=$stp"
    echo "EXPORT unfinished $(unfinished_ops)"
    echo "EXPORT note: nothing is sent automatically (network sending is off and there is no receiver); this is a local file for manual transfer; it holds no address, user name, password, key, console output or project content"; } > "$F_EXPORT.tmp"
  # the note names the forbidden classes in words, so the gate runs on every line except the note
  grep -v '^EXPORT note:' "$F_EXPORT.tmp" > "$F_EXPORT.chk"
  if export_gate "$F_EXPORT.chk"; then mv "$F_EXPORT.tmp" "$F_EXPORT"; rm -f "$F_EXPORT.chk"; cat "$F_EXPORT"
  else rm -f "$F_EXPORT.tmp" "$F_EXPORT.chk" "$F_EXPORT"; fail "EXPORT_REFUSED: a field looks like an address, host name, path, mail or secret; nothing was written (inspect the answers and state codes)" 3; fi
fi
[ "$CTL" -eq 1 ] && exit 0


# ---------- summary: five separate results, never one general PASS from partial facts ----------
if [ "$SUMMARY" -eq 1 ]; then
  ensure_state; ensure_meta; init_stages
  ws=""; [ "$(stage_status 5)" = "PASS" ] || ws="$ws${ws:+,}STAGE_5"; [ "$(stage_status 7)" = "PASS" ] || ws="$ws${ws:+,}STAGE_7"
  for n in KEY_LOGIN ENGINE_READY; do fact_ok "$n" || ws="$ws${ws:+,}$n"; done
  app=""; [ "$(stage_status 11)" = "PASS" ] || app="STAGE_11"; fact_ok APP_BROWSER || app="$app${app:+,}APP_BROWSER"
  rec=""; [ "$(stage_status 12)" = "PASS" ] || rec="STAGE_12"; fact_ok RECONNECT || rec="$rec${rec:+,}RECONNECT"
  sec=""; [ "$(stage_status 6)" = "PASS" ] || sec="STAGE_6"
  for n in ADMIN_READY UFW SSH_HARDENING; do fact_ok "$n" || sec="$sec${sec:+,}$n"; done
  tr_pass=0; tr_all=0
  for n in $TRAIN_NAMES; do tr_all=$((tr_all + 1)); [ "$(fs "$n")" = "PASS" ] && tr_pass=$((tr_pass + 1)); done
  tr_skipped=0; [ "$(fs TRAINING)" = "SKIPPED" ] && tr_skipped=1
  tr_ok=0; [ "$tr_pass" -eq "$tr_all" ] && tr_ok=1
  if [ -z "$ws" ]; then echo "SUMMARY WORKSPACE READY"; else echo "SUMMARY WORKSPACE OPEN missing=$ws"; fi
  if [ -z "$app" ]; then echo "SUMMARY APP VERIFIED"; else echo "SUMMARY APP OPEN missing=$app"; fi
  if [ -z "$rec" ]; then echo "SUMMARY RECONNECT VERIFIED"; else echo "SUMMARY RECONNECT OPEN missing=$rec"; fi
  if [ -z "$sec" ]; then echo "SUMMARY SECURITY COMPLETE"; else echo "SUMMARY SECURITY OPEN missing=$sec"; fi
  # administrator access: a candidate (an account in the sudo group) is never ADMIN_READY; the last sudo outcome is kept apart
  a_res="$(get_answer admin_sudo_result)"; [ -n "$a_res" ] || a_res="untested"
  a_act="$(get_answer admin_sudo_actor)"; [ -n "$a_act" ] || a_act="untested"
  a_can="$(get_answer admin_candidate)"; [ -n "$a_can" ] || a_can="unknown"
  a_ctx="$(get_answer admin_context)"; [ -n "$a_ctx" ] || a_ctx="none"
  if fact_ok ADMIN_READY; then echo "SUMMARY ADMIN READY confirmed_in=$a_ctx"
  elif [ "$a_can" = "current_user_in_sudo_group" ] || [ "$a_can" = "other_account_in_sudo_group" ]; then echo "SUMMARY ADMIN CANDIDATE_ONLY candidate=$a_can last_sudo_actor=$a_act last_sudo_result=$a_res (not confirmed administrative access)"
  else echo "SUMMARY ADMIN NOT_PROVEN candidate=$a_can last_sudo_actor=$a_act last_sudo_result=$a_res"; fi
  if [ "$tr_ok" -eq 1 ]; then echo "SUMMARY TRAINING COMPLETE"
  elif [ "$tr_skipped" -eq 1 ]; then echo "SUMMARY TRAINING SKIPPED done=$tr_pass/$tr_all"
  else echo "SUMMARY TRAINING OPEN done=$tr_pass/$tr_all"; fi
  hid="$(fs HOST_IDENTITY)"
  [ "$hid" = "PASS" ] || echo "SUMMARY NOTE host_identity=$hid (not independently verified)"
  if [ -z "$ws$app$rec$sec" ] && [ "$tr_ok" -eq 1 ] && [ "$hid" = "PASS" ]; then echo "SUMMARY OVERALL FULL_PASS"; else echo "SUMMARY OVERALL PARTIAL"; fi
  offer="$(get_answer neurolab_offer)"
  if [ -n "$offer" ]; then echo "SUMMARY OFFER not_eligible reason=already_$offer"
  elif [ -z "$app$rec" ] && { [ "$tr_ok" -eq 1 ] || [ "$tr_skipped" -eq 1 ]; }; then
    mem="$(get_answer neurolab_member)"; br="ask_member"
    [ "$mem" = "yes" ] && br="resident"; [ "$mem" = "no" ] && br="new"
    cta="hidden"; offer_ready && cta="ready"
    echo "SUMMARY OFFER eligible branch=$br cta=$cta ($OFFER_REASON)"
  else echo "SUMMARY OFFER not_eligible reason=result_or_training_not_done"; fi
  cps2=""; for cn in HOST_IDENTITY SSH_AUTH ADMIN_ACCESS RECOVERY; do cps2="$cps2 $cn=$(chk_status "$cn")"; done
  echo "SUMMARY CHECKPOINTS$cps2"
  dfr=""; nap=""
  if [ -f "$F_FACTS" ]; then
    dfr="$(awk -F'\t' '$2=="DEFERRED"{printf "%s%s", (n++?",":""), $1}' "$F_FACTS")"
    nap="$(awk -F'\t' '$2=="NOT_APPLICABLE"{printf "%s%s", (n++?",":""), $1}' "$F_FACTS")"
  fi
  [ -z "$dfr" ] || echo "SUMMARY DEFERRED $dfr"
  [ -z "$nap" ] || echo "SUMMARY NOT_APPLICABLE $nap"
  stpa=""; for ar in $ATTEMPT_AREAS; do [ "$(attempt_count "$ar")" -ge 2 ] && stpa="$stpa${stpa:+,}$ar"; done
  [ -z "$stpa" ] || echo "SUMMARY ATTEMPTS stopped=$stpa (explain the blocker, take an independent check or prepare the support request)"
  echo "SUMMARY GENERATION $(meta_get generation)"
  exit 0
fi

# ---------- safe report: kit version, OS label, stage table, check ids/statuses; no paths, addresses, names ----------
if [ "$REPORT" -eq 1 ]; then
  osv=""; [ -f "$F_DIAG" ] && osv="$(awk -F'	' '$1=="os"{print $3}' "$F_DIAG")"
  echo "REPORT kit=$KIT_VERSION os=$osv"
  [ -f "$F_STAGES" ] && awk -F'	' '{print "REPORT_STAGE " $1 " " $2 " " $3 " " $4 " " $5 " " $6}' "$F_STAGES"
  [ -f "$F_FACTS" ] && awk -F'	' '{print "REPORT_FACT " $1 " " $2 " " $3 " " $4 " " $5 " " $6}' "$F_FACTS"
  g="$(meta_get generation)"; [ -n "$g" ] && echo "REPORT_GENERATION $g"
  [ -f "$F_DIAG" ] && awk -F'	' '{print "REPORT_CHECK " $1 " " $2 " " $3}' "$F_DIAG"
  echo "REPORT_END (add: stage number, what you saw in your own words WITHOUT passwords, keys, IP addresses, user names, paths)"
  exit 0
fi

# ---------- diagnostics ----------
ensure_state
HAD_STAGES=0; [ -f "$F_STAGES" ] && HAD_STAGES=1
ensure_meta
[ "$ENSURED" -eq 1 ] && [ "$HAD_STAGES" -eq 1 ] && echo "STATE_MIGRATED schema=2 (backup in state/backup-schema1)"
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
  path="$(command -v "$name" 2>/dev/null || true)"
  if [ -z "$path" ]; then
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
un="$(uname -s 2>/dev/null || echo unknown)"
case "$(lower "$un")" in
  darwin|macos) ost="PASS"; ver_os="$(sw_vers -productVersion 2>/dev/null || echo unknown)"; osval="macos-$ver_os"; OSFAM="macos" ;;
  linux) ost="PASS"; osval="linux (remote window or Linux host)"; OSFAM="linux" ;;
  mingw*|msys*|cygwin*) ost="UNKNOWN"; osval="windows-shell; use tools/diagnose.ps1"; OSFAM="windows" ;;
  *) ost="UNKNOWN"; osval="unrecognized"; OSFAM="other" ;;
esac
add_check os "$ost" "$osval" L "$(secs_ms "$t0" "$(date +%s)")"

# place of execution: host OS, shell and the VPS are different things; a Linux shell is not proof of the VPS
case "$OSFAM" in
  macos) add_check exec_place PASS laptop_macos L 0 ;;
  linux)
    ep="$(get_answer exec_place)"
    if [ -n "$ep" ] && [ "$ep" != "unknown" ]; then add_check exec_place PASS "reported $ep" U 0
    elif [ -n "${SSH_CONNECTION:-}" ]; then add_check exec_place PASS ssh-session L 0
    elif grep -qi microsoft /proc/version 2>/dev/null; then add_check exec_place UNKNOWN wsl-not-the-vps ? 0; ask exec_place "WSL detected: this shell is NOT the VPS. Where is this terminal? (remote_linux/local_linux/wsl/unknown)"
    else add_check exec_place UNKNOWN linux-place-unproven ? 0; ask exec_place "Linux shell without an SSH session: is this the remote VPS window or a local Linux? (remote_linux/local_linux/wsl/unknown)"; fi ;;
  windows) add_check exec_place UNKNOWN windows-shell ? 0 ;;
  *) add_check exec_place UNKNOWN unrecognized ? 0 ;;
esac

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

for q in "entry_mode:How to continue: gpt_guide (recommended for newcomers) or vscode_direct?" \
         "server_state:Server state: none, existing_active, replaced or unknown?" \
         "engine_mode:Engines: claude_only, codex_only, both or undecided?"; do
  qk="${q%%:*}"; qt="${q#*:}"
  [ -n "$(get_answer "$qk")" ] || ask "$qk" "$qt"
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
