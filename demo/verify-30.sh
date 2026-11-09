#!/bin/bash
# 30 端口测试桩全量自动化验证（直连基线 + 经网关转发 + 认证/负向 + mTLS 证书链）
#
# 用法：cd demo && ./verify-30.sh
# 前置：docker compose up -d --build 全栈已启动
# 退出码：0 = 全部通过；非 0 = 有失败（逐条列出）
set -u
cd "$(dirname "$0")"
DEMO=$(pwd)
JWT_TOKEN=$(python3 "$DEMO/stub/gen-jwt.py" mysecret)
JWT_EXPIRED=$(python3 "$DEMO/stub/gen-jwt.py" mysecret '{"exp":1700000000}')
BASIC_B64=$(printf 'svcuser:svcpass' | base64)

# 客户端凭据材料（demo CA 签发的网关客户端证书，供 mTLS 直连）——失败立即终止
docker cp demo-upstream:/certs/demo-ca.crt /tmp/demo-ca.crt || { echo "docker cp demo-ca.crt 失败"; exit 1; }
docker cp demo-upstream:/certs/gw-client.crt /tmp/gw-client.crt || { echo "docker cp gw-client.crt 失败"; exit 1; }
docker cp demo-upstream:/certs/gw-client.key /tmp/gw-client.key || { echo "docker cp gw-client.key 失败"; exit 1; }

PASS=0; FAIL=0; FAILED_CASES=()
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  ❌ %s\n' "$1"; }
check() { # check <用例名> <命令...>：命令退出 0 即通过
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
# 常驻 grpcurl 客户端容器（一次起容器，docker exec 复用网络与描述符——避免高频 --rm 容器的网络抖动）
NET=$(docker compose -f "$DEMO/docker-compose.yml" ps -q envoy | xargs docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
# 挂载与 stub 相同的证书卷（卷名带 compose 项目前缀，从 stub 容器动态解析，避免短名挂出空卷）
CERT_VOL=$(docker inspect demo-stub -f '{{range .Mounts}}{{if eq .Destination "/certs"}}{{.Name}}{{end}}{{end}}')
[ -n "$CERT_VOL" ] || { echo "无法解析证书卷名"; exit 1; }
# grpcurl 属 profiles:[client]，up -d 不构建——确保镜像存在
docker image inspect sa-gateway-demo-grpcurl >/dev/null 2>&1 || docker compose -f "$DEMO/docker-compose.yml" build grpcurl >/dev/null || { echo "grpcurl 客户端镜像构建失败"; exit 1; }
docker rm -f demo-verify-client >/dev/null 2>&1
docker run -d --name demo-verify-client --network "$NET" -v "$CERT_VOL":/certs:ro sa-gateway-demo-grpcurl >/dev/null \
  || { echo "grpcurl 常驻客户端启动失败"; exit 1; }
gc() { docker exec demo-verify-client grpcurl "$@"; }
cleanup() { docker rm -f demo-verify-client >/dev/null 2>&1; }
trap cleanup EXIT

echo "════════════════════════════════════════════════════════"
echo " 一、直连基线：HTTP 家族 15 端口（40051-40065）"
echo "════════════════════════════════════════════════════════"
i=0
for auth in basic bearer jwt apikey custom; do
  case $auth in
    basic)  CRED=(-u svcuser:svcpass); NEG=(-u wrong:wrong) ;;
    bearer) CRED=(-H 'Authorization: Bearer mytoken'); NEG=(-H 'Authorization: Bearer wrong') ;;
    jwt)    CRED=(-H "Authorization: Bearer $JWT_TOKEN"); NEG=(-H "Authorization: Bearer $JWT_EXPIRED") ;;
    apikey) CRED=(-H 'X-Api-Key: myapikey'); NEG=(-H 'X-Api-Key: wrong') ;;
    custom) CRED=(-H 'X-Edge-Auth: edge1'); NEG=(-H 'X-Edge-Auth: wrong') ;;
  esac
  hp=$((40051 + i)); tp=$((40056 + i)); mp=$((40061 + i))

  http_ok()   { B=$(curl -s -m 5 -H 'Host: svc.example.com' "${CRED[@]}" "http://localhost:$hp/"); echo "$B" | grep -q '"auth_passed"' && echo "$B" | grep -q 'svc.example.com'; }
  http_neg()  { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H 'Host: svc.example.com' "${NEG[@]}" "http://localhost:$hp/")" = 401 ]; }
  tls_ok()    { B=$(curl -sk -m 5 -H 'Host: svc.example.com' "${CRED[@]}" "https://localhost:$tp/"); echo "$B" | grep -q '"auth_passed"'; }
  mtls_ok()   { B=$(curl -sk -m 5 --cacert /tmp/demo-ca.crt --cert /tmp/gw-client.crt --key /tmp/gw-client.key -H 'Host: svc.example.com' "${CRED[@]}" "https://localhost:$mp/"); echo "$B" | grep -q '"auth_passed"' && echo "$B" | grep -q 'sa-gateway-demo-client'; }
  mtls_neg()  { curl -sk -o /dev/null -m 5 --cacert /tmp/demo-ca.crt "https://localhost:$mp/" 2>/dev/null; [ $? -ne 0 ]; }
  health_ok() { [ "$(curl -s -m 5 "http://localhost:$hp/healthz")" = ok ]; }

  check "http-$auth 正确凭据 → 200 + auth_passed + Host 校验过" http_ok
  check "http-$auth 错误凭据 → 401" http_neg
  check "tls-$auth 正确凭据 → 200 + auth_passed" tls_ok
  check "mtls-$auth 网关客户端证书 → 200 + 网关身份回显" mtls_ok
  check "mtls-$auth 无客户端证书 → TLS 握手拒绝" mtls_neg
  check "$auth 健康探针 /healthz 免认证 → ok" health_ok
  i=$((i + 1))
done

echo "════════════════════════════════════════════════════════"
echo " 二、直连基线：gRPC 家族 15 端口（40066-40080）"
echo "════════════════════════════════════════════════════════"
i=0
for auth in basic bearer jwt apikey custom; do
  case $auth in
    basic)  M=(-H "authorization: Basic $BASIC_B64"); NM=(-H 'authorization: Basic d3Jvbmc6d3Jvbmc=') ;;
    bearer) M=(-H 'authorization: Bearer mytoken'); NM=(-H 'authorization: Bearer wrong') ;;
    jwt)    M=(-H "authorization: Bearer $JWT_TOKEN"); NM=(-H "authorization: Bearer $JWT_EXPIRED") ;;
    apikey) M=(-H 'x-api-key: myapikey'); NM=(-H 'x-api-key: wrong') ;;
    custom) M=(-H 'x-edge-auth: edge1'); NM=(-H 'x-edge-auth: wrong') ;;
  esac
  gp=$((40066 + i)); sp=$((40071 + i)); mp=$((40076 + i))

  grpc_ok()    { gc -import-path /protos -proto "grpc.$auth.proto" -plaintext -max-time 8 "${M[@]}" -d '{"data":"d"}' "demo-stub:$gp" "grpc.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  grpc_neg()   { ! gc -import-path /protos -proto "grpc.$auth.proto" -plaintext -max-time 8 "${NM[@]}" -d '{}' "demo-stub:$gp" "grpc.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  grpcs_ok()   { gc -import-path /protos -proto "grpcs.$auth.proto" -max-time 8 -insecure "${M[@]}" -d '{"data":"d"}' "demo-stub:$sp" "grpcs.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  grpcmtls_ok() { gc -import-path /protos -proto "grpcmtls.$auth.proto" -max-time 8 -insecure -cert /certs/certificates/demo-gw-client-cert/1/chain.pem -key /certs/certificates/demo-gw-client-cert/1/key.pem "${M[@]}" -d '{"data":"d"}' "demo-stub:$mp" "grpcmtls.$auth.Stub/Echo" 2>&1 | grep -q sa-gateway-demo-client; }

  check "grpc-$auth 正确凭据 → Echo + auth_passed" grpc_ok
  check "grpc-$auth 错误凭据 → Unauthenticated" grpc_neg
  check "grpcs-$auth 正确凭据（TLS 单向）→ Echo" grpcs_ok
  check "grpcmtls-$auth 网关客户端证书 → Echo + 网关身份回显" grpcmtls_ok
  i=$((i + 1))
done

echo "════════════════════════════════════════════════════════"
echo " 三、经网关转发：HTTP 家族 15 链路（:10000，Host 由网关重写）"
echo "════════════════════════════════════════════════════════"
i=0
for auth in basic bearer jwt apikey custom; do
  case $auth in
    basic)  CRED=(-u svcuser:svcpass) ;;
    bearer) CRED=(-H 'Authorization: Bearer mytoken') ;;
    jwt)    CRED=(-H "Authorization: Bearer $JWT_TOKEN") ;;
    apikey) CRED=(-H 'X-Api-Key: myapikey') ;;
    custom) CRED=(-H 'X-Edge-Auth: edge1') ;;
  esac
  for t in http tls mtls; do
    gw_ok()   { B=$(curl -s -m 8 "${CRED[@]}" "http://localhost:10000/stub/$t-$auth/"); echo "$B" | grep -q '"auth_passed"' && echo "$B" | grep -q '"host":"svc.example.com"'; }
    gw_mtls() { B=$(curl -s -m 8 "${CRED[@]}" "http://localhost:10000/stub/$t-$auth/"); echo "$B" | grep -q '"auth_passed"' && echo "$B" | grep -q 'sa-gateway-demo-client'; }
    gw_neg()  { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://localhost:10000/stub/$t-$auth/")" = 401 ]; }
    if [ "$t" = mtls ]; then
      check "gw /stub/$t-$auth/ → auth_passed + 网关 mTLS 客户端证书被后端确认" gw_mtls
    else
      check "gw /stub/$t-$auth/ → auth_passed + Host 重写生效" gw_ok
    fi
    check "gw /stub/$t-$auth/ 无凭据 → 后端 401 透传" gw_neg
  done
  health_gw() { [ "$(curl -s -m 8 "${CRED[@]}" "http://localhost:10000/stub/http-$auth/healthz")" = ok ]; }
  check "gw /stub/http-$auth/healthz → prefix 改写后命中免认证探针（网关健康检查语义）" health_gw
  i=$((i + 1))
done

echo "════════════════════════════════════════════════════════"
echo " 三A、业务端点真实返回（页面/JSON/文件，浏览器与工具均可回显）"
echo "════════════════════════════════════════════════════════"
# 直连 http-basic :40051（凭据 basic）
ep_json()   { curl -s -m 5 -u svcuser:svcpass -H 'Host: svc.example.com' http://localhost:40051/json | grep -q '"order-alpha"'; }
ep_echo()   { curl -s -m 5 -u svcuser:svcpass -H 'Host: svc.example.com' http://localhost:40051/echo/hello-123 | grep -q '"echo":"hello-123"'; }
ep_file()   { curl -s -m 5 -D /tmp/ep-h -u svcuser:svcpass -H 'Host: svc.example.com' http://localhost:40051/file | grep -q "order-alpha,128.50" && grep -qi "content-disposition" /tmp/ep-h; }
ep_page()   { curl -s -m 5 -u svcuser:svcpass -H 'Host: svc.example.com' -H 'Accept: text/html' http://localhost:40051/ | grep -q '联调成功'; }
check "直连 /json → 结构化样例数据（order-alpha）" ep_json
check "直连 /echo/hello-123 → 回显输入值" ep_echo
check "直连 /file → CSV 正文 + Content-Disposition 下载头" ep_file
check "直连 / → HTML 状态页（浏览器回显）" ep_page
# 经网关 :10000（透传凭据）
gw_json()   { curl -s -m 8 -u svcuser:svcpass http://localhost:10000/stub/http-basic/json | grep -q '"order-beta"'; }
gw_echo()   { curl -s -m 8 -u svcuser:svcpass http://localhost:10000/stub/http-basic/echo/via-gateway | grep -q '"via-gateway"'; }
gw_file()   { curl -s -m 8 -u svcuser:svcpass http://localhost:10000/stub/http-basic/file | grep -q "order-gamma,512.75"; }
gw_tls_json() { curl -s -m 8 -u svcuser:svcpass http://localhost:10000/stub/tls-basic/json | grep -q '"order-alpha"'; }
gw_mtls_file() { curl -s -m 8 -u svcuser:svcpass http://localhost:10000/stub/mtls-basic/file | grep -q "order-beta,64.00"; }
gw_xfer_echo() { curl -s -m 8 -u svcuser:svcpass http://localhost:10001/stub/http-basic/echo/h1-to-grpc-entry | grep -q '"h1-to-grpc-entry"'; }
check "网关 /stub/http-basic/json → 样例数据透传" gw_json
check "网关 /stub/http-basic/echo/via-gateway → 回显" gw_echo
check "网关 /stub/http-basic/file → CSV 内容" gw_file
check "网关 /stub/tls-basic/json → TLS 回源链路上端点可用" gw_tls_json
check "网关 /stub/mtls-basic/file → mTLS 链路上文件返回" gw_mtls_file
check "互转 10001(h1) /echo/ → 回显" gw_xfer_echo

echo "════════════════════════════════════════════════════════"
echo " 四、经网关转发：gRPC 家族 15 链路（:10000）"
echo "════════════════════════════════════════════════════════"
for auth in basic bearer jwt apikey custom; do
  case $auth in
    basic)  M=(-H "authorization: Basic $BASIC_B64") ;;
    bearer) M=(-H 'authorization: Bearer mytoken') ;;
    jwt)    M=(-H "Authorization: Bearer $JWT_TOKEN") ;;
    apikey) M=(-H 'x-api-key: myapikey') ;;
    custom) M=(-H 'x-edge-auth: edge1') ;;
  esac

  gw_grpc()   { gc -import-path /protos -proto "grpc.$auth.proto" -plaintext -max-time 8 "${M[@]}" -d '{"data":"gw"}' "demo-envoy:10000" "grpc.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  gw_grpcs()  { gc -import-path /protos -proto "grpcs.$auth.proto" -plaintext -max-time 8 "${M[@]}" -d '{"data":"gw"}' "demo-envoy:10000" "grpcs.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  gw_mtls()   { gc -import-path /protos -proto "grpcmtls.$auth.proto" -plaintext -max-time 8 "${M[@]}" -d '{"data":"gw"}' "demo-envoy:10000" "grpcmtls.$auth.Stub/Echo" 2>&1 | grep -q sa-gateway-demo-client; }

  check "gw grpc.$auth.Stub/Echo → auth_passed" gw_grpc
  check "gw grpcs.$auth.Stub/Echo（TLS 回源）→ auth_passed" gw_grpcs
  check "gw grpcmtls.$auth.Stub/Echo（网关出示客户端证书）→ 网关身份回显" gw_mtls
done

echo "════════════════════════════════════════════════════════"
echo " 五、基础链路回归（页面 / secure / gRPC 服务）"
echo "════════════════════════════════════════════════════════"
page_http()    { curl -s -m 5 http://localhost:10000/ | grep -q 'tag http'; }
page_secure()  { curl -s -m 5 http://localhost:10000/secure/ | grep -q 'tag https'; }
page_https_in(){ curl -s --cacert /tmp/demo-ca.crt -m 5 https://localhost:10443/ | grep -q 'tag http'; }
base_grpc()    { gc -import-path /protos -proto demo.proto -plaintext -max-time 8 -d '{"data":"r"}' demo-envoy:10000 demo.DemoService/Echo 2>&1 | grep -q '"data": "r"'; }
base_grpcs()   { gc -import-path /protos -proto demo.proto -plaintext -max-time 8 -d '{"data":"r"}' demo-envoy:10000 demo.SecureDemoService/Echo 2>&1 | grep -q '"data": "r"'; }
check "gw / → HTTP 上游页面" page_http
check "gw /secure/ → HTTPS 上游页面" page_secure
check "gw :10443（CA 校验）→ 200" page_https_in
check "gw demo.DemoService/Echo → Echo 回显" base_grpc
check "gw demo.SecureDemoService/Echo → Echo 回显" base_grpcs

echo "════════════════════════════════════════════════════════"
echo " 六、流量互转矩阵：HTTP 家族 × 入口 {10001 h1-only, 10002 h2, 10443 https}（45 条）"
echo "════════════════════════════════════════════════════════"
# 矩阵语义（docs/33 §6.1）：入口协议由 codec_type 决定（10001=HTTP1 强制 h1；10002=AUTO h2 可用；
# 10443=TLS 终止），出口协议由 upstream.protocol 决定，两侧独立编码 → 无需任何"转换"配置。
i=0
for auth in basic bearer jwt apikey custom; do
  case $auth in
    basic)  CRED=(-u svcuser:svcpass) ;;
    bearer) CRED=(-H 'Authorization: Bearer mytoken') ;;
    jwt)    CRED=(-H "Authorization: Bearer $JWT_TOKEN") ;;
    apikey) CRED=(-H 'X-Api-Key: myapikey') ;;
    custom) CRED=(-H 'X-Edge-Auth: edge1') ;;
  esac
  for entry in 10001:h1 10002:h2; do
    port=${entry%%:*}
    xfer_ok()   { B=$(curl -s -m 8 "${CRED[@]}" "http://localhost:$port/stub/http-$auth/"); echo "$B" | grep -q '"auth_passed"' && echo "$B" | grep -q '"host":"svc.example.com"'; }
    xfer_mtls() { B=$(curl -s -m 8 "${CRED[@]}" "http://localhost:$port/stub/mtls-$auth/"); echo "$B" | grep -q '"auth_passed"' && echo "$B" | grep -q 'sa-gateway-demo-client'; }
    check "互转 $port(h$([ $port = 10001 ] && echo 1 || echo 2)) /stub/http-$auth/ → auth_passed + Host 重写" xfer_ok
    check "互转 $port /stub/mtls-$auth/ → 网关 mTLS 客户端证书被后端确认" xfer_mtls
  done
  https_xfer() { B=$(curl -s --cacert /tmp/demo-ca.crt -m 8 "${CRED[@]}" "https://localhost:10443/stub/http-$auth/"); echo "$B" | grep -q '"auth_passed"' && echo "$B" | grep -q '"host":"svc.example.com"'; }
  check "互转 10443(TLS 终止) /stub/http-$auth/ → auth_passed" https_xfer
  i=$((i + 1))
done

echo "════════════════════════════════════════════════════════"
echo " 七、流量互转矩阵：gRPC 家族 × 入口 {10002 h2, 10443 https}（30 条）"
echo "════════════════════════════════════════════════════════"
for auth in basic bearer jwt apikey custom; do
  case $auth in
    basic)  M=(-H "authorization: Basic $BASIC_B64") ;;
    bearer) M=(-H 'authorization: Bearer mytoken') ;;
    jwt)    M=(-H "Authorization: Bearer $JWT_TOKEN") ;;
    apikey) M=(-H 'x-api-key: myapikey') ;;
    custom) M=(-H 'x-edge-auth: edge1') ;;
  esac
  xfer_grpc()  { gc -import-path /protos -proto "grpc.$auth.proto" -plaintext -max-time 8 "${M[@]}" -d '{"data":"x"}' demo-envoy:10002 "grpc.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  xfer_grpcs() { gc -import-path /protos -proto "grpcs.$auth.proto" -plaintext -max-time 8 "${M[@]}" -d '{"data":"x"}' demo-envoy:10002 "grpcs.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  xfer_https_grpc()  { gc -import-path /protos -proto "grpc.$auth.proto" -max-time 8 -insecure -servername localhost "${M[@]}" -d '{"data":"x"}' host.docker.internal:10443 "grpc.$auth.Stub/Echo" 2>&1 | grep -q authPassed; }
  check "互转 10002(h2) grpc.$auth.Stub/Echo → authPassed" xfer_grpc
  check "互转 10002(h2) grpcs.$auth.Stub/Echo（TLS 回源）→ authPassed" xfer_grpcs
  check "互转 10443(https) grpc.$auth.Stub/Echo → authPassed" xfer_https_grpc
done

echo "════════════════════════════════════════════════════════"
echo " 结果：PASS=$PASS FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then printf '失败用例:\n'; printf ' - %s\n' "${FAILED_CASES[@]}"; fi
echo "════════════════════════════════════════════════════════"
[ $FAIL -eq 0 ]
