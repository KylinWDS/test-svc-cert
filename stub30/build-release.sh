#!/bin/bash
# 裸机部署包构建器：交叉编译静态二进制 + 服务器脚本 + systemd unit + 证书 → tar.gz
#
# 用法：
#   ./build-release.sh                    # 证书取自 demo-certs 卷（docker cp，需 Docker Desktop 运行）
#   ./build-release.sh --certs-dir <dir>  # 证书取自本地目录（CERT_DIR 布局：upstream/server.chain.crt、
#                                         #   upstream/server.key、certificates/demo-upstream-ca/1/ca.pem）
# 产物：demo/dist/sa-gw-stub-30-<arch>.tar.gz（arch = amd64 / arm64，各一包）
#
# 目标机要求：仅 Debian Linux（纯静态二进制），无 Docker/openssl/Go 依赖。
set -euo pipefail
cd "$(dirname "$0")"

CERTS_OPT=""
if [ "${1:-}" = "--certs-dir" ] && [ -n "${2:-}" ]; then
  CERTS_OPT="$2"; shift 2 || true
else
  # 默认使用本仓库 certs/generated（先运行 certs/gen.sh 生成；gitignore 不入库）
  CERTS_OPT="$(pwd)/certs/generated"
fi
ARCHS="${ARCHS:-amd64 arm64}"
DIST="$(pwd)/dist"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> 交叉编译静态二进制（goproxy.cn + go.sum 校验）"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" GOSUMDB=off
for arch in $ARCHS; do
  GOOS=linux GOARCH=$arch CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
    -o "$STAGE/origin-linux-$arch" ./cmd/origin
  GOOS=linux GOARCH=$arch CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
    -o "$STAGE/stubgrpc-linux-$arch" ./cmd/stubgrpc
done

echo "==> 收集证书"
CERT_SRC="$(mktemp -d)"
if [ -n "$CERTS_OPT" ] && [ -f "$CERTS_OPT/upstream/server.chain.crt" ]; then
  cp -R "$CERTS_OPT"/. "$CERT_SRC"/
else
  echo "缺少证书：先运行 stub30/certs/gen.sh 生成到 certs/generated/，或用 --certs-dir 指定"
  exit 1
fi
for f in upstream/server.chain.crt upstream/server.key certificates/demo-upstream-ca/1/ca.pem; do
  [ -f "$CERT_SRC/$f" ] || { echo "缺少证书文件 $f（检查 --certs-dir 或容器状态）"; exit 1; }
done

echo "==> 组装部署包"
for arch in $ARCHS; do
  PKG="$STAGE/sa-gw-stub-30"
  mkdir -p "$PKG/bin" "$PKG/certs/upstream" "$PKG/certs/certificates/demo-upstream-ca/1" "$PKG/certs/certificates/demo-gw-client-cert/1" "$PKG/tools" "$PKG/systemd"
  mv "$STAGE/origin-linux-$arch" "$PKG/bin/origin"
  mv "$STAGE/stubgrpc-linux-$arch" "$PKG/bin/stubgrpc"
  # 布局与编译契约一致：CERT_DIR/upstream/* + CERT_DIR/certificates/<id>/<v>/*
  cp "$CERT_SRC/upstream/server.chain.crt" "$PKG/certs/upstream/"
  cp "$CERT_SRC/upstream/server.key" "$PKG/certs/upstream/"
  cp "$CERT_SRC/certificates/demo-upstream-ca/1/ca.pem" "$PKG/certs/certificates/demo-upstream-ca/1/ca.pem"
  # gateway client cert (presented by gateway on mTLS upstream; shipped for local verification)
  cp "$CERT_SRC/certificates/demo-gw-client-cert/1/chain.pem" "$PKG/certs/certificates/demo-gw-client-cert/1/chain.pem"
  cp "$CERT_SRC/certificates/demo-gw-client-cert/1/key.pem" "$PKG/certs/certificates/demo-gw-client-cert/1/key.pem"
  cp stub-30.sh "$PKG/stub-30.sh"
  cp stub-ctl.sh "$PKG/stub-ctl.sh"
  # cert regeneration tool (needs openssl on the build machine; supports ALLOW_HOSTS domain binding)
  cp certs/gen.sh "$PKG/tools/gen-certs.sh"
  cat > "$PKG/systemd/sa-gw-stub-30.service" <<UNIT
[Unit]
Description=sa-gateway 30-port test stub (origin-test x15 + stubgrpc x15)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/sa-gw-stub-30
Environment=BIN_DIR=/opt/sa-gw-stub-30/bin
Environment=CERT_DIR=/opt/sa-gw-stub-30/certs
Environment=LOG_DIR=/var/log/sa-gw-stub-30
ExecStart=/bin/sh /opt/sa-gw-stub-30/stub-30.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  # VERSION：版本溯源（git commit / 构建时间 / 关键产物 md5）
  {
    echo "build: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "source: test-svc-cert stub30 (branch feature/stub-30)"
    echo "commit: $(git -C "$(pwd)" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "arch:   linux/$arch"
    echo "bin md5:"
    (cd "$PKG" && md5 -r bin/origin bin/stubgrpc 2>/dev/null || md5sum bin/origin bin/stubgrpc)
    echo "certs CA fp: $(openssl x509 -in "$PKG/certs/certificates/demo-upstream-ca/1/ca.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2-)"
    echo "stub-ctl md5: $(cd "$PKG" && md5 -r stub-ctl.sh 2>/dev/null || md5sum stub-ctl.sh)"
  } > "$PKG/VERSION"

  cat > "$PKG/INSTALL.txt" <<INST
sa-gateway 30-port test stub -- Debian bare-metal deploy (no Docker / no openssl / binaries only)
=============================================================================
Contents: bin/origin + bin/stubgrpc (Go static build, linux-$arch),
          certs/ (gateway upstream trust chain), stub-30.sh (30-port launcher),
          systemd/sa-gw-stub-30.service

1) Install on target (root or sudo)
  tar xzf sa-gw-stub-30-linux-$arch.tar.gz -C /opt/         # -> /opt/sa-gw-stub-30/
  mkdir -p /var/log/sa-gw-stub-30
  cp /opt/sa-gw-stub-30/systemd/sa-gw-stub-30.service /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now sa-gw-stub-30
  systemctl status sa-gw-stub-30                            # active (running)
  ss -ltn | grep -E '400(5[1-9]|6[0-9]|7[0-9]|80)'          # all 30 ports LISTEN

2) Without systemd (foreground/background)
  cd /opt/sa-gw-stub-30
  BIN_DIR=./bin CERT_DIR=./certs LOG_DIR=./logs nohup sh stub-30.sh >/dev/null 2>&1 &
  # stop: pkill -f 'stub-30.sh|bin/origin|bin/stubgrpc'

3) Business endpoints (all require business auth; /healthz is auth-free)
  GET /            HTML status page (browser-renderable: auth/mTLS state + endpoint list)
  GET /info        request/forwarding info as JSON echo
  GET /json        structured sample data (orders)
  GET /echo/<val>  path param + query full echo
  GET /file        CSV sample (Content-Disposition attachment)
  GET /healthz     auth-free liveness probe (200 ok)
  credentials: basic=svcuser/svcpass  bearer=mytoken  jwt=HS256 mysecret
          apikey=X-Api-Key:myapikey  custom=X-Edge-Auth:edge1

4) Wire up with the gateway (same CA as gateway side, see certs/)
  upstream targets: <server-ip>:<port> (e.g. 10.0.0.5:40051)
  - tls/mtls/grpcs/grpcmtls upstreams: gateway must trust certs/ demo-upstream-ca
    (deployed at certificates/demo-upstream-ca/1/ca.pem under gateway release dir)
  - mtls/grpcmtls upstreams: gateway must present demo-gw-client-cert (client cert)
  - Host check: gateway route rewrite.host=svc.example.com, or send that Host directly
  - credentials: basic=svcuser/svcpass  bearer=mytoken  jwt=HS256 mysecret
            apikey=X-Api-Key:myapikey  custom=X-Edge-Auth:edge1
INST
  # COPYFILE_DISABLE: suppress macOS bsdtar AppleDouble/xattr headers (Debian tar warns on them)
  COPYFILE_DISABLE=1 tar czf "$DIST/sa-gw-stub-30-linux-$arch.tar.gz" --no-xattrs -C "$STAGE" sa-gw-stub-30 2>/dev/null || COPYFILE_DISABLE=1 tar czf "$DIST/sa-gw-stub-30-linux-$arch.tar.gz" -C "$STAGE" sa-gw-stub-30
  echo "  -> dist/sa-gw-stub-30-linux-$arch.tar.gz"
done

echo "==> 完成：dist/ 下共 $(ls "$DIST" | grep -c tar.gz) 个部署包"
