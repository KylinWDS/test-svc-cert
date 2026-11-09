# sa-gateway 演示与测试桩环境（demo/）

从零到一构建一套**网关流量转发演示与全量验证环境**：以本项目真实编译链（发布校验 →
编译）生成 Envoy bootstrap，注入真实 Envoy（v1.37.1），对 **30 端口测试桩**完成
**4 个网关入口 × 30 个上游 = 120 条流量互转链路**的全组合验证，覆盖
**入口 {h1, h2, TLS 终止} × 回源 {http, tls, mtls, grpc, grpcs, grpcmtls} × 认证
{basic, bearer, jwt, apikey, custom}**。

- 读者对象：首次接触本环境的人员，以及需要把测试桩部署到联调服务器的运维。
- 环境要求：仅需 Docker（构建期访问 `goproxy.cn` 下载 Go 模块，`go.sum` 锁定完整性）；
  配置生成步骤需要项目构建环境（JDK 17 + Maven，配置见 `docs/33`）。
- 配套验证：`verify-30.sh`，**155 项断言**全量自动化（含直连基线、网关转发、互转矩阵、
  业务端点真实返回、认证正/负向、mTLS 证书链）。

---

## 1. 这是什么

### 1.1 架构与流量拓扑

```
                    ┌─ :10000 入口 HTTP（codec AUTO，h1/h2 协商）
                    ├─ :10001 入口 HTTP（codec HTTP1，h1 强制）      ┐
 客户端 ──── 网关 ──┤ :10002 入口 HTTP（codec AUTO，h2 可用）         ├ 4 入口
                    └─ :10443 入口 HTTPS（TLS 终止，demo-gw-cert）    ┘
                          │ 路由（真实编译链生成，136 clusters / 152 routes）
                          ▼
        ┌── demo-upstream（四合一演示上游 :8080/:8443/:9090/:9091）
        └── demo-stub（30 端口测试桩 :40051-40080）
```

Envoy 以"协议终止 + 协议发起"方式工作：入口按 listener 配置解码（`codec_type` 由
`server.http.http2` 决定），出口按 cluster 配置重新编码（由 `upstream.protocol` 决定，
GRPC/GRPCS 无条件 HTTP/2）。两侧互不感知，因此 **120 条互转链路不需要任何"转换"类
配置**——入口与出口是模型里两个正交字段（论证详见 `docs/33` §6）。

### 1.2 组件清单

| 组件 | 容器/镜像 | 职责 |
|---|---|---|
| 网关 | `demo-envoy`（envoyproxy/envoy:v1.37.1 + 烧入编译产物） | 加载真实编译链 bootstrap，执行全部转发 |
| 演示上游 | `demo-upstream` | 单进程四合一：HTTP 页面 :8080 / HTTPS :8443 / gRPC :9090 / gRPCS :9091，可视化页面 + `/info` 回显 |
| 测试桩 | `demo-stub` | 30 端口（见 §4.1）：15 个 origin-test 实例 + 1 个 stubgrpc 进程（15 listeners） |
| 证书生成 | `sa-gateway-demo-certs-1`（一次性任务） | 按编译契约布局生成证书并写入 `demo-certs` 卷 |
| 客户端 | `sa-gateway-demo-grpcurl` 镜像 | grpcurl + 17 个 proto 描述符，常驻模式供脚本复用 |

### 1.3 关键设计约定

- **证书契约**：编译产物按 `{{PILOT_RELEASE_DIR}}/certificates/<id>/<version>/{chain.pem,key.pem,ca.pem}`
  引用证书；`certs/gen.sh` 按同布局生成，且**幂等**（卷内 `.done` 存在即跳过）——证书集
  跨重启恒定，避免运行中重生成导致信任链错配。
- **无 bind mount**：所有注入经镜像 COPY（规避 Docker Desktop 文件共享限制）。
- **认证语义**：网关真实执行传输层（TLS/mTLS 回源、协议转换、Host 重写）；业务认证凭据
  由**客户端持有并透传**、后端校验——网关代填凭据属于"意图"（见 §4.4）。

---

## 2. 快速开始（TL;DR）

```bash
# ① 生成网关配置（真实编译链，产物自动同步到 demo/output/）
mvn -s /Applications/Works/maven/apache-maven-3.9.16/conf/gts-aliyun-global-settings.xml \
  -pl sa-gateway-api,sa-gateway-domain test -Dtest=EnvoyDemoConfigDumpTest

# ② 启动环境（全量构建：certs → stub → upstream → envoy）
cd demo && docker compose up -d --build

# ③ 全量验证（155 项断言）
./verify-30.sh        # 期望：PASS=155 FAIL=0，退出码 0

# ④ 打开页面看流量转发效果
open http://localhost:10000/
```

---

## 3. 详细指引

### 3.1 步骤 1：生成网关配置

`EnvoyDemoConfigDumpTest`（位于 `sa-gateway-domain` 测试）调用项目真实编译链完成
发布校验 → 编译，并做节点侧运行时物化（替换 `{{PILOT_*}}` 占位符、剥离零插件场景的
wasm 单例）。

```bash
mvn -s /Applications/Works/maven/apache-maven-3.9.16/conf/gts-aliyun-global-settings.xml \
  -pl sa-gateway-api,sa-gateway-domain test -Dtest=EnvoyDemoConfigDumpTest
```

产物：

| 文件 | 用途 |
|---|---|
| `demo/output/bootstrap.docker.json` | 可挂载配置（envoy 镜像 COPY 用，步骤 2 前置） |
| `sa-gateway-domain/target/envoy-demo/envoy-bootstrap.json` | 编译原始产物（含占位符，供核对） |
| `sa-gateway-domain/target/envoy-demo/REQUIRED-CERTS.txt` | 编译契约要求的证书文件清单 |
| `sa-gateway-domain/target/envoy-demo/canonical.json` 等 | 编译链其余产物 |

编译断言（内置，不通过即失败）：136 clusters；68 个 GRPC/GRPCS cluster 无条件输出
`http2_protocol_options`；88 个加密回源 cluster（×2 处 UpstreamTlsContext/ca.pem）；
40 个 mTLS cluster 出示网关客户端证书；60 条路由 Host 重写；入口 codec 形态
1×HTTP1 + 3×AUTO。

### 3.2 步骤 2：启动环境

```bash
cd demo && docker compose up -d --build
```

启动顺序由 compose 依赖关系保证：certs（幂等生成证书）→ stub / upstream → envoy。

> 说明：grpcurl 客户端镜像属 `profiles:["client"]`，`up -d` 不会构建它——
> `verify-30.sh` 会在需要时自动补建，也可手动 `docker compose build grpcurl`。

### 3.3 步骤 3：全量验证

```bash
./verify-30.sh       # 退出码 0 = 全部通过；失败逐条列出
```

155 项断言分八组：

| 组 | 内容 | 数量 |
|---|---|---|
| 一 | 直连基线：HTTP 家族 15 端口（正/负凭据、mTLS 证书直连、无证书握手拒绝、健康探针） | 90 |
| 二 | 直连基线：gRPC 家族 15 端口（三传输 × 5 认证 + 负凭据 Unauthenticated） | 20 |
| 三 | 经网关 :10000：HTTP 家族 15 链路（Host 重写、凭据透传、无凭据 401、mTLS 客户端证书被后端确认） | 45 |
| 四 | 经网关 :10000：gRPC 家族 15 链路（明文/TLS/mTLS 回源 + metadata 透传 + 网关身份回显） | 15 |
| 五 | 基础链路回归（页面、基础 gRPC/gRPCS） | 5 |
| 六 | 互转矩阵：HTTP 家族 × 入口 {:10001 h1-only, :10002 h2, :10443 TLS 终止} | 45 |
| 七 | 互转矩阵：gRPC 家族 × 入口 {:10002 h2, :10443 https} | 30 |
| 八 | 业务端点真实返回（/json 样例数据、/echo 回显、/file CSV 下载、状态页、跨链路抽样） | 11 |

脚本内部自动完成：从 stub 容器解析证书卷名（带 compose 项目前缀）、物化 `/tmp` 客户端
凭据、按需构建 grpcurl 镜像、以常驻容器 + `docker exec` 复用（避免逐条 `compose run`
抖动）。

### 3.4 步骤 4：手工体验

```bash
open http://localhost:10000/          # 页面，tag 显示命中的后端
curl http://localhost:10000/secure/   # HTTPS 回源页面
curl http://localhost:10002/info      # h2 入口注入头（X-Forwarded-*）
# h1 强制入口 × mTLS 回源
curl -u svcuser:svcpass http://localhost:10001/stub/mtls-basic/
# gRPC 互转（h2 入口 × gRPCS TLS 回源）
docker compose run --rm grpcurl -import-path /protos -proto grpcs.jwt.proto -plaintext \
  -H "authorization: Bearer $(python3 stub/gen-jwt.py mysecret)" \
  -d '{"data":"hi"}' demo-envoy:10002 grpcs.jwt.Stub/Echo

# 业务端点（真实值返回，浏览器直接打开可回显）
curl -u svcuser:svcpass http://localhost:10000/stub/http-basic/json     # 结构化样例
curl -u svcuser:svcpass http://localhost:10000/stub/http-basic/echo/hello-world
curl -u svcuser:svcpass -OJ http://localhost:10000/stub/http-basic/file # 下载 CSV
open http://localhost:10000/stub/http-basic/                            # 状态页（浏览器）
```

---

## 4. 端口与路由参考

### 4.1 测试桩端口矩阵（30 个，:40051-40080）

| | basic | bearer | jwt | apikey | custom |
|---|---|---|---|---|---|
| **http**（明文） | 40051 | 40052 | 40053 | 40054 | 40055 |
| **tls**（单向 TLS） | 40056 | 40057 | 40058 | 40059 | 40060 |
| **mtls**（双向 mTLS） | 40061 | 40062 | 40063 | 40064 | 40065 |
| **grpc**（明文 gRPC） | 40066 | 40067 | 40068 | 40069 | 40070 |
| **grpcs**（TLS gRPC） | 40071 | 40072 | 40073 | 40074 | 40075 |
| **grpcmtls**（mTLS gRPC） | 40076 | 40077 | 40078 | 40079 | 40080 |

- HTTP 家族：origin-test（`test-svc-cert` 移植）15 实例；校验 Host（放行
  `svc.example.com`）、业务认证；健康探针 `/health /healthz /readyz /livez` 免认证。
- gRPC 家族：stubgrpc 单进程 15 listeners；认证读 gRPC metadata（HTTP/2 头小写），
  JWT 为 HS256 验签 + exp；失败返回 `codes.Unauthenticated`，message 与 HTTP 版一致；
  grpcmtls 强制校验网关客户端证书并回显 Subject。
- **凭据集**：`basic=svcuser/svcpass`、`bearer=mytoken`、`jwt=HS256 mysecret`、
  `apikey=X-Api-Key:myapikey`、`custom=X-Edge-Auth:edge1`。
  JWT 签发：`python3 stub/gen-jwt.py mysecret '{"sub":"alice"}'`。
- **业务端点**（HTTP 家族，均需业务认证，返回真实值且浏览器可回显；网关路由
  `rewrite.path=/` 已将前缀改写为根路径）：

  | 端点 | 返回 |
  |---|---|
  | `GET /` | HTML 状态页（联调信息 + 认证/mTLS 状态 + 接口清单，浏览器直接渲染） |
  | `GET /info` | 请求头/透传信息 JSON 回显 |
  | `GET /json` | 结构化业务样例数据（订单列表，真实字段） |
  | `GET /echo/<任意值>` | 路径参数 + query 全量回显 JSON |
  | `GET /file` | CSV 样例文件（`Content-Disposition: attachment`，浏览器下载） |
  | `GET /healthz` | 免认证探活，`200 ok` |

  gRPC 家族 `Echo` 返回真实值：data 回显 + 后端标识 + `auth_passed` + mTLS 网关证书
  Subject + 时间戳（grpcurl 可读）。

### 4.2 网关入口与 120 条互转链路

| 入口 \ 回源 | http | tls | mtls | grpc | grpcs | grpcmtls |
|---|---|---|---|---|---|---|
| **:10000**（h1/h2 协商） | 无转换 | TLS 发起 | 出示客户端证书 | h1/h2→h2 | h1/h2→h2+TLS | h1/h2→h2+mTLS |
| **:10001**（h1 强制） | h1→h1 | h1→TLS | h1→TLS+mTLS | h1→h2（协议升级） | h1→h2+TLS | h1→h2+mTLS |
| **:10002**（h2 可用） | h2→h1（降级） | h2→TLS | h2→TLS+mTLS | h2→h2 | h2→h2+TLS | h2→h2+mTLS |
| **:10443**（TLS 终止） | TLS 终止→明文 | 双跳 TLS | 双跳+mTLS | TLS 终止→h2 | TLS 终止→h2+TLS | TLS 终止→h2+mTLS |

网关路由前缀（每个入口相同）：

| 路由前缀 | 上游 | 说明 |
|---|---|---|
| `/stub/http-<auth>/` | u-stub-http-* | 明文回源 + rewrite.host=svc.example.com |
| `/stub/tls-<auth>/` | u-stub-tls-* | TLS 回源（信任 demo-upstream-ca） |
| `/stub/mtls-<auth>/` | u-stub-mtls-* | mTLS 回源（网关出示 demo-gw-client-cert） |
| `/grpc.<auth>.Stub/` | u-stub-grpc-* | gRPC 明文回源（服务名即路由键） |
| `/grpcs.<auth>.Stub/` | u-stub-grpcs-* | gRPCS TLS 回源 |
| `/grpcmtls.<auth>.Stub/` | u-stub-grpcmtls-* | gRPCS mTLS 回源 |
| `/`、`/secure/`、`/demo.DemoService/`、`/demo.SecureDemoService/` | 演示上游 | 基础链路 |

### 4.3 网关执行 / 意图边界（产品契约）

| 维度 | 状态 | 说明 |
|---|---|---|
| 传输层回源 TLS / mTLS | ✅ 本期执行 | UpstreamTlsContext：信任 CA、SNI/SAN 匹配、网关出示客户端证书 |
| 路由 Host 重写 / 前缀路由 | ✅ 本期执行 | `host_rewrite_literal` / PREFIX match |
| 入口协议形态（h1/h2/TLS 终止） | ✅ 本期执行 | `codec_type`：HTTP1 / AUTO |
| 转发协议（HTTP/HTTPS/GRPC/GRPCS） | ✅ 本期执行 | GRPC/GRPCS 上游无条件 HTTP/2（docs/33 §6.4-1） |
| 业务认证注入（网关代填 5 种凭据） | ⛔ 发布拦截为意图 | `CODE_NATIVE_AUTH_UNAVAILABLE`——运行时秘密注入未接入，不允许发布伪造认证配置；配置/校验/意图存储完整可用 |

矩阵中的认证 = 客户端持有凭据 → 网关透传 → 后端校验。意图契约由
`EnvoyDemoConfigDumpTest.authIntentContract` 测试锁定（5 种类型配置校验通过、发布各
1 条 blocked）。

**协议层面的两条边界**（任何网关皆然，非本环境缺口）：
1. 真 gRPC 调用不能路由到 HTTP(h1) 上游——gRPC 语义要求 trailers，HTTP/1.1 无此机制。
2. "REST 请求自动转 gRPC 调用"的语义转码属 Envoy `grpc_json_transcoder` 插件能力，
   当前编译器无该 filter 渲染，规划于插件/意图里程碑（docs/33 附录 A）。

---

## 5. 集成场景 A：Envoy 网关层已部署 —— 只下发配置

网关（Envoy + 节点侧 pilot）已在目标环境运行时，**本系统是控制面，只产出与下发三件套，
目标机不装任何东西**：

| 交付物 | 来源 | 节点侧用途 |
|---|---|---|
| `envoy-bootstrap.json`（原始产物） | `EnvoyDemoConfigDumpTest` | pilot 物化后加载 |
| `certificates/` 树 | 证书服务按编译契约签发 | 契约路径 `certificates/<id>/<v>/*` |
| 占位符值清单 | 随发布下发 | `{{PILOT_RELEASE_DIR}}` / `{{PILOT_RELEASE_ID}}` / `{{PILOT_CONFIG_SHA}}` / `{{PILOT_ENVOY_ADMIN_PORT}}` / `{{PILOT_MARKER_PORT}}` |

节点侧按契约完成：替换占位符 → 物化证书目录 → 注入 `bootstrap_extensions`（wasm 单例
等基础设施）→ 热加载。本环境的 `bootstrap.docker.json`（占位符已替换 + 剥离零插件 wasm
单例）即"节点物化后最终形态"的等价物，已用真实 Envoy v1.37.1 完成真机验证
（`--mode validate` configuration OK + 真实 gRPC 流量 grpc-status: 0，见 docs/33 附录 C）。

**零数据库变更、零 Nacos 变更**（协议值存于 revision 模型 JSON 大字段；技术字典为纯
代码所有；详见 docs/33 §2）。互转组合全部内嵌在这份 JSON 中，pilot 侧无需任何协议感知
逻辑。

---

## 6. 集成场景 B：裸机 Debian 部署测试桩（无 Docker、无 openssl、仅二进制）

测试桩是 `CGO_ENABLED=0` 纯静态 Go 二进制（`ELF, statically linked`，不依赖 glibc/musl），
TLS 为 Go 内置 crypto/tls——**目标机不需要 Docker、openssl、Go 或任何运行时**；证书是
PEM 文件，在本机制作时打包，目标机只解压。

**覆盖范围**：`build-release.sh` 默认产出 `amd64`/`arm64` 两个包（覆盖主流服务器 CPU；
其它架构改 `ARCHS` 环境变量即可，如 `ARCHS="amd64 arm64 386"`）。发行版无关——静态
二进制在 Debian/Ubuntu/CentOS/RHEL/Alpine 等均可直接运行；唯 `stub-ctl.sh` 管理脚本
依赖 bash 与 `/dev/tcp` 探活（主流发行版默认满足），无 bash 时按 §6.2 的 nohup + 手工
命令兜底。

### 6.1 制作部署包（本机）

```bash
cd demo/stub && ./build-release.sh
# 证书可从本地目录取：./build-release.sh --certs-dir /path/to/certs
# 产物（顶层目录 sa-gw-stub-30/）：
#   dist/sa-gw-stub-30-linux-amd64.tar.gz   x86_64
#   dist/sa-gw-stub-30-linux-arm64.tar.gz   ARM64
# 包内：bin/origin + bin/stubgrpc（静态二进制）、certs/（编译契约布局）、
#       stub-30.sh（启动器）、stub-ctl.sh（start/stop/status/verify 一键管理）、
#       systemd/sa-gw-stub-30.service、INSTALL.txt
# 二进制能力：业务端点真实值返回（/ 页面、/info、/json、/echo/<值>、/file CSV 下载、
#             /healthz 探活），gRPC Echo 完整回显——浏览器与工具均可验证
```

> 前提：目标网关环境使用的 CA 与包内证书同源。若网关用其它 CA，先重跑
> `demo/certs/gen.sh`（或自有 CA 流程）再打包，保持"网关 trust CA ↔ 桩服务端证书 ↔
> 桩校验网关客户端证书"三者一致。

### 6.2 目标机安装（Debian）

```bash
# 本机
scp demo/stub/dist/sa-gw-stub-30-linux-<arch>.tar.gz user@<server>:/tmp/

# 目标机（root 或 sudo）
tar xzf /tmp/sa-gw-stub-30-linux-<arch>.tar.gz -C /opt/      # → /opt/sa-gw-stub-30/
mkdir -p /var/log/sa-gw-stub-30
cp /opt/sa-gw-stub-30/systemd/sa-gw-stub-30.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now sa-gw-stub-30
systemctl status sa-gw-stub-30                               # active (running)

# 一键管理（start/stop/status/verify，见 6.3）
cd /opt/sa-gw-stub-30 && ./stub-ctl.sh status                # 30 端口逐个 UP/DOWN
./stub-ctl.sh verify                                         # 语义探活：/healthz 200 + gRPC 端口 TCP
```

无 systemd 的环境（stub-ctl.sh 同样可用，start 内部即 nohup 模式）：

```bash
cd /opt/sa-gw-stub-30
./stub-ctl.sh start     # 内部即 nohup 拉起（已写 pidfile，stop 可精确停止）
./stub-ctl.sh verify
```

### 6.3 一键管理（stub-ctl.sh）

| 命令 | 行为 |
|---|---|
| `./stub-ctl.sh start` | 幂等后台拉起 30 端口（检查二进制/证书、写 pidfile、输出存活表） |
| `./stub-ctl.sh stop`  | 精确停止（pidfile + pkill 兜底） |
| `./stub-ctl.sh status` | 30 端口逐个 TCP 存活表 + 主进程状态 |
| `./stub-ctl.sh verify` | 语义探活：HTTP 家族 `/healthz` 应答 200（免 Host/认证）+ gRPC 家族 15 端口 TCP |

依赖：bash（Debian/Ubuntu/CentOS/RHEL 默认自带）+ wget 或 curl（探活，自动回退）。

### 6.4 与网关对接

- 网关上游 `nodes[].host` = 裸机服务器 IP（source=DNS 或 STATIC+IP），路由同 §4.2；
- tls/mtls/grpcs/grpcmtls 上游：网关 trust 包内同一 `demo-upstream-ca`；
- mtls/grpcmtls 上游：网关出示 `demo-gw-client-cert`；
- Host 校验：网关路由 `rewrite.host=svc.example.com`，或客户端直连自带该 Host；
- 建议仅对网关开放内网访问。

---

## 7. 运维

### 7.1 日常操作

```bash
docker compose logs -f envoy stub upstream   # 转发/握手日志（stub 内实例日志在容器 /var/log/stub/）
docker compose restart envoy                 # 重新生成配置后重启网关（证书幂等，不会重生成）
docker compose build grpcurl                 # 客户端镜像按需构建（profiles:[client]）
```

### 7.2 环境重置（清理 → 从零复现）

```bash
# ① 清理：容器/网络/卷/本项目镜像
cd demo && docker compose down --rmi local -v
docker rmi sa-gateway-demo-grpcurl sa-gw-bare-metal 2>/dev/null   # profiles 服务与演练遗留
docker volume rm demo-certs 2>/dev/null                           # 历史短名卷
# ② 宿主机临时文件（验证脚本物化的凭据/帧文件）
rm -f /tmp/demo-ca.crt /tmp/gw-client.crt /tmp/gw-client.key /tmp/grpc-h1.bin \
      /tmp/resp-h1grpc.bin /tmp/verify-out.txt /tmp/resp-*.bin
# ③ 可再生产物目录
rm -rf demo/output sa-gateway-domain/target/envoy-demo
# ④ 重跑 §2 的三步（生成 → 启动 → 验证）即完成从零复现
```

> 只清理本环境产物；`redis`/`kingbase`/`mysql` 等既有容器不受影响。证书卷随 `down -v`
> 清除后自动重新生成（幂等标记随卷清除）。

### 7.3 故障排查 FAQ

| 现象 | 原因与处理 |
|---|---|
| grpcurl 报 `failed to query for service descriptor` | reflection 请求会被 PREFIX `/` 路由走偏——镜像已烧入 17 个描述符，始终带 `-import-path /protos -proto <变体>.proto` |
| grpcurl 输出字段与文档不一致 | grpcurl JSON 为 camelCase（`authPassed`/`clientDn`）；HTTP 家族为服务端自有 snake_case（`auth_passed`） |
| HTTPS 入口证书告警 | 网关证书为演示自签（SAN: localhost/demo-gateway）——宿主机 `--cacert demo-ca.crt`，容器内 grpcurl 用 `-insecure -servername localhost` |
| 改了模型/编译器后行为未变 | 重跑 `EnvoyDemoConfigDumpTest` → `docker compose up -d --build envoy stub` |
| 构建报 Go 模块下载失败 | 检查 `goproxy.cn` 可达性；`go.sum` 锁定完整性，重试即可 |
| 演示上游/测试桩证书信任错配 | 证书卷被重生成而消费方未重启——`docker compose restart envoy upstream stub`；轮换证书请 `down -v` |

---

## 7A. 与 test-svc-cert 的内容对照

`demo/` 已完整包含 `test-svc-cert` 的全部能力，并按本环境架构重组：

| test-svc-cert | demo 对应物 | 说明 |
|---|---|---|
| `main.go`（origin-test） | `stub/cmd/origin/main.go` | **逐字节一致**（diff 校验） |
| `main_test.go` | `stub/cmd/origin/main_test.go` | 同包移植，`go test ./cmd/origin` 通过 |
| `gen-jwt.py` | `stub/gen-jwt.py` | **逐字节一致** |
| `deploy-15.sh`（start/stop/status/verify） | `stub/entrypoint.sh`（启动器）+ `stub/stub-ctl.sh`（一键管理，四命令对齐并扩展到 30 端口） | PID 管理改为 pidfile + pkill |
| `gen-cert.sh` | `demo/certs/gen.sh` | 语义覆盖并扩展：SAN 增加 demo-stub/svc.example.com，增加网关证书与 mTLS 客户端证书，幂等保护 |
| `certs/`（6 件套） | `certs/gen.sh` 运行时生成（卷内编译契约布局） | 同一 CA 签发网关/上游/客户端三类证书 |
| `README.md` | 本文档 §6（裸机部署）+ docs/33 | 凭据集/URI/认证手册全部并入 |

新增能力（test-svc-cert 没有）：gRPC 家族 15 端口（grpc/grpcs/grpcmtls × 5 认证）、
Host 重写联动、verify-30.sh 全量断言、与真实编译链配置的端到端闭环。

## 8. 附录

### 8.1 文件清单

```
demo/
├── README.md                 # 本文档
├── verify-30.sh              # 155 项断言全量自动化验证（互转矩阵 + 业务端点 + 从零复现自检）
├── docker-compose.yml        # certs → upstream/stub → envoy（+ grpcurl 客户端，profiles:[client]）
├── certs/gen.sh              # 证书生成（编译契约布局 + 幂等保护）
├── certs/Dockerfile          # alpine/openssl + 烧入脚本
├── envoy/Dockerfile          # envoyproxy/envoy:v1.37.1 + 烧入编译产物
├── upstream/                 # 四合一演示上游
│   ├── main.go               # HTTP 页面 / HTTPS / gRPC / gRPCS（手写 protowire codec，无 protoc）
│   ├── proto/demo.proto      # demo.DemoService / demo.SecureDemoService 描述符
│   └── Dockerfile            # 多阶段构建（goproxy.cn + BuildKit 缓存挂载）
├── stub/                     # 30 端口测试桩
│   ├── cmd/origin/main.go    # origin-test 原样移植（纯 Go 标准库）
│   ├── cmd/origin/main_test.go # origin-test 自包含测试（内存证书，go test ./cmd/origin）
│   ├── cmd/stubgrpc/main.go  # gRPC 家族 15 listeners（CERT_DIR 可参数化）
│   ├── protos/               # stub.proto + 15 个变体描述符（包名 = 路由键）
│   ├── gen-jwt.py            # HS256 JWT 签发工具
│   ├── entrypoint.sh         # 30 端口启动器（容器/裸机通用，路径参数化）
│   ├── stub-ctl.sh           # 一键管理 start/stop/status/verify（裸机交付物）
│   ├── build-release.sh      # 裸机部署包构建器（交叉编译 + systemd + 证书）
│   └── dist/                 # 部署包产物（amd64/arm64 tar.gz，可由 build-release.sh 重建）
├── grpcurl/Dockerfile        # 客户端镜像（静态 grpcurl + 17 描述符 + 常驻模式）
└── output/bootstrap.docker.json   # 导出器产物（由步骤 1 生成）
```

仓库不提交 Go vendor 快照：模块经 `goproxy.cn` 下载 + BuildKit 缓存挂载
（`GOMODCACHE`/`GOCACHE`），`go.sum` 锁定完整性——首次构建需网络，之后命中缓存。

### 8.2 验证覆盖范围

| 维度 | 覆盖 |
|---|---|
| 编译断言（导出器内置） | 136 clusters；68×HTTP/2；88 加密回源（×2 UpstreamTlsContext/ca.pem）；40 mTLS 客户端证书；60 Host 重写；codec 1×HTTP1+3×AUTO |
| 直连基线 | 30 端口（HTTP 家族 15 + gRPC 家族 15），正/负凭据、mTLS、健康探针 |
| 网关转发 | 4 入口 × 30 上游 = 120 条互转链路（含协议升级/降级、TLS 终止、mTLS 双向证书链） |
| 认证意图契约 | 5 种类型可配置可校验、发布 blocked 各 1 条（`authIntentContract` 用例） |
| 裸机部署 | 三形态流量全通（HTTP/gRPC/gRPCS-mTLS），纯静态二进制零依赖 |
| 业务端点 | /json /echo /file / 状态页真实值返回，直连/网关/互转三链路抽样断言 |

### 8.3 与 docs/33 的关系

本环境是 `docs/33-L7上游协议GRPC-GRPCS扩展方案-20261107.md` 的持续可执行证明：
§6 协议转换矩阵（本环境 120 链路全量验证）、§7 零插件可执行性论证（附录 C 真机验证）、
附录 E/E.1/E.2（环境演进记录）。方案评审与里程碑（M1 协议链路 / M2 插件目录合同开放）
见 docs/33 正文；本 README 只覆盖环境的搭建与使用。
