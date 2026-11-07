#!/bin/bash
# 生成一套自测证书: 一个 CA 同时充当
#   网关的 trust CA(校验被防护服务证书) 和 后端的 client CA(校验网关客户端证书)
set -euo pipefail

dir="${1:-certs}"
mkdir -p "$dir"
cd "$dir"

# 根 CA
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout ca.key -out ca.pem -days 3650 \
  -subj "/CN=Test WAF Root CA" \
  -addext "basicConstraints=critical,CA:TRUE"

# 被防护后端服务证书 (网关用 ca.pem 校验它)
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=svc.example.com"
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out server.pem -days 825 \
  -extfile <(printf "subjectAltName=DNS:svc.example.com,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth")

# 网关客户端证书 (后端用 ca.pem 校验它, 证明网关身份)
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
  -subj "/CN=gateway-client"
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out client.pem -days 825 \
  -extfile <(printf "extendedKeyUsage=clientAuth")

rm -f server.csr client.csr ca.srl
echo "OK -> $dir/{ca.pem ca.key server.pem server.key client.pem client.key}"
echo "  ca.pem:     网关 trust CA     (校验 server.pem)"
echo "  ca.pem:     后端 client CA     (校验 client.pem, 即网关身份)"
echo "  server.*:   被防护服务证书"
echo "  client.*:   网关客户端证书"