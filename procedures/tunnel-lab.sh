#!/usr/bin/env bash
# Temporary A/B tunnel check between this computer and a server you already have key access to.
# usage: bash procedures/tunnel-lab.sh <ssh-host-alias> [local-port-A] [remote-port-A] [local-port-B] [remote-port-B]
# What it does (all temporary, all on loopback only, all removed at the end):
#   A  local forward : a throw-away test service runs on the SERVER loopback; ssh -L brings it to this computer's loopback.
#   B  reverse forward: a throw-away test service runs on THIS computer's loopback; ssh -R exposes it on the SERVER loopback.
# What it does NOT do: no SSH or firewall configuration change, no package install, no permanent service, no autostart,
# no traffic routing, no public port, no password prompt (BatchMode), no write outside one temporary directory.
# Output is codes only: no address, no user name, no path of the server.
set -u
HOST="${1:-}"; LA="${2:-18480}"; RA="${3:-18481}"; LB="${4:-18482}"; RB="${5:-18483}"
[ -n "$HOST" ] || { echo "usage: tunnel-lab.sh <ssh-host-alias> [ports...]"; exit 2; }
printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9_.-]{1,60}$' || { echo "TUNNEL_LAB_ERROR bad host alias"; exit 2; }
for p in "$LA" "$RA" "$LB" "$RB"; do case "$p" in ''|*[!0-9]*) echo "TUNNEL_LAB_ERROR ports must be numbers"; exit 2 ;; esac; [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] || { echo "TUNNEL_LAB_ERROR ports must be 1024..65535"; exit 2; }; done
SSHO="-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes"
MARK="tunnel-lab-$$-$(date +%s)"
LOCAL_TMP="$(mktemp -d)"; LPIDS=""; REMOTE_DIR=""; ACCESS_OK=0
res() { echo "TUNNEL_LAB $1 $2${3:+ $3}"; }

port_free_local() { ! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null; }
cleanup() {
  for p in $LPIDS; do kill "$p" 2> /dev/null; done
  [ -n "$REMOTE_DIR" ] && ssh $SSHO "$HOST" "d='$REMOTE_DIR'; [ -f \"\$d/pid\" ] && kill \$(cat \"\$d/pid\") 2>/dev/null; rm -rf \"\$d\"" > /dev/null 2>&1
  rm -rf "$LOCAL_TMP"
  sleep 1
  ok=1; for p in "$LA" "$LB"; do port_free_local "$p" || ok=0; done
  rok="unknown"
  if [ "$ACCESS_OK" = 0 ]; then rok="free"
  elif ssh $SSHO "$HOST" "python3 - <<'PY'
import socket,sys
bad=0
for p in ($RA,$RB):
    s=socket.socket(); s.settimeout(1)
    try:
        s.connect(('127.0.0.1',p)); bad=1
    except Exception: pass
    finally: s.close()
sys.exit(bad)
PY" > /dev/null 2>&1; then rok="free"; else rok="IN_USE"; fi
  if [ "$ok" = 1 ] && [ "$rok" = "free" ]; then res CLEANUP PASS "local_ports=free remote_ports=free temp_removed=yes"; else res CLEANUP CHECK "local_ports_free=$ok remote_ports=$rok"; fi
}
trap cleanup EXIT

listeners() { # non-loopback listening sockets on the SERVER (count only; nothing is printed)
  ssh $SSHO "$HOST" "ss -ltnH 2>/dev/null | awk '{print \$4}' | grep -Ev '^(127\.0\.0\.1|\[::1\]|::1)' | sort | md5sum | cut -c1-12" 2> /dev/null
}
diagnose() { # $1 = pid of the ssh forward process, $2 = remote port of the test service
  if ! kill -0 "$1" 2> /dev/null; then echo "FORWARD_PROCESS_ENDED (forwarding refused by the server, the port was taken, or the connection dropped)"; return; fi
  ssh $SSHO "$HOST" true > /dev/null 2>&1 || { echo "NETWORK_OR_ACCESS_DOWN (the server is not reachable now)"; return; }
  if ssh $SSHO "$HOST" "curl -s --max-time 3 -o /dev/null 127.0.0.1:$2/marker.txt" > /dev/null 2>&1; then echo "TUNNEL_PATH_PROBLEM (service answers on the server, the tunnel does not carry it)"; else echo "TEST_SERVICE_NOT_RUNNING (the throw-away service on the server is not answering)"; fi
}
# ---- pre-checks (nothing is started before they pass)
for p in "$LA" "$LB"; do port_free_local "$p" || { res PRECHECK FAIL "local_port_in_use=$p"; exit 3; }; done
ssh $SSHO "$HOST" true > /dev/null 2>&1 || { res ACCESS FAIL "key_access_not_available (no password is requested; nothing changed)"; exit 3; }
ACCESS_OK=1; res ACCESS PASS "key_only"
R="$(ssh $SSHO "$HOST" "command -v python3 >/dev/null && command -v curl >/dev/null && echo tools_ok || echo tools_missing; python3 - <<'PY'
import socket
for p in ($RA,$RB):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(('127.0.0.1',p)); print('free',p)
    except Exception: print('busy',p)
    finally: s.close()
PY" 2> /dev/null | tr '\n' ' ')"
case "$R" in *tools_ok*) ;; *) res PRECHECK FAIL "remote_tools_missing"; exit 3 ;; esac
case "$R" in *busy*) res PRECHECK FAIL "remote_port_in_use"; exit 3 ;; esac
res PRECHECK PASS "ports_free tools_ok"
L0="$(listeners)"

# ---- remote temporary loopback test service
REMOTE_DIR="$(ssh $SSHO "$HOST" "d=\$(mktemp -d) && echo '$MARK' > \"\$d/marker.txt\" && (nohup python3 -m http.server $RA --bind 127.0.0.1 --directory \"\$d\" > /dev/null 2>&1 & echo \$! > \"\$d/pid\") && echo \"\$d\"" 2> /dev/null | tail -n1)"
[ -n "$REMOTE_DIR" ] || { res REMOTE_SERVICE FAIL "could_not_start"; exit 3; }
sleep 2

# ---- A: local forward
ssh $SSHO -N -L "127.0.0.1:$LA:127.0.0.1:$RA" "$HOST" > /dev/null 2>&1 &
PA=$!; LPIDS="$LPIDS $PA"
got=""; for i in 1 2 3 4 5 6 7 8 9 10; do got="$(curl -s --max-time 3 "127.0.0.1:$LA/marker.txt" 2> /dev/null | tr -d '\r\n')"; [ "$got" = "$MARK" ] && break; sleep 1; done
if [ "$got" = "$MARK" ]; then res A_LOCAL_FORWARD PASS "marker_matched"; else res A_LOCAL_FORWARD FAIL "$(diagnose "$PA" "$RA")"; fi

# ---- B: reverse forward
echo "$MARK-b" > "$LOCAL_TMP/marker.txt"
python3 -m http.server "$LB" --bind 127.0.0.1 --directory "$LOCAL_TMP" > /dev/null 2>&1 &
LPIDS="$LPIDS $!"
sleep 1
ssh $SSHO -N -R "127.0.0.1:$RB:127.0.0.1:$LB" "$HOST" > /dev/null 2>&1 &
PB=$!; LPIDS="$LPIDS $PB"
got=""; for i in 1 2 3 4 5 6 7 8 9 10; do got="$(ssh $SSHO "$HOST" "curl -s --max-time 3 127.0.0.1:$RB/marker.txt" 2> /dev/null | tr -d '\r\n')"; [ "$got" = "$MARK-b" ] && break; sleep 1; done
if [ "$got" = "$MARK-b" ]; then res B_REVERSE_FORWARD PASS "marker_matched"; else res B_REVERSE_FORWARD FAIL "$(kill -0 "$PB" 2> /dev/null && echo "TUNNEL_PATH_PROBLEM_OR_LOCAL_SERVICE_DOWN" || echo "FORWARD_PROCESS_ENDED (reverse forwarding refused by the server, the port was taken, or the connection dropped)")"; fi
L1="$(listeners)"
if [ -n "$L0" ] && [ "$L0" = "$L1" ]; then res PUBLIC_LISTENERS PASS "no_new_non_loopback_listener"; else res PUBLIC_LISTENERS CHECK "snapshot_differs_or_unavailable"; fi
# the main access must still work at the end (the cleanup trap checks ports; this checks the access itself)
ssh $SSHO "$HOST" true > /dev/null 2>&1 && res MAIN_SSH PASS "still_key_only" || res MAIN_SSH FAIL "not_reachable_after_test"
exit 0
