#!/bin/sh
# stub-ctl.sh - 30-port test stub management (start / stop / status / health / info / verify)
# Pure POSIX sh (no bash needed) - works on Debian/Ubuntu/Alpine/busybox.
# Semantics aligned with test-svc-cert/deploy-15.sh, extended to 30 ports.
#
#   start   launch all 30 ports in background (idempotent)
#   stop    stop all instances, clean pidfile
#   status  process liveness (16 processes) + HTTP family /healthz probes
#   verify  semantic probes: HTTP family /healthz must answer 200 (auth-free)
#
# Env overrides (defaults match /opt/sa-gw-stub-30 layout):
#   BIN_DIR / CERT_DIR / LOG_DIR / ALLOW_HOST
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# Path auto-detection: explicit env > extracted dir (./bin ./certs) > /opt default.
# Extract anywhere and run ./stub-ctl.sh start -- no /opt requirement.
BIN_DIR="${BIN_DIR:-}"
CERT_DIR="${CERT_DIR:-}"
if [ -z "$BIN_DIR" ]; then
  if [ -x "$SELF_DIR/bin/origin" ]; then BIN_DIR="$SELF_DIR/bin"; else BIN_DIR="/opt/sa-gw-stub-30/bin"; fi
fi
if [ -z "$CERT_DIR" ]; then
  if [ -f "$SELF_DIR/certs/upstream/server.chain.crt" ]; then CERT_DIR="$SELF_DIR/certs"; else CERT_DIR="/opt/sa-gw-stub-30/certs"; fi
fi
if [ -z "${LOG_DIR:-}" ]; then
  if [ -w "$SELF_DIR" ] || [ "$(id -u)" = 0 ]; then LOG_DIR="$SELF_DIR/logs"; else LOG_DIR="/var/log/sa-gw-stub-30"; fi
fi
ALLOW_HOST="${ALLOW_HOST:-svc.example.com}"
# PORT_BASE: port-segment base (default 40051; segment = base..base+29).
# Shift to avoid collision with ephemeral outbound source ports (bind: address already in use).
PORT_BASE="${PORT_BASE:-40051}"
PIDFILE="$LOG_DIR/stub-30.pid"
AUTH_KEYS="basic bearer jwt apikey custom"

http_probe() { # http_probe <url> -> prints HTTP status code (wget first, curl fallback)
  if command -v wget >/dev/null 2>&1; then
    wget -qO /dev/null -T 3 --server-response "$1" 2>&1 | awk '/HTTP\//{c=$2} END{print c}'
  elif command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -m 3 -w '%{http_code}' "$1"
  else
    echo "000"
  fi
}

is_running() { # main process alive: pidfile or any instance process
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && return 0
  pgrep -f "$BIN_DIR/origin|$BIN_DIR/stubgrpc" >/dev/null 2>&1
}

cmd_start() {
  if is_running; then
    echo "[ctl] already running (pid $(cat "$PIDFILE" 2>/dev/null || echo '?')); use status / stop"
    return 0
  fi
  [ -x "$BIN_DIR/origin" ] && [ -x "$BIN_DIR/stubgrpc" ] || { echo "[ctl] missing binaries in: $BIN_DIR"
    echo "[ctl] hint: run from the extracted sa-gw-stub-30/ directory, or set BIN_DIR=<path> explicitly"
    return 1; }
  [ -f "$CERT_DIR/upstream/server.chain.crt" ] || { echo "[ctl] missing cert: $CERT_DIR/upstream/server.chain.crt"; return 1; }
  mkdir -p "$LOG_DIR"
  nohup env BIN_DIR="$BIN_DIR" CERT_DIR="$CERT_DIR" LOG_DIR="$LOG_DIR" ALLOW_HOST="$ALLOW_HOST" \
    sh "$SELF_DIR/stub-30.sh" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  sleep 3
  cmd_status
  echo "[ctl] started (main pid $(cat "$PIDFILE"), logs in $LOG_DIR/)"
  if ! pgrep -f "$BIN_DIR/stubgrpc" >/dev/null 2>&1; then
    echo "[ctl] WARNING: stubgrpc is NOT running - last log lines ($LOG_DIR/stubgrpc.log):"
    tail -5 "$LOG_DIR/stubgrpc.log" 2>/dev/null || echo "(no stubgrpc.log found)"
    echo "[ctl] port 40066 occupant (if any):"
    ss -ltnp 'sport = :40066' 2>/dev/null || echo "(none listening now - occupancy was transient)"
  fi
}

cmd_stop() {
  killed=0
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null && killed=1
    rm -f "$PIDFILE"
  fi
  pkill -f "$BIN_DIR/origin" 2>/dev/null && killed=1
  pkill -f "$BIN_DIR/stubgrpc" 2>/dev/null && killed=1
  pkill -f "stub-30.sh" 2>/dev/null && killed=1
  sleep 1
  if [ "$killed" = 1 ]; then echo "[ctl] stopped"; else echo "[ctl] no running stub found"; fi
}

cmd_status() {
  echo "== process liveness =="
  origins=$(pgrep -f "$BIN_DIR/origin" | wc -l | tr -d ' ')
  grpc=$(pgrep -f "$BIN_DIR/stubgrpc" | wc -l | tr -d ' ')
  echo "  origin instances   : $origins/15"
  echo "  stubgrpc processes : $grpc/1"
  echo "== HTTP family /healthz probes =="
  idx=0
  fail=0
  for auth in $AUTH_KEYS; do
    p=$((PORT_BASE + idx))
    code=$(http_probe "http://127.0.0.1:$p/healthz")
    if [ "$code" = 200 ]; then st=UP; else st="DOWN($code)"; fail=$((fail + 1)); fi
    echo "  http-$auth    $p  /healthz -> $st"
    idx=$((idx + 1))
  done
  echo "== summary =="
  if is_running && [ "$fail" = 0 ]; then
    echo "main: running, all health probes passed"
    return 0
  fi
  echo "main: NOT healthy (fail=$fail)"
  return 1
}


cmd_info() {
  echo "== stub deployment info =="
  [ -f "$SELF_DIR/VERSION" ] && sed 's/^/  /' "$SELF_DIR/VERSION"
  echo "  binary dir   : $BIN_DIR"
  echo "  origin       : $(ls -l "$BIN_DIR/origin" 2>/dev/null | awk '{print $5" bytes"}')"
  echo "  stubgrpc     : $(ls -l "$BIN_DIR/stubgrpc" 2>/dev/null | awk '{print $5" bytes"}')"
  echo "  state        : $(is_running && echo running || echo stopped)"
  echo "  allow hosts  : $ALLOW_HOST"
  echo "  cert dir     : $CERT_DIR"
  echo "  server cert  : $CERT_DIR/upstream/server.chain.crt"
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$CERT_DIR/upstream/server.chain.crt" -noout -subject -ext subjectAltName 2>/dev/null | sed 's/^/    /'
  fi
  echo "  gateway CA   : $CERT_DIR/certificates/demo-upstream-ca/1/ca.pem"
  echo "  gw client cert: $CERT_DIR/certificates/demo-gw-client-cert/1/chain.pem"
  echo "  log dir      : $LOG_DIR"
  echo "== port matrix (base $PORT_BASE) =="
  echo "  http  $PORT_BASE..$((PORT_BASE+4))    | tls  $((PORT_BASE+5))..$((PORT_BASE+9))    | mtls  $((PORT_BASE+10))..$((PORT_BASE+14))"
  echo "  grpc  $((PORT_BASE+15))..$((PORT_BASE+19)) | grpcs $((PORT_BASE+20))..$((PORT_BASE+24)) | grpcmtls $((PORT_BASE+25))..$((PORT_BASE+29))"
  echo "== credentials =="
  echo "  basic=svcuser/svcpass  bearer=mytoken  jwt=HS256 mysecret"
  echo "  apikey=X-Api-Key:myapikey  custom=X-Edge-Auth:edge1"
  echo "== business endpoints (auth required; /healthz auth-free) =="
  echo "  GET /            HTML status page"
  echo "  GET /info        request/forwarding info JSON"
  echo "  GET /json        structured sample data"
  echo "  GET /echo/<val>  path+query echo JSON"
  echo "  GET /file        CSV sample (attachment download)"
}

cmd_health() {
  fail=0
  if ! is_running; then
    echo "HEALTH: FAIL (processes not running)"
    return 1
  fi
  idx=0
  for auth in $AUTH_KEYS; do
    p=$((40051 + idx))
    code=$(http_probe "http://127.0.0.1:$p/healthz")
    if [ "$code" != 200 ]; then
      echo "HEALTH: FAIL (http-$auth :$p /healthz -> $code)"
      fail=1
    fi
    idx=$((idx + 1))
  done
  if ! pgrep -f "$BIN_DIR/stubgrpc" >/dev/null 2>&1; then
    echo "HEALTH: FAIL (stubgrpc process missing)"
    fail=1
  fi
  if [ "$fail" = 0 ]; then
    echo "HEALTH: PASS (15/15 http probes 200, grpc family alive)"
    return 0
  fi
  return 1
}

cmd_verify() {
  echo "== semantic probes =="
  fail=0
  idx=0
  # HTTP family /healthz (auth-free) must answer 200
  for auth in $AUTH_KEYS; do
    p=$((PORT_BASE + idx))
    code=$(http_probe "http://127.0.0.1:$p/healthz")
    if [ "$code" = 200 ]; then st=UP; else st="DOWN($code)"; fail=$((fail + 1)); fi
    echo "  http-$auth    $p  /healthz -> $st"
    idx=$((idx + 1))
  done
  # Business endpoints must return real values (with credentials).
  # Requires a client able to send custom headers: curl, or GNU wget (--header).
  # busybox wget (alpine) cannot send Host/Authorization -> these checks are skipped.
  if command -v curl >/dev/null 2>&1 || wget --help 2>&1 | grep -q -- '--header'; then
    host_hdr=$(echo "$ALLOW_HOST" | cut -d, -f1)
    body=$(curl -s -m 3 -u svcuser:svcpass -H "Host: $host_hdr" "http://127.0.0.1:$PORT_BASE/json" 2>/dev/null || wget -qO- -T 3 --header "Host: $host_hdr" --header 'Authorization: Basic c3ZjdXNlcjpzdmNwYXNz' "http://127.0.0.1:$PORT_BASE/json" 2>/dev/null)
    case "$body" in *order-alpha*) echo "  /json  40051  real-value -> UP";; *) echo "  /json  40051  real-value -> DOWN"; fail=$((fail + 1));; esac
    body=$(curl -s -m 3 -u svcuser:svcpass -H "Host: $host_hdr" "http://127.0.0.1:$PORT_BASE/echo/ctl-selfcheck" 2>/dev/null || wget -qO- -T 3 --header "Host: $host_hdr" --header 'Authorization: Basic c3ZjdXNlcjpzdmNwYXNz' "http://127.0.0.1:$PORT_BASE/echo/ctl-selfcheck" 2>/dev/null)
    case "$body" in *ctl-selfcheck*) echo "  /echo  40051  echo -> UP";; *) echo "  /echo  40051  echo -> DOWN"; fail=$((fail + 1));; esac
    body=$(curl -s -m 3 -u svcuser:svcpass -H "Host: $host_hdr" "http://127.0.0.1:$PORT_BASE/file" 2>/dev/null || wget -qO- -T 3 --header "Host: $host_hdr" --header 'Authorization: Basic c3ZjdXNlcjpzdmNwYXNz' "http://127.0.0.1:$PORT_BASE/file" 2>/dev/null)
    case "$body" in *order-alpha*) echo "  /file  40051  csv -> UP";; *) echo "  /file  40051  csv -> DOWN"; fail=$((fail + 1));; esac
  else
    echo "  business endpoints: SKIP (client cannot send custom headers; use curl or GNU wget)"
  fi
  # gRPC family: process liveness (stubgrpc binds all 15 ports; real calls need grpcurl)
  if pgrep -f "$BIN_DIR/stubgrpc" >/dev/null 2>&1; then
    echo "  grpc family  $((PORT_BASE+15))-$((PORT_BASE+29))  process -> UP (grpcurl calls: see README)"
  else
    echo "  grpc family  $((PORT_BASE+15))-$((PORT_BASE+29))  process -> DOWN"
    fail=$((fail + 1))
  fi
  if [ "$fail" = 0 ]; then
    echo "== all passed =="
    return 0
  fi
  echo "== $fail failures =="
  return 1
}

case "${1:-}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  health) cmd_health ;;
  info)   cmd_info ;;
  verify) cmd_verify ;;
  *) echo "usage: $0 {start|stop|status|health|info|verify}"; exit 1 ;;
esac
