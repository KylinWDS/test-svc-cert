# test-svc-cert —— sa-gateway 测试桩与联调交付物

为 **sa-gateway 安全网关**提供可独立部署的被测上游（测试桩）与网关配置交付物。
仓库自包含：测试桩源码与静态二进制、证书生成脚本、一键管理脚本、网关配置样例。

- 测试桩定位：模拟"被防护服务"，验证网关的 **Host 校验 / HTTP-HTTPS-gRPC 回源 / 回源
  TLS 与 mTLS / 5 种业务认证 / 健康探针** 全部维度，接口返回真实值（页面 / JSON /
  CSV 文件均可浏览器回显）。
- 仓库自包含、开箱即用：**目标机不需要 Docker、openssl、Go、Python**——测试桩为
  `CGO_ENABLED=0` 纯静态 Go 二进制（不依赖 glibc/musl），证书为 PEM 文件（本机生成
  打包），管理与验证仅依赖 `sh` + `wget`（或 curl）。
- 仓库分三部分：
  - **`stub30/`（测试桩交付物）**：30 端口测试桩——{http, tls, mtls} × {grpc,
    grpcs, grpcmtls} 六种传输形态 × 5 种认证，一键启停 `stub-ctl.sh`；**无 Docker
    依赖**（静态二进制部署）。
  - **`demo/`（网关演示环境，本机测试用）**：Envoy 网关（真实编译链 bootstrap 烧入
    envoyproxy/envoy:v1.37.1 镜像）+ 演示上游 + `verify-30.sh`（155 项断言互转验证）。
    需 Docker，仅用于本机/联调机做端到端测试——目标服务器部署测试桩不需要它。
  - **根目录遗留 v1**（`main.go` + `deploy-15.sh`，15 端口单实例平铺）：早期版本，
    保留向后兼容，详见 `docs/origin-test-legacy.md`。

> 网关侧（Envoy）由 sa-gateway 项目与节点 pilot 负责；本仓库只交付测试桩与网关配置
> 样例，不承载网关运行时。
>
> **另**：sa-gateway 项目侧的本机演示环境已迁入本仓库 `demo/` 目录（Envoy 网关 +
> 演示上游 + verify-30.sh），使用方式见 §9。

---

## 1. 快速开始

```bash
# 本机（任意有 Go 1.23+ 的机器）制作部署包
cd stub30 && sh certs/gen.sh && ./build-release.sh
# 产物：dist/sa-gw-stub-30-linux-{amd64,arm64}.tar.gz（含 TLS 私钥，勿入库勿外传）

# 目标机（任意 Linux amd64/arm64，Debian/Ubuntu/CentOS/RHEL/Alpine 均可）
scp dist/sa-gw-stub-30-linux-<arch>.tar.gz user@<server>:/tmp/
ssh user@<server>
tar xzf /tmp/sa-gw-stub-30-linux-<arch>.tar.gz -C /opt/     # 解压到任意目录均可
cd /opt/sa-gw-stub-30 && ./stub-ctl.sh start                # 一键启动（脚本自动探测 bin/certs）
./stub-ctl.sh verify                                        # 全部 UP 即成功
```

浏览器打开 `http://<server>:40051/`（凭据 `svcuser/svcpass`，Host 头
`svc.example.com`——直连访问需自带 Host 头或经网关由其重写）。

---

## 2. 测试桩端口与能力

### 2.1 端口矩阵（30 个）

| | basic | bearer | jwt | apikey | custom |
|---|---|---|---|---|---|
| **http**（明文） | 40051 | 40052 | 40053 | 40054 | 40055 |
| **tls**（单向 TLS） | 40056 | 40057 | 40058 | 40059 | 40060 |
| **mtls**（双向 mTLS） | 40061 | 40062 | 40063 | 40064 | 40065 |
| **grpc**（明文 gRPC） | 40066 | 40067 | 40068 | 40069 | 40070 |
| **grpcs**（TLS gRPC） | 40071 | 40072 | 40073 | 40074 | 40075 |
| **grpcmtls**（mTLS gRPC） | 40076 | 40077 | 40078 | 40079 | 40080 |

- HTTP 家族：每实例校验 Host（放行 `svc.example.com`）、业务认证；`/healthz` 等探针免认证。
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

## 3. 一键管理（stub-ctl.sh）

| 命令 | 行为 |
|---|---|
| `./stub-ctl.sh start` | 幂等后台拉起 30 端口（检查二进制/证书、写 pidfile、输出健康表） |
| `./stub-ctl.sh stop` | 精确停止（pidfile + pkill 兜底） |
| `./stub-ctl.sh status` | 进程存活（15 origin + 1 stubgrpc）+ HTTP 家族 `/healthz` 探测 |
| `./stub-ctl.sh health` | 健康检查一句话结果（PASS/FAIL，退出码 0/1——适合巡检脚本） |
| `./stub-ctl.sh info` | 部署信息（二进制/放行域/证书 SAN/端口矩阵/凭据/端点清单） |
| `./stub-ctl.sh verify` | 语义探活：探针 200 + **业务端点真实值自检**（/json /echo /file）+ gRPC 进程 |

依赖：`sh` + `wget`（或 curl）——Debian/Ubuntu/CentOS/RHEL/Alpine 默认满足，无
systemd/bash/python 依赖。systemd 环境可用 `systemd/sa-gw-stub-30.service`。

---


### 测试命令手册（curl / grpcurl，直连与经网关同构）

> 端口-认证配对：`40066+0..4 = grpc.{basic,bearer,jwt,apikey,custom}`，`40071+0..4 = grpcs.*`，`40076+0..4 = grpcmtls.*`。放行域默认 `svc.example.com`（自定义见 `stub-ctl.sh info`）。

**HTTP 家族（basic 凭据示例）**

```bash
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:40051/            # 状态页（浏览器回显）
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:40051/info        # 请求/透传信息 JSON
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:40051/json        # 业务样例 JSON
curl -u svcuser:svcpass -H 'Host: svc.example.com' http://127.0.0.1:40051/echo/hello  # 回显
curl -u svcuser:svcpass -H 'Host: svc.example.com' -OJ http://127.0.0.1:40051/file    # CSV 文件下载
curl http://127.0.0.1:40051/healthz                                                   # 免认证探活 → ok
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:40051/json                  # 负向：无凭据 → 401
```

**TLS 单向（严格校验证书链与 SAN）**

```bash
curl --cacert /opt/sa-gw-stub-30/certs/certificates/demo-upstream-ca/1/ca.pem \
  --resolve svc.example.com:40056:127.0.0.1 -u svcuser:svcpass \
  https://svc.example.com:40056/json
```

**gRPC 家族（grpcurl，静态二进制见 verify-tools/）**

```bash
G='grpcurl -import-path protos -max-time 8'
# grpc 明文（basic）
$G -proto grpc.basic.proto -plaintext -H 'authorization: Basic c3ZjdXNlcjpzdmNwYXNz' \
  -d '{"data":"hi"}' 127.0.0.1:40066 grpc.basic.Stub/Echo
# grpc 明文（bearer；JWT 由 gen-jwt.py 签发：python3 gen-jwt.py mysecret，可选 Python）
JWT=$(python3 gen-jwt.py mysecret)
$G -proto grpc.bearer.proto -plaintext -H "authorization: Bearer $JWT" \
  -d '{"data":"hi"}' 127.0.0.1:40067 grpc.bearer.Stub/Echo
# grpcs TLS 单向（apikey）
$G -proto grpcs.apikey.proto -insecure -H 'x-api-key: myapikey' \
  -d '{"data":"hi"}' 127.0.0.1:40071 grpcs.apikey.Stub/Echo
# grpcmtls 双向（网关客户端证书，部署包 certs/ 或 certs/generated/）
$G -proto grpcmtls.custom.proto -insecure \
  -cert certs/generated/certificates/demo-gw-client-cert/1/chain.pem \
  -key  certs/generated/certificates/demo-gw-client-cert/1/key.pem \
  -H 'x-edge-auth: edge1' -d '{"data":"hi"}' 127.0.0.1:40076 grpcmtls.custom.Stub/Echo
# 负向：无凭据 → Unauthenticated
$G -proto grpc.basic.proto -plaintext -d '{"data":"x"}' 127.0.0.1:40066 grpc.basic.Stub/Echo
```

**经网关转发（网关 :10000/:10001/:10002/:10443；桩侧命令不变，仅替换地址与路径前缀）**

```bash
# HTTP 家族（网关重写 Host=svc.example.com；rewrite.path=/ 后端收到干净路径）
curl -u svcuser:svcpass http://<gateway>:10000/stub/http-basic/json
curl -u svcuser:svcpass http://<gateway>:10001/stub/mtls-basic/echo/gateway-h1
curl --cacert <ca.pem> -u svcuser:svcpass https://<gateway>:10443/stub/tls-bearer/echo/gw-tls
# gRPC 家族
$G -proto grpcs.jwt.proto -plaintext -H 'authorization: Bearer mytoken' \
  -d '{"data":"hi"}' <gateway>:10002 grpcs.jwt.Stub/Echo
```


---

## 4. 证书

```bash
cd stub30/certs && sh gen.sh        # 输出到 certs/generated/（gitignore，含私钥）
```

生成内容（与 sa-gateway 网关编译契约一致，路径
`certificates/<id>/<version>/{chain.pem,key.pem,ca.pem}`）：

| 证书 | 用途 |
|---|---|
| `demo-gw-cert/1/` | 网关入口 HTTPS listener 证书 |
| `demo-upstream-ca/1/ca.pem` | 加密/mTLS 回源信任 CA（网关与桩共用） |
| `demo-gw-client-cert/1/` | mTLS 回源时网关出示的客户端证书 |
| `upstream/server.chain.crt + key` | 测试桩服务端证书（SAN 含 demo-upstream/demo-stub/svc.example.com） |

**端口段偏移**（默认 40051-40080 与 ephemeral 出站源端口冲突时的自救）：

```bash
# 目标机启动时整段平移 30 个端口（PORT_BASE..PORT_BASE+29），无需 root 改内核参数
# 先查系统临时端口范围（出站连接源端口从中分配）：
cat /proc/sys/net/ipv4/ip_local_port_range   # 例如 32768 60999
# 选一个完全在范围之外的段（默认范围 32768-60999 时用 62051；范围被改宽则相应调整）：
PORT_BASE=62051 ./stub-ctl.sh start          # 端口段变为 62051-62080
./stub-ctl.sh verify                         # status/info/verify 自动跟随新端口段
```
> 背景：Linux 默认 ephemeral 出站源端口范围 32768-60999 与 40051-40080 重叠——服务器上
> 出站连接的**源端口**恰好占用桩端口时 listen 报 `address already in use`，且
> `ss -ltn | grep :40066` 平时看不到（源端口占用不产生 LISTEN 行）。PORT_BASE 平移到
> 范围之外（如 62051）即可避开；桩 grpc 内置绑定重试（3 次×2s）自愈瞬时占用。

**自定义域名绑定**（重新生成并指定绑定）：

```bash
cd stub30
ALLOW_HOSTS="api.test.cn my.api.cn" sh certs/gen.sh   # 多域名全部写入证书 SAN
./build-release.sh                                     # 重新打包
# 目标机启动（-allow-host 支持逗号分隔多域名）：
ALLOW_HOST='api.test.cn,my.api.cn' ./stub-ctl.sh start
# 验证（TLS 严格校验 SAN）：
curl --cacert <部署包解压>/certs/certificates/demo-upstream-ca/1/ca.pem \
  --resolve api.test.cn:40056:127.0.0.1 -u svcuser:svcpass https://api.test.cn:40056/json
```

**安全约定**：`*.key` 与 `certs/generated/` 已被 `.gitignore` 忽略——私钥只在本地与
部署包中，绝不入库。轮换证书：删除 `certs/generated/.done` 后重跑 `gen.sh`。

---

## 5. 网关配置样例（gateway-config/）

| 文件 | 说明 |
|---|---|
| `bootstrap.docker.json` | sa-gateway 编译链（发布校验→编译）生成的 Envoy bootstrap 等价形态（占位符已物化），与桩的证书/端口一一对应 |
| `REQUIRED-CERTS.txt` | 编译契约要求的证书清单 |

配置由 sa-gateway 项目生成（`EnvoyDemoConfigDumpTest`）；本仓库只提供联调样例与证书
对齐说明。网关侧 TLS/mTLS 回源、协议转换（h1/h2↔h2、TLS 终止）、Host 重写均为网关
原生能力，桩侧无需感知。

---

## 6. 移植到其它机器 / 环境

| 需求 | 说明 |
|---|---|
| CPU | `amd64` / `arm64` 部署包默认产出；其它架构改 `build-release.sh` 的 `ARCHS`（如 `ARCHS="amd64 arm64 386"`） |
| 发行版 | 无关——纯静态二进制 + `sh` + `wget`；Debian/Ubuntu/CentOS/RHEL/Alpine 均可 |
| 网络 | 部署包自包含（含证书），目标机零下载；构建机首次构建访问 `goproxy.cn` |
| 依赖本仓库 | 否——`dist/*.tar.gz` 为自包含交付物（含私钥，仅内网流转） |
| 依赖 sa-gateway 项目 | 否——测试桩独立运行；仅网关配置样例与证书 CA 需与网关侧对齐 |

---

## 7. 开发与构建（stub30/）

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
├── stub-30.sh                # 30 端口启动器（BIN_DIR/CERT_DIR/LOG_DIR/ALLOW_HOST 参数化）
├── stub-ctl.sh               # 一键管理 start/stop/status/verify（POSIX sh）
├── certs/gen.sh              # 证书生成（编译契约布局 + 幂等）
├── build-release.sh          # 部署包构建器（交叉编译 amd64/arm64 + systemd + 证书）
├── go.mod / go.sum           # Go 依赖（grpc/protobuf，go.sum 锁定）
└── dist/                     # 部署包产物（gitignore：含私钥）
```

---

## 8. FAQ

| 现象 | 处理 |
|---|---|
| `/healthz` DOWN | `stub-ctl.sh status` 看进程；日志在 `LOG_DIR/`（http-basic.log 等） |
| grpcurl 报 `unknown service` | 服务名与端口按认证变体配对——`/grpc.basic.Stub/` 在 40066、bearer 在 40067，以此类推；描述符在 `stub30/protos/` |
| gRPC 调用 `Unauthenticated` | 凭据放 metadata（HTTP/2 头小写），见 §2.3；JWT 用 `gen-jwt.py mysecret` 签发 |
| TLS 握手失败 `unknown ca` | 客户端须信任 `certs/generated/` 的 CA（demo-upstream-ca）；mTLS 客户端须出示 demo-gw-client-cert |
| 端口被占用 | `stub-ctl.sh stop` 后重启；或 `ss -ltnp \| grep 4005` 查占用者 |
| 想换放行域名 | `ALLOW_HOST=<域名> ./stub-ctl.sh start`（网关侧路由需同步 rewrite.host） |

---

## 9. 网关演示环境（demo/，本机端到端测试）

`demo/` 是完整的 Envoy 网关演示/测试环境：真实编译链 bootstrap → 真实 Envoy v1.37.1 →
演示上游 + 30 端口测试桩，**4 入口 × 30 上游 = 120 条互转链路**全量可验证
（`verify-30.sh`，155 项断言：直连基线/网关转发/互转矩阵/业务端点真实值/认证正负向/mTLS 证书链）。

```bash
# ① 生成网关配置（需 sa-gateway 项目构建环境，JDK17 + Maven）
mvn -f <sa-gateway>/pom.xml -pl sa-gateway-api,sa-gateway-domain test \
  -Dtest=EnvoyDemoConfigDumpTest        # 产物写入 demo/output/bootstrap.docker.json

# ② 构建并启动
cd demo && docker compose up -d --build

# ③ 全量验证
./verify-30.sh        # PASS=155 FAIL=0
```

说明：`demo/stub/` 是测试桩源码的**构建快照**（演示镜像构建输入）；测试桩的权威源码
与交付物在 `stub30/`。演示环境需 Docker，仅本机/联调机使用——服务器部署测试桩走 §1。

## 10. 历史版本

根目录遗留 v1（单实例 origin-test + `deploy-15.sh` 15 端口平铺、`gen-cert.sh`、原
README）已归档至 `docs/origin-test-legacy.md`，仅供向后参考；新部署一律使用 `stub30/`。
