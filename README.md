# test-svc-cert —— sa-gateway 测试桩与联调交付物

为 **sa-gateway 安全网关**提供可独立部署的被测上游（测试桩）与网关配置交付物。
仓库自包含：测试桩源码、静态部署包、证书生成脚本、一键管理脚本、网关配置样例。

- 测试桩定位：模拟"被防护服务"，验证网关的 **Host 校验 / HTTP-HTTPS-gRPC 回源 / 回源
  TLS 与 mTLS / 5 种业务认证 / 健康探针** 全部维度，接口返回真实值（页面 / JSON /
  CSV 文件均可浏览器回显）。
- 仓库自包含、开箱即用：**目标机不需要 Docker、openssl、Go、Python**——测试桩为
  `CGO_ENABLED=0` 纯静态 Go 二进制（不依赖 glibc/musl），证书为 PEM 文件（构建机生成
  打包），管理与验证仅依赖 `sh` + `wget`（或 curl）。
- 仓库结构（三部分）：
  - **`stub30/`（测试桩交付物，当前主线）**：30 端口测试桩——{http, tls, mtls} × {grpc,
    grpcs, grpcmtls} 六种传输形态 × 5 种认证，一键管理 `stub-ctl.sh`（六命令）。
  - **`demo/`（网关演示环境，本机测试用）**：Envoy 网关（真实编译链 bootstrap 烧入
    envoyproxy/envoy:v1.37.1 镜像）+ 演示上游 + `verify-30.sh`（155 项断言互转验证）。
    需 Docker，仅用于本机/联调机端到端测试——服务器部署测试桩不需要它。
  - **根目录遗留 v1**（`main.go` + `deploy-15.sh`，15 端口单实例平铺）：早期版本，
    保留向后兼容，详见 `docs/origin-test-legacy.md`。
- **部署实例**：10.66.69.212 已按本仓库交付物完成部署与跨机连通性验证（六形态矩阵
  全通过，实例化手册见 `/Users/kylin/Downloads/stub-deploy-10.66.69.212/README.md`）。

> 网关侧（Envoy）由 sa-gateway 项目与节点 pilot 负责；本仓库只交付测试桩与网关配置
> 样例，不承载网关运行时。

---

## 1. 快速开始

```bash
# 构建机（任意有 Go 1.23+ 的机器）：证书 + 部署包
cd stub30 && sh certs/gen.sh && ./build-release.sh
# 产物：dist/sa-gw-stub-30-linux-{amd64,arm64}.tar.gz（含 TLS 私钥，勿入库勿外传）

# 目标机（任意 Linux amd64/arm64；解压到任意目录，脚本自动探测 bin/certs）
scp dist/sa-gw-stub-30-linux-<arch>.tar.gz user@<server>:/tmp/
ssh user@<server>
tar xzf /tmp/sa-gw-stub-30-linux-<arch>.tar.gz -C /opt/
cd /opt/sa-gw-stub-30 && ./stub-ctl.sh start      # 一键启动 30 端口
./stub-ctl.sh verify                              # 语义探活 + 真实值自检 → all passed
```

浏览器打开 `http://<server>:62051/`（凭据 `svcuser/svcpass`，Host 头
`svc.example.com`——直连访问需自带 Host 头或经网关由其重写）。

---

## 2. 测试桩端口与能力

### 2.1 端口矩阵（30 个，基址默认 62051/PORT_BASE 可平移）

| | basic | bearer | jwt | apikey | custom |
|---|---|---|---|---|---|
| **http**（明文） | +0 | +1 | +2 | +3 | +4 |
| **tls**（单向 TLS） | +5 | +6 | +7 | +8 | +9 |
| **mtls**（双向 mTLS） | +10 | +11 | +12 | +13 | +14 |
| **grpc**（明文 gRPC） | +15 | +16 | +17 | +18 | +19 |
| **grpcs**（TLS gRPC） | +20 | +21 | +22 | +23 | +24 |
| **grpcmtls**（mTLS gRPC） | +25 | +26 | +27 | +28 | +29 |

默认基址 62051（段 62051-62080，在系统 ephemeral 出站源端口范围 32768-60999 之外——
实测该范围与低段端口会冲突，见 §5 端口段偏移）。

- HTTP 家族：每实例校验 Host（放行域）、业务认证；`/healthz` 等探针免认证。
- gRPC 家族：`stubgrpc` 单进程 15 listeners；认证读 gRPC metadata；JWT 为 HS256 验签 +
  exp；失败返回 `codes.Unauthenticated`；grpcmtls 强制校验网关客户端证书并回显 Subject。

### 2.2 业务端点（HTTP 家族，均需业务认证，返回真实值、浏览器可回显）

| 端点 | 返回 |
|---|---|
| `GET /` | HTML 状态页（联调信息 + 认证/mTLS 状态 + 接口清单） |
| `GET /info` | 请求头 / 透传信息 JSON 回显 |
| `GET /json` | 结构化业务样例数据（订单列表） |
| `GET /echo/<任意值>` | 路径参数 + query 全量回显 JSON |
| `GET /file` | CSV 样例文件（`Content-Disposition: attachment`，浏览器下载） |
| `GET /healthz` | 免认证探活，`200 ok` |

gRPC 家族 `Echo` 返回真实值：data 回显 + 后端标识 + `auth_passed` + mTLS 证书 Subject
+ 时间戳。

### 2.3 凭据集

| 认证 | 凭据 |
|---|---|
| basic | `svcuser` / `svcpass` |
| bearer | `mytoken` |
| jwt | HS256 密钥 `mysecret`（`gen-jwt.py` 签发） |
| apikey | 头 `X-Api-Key`，值 `myapikey` |
| custom | 头 `X-Edge-Auth`，值 `edge1` |

---

## 3. 一键管理（stub-ctl.sh，六命令）

| 命令 | 行为 |
|---|---|
| `./stub-ctl.sh start` | 幂等后台拉起 30 端口（检查二进制/证书、写 pidfile、输出健康表） |
| `./stub-ctl.sh stop` | 精确停止（pidfile + pkill 兜底） |
| `./stub-ctl.sh status` | 进程存活（15 origin + 1 stubgrpc）+ HTTP 家族 `/healthz` 探测 |
| `./stub-ctl.sh health` | 健康检查一句话结果（PASS/FAIL，退出码 0/1——适合巡检脚本） |
| `./stub-ctl.sh info` | 部署信息（VERSION 溯源/放行域/证书 SAN/端口矩阵/凭据/端点清单） |
| `./stub-ctl.sh verify` | 语义探活：探针 200 + **业务端点真实值自检**（/json /echo /file）+ gRPC 进程 |

依赖：`sh` + `wget`（或 curl）。systemd 环境可用 `systemd/sa-gw-stub-30.service`。

### 测试命令手册（curl / grpcurl，直连与经网关同构）

> **已在 10.66.69.212 实例实测通过**（2026-11-09，跨机连通性验证，见文末验证记录）。
> 端口-认证配对：`{base}+0..4 = {family}.{basic,bearer,jwt,apikey,custom}`（family 与 base 见端口矩阵）。放行域默认 `svc.example.com`（自定义见 `stub-ctl.sh info`）。

**连通性验证矩阵（实测，PORT_BASE=62051 段）**

| 形态 | 端口 | 验证方式 | 结果 |
|---|---|---|---|
| HTTP 明文 | 62051-62055 | curl（/healthz /json /echo /file / 负向 401） | ✅ 全部真实值返回 |
| TLS 单向 | 62056-62060 | curl --cacert --resolve（SNI+SAN 严格校验） | ✅ 业务数据 + Host 确认 |
| mTLS 双向 | 62061-62065 | curl --cacert --cert --key（网关客户端证书） | ✅ mtls:true |
| gRPC 明文 | 62066-62070 | curl h2 手工帧 / grpcurl | ✅ grpc-status: 0 |
| gRPCS TLS | 62071-62075 | curl h2 + cacert / grpcurl | ✅ grpc-status: 0 |
| gRPC mTLS | 62076-62080 | curl h2 + cacert + 客户端证书 / grpcurl | ✅ grpc-status: 0 |

**HTTP 家族（basic 凭据示例）**

```bash
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:62051/            # 状态页（浏览器回显）
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:62051/info        # 请求/透传信息 JSON
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:62051/json        # 业务样例 JSON
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:62051/echo/hello  # 回显
curl -u svcuser:svcpass -H 'Host: svc.example.com' -OJ http://127.0.0.1:62051/file    # CSV 文件下载
curl http://127.0.0.1:62051/healthz                                                   # 免认证探活 → ok
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:62051/json                  # 负向：无凭据 → 401
```

**TLS 单向（严格校验证书链与 SAN）**

```bash
curl --cacert certs/certificates/demo-upstream-ca/1/ca.pem \
  --resolve svc.example.com:62056:127.0.0.1 -u svcuser:svcpass \
  https://svc.example.com:62056/json
```

**mTLS 双向（出示网关客户端证书）**

```bash
curl --cacert certs/certificates/demo-upstream-ca/1/ca.pem \
  --cert certs/certificates/demo-gw-client-cert/1/chain.pem \
  --key  certs/certificates/demo-gw-client-cert/1/key.pem \
  --resolve svc.example.com:62061:127.0.0.1 -u svcuser:svcpass \
  https://svc.example.com:62061/json        # 响应含 "mtls":true
```

**gRPC 家族（grpcurl，静态二进制见 verify-tools/）**

```bash
G='grpcurl -import-path protos -max-time 8'
# gRPC 明文（basic）
$G -proto grpc.basic.proto -plaintext -H 'authorization: Basic c3ZjdXNlcjpzdmNwYXNz' \
  -d '{"data":"hi"}' 127.0.0.1:62066 grpc.basic.Stub/Echo
# gRPC 明文（bearer；JWT 由 gen-jwt.py 签发：python3 gen-jwt.py mysecret，可选 Python）
JWT=$(python3 gen-jwt.py mysecret)
$G -proto grpc.bearer.proto -plaintext -H "authorization: Bearer $JWT" \
  -d '{"data":"hi"}' 127.0.0.1:62067 grpc.bearer.Stub/Echo
# gRPCS TLS（apikey）
$G -proto grpcs.apikey.proto -insecure -H 'x-api-key: myapikey' \
  -d '{"data":"hi"}' 127.0.0.1:62074 grpcs.apikey.Stub/Echo
# gRPC mTLS（网关客户端证书，部署包 certs/ 或 certs/generated/）
$G -proto grpcmtls.custom.proto -insecure \
  -cert certs/generated/certificates/demo-gw-client-cert/1/chain.pem \
  -key  certs/generated/certificates/demo-gw-client-cert/1/key.pem \
  -H 'x-edge-auth: edge1' -d '{"data":"hi"}' 127.0.0.1:62080 grpcmtls.custom.Stub/Echo
# 负向：无凭据 → Unauthenticated
$G -proto grpc.basic.proto -plaintext -d '{"data":"x"}' 127.0.0.1:62066 grpc.basic.Stub/Echo
```

**手工 gRPC 帧（无 grpcurl 时用 curl 直发）**

```bash
# EchoRequest 帧构造：compressed-flag(0x00) + 4B 大端长度 + protobuf(field1=字符串)
python3 -c "
d=b'mac-curl-grpc-ok'
payload=b'\x0a'+bytes([len(d)])+d
open('/tmp/grpc-frame.bin','wb').write(b'\x00'+len(payload).to_bytes(4,'big')+payload)"
# gRPC 明文（h2c）
curl -s --http2-prior-knowledge -X POST -H 'content-type: application/grpc' -H 'te: trailers' \
  -H 'authorization: Basic c3ZjdXNlcjpzdmNwYXNz' --data-binary @/tmp/grpc-frame.bin \
  http://127.0.0.1:62066/grpc.basic.Stub/Echo -o /tmp/resp.bin -D -   # grpc-status: 0 + 响应帧
```

**双层域名写法（证书 SAN 与放行域不同源时）**

> 若桩证书由 `ALLOW_HOSTS="api.test.cn my.api.cn"` 生成（SAN 主域=api.test.cn），而放行域为
> `svc.example.com`：TLS 层 SNI 用证书域名（--resolve），HTTP 层 Host 覆盖为放行域——两层各自匹配。

```bash
curl --cacert certs/certificates/demo-upstream-ca/1/ca.pem \
  --resolve api.test.cn:62056:<stub-ip> -u svcuser:svcpass -H 'Host: svc.example.com' \
  https://api.test.cn:62056/json
```

**经网关转发（网关 :10000/:10001/:10002/:10443；桩侧命令不变，仅替换地址与路径前缀）**

```bash
curl -u svcuser:svcpass http://<gateway>:10000/stub/http-basic/json
curl -u svcuser:svcpass http://<gateway>:10001/stub/mtls-basic/echo/gateway-h1
curl --cacert <ca.pem> -u svcuser:svcpass https://<gateway>:10443/stub/tls-bearer/echo/gw-tls
$G -proto grpcs.jwt.proto -plaintext -H 'authorization: Bearer mytoken' \
  -d '{"data":"hi"}' <gateway>:10002 grpcs.jwt.Stub/Echo
```


---

## 5. 证书

```bash
cd stub30/certs && sh gen.sh                          # 默认 SAN（svc.example.com 等）
ALLOW_HOSTS="api.test.cn my.api.cn" sh gen.sh         # 自定义域名绑定（多域名全部写入 SAN）
```

生成到 `certs/generated/`（gitignore，含私钥），布局与 sa-gateway 网关编译契约一致：

| 证书 | 用途 |
|---|---|
| `certificates/demo-gw-cert/1/` | 网关入口 HTTPS listener 证书（网关侧） |
| `certificates/demo-upstream-ca/1/ca.pem` | 回源信任 CA（网关与桩共用） |
| `certificates/demo-gw-client-cert/1/` | mTLS 回源时网关出示的客户端证书 |
| `upstream/server.chain.crt + key` | 测试桩服务端证书（SAN 含放行域 + demo-upstream/demo-stub/127.0.0.1） |

**安全约定**：`*.key` 与 `certs/generated/` 已被 `.gitignore` 忽略——私钥只在本地与
部署包中，绝不入库。轮换：删除 `certs/generated/.done` 后重跑 `gen.sh`，并同步网关侧
物化的 CA。

---

## 6. 端口段偏移（PORT_BASE）

默认基址 **62051**（段 62051-62080）——刻意选在系统 ephemeral 出站源端口范围
（32768-60999）之外：低段端口（如 40051-40080）会被服务器出站连接的**源端口**偶发占用，
表现为启动时 `bind: address already in use` 且 `ss -ltn | grep :<port>` 平时无监听
（源端口占用不产生 LISTEN 行）。`stubgrpc` 另内置绑定重试（3 次×2s）自愈瞬时占用。

```bash
PORT_BASE=<base> ./stub-ctl.sh start    # 段 = <base>..<base+29>
# 选择原则：cat /proc/sys/net/ipv4/ip_local_port_range，选范围之外的段
```

---

## 7. 网关配置样例（gateway-config/）

| 文件 | 说明 |
|---|---|
| `bootstrap.docker.json` | sa-gateway 编译链（发布校验→编译）生成的 Envoy bootstrap 等价形态（占位符已物化），与桩的证书/端口一一对应 |
| `REQUIRED-CERTS.txt` | 编译契约要求的证书清单 |

配置由 sa-gateway 项目生成（`EnvoyDemoConfigDumpTest`）；本仓库只提供联调样例与证书
对齐说明。网关侧 TLS/mTLS 回源、协议转换（h1/h2↔h2、TLS 终止）、Host 重写均为网关
原生能力，桩侧无需感知。

---

## 8. 移植到其它机器 / 环境

| 需求 | 说明 |
|---|---|
| CPU | `amd64` / `arm64` 部署包默认产出；其它架构改 `build-release.sh` 的 `ARCHS` |
| 发行版 | 无关——纯静态二进制 + `sh` + `wget`；Debian/Ubuntu/CentOS/RHEL/Alpine 均可 |
| 网络 | 部署包自包含（含证书），目标机零下载；构建机首次构建访问 `goproxy.cn` |
| 依赖本仓库 | 否——`dist/*.tar.gz` 为自包含交付物（含私钥，仅内网流转） |
| 依赖 sa-gateway 项目 | 否——测试桩独立运行；仅网关配置样例与证书 CA 需与网关侧对齐 |

---

## 9. 开发与构建（stub30/）

```bash
cd stub30
go test ./cmd/origin                     # 单元测试（内存证书，自包含）
sh certs/gen.sh                          # 生成证书 → certs/generated/
./build-release.sh                       # 打包 → dist/
```

源码结构：

```
stub30/
├── cmd/origin/main.go        # HTTP 家族主体（Host 校验/5 种认证/业务端点/页面）
├── cmd/origin/main_test.go   # 单元测试（认证矩阵/Host/业务端点，内存证书）
├── cmd/stubgrpc/main.go      # gRPC 家族 15 listeners（手写 protowire codec，无 protoc）
├── protos/                   # stub.proto + 15 个变体描述符（服务名 = 网关路由键）
├── gen-jwt.py                # HS256 JWT 签发工具
├── stub-30.sh                # 30 端口启动器（BIN_DIR/CERT_DIR/LOG_DIR/ALLOW_HOST/PORT_BASE 参数化）
├── stub-ctl.sh               # 一键管理 start/stop/status/health/info/verify（POSIX sh）
├── certs/gen.sh              # 证书生成（编译契约布局 + 幂等 + ALLOW_HOSTS 多域名 SAN）
├── build-release.sh          # 部署包构建器（交叉编译 amd64/arm64 + systemd + 证书 + VERSION 溯源）
├── go.mod / go.sum           # Go 依赖（grpc/protobuf，go.sum 锁定）
└── dist/                     # 部署包产物（gitignore：含私钥）
```

---

## 10. FAQ

| 现象 | 处理 |
|---|---|
| `/healthz` DOWN | `stub-ctl.sh status` 看进程；日志在 `LOG_DIR/`（http-basic.log 等） |
| grpcurl 报 `unknown service` | 服务名与端口按认证变体配对（见 §2.1 矩阵）——描述符在 `stub30/protos/` |
| gRPC 调用 `Unauthenticated` | 凭据放 metadata（HTTP/2 头小写），见 §2.3；JWT 用 `gen-jwt.py mysecret` 签发 |
| TLS 握手失败 `unknown ca` | 客户端须信任 `certs/generated/` 的 CA；mTLS 客户端须出示 demo-gw-client-cert |
| **证书 SAN 与放行域不同源** | TLS 层用证书域名（`--resolve`），HTTP 层 Host 覆盖放行域——见手册"双层域名写法" |
| 启动报 `bind: address already in use` 且事后无监听 | ephemeral 源端口占用——`PORT_BASE=<段外基址>` 平移（见 §6） |
| 想换放行域名 | `ALLOW_HOSTS` 重新生成证书 + `ALLOW_HOST='<逗号分隔多域>' ./stub-ctl.sh start`（网关侧 rewrite.host 同步） |

---

## 11. 历史版本

根目录遗留 v1（单实例 origin-test + `deploy-15.sh` 15 端口平铺、`gen-cert.sh`、原
README）已归档至 `docs/origin-test-legacy.md`，仅供向后参考；新部署一律使用 `stub30/`。
