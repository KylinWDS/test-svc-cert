#!/bin/sh
# 证书生成脚本（需 openssl，在构建机执行；目标机不需要 openssl——证书随部署包分发）
# 输出到 certs/generated/（gitignore，含私钥）；布局与 sa-gateway 网关编译契约一致：
#   certificates/demo-gw-cert/1/{chain.pem,key.pem}        网关入口 HTTPS 证书（网关侧使用）
#   certificates/demo-upstream-ca/1/ca.pem                 回源信任 CA（网关与桩共用）
#   certificates/demo-gw-client-cert/1/{chain.pem,key.pem} 网关客户端证书（mTLS 回源时网关出示；桩校验）
#   upstream/server.chain.crt + upstream/server.key        测试桩服务端证书（tls/mtls/grpcs/grpcmtls）
#   demo-ca.crt                                            客户端信任副本
#
# 自定义域名绑定：
#   ALLOW_HOSTS="svc.example.com api.test.cn my.api.cn" sh gen.sh
#   - 第一个域名 = 桩默认放行域（启动时 ALLOW_HOST=第一个域名）
#   - 全部域名写入上游服务端证书 SAN（与网关入口证书 SAN）
#   - 桩启动：ALLOW_HOST="<逗号分隔多域名>" ./stub-ctl.sh start（-allow-host 支持逗号分隔）
#   - 固定 SAN（始终包含）：demo-upstream、demo-stub、127.0.0.1
# 环境变量：CERT_DIR（默认脚本目录/generated）、ALLOW_HOSTS、CERT_DAYS（默认 3650）
set -e
D="${CERT_DIR:-$(cd "$(dirname "$0")" && pwd)/generated}"
ALLOW_HOSTS="${ALLOW_HOSTS:-svc.example.com}"
DAYS="${CERT_DAYS:-3650}"

# 幂等保护：证书已生成则跳过（桩/网关运行中重生成会造成信任链错配）。
# 轮换：删除 $D/.done 后重跑，并同步网关侧物化的 ca.pem。
if [ -f "$D/.done" ]; then
  echo "[certs] already generated (see .done), skip."
  exit 0
fi

mkdir -p "$D/certificates/demo-gw-cert/1" "$D/certificates/demo-upstream-ca/1" "$D/certificates/demo-gw-client-cert/1" "$D/upstream"

# 拼接 DNS 列表：自定义域名 + 固定 SAN
SAN_EXTRA=""
FIRST_HOST=""
for h in $ALLOW_HOSTS; do
  if [ -z "$FIRST_HOST" ]; then FIRST_HOST="$h"; fi
  SAN_EXTRA="$SAN_EXTRA DNS:$h,"
done
SAN_UPSTREAM="subjectAltName=DNS:demo-upstream,DNS:demo-stub,${SAN_EXTRA}IP:127.0.0.1"
SAN_GW="subjectAltName=DNS:localhost,DNS:demo-gateway,${SAN_EXTRA}IP:127.0.0.1"

echo "[certs] CA: sa-gateway-demo-ca | 放行域(桩): $ALLOW_HOSTS | 主放行域: $FIRST_HOST"

# 1) 演示 CA（同时签发网关证书与上游证书，客户端统一信任它即可）
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
  -keyout "$D/ca.key" -out "$D/ca.crt" \
  -subj "/CN=sa-gateway-demo-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

# 2) 网关入口证书（SAN: localhost/demo-gateway + 自定义域名/127.0.0.1）
printf "%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nauthorityKeyIdentifier=keyid,issuer\n" "$SAN_GW" > "$D/gw.ext"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$D/gw.key" -out "$D/gw.csr" \
  -subj "/CN=demo-gateway" \
  -addext "$SAN_GW"
openssl x509 -req -in "$D/gw.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
  -days "$DAYS" -sha256 -extfile "$D/gw.ext" -out "$D/gw.crt"
cat "$D/gw.crt" "$D/ca.crt" > "$D/certificates/demo-gw-cert/1/chain.pem"
cp "$D/gw.key" "$D/certificates/demo-gw-cert/1/key.pem"

# 3) 上游服务端证书（SAN: demo-upstream/demo-stub + 自定义放行域/127.0.0.1；
#    Envoy 回源按节点主机名做 SAN 匹配与 SNI，桩按 ALLOW_HOST 校验 Host 头）
printf "%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nauthorityKeyIdentifier=keyid,issuer\n" "$SAN_UPSTREAM" > "$D/upstream/server.ext"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$D/upstream/server.key" -out "$D/upstream/server.csr" \
  -subj "/CN=demo-upstream" \
  -addext "$SAN_UPSTREAM"
openssl x509 -req -in "$D/upstream/server.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
  -days "$DAYS" -sha256 -extfile "$D/upstream/server.ext" -out "$D/upstream/server.crt"
cat "$D/upstream/server.crt" "$D/ca.crt" > "$D/upstream/server.chain.crt"

# 3.1) 网关客户端证书（mTLS 回源时网关向测试桩出示，编译契约 clientCertificateId）
printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\nauthorityKeyIdentifier=keyid,issuer\n" > "$D/client.ext"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$D/gw-client.key" -out "$D/gw-client.csr" \
  -subj "/CN=sa-gateway-demo-client" \
  -addext "subjectAltName=DNS:sa-gateway-demo-client"
openssl x509 -req -in "$D/gw-client.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
  -days "$DAYS" -sha256 -extfile "$D/client.ext" -out "$D/gw-client.crt"
cat "$D/gw-client.crt" "$D/ca.crt" > "$D/certificates/demo-gw-client-cert/1/chain.pem"
cp "$D/gw-client.key" "$D/certificates/demo-gw-client-cert/1/key.pem"

# 4) Envoy 回源信任的 CA（编译产物契约：{{PILOT_RELEASE_DIR}}/certificates/<caId>/<version>/ca.pem）
cp "$D/ca.crt" "$D/certificates/demo-upstream-ca/1/ca.pem"

# 5) 客户端信任副本（curl https --cacert 用）
cp "$D/ca.crt" "$D/demo-ca.crt"

touch "$D/.done"
chmod -R a+rX "$D"
echo "[certs] generated (CA=$(openssl x509 -in "$D/ca.crt" -noout -subject | cut -d' ' -f2-)):"
find "$D" -type f \( -name "*.pem" -o -name "*.crt" -o -name "*.key" \) | sort
echo "[certs] 桩启动放行域: ALLOW_HOST=\"$FIRST_HOST\"（多域名: ALLOW_HOST=\"$(echo $ALLOW_HOSTS | tr ' ' ',')\"）"
