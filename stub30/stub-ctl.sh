#!/bin/sh
# stub-ctl.sh - 30-port test stub management (start / stop / status / verify)
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
BIN_DIR="${BIN_DIR:-/opt/sa-gw-stub-30/bin}"
CERT_DIR="${CERT_DIR:-/opt/sa-gw-stub-30/certs}"
LOG_DIR="${LOG_DIR:-/var/log/sa-gw-stub-30}"
ALLOW_HOST="${ALLOW_HOST:-svc.example.com}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
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
  [ -x "$BIN_DIR/origin" ] && [ -x "$BIN_DIR/stubgrpc" ] || { echo "[ctl] missing binaries: $BIN_DIR/{origin,stubgrpc}"; return 1; }
  [ -f "$CERT_DIR/upstream/server.chain.crt" ] || { echo "[ctl] missing cert: $CERT_DIR/upstream/server.chain.crt"; return 1; }
  mkdir -p "$LOG_DIR"
  nohup env BIN_DIR="$BIN_DIR" CERT_DIR="$CERT_DIR" LOG_DIR="$LOG_DIR" ALLOW_HOST="$ALLOW_HOST" \
    sh "$SELF_DIR/stub-30.sh" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  sleep 3
  cmd_status
  echo "[ctl] started (main pid $(cat "$PIDFILE"), logs in $LOG_DIR/)"
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
    p=$((40051 + idx))
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

cmd_verify() {
  echo "== semantic probes =="
  fail=0
  idx=0
  # HTTP family /healthz (auth-free) must answer 200
  for auth in $AUTH_KEYS; do
    p=$((40051 + idx))
    code=$(http_probe "http://127.0.0.1:$p/healthz")
    if [ "$code" = 200 ]; then st=UP; else st="DOWN($code)"; fail=$((fail + 1)); fi
    echo "  http-$auth    $p  /healthz -> $st"
    idx=$((idx + 1))
  done
  # Business endpoints must return real values (with credentials)
  if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
    if http_probe "http://127.0.0.1:40051/json" >/dev/null 2>&1; then
      body=$(wget -qO- -T 3 --header 'Host: svc.example.com' --header 'Authorization: Basic c3ZjdXNlcjpzdmNwYXNz' http://127.0.0.1:40051/json 2>/dev/null || curl -s -m 3 -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:40051/json)
      case "$body" in *order-alpha*) echo "  /json  40051  real-value -> UP";; *) echo "  /json  40051  real-value -> DOWN"; fail=$((fail + 1));; esac
      body=$(wget -qO- -T 3 --header 'Host: svc.example.com' --header 'Authorization: Basic c3ZjdXNlcjpzdmNwYXNz' http://127.0.0.1:40051/echo/ctl-selfcheck 2>/dev/null || curl -s -m 3 -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:40051/echo/ctl-selfcheck)
      case "$body" in *ctl-selfcheck*) echo "  /echo  40051  echo -> UP";; *) echo "  /echo  40051  echo -> DOWN"; fail=$((fail + 1));; esac
      body=$(wget -qO- -T 3 --header 'Host: svc.example.com' --header 'Authorization: Basic c3ZjdXNlcjpzdmNwYXNz' http://127.0.0.1:40051/file 2>/dev/null || curl -s -m 3 -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:40051/file)
      case "$body" in *order-alpha*) echo "  /file  40051  csv -> UP";; *) echo "  /file  40051  csv -> DOWN"; fail=$((fail + 1));; esac
    fi
  fi
  # gRPC family: process liveness (stubgrpc binds all 15 ports; real calls need grpcurl)
  if pgrep -f "$BIN_DIR/stubgrpc" >/dev/null 2>&1; then
    echo "  grpc family  40066-40080  process -> UP (grpcurl calls: see README)"
  else
    echo "  grpc family  40066-40080  process -> DOWN"
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
  verify) cmd_verify ;;
  *) echo "usage: $0 {start|stop|status|verify}"; exit 1 ;;
esac
