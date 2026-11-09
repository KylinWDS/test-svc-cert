#!/bin/sh
# 30 端口测试桩启动器（容器与裸机 Debian 通用，路径可参数化）
#
#   origin-test 15 实例（http/tls/mtls × basic/bearer/jwt/apikey/custom，端口 40051–40065）
#   stubgrpc    1 进程 15 listeners（grpc/grpcs/grpcmtls × 5 认证，端口 40066–40080）
# 凭据集与 test-svc-cert/README 默认值一致：
#   basic=svcuser/svcpass  bearer=mytoken  jwt=HS256 mysecret  apikey=X-Api-Key:myapikey  custom=X-Edge-Auth:edge1
#
# 环境变量（默认值为容器布局）：
#   BIN_DIR=/usr/local/bin  CERT_DIR=/certs  LOG_DIR=/var/log/stub  ALLOW_HOST=svc.example.com
set -u
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CERT_DIR="${CERT_DIR:-/certs}"
LOG_DIR="${LOG_DIR:-/var/log/stub}"
ALLOW_HOST="${ALLOW_HOST:-svc.example.com}"
# PORT_BASE: 端口段基址（默认 40051，段内 30 个端口 = base..base+29）。
# 若默认段与系统 ephemeral 出站源端口范围冲突（bind: address already in use），
# 设 PORT_BASE=41051 整段平移避开，无需 root 改内核参数。
PORT_BASE="${PORT_BASE:-40051}"

CERT="$CERT_DIR/upstream/server.chain.crt"
KEY="$CERT_DIR/upstream/server.key"
CA="$CERT_DIR/certificates/demo-upstream-ca/1/ca.pem"
ORIGIN="$BIN_DIR/origin"
STUBGRPC="$BIN_DIR/stubgrpc"

mkdir -p "$LOG_DIR"

case_auth() {
  case "$1" in
    basic)  echo "-auth-basic-user svcuser -auth-basic-pass svcpass" ;;
    bearer) echo "-auth-bearer-token mytoken" ;;
    jwt)    echo "-auth-jwt-secret mysecret" ;;
    apikey) echo "-auth-api-key myapikey -auth-api-key-header X-Api-Key" ;;
    custom) echo "-auth-custom-header X-Edge-Auth -auth-custom-value edge1" ;;
  esac
}

i=0
for auth in basic bearer jwt apikey custom; do
  A=$(case_auth "$auth")

  # ① HTTP 明文：PORT_BASE+0..4（默认 40051-40055）
  p=$((PORT_BASE + i))
  "$ORIGIN" -listen-http ":$p" -listen-https "" $A -allow-host "$ALLOW_HOST" >"$LOG_DIR/http-$auth.log" 2>&1 &
  echo "[stub] http-$auth    :$p (pid $!)"

  # ② 回源 TLS 单向：PORT_BASE+5..9（默认 40056-40060）
  p=$((PORT_BASE + 5 + i))
  "$ORIGIN" -listen-http "" -listen-https ":$p" -cert "$CERT" -key "$KEY" $A -allow-host "$ALLOW_HOST" >"$LOG_DIR/tls-$auth.log" 2>&1 &
  echo "[stub] tls-$auth     :$p (pid $!)"

  # ③ 回源 mTLS 双向：PORT_BASE+10..14（默认 40061-40065）
  p=$((PORT_BASE + 10 + i))
  "$ORIGIN" -listen-http "" -listen-https ":$p" -cert "$CERT" -key "$KEY" -client-ca "$CA" $A -allow-host "$ALLOW_HOST" >"$LOG_DIR/mtls-$auth.log" 2>&1 &
  echo "[stub] mtls-$auth    :$p (pid $!)"

  i=$((i + 1))
done

# ④ gRPC family: PORT_BASE+15..+29 (5 auths) + +30..+32 (auth-free none); GRPC_PORT_BASE aligned with PORT_BASE
GRPC_PORT_BASE=$((PORT_BASE + 15)) "$STUBGRPC" >"$LOG_DIR/stubgrpc.log" 2>&1 &
echo "[stub] grpc family   :$((PORT_BASE + 15))-$((PORT_BASE + 32)) incl. 3 auth-free none (pid $!)"
echo "[stub] 全部 30 端口已拉起，日志见 $LOG_DIR/"
wait
