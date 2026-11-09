#!/bin/sh
# 初始化容器执行的证书生成脚本（alpine/openssl 镜像，sh 兼容）。
# 生成物写入 /certs（demo-certs 卷）：
#   certificates/demo-gw-cert/1/{chain.pem,key.pem}      网关入口 HTTPS 证书（:10443）
#   certificates/demo-upstream-ca/1/ca.pem               Envoy 回源信任 CA
#   upstream/server.chain.crt + upstream/server.key      上游服务端证书（HTTPS/gRPCS）
# 客户端信任用的 CA 副本：/certs/demo-ca.crt（可用 docker cp 拷出）
set -e
# 证书输出目录：默认为本脚本所在目录（stub30/certs/），可用 CERT_DIR 覆盖
# 布局与编译契约一致：certs/upstream/* + certs/certificates/<id>/<version>/*
D="${CERT_DIR:-$(cd "$(dirname "$0")" && pwd)/generated}"

# 幂等保护：证书已生成则跳过（保证 CA/证书集跨容器重启恒定；
# 消费方（Envoy/上游）启动时读入内存，若证书在运行中被重生成会造成信任链错配。
# 需要轮换时：docker compose down -v 清卷后重建，或手动删除 /certs/.done）
if [ -f "$D/.done" ]; then
  echo "[certs] already generated (see .done), skip."
  exit 0
fi

mkdir -p "$D/certificates/demo-gw-cert/1" "$D/certificates/demo-upstream-ca/1" "$D/certificates/demo-gw-client-cert/1" "$D/upstream"

# 1) 演示 CA（同时签发网关证书与上游证书，客户端统一信任它即可）
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout "$D/ca.key" -out "$D/ca.crt" \
  -subj "/CN=sa-gateway-demo-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

# 2) 网关入口证书（SAN: localhost / demo-gateway / 127.0.0.1）
printf "subjectAltName=DNS:localhost,DNS:demo-gateway,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > "$D/gw.ext"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$D/gw.key" -out "$D/gw.csr" \
  -subj "/CN=demo-gateway" \
  -addext "subjectAltName=DNS:localhost,DNS:demo-gateway,IP:127.0.0.1"
openssl x509 -req -in "$D/gw.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
  -days 3650 -sha256 -extfile "$D/gw.ext" -out "$D/gw.crt"
cat "$D/gw.crt" "$D/ca.crt" > "$D/certificates/demo-gw-cert/1/chain.pem"
cp "$D/gw.key" "$D/certificates/demo-gw-cert/1/key.pem"

# 3) 上游服务端证书（SAN 必须覆盖：demo-upstream（演示上游）、demo-stub（30 端口测试桩）、
#    svc.example.com（origin-test -allow-host 放行域），Envoy 回源按节点主机名做 SAN 匹配与 SNI）
printf "subjectAltName=DNS:demo-upstream,DNS:demo-stub,DNS:svc.example.com,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > "$D/upstream/server.ext"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$D/upstream/server.key" -out "$D/upstream/server.csr" \
  -subj "/CN=demo-upstream" \
  -addext "subjectAltName=DNS:demo-upstream,DNS:demo-stub,DNS:svc.example.com,IP:127.0.0.1"
openssl x509 -req -in "$D/upstream/server.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
  -days 3650 -sha256 -extfile "$D/upstream/server.ext" -out "$D/upstream/server.crt"
cat "$D/upstream/server.crt" "$D/ca.crt" > "$D/upstream/server.chain.crt"

# 3.1) 网关客户端证书（mTLS 回源时网关向测试桩出示，编译契约 clientCertificateId）
#      布局：certificates/demo-gw-client-cert/1/{chain.pem,key.pem}
mkdir -p "$D/certificates/demo-gw-client-cert/1"
printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n" > "$D/client.ext"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$D/gw-client.key" -out "$D/gw-client.csr" \
  -subj "/CN=sa-gateway-demo-client" \
  -addext "subjectAltName=DNS:sa-gateway-demo-client"
openssl x509 -req -in "$D/gw-client.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
  -days 3650 -sha256 -extfile "$D/client.ext" -out "$D/gw-client.crt"
cat "$D/gw-client.crt" "$D/ca.crt" > "$D/certificates/demo-gw-client-cert/1/chain.pem"
cp "$D/gw-client.key" "$D/certificates/demo-gw-client-cert/1/key.pem"

# 4) Envoy 回源信任的 CA（编译产物契约：{{PILOT_RELEASE_DIR}}/certificates/<caId>/<version>/ca.pem）
cp "$D/ca.crt" "$D/certificates/demo-upstream-ca/1/ca.pem"

# 5) 客户端信任副本（curl https://localhost:10443 --cacert 用）
cp "$D/ca.crt" "$D/demo-ca.crt"

touch "$D/.done"
# 卷由 root 生成，消费方（upstream 以非 root 运行）需要读权限
chmod -R a+rX "$D"
echo "[certs] generated:"
find "$D" -type f -name "*.pem" -o -type f -name "*.crt" -o -type f -name "*.key" | sort
