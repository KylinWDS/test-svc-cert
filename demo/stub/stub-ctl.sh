#!/usr/bin/env bash
# stub-ctl.sh - 30-port test stub management (start / stop / status / verify)
# Semantics aligned with test-svc-cert/deploy-15.sh, extended to 30 ports (gRPC family).
# Requires: bash (built-in on Debian); probes prefer wget, fall back to curl.
# Env overrides (defaults match /opt/sa-gw-stub-30 layout):
#   BIN_DIR / CERT_DIR / LOG_DIR / ALLOW_HOST
set -u
BIN_DIR="${BIN_DIR:-/opt/sa-gw-stub-30/bin}"
CERT_DIR="${CERT_DIR:-/opt/sa-gw-stub-30/certs}"
LOG_DIR="${LOG_DIR:-/var/log/sa-gw-stub-30}"
ALLOW_HOST="${ALLOW_HOST:-svc.example.com}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$LOG_DIR/stub-30.pid"
AUTH_KEYS=(basic bearer jwt apikey custom)
FAMILIES=("http 40051" "tls 40056" "mtls 40061" "grpc 40066" "grpcs 40071" "grpcmtls 40076")

http_probe() { # http_probe <url> -> prints HTTP status code (wget first, curl fallback)
  if command -v wget >/dev/null 2>&1; then
    wget -qO /dev/null -T 3 --server-response "$1" 2>&1 | awk '/HTTP\//{c=$2} END{print c}'
  elif command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -m 3 -w '%{http_code}' "$1"
  else
    echo "000"
  fi
}

tcp_probe() { # tcp_probe <host> <port> -> 0 if connectable
  timeout 2 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null
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
  local killed=0
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
  echo "== 30-port TCP liveness =="
  local down=0 idx=0 fam p st
  for auth in "${AUTH_KEYS[@]}"; do
    for f in "${FAMILIES[@]}"; do
      set -- $f
      fam="$1"; p=$(($2 + idx))
      if tcp_probe 127.0.0.1 "$p"; then st=UP; else st=DOWN; down=$((down + 1)); fi
      printf "  %-14s %s  %s\n" "$fam-$auth" "$p" "$st"
    done
    idx=$((idx + 1))
  done
  echo "== summary =="
  if is_running; then echo "main: running (DOWN=$down)"; else echo "main: NOT running (DOWN=$down)"; return 1; fi
}

cmd_verify() {
  echo "== semantic probes =="
  local fail=0 idx p code st
  # HTTP family /healthz (no Host/auth required) must answer 200
  for idx in 0 1 2 3 4; do
    p=$((40051 + idx))
    code=$(http_probe "http://127.0.0.1:$p/healthz")
    case "$code" in 200) st=UP ;; *) st="DOWN($code)"; fail=$((fail + 1)) ;; esac
    printf "  http-%-9s %s  /healthz -> %s\n" "${AUTH_KEYS[$idx]}" "$p" "$st"
  done
  # gRPC family TCP liveness (real protocol calls need grpcurl, see demo/README.md 3.4)
  for base in 40066 40071 40076; do
    for idx in 0 1 2 3 4; do
      p=$((base + idx))
      if tcp_probe 127.0.0.1 "$p"; then st=UP; else st=DOWN; fail=$((fail + 1)); fi
      printf "  grpc@%s   %s  tcp -> %s\n" "$base" "$p" "$st"
    done
  done
  if [ "$fail" = 0 ]; then echo "== all passed =="; else echo "== $fail failures =="; return 1; fi
}

case "${1:-}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  verify) cmd_verify ;;
  *) echo "usage: $0 {start|stop|status|verify}"; exit 1 ;;
esac
