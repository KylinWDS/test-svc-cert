# test-svc-cert —— sa-gateway 测试桩与联调交付物

为 **sa-gateway 安全网关**提供可独立部署的被测上游（测试桩）与网关配置交付物。
仓库自包含：测试桩源码与静态二进制、证书生成脚本、一键管理脚本、网关配置样例。

- 测试桩定位：模拟"被防护服务"，验证网关的 **Host 校验 / HTTP-HTTPS-gRPC 回源 / 回源
  TLS 与 mTLS / 5 种业务认证 / 健康探针** 全部维度，接口返回真实值（页面 / JSON /
  CSV 文件均可浏览器回显）。
- 仓库自包含、开箱即用：**目标机不需要 Docker、openssl、Go、Python**——测试桩为
  `CGO_ENABLED=0` 纯静态 Go 二进制（不依赖 glibc/musl），证书为 PEM 文件（本机生成
  打包），管理与验证仅依赖 `sh` + `wget`（或 curl）。
- 仓库分两部分：
  - **`stub30/`（当前交付物，推荐）**：30 端口测试桩——{http, tls, mtls} × {grpc,
    grpcs, grpcmtls} 六种传输形态 × 5 种认证，一键启停 `stub-ctl.sh`。
  - **根目录遗留 v1**（`main.go` + `deploy-15.sh`，15 端口单实例平铺）：早期版本，
    保留向后兼容，详见 `docs/origin-test-legacy.md`。

> 网关侧（Envoy）由 sa-gateway 项目与节点 pilot 负责；本仓库只交付测试桩与网关配置
> 样例，不承载网关运行时。
>
> **另**：sa-gateway 项目侧的本机演示环境（docker-compose + 演示上游 + verify-30.sh
> 155 断言网关互转验证）已归档至本仓库 `docs/demo-environment-legacy.tar.gz`
> （解包后 `docker compose up -d --build` 可在装有 Docker 的机器复现演示）。

---

## 1. 快速开始

```bash
# 本机（任意有 Go 1.23+ 的机器）制作部署包
cd stub30 && sh certs/gen.sh && ./build-release.sh
# 产物：dist/sa-gw-stub-30-linux-{amd64,arm64}.tar.gz（含 TLS 私钥，勿入库勿外传）

# 目标机（任意 Linux amd64/arm64，Debian/Ubuntu/CentOS/RHEL/Alpine 均可）
scp dist/sa-gw-stub-30-linux-<arch>.tar.gz user@<server>:/tmp/
ssh user@<server>
tar xzf /tmp/sa-gw-stub-30-linux-<arch>.tar.gz -C /opt/     # → /opt/sa-gw-stub-30/
cd /opt/sa-gw-stub-30 && ./stub-ctl.sh start                # 一键启动 30 端口
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
| `./stub-ctl.sh verify` | 语义探活：探针 200 + **业务端点真实值自检**（/json /echo /file）+ gRPC 进程 |

依赖：`sh` + `wget`（或 curl）——Debian/Ubuntu/CentOS/RHEL/Alpine 默认满足，无
systemd/bash/python 依赖。systemd 环境可用 `systemd/sa-gw-stub-30.service`。

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

## 9. 历史版本

根目录遗留 v1（单实例 origin-test + `deploy-15.sh` 15 端口平铺、`gen-cert.sh`、原
README）已归档至 `docs/origin-test-legacy.md`，仅供向后参考；新部署一律使用 `stub30/`。
