#!/usr/bin/env bash
# deploy-15.sh — 一键平铺部署 15 种「传输层 × 业务认证」组合的 origin-test 实例
#
#   传输层 3 种:  http(明文) / tls(回源TLS单向) / mtls(回源mTLS双向)
#   认证 5 种:    basic / bearer / jwt / apikey / custom
#   端口:         40051 - 40065 (每实例 1 个)
#
# 用法:
#   ./deploy-15.sh           启动全部 15 个实例
#   ./deploy-15.sh start     同上
#   ./deploy-15.sh stop      停止全部
#   ./deploy-15.sh restart   重启全部
#   ./deploy-15.sh status    列出 15 个实例的端口/方式/存活
#   ./deploy-15.sh verify    逐一探活 /healthz, 输出 UP/DOWN
#
# 覆盖:
#   BIN=<路经>   指定要用的二进制(默认同目录 origin-test-linux-amd64;
#                                本地自测可 BIN=./origin-test 用原生二进制)
#   ALLOW_HOST=  允许的 Host(默认 svc.example.com)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BIN:-$DIR/origin-test-linux-amd64}"
CERTDIR="${DIR}/certs"
PIDS_DIR="${DIR}/run"
HOST="${ALLOW_HOST:-svc.example.com}"

TRANSPORT=(http tls mtls)
AUTH=(basic bearer jwt apikey custom)
PORT_BASE=40051

# “该组合(传输层, 认证, 端口)”要传的参数 → 写入全局数组 COMBO_ARGS
COMBO_ARGS=()
combine_args() { # $1=transport $2=auth $3=port
  local t="$1" a="$2" p="$3"
  COMBO_ARGS=()
  case "$t" in
    http) COMBO_ARGS=(-listen-http ":$p" -listen-https "") ;;
    tls)  COMBO_ARGS=(-listen-http "" -listen-https ":$p" \
                     -cert "${CERTDIR}/server.pem" -key "${CERTDIR}/server.key") ;;
    mtls) COMBO_ARGS=(-listen-http "" -listen-https ":$p" \
                     -cert "${CERTDIR}/server.pem" -key "${CERTDIR}/server.key" \
                     -client-ca "${CERTDIR}/ca.pem") ;;
  esac
  case "$a" in
    basic)  COMBO_ARGS+=(-auth-basic-user svcuser -auth-basic-pass svcpass) ;;
    bearer) COMBO_ARGS+=(-auth-bearer-token mytoken) ;;
    jwt)    COMBO_ARGS+=(-auth-jwt-secret mysecret) ;;
    apikey) COMBO_ARGS+=(-auth-api-key myapikey -auth-api-key-header X-Api-Key) ;;
    custom) COMBO_ARGS+=(-auth-custom-header X-Edge-Auth -auth-custom-value edge1) ;;
  esac
  COMBO_ARGS+=(-allow-host "${HOST}")
}

name_of() { echo "${TRANSPORT[$1]}-${AUTH[$2]}"; } # $1=t $2=a
port_of() { echo $((PORT_BASE + $1 * ${#AUTH[@]} + $2)); }

preflight() {
  [ -x "$BIN" ] || { echo "错误: 找不到可执行文件 $BIN (用 BIN=<路经> 指定)"; exit 1; }
  # tls/mtls 需要证书; 缺失则提示如何生成(见 README「文件与生成」)
  if [ ! -f "${CERTDIR}/server.pem" ] || [ ! -f "${CERTDIR}/server.key" ]; then
    echo "错误: 缺少 ${CERTDIR}/server.pem 或 server.key。"
    echo "  生成方式(在能跑 openssl 的机器上): ./gen-cert.sh"
    echo "  然后把 certs/*(含 ca.pem/server.pem/server.key/client.pem/client.key) 整体传上来。"
    exit 1
  fi
}

start_one() { # $1=t $2=a
  local t="$1" a="$2" name port pid
  name=$(name_of "$t" "$a"); port=$(port_of "$t" "$a")
  combine_args "${TRANSPORT[$t]}" "${AUTH[$a]}" "$port"
  # shellcheck disable=SC2068
  nohup "$BIN" "${COMBO_ARGS[@]}" >>"${PIDS_DIR}/${name}.log" 2>&1 &
  pid=$!
  echo "$pid" > "${PIDS_DIR}/${name}.pid"
  echo "  起  [$(printf '%-12s' "$name")] 端口 $port  ${COMBO_ARGS[*]}"
}

stop_one() { # $1=name
  local f="${PIDS_DIR}/$1.pid"
  [ -f "$f" ] || return 0
  kill "$(cat "$f")" 2>/dev/null && echo "  停  $1" || echo "  停  $1 (已不在运行)"
  rm -f "$f"
}

start_all() {
  mkdir -p "$PIDS_DIR"
  echo "== 启动全部 15 个实例(端口 $PORT_BASE-$((PORT_BASE+14))) =="
  for t in "${!TRANSPORT[@]}"; do for a in "${!AUTH[@]}"; do
    start_one "$t" "$a"
  done; done
  echo "== 全部已启动. PID 见 run/*.pid, 日志见 run/*.log. 用 './deploy-15.sh status' 确认 =="
}

stop_all() {
  echo "== 停止全部 =="
  for f in "${PIDS_DIR}"/*.pid; do
    [ -e "$f" ] || continue
    stop_one "$(basename "$f" .pid)"
  done
}

status() {
  echo "端口    组合              传输    认证      PID   状态"
  echo "-----  ---------------  --------  -------  ----  ------"
  for t in "${!TRANSPORT[@]}"; do for a in "${!AUTH[@]}"; do
    local name port pid alive
    name=$(name_of "$t" "$a"); port=$(port_of "$t" "$a")
    pid=$(cat "${PIDS_DIR}/${name}.pid" 2>/dev/null || echo "-")
    alive="-"
    if [ "$pid" != "-" ] && kill -0 "$pid" 2>/dev/null; then alive="运行中"; fi
    printf "%s  %-12s  %-8s  %-7s  %-4s  %s\n" \
      "$port" "$name" "${TRANSPORT[$t]}" "${AUTH[$a]}" "$pid" "$alive"
  done; done
}

verify() {
  echo "== 逐一探活 /healthz(免 Host/认证; https 用 -k) =="
  for t in "${!TRANSPORT[@]}"; do for a in "${!AUTH[@]}"; do
    local name port url extra
    name=$(name_of "$t" "$a"); port=$(port_of "$t" "$a")
    if   [ "${TRANSPORT[$t]}" = "http" ]; then url="http://127.0.0.1:${port}/healthz";             extra=()
    elif [ "${TRANSPORT[$t]}" = "tls" ];  then url="https://127.0.0.1:${port}/healthz";             extra=()
    else                                       url="https://127.0.0.1:${port}/healthz";             extra=(--cert "${CERTDIR}/client.pem" --key "${CERTDIR}/client.key")
    fi
    code=$(curl -sk "${extra[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    printf "  %-12s 端口 %s  /healthz → %s\n" "$name" "$port" "$([ "$code" = 200 ] && echo UP || echo "DOWN($code)")"
  done; done
}

preflight
case "${1:-start}" in
  start|deploy)  start_all ;;
  stop)          stop_all ;;
  restart)       stop_all; start_all ;;
  status)        status ;;
  verify)        verify ;;
  *) echo "用法: $0 [start|stop|restart|status|verify]"; exit 2 ;;
esac