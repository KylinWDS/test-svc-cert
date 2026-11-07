# origin-test — 被防护微服务测试桩(网关联调)

模拟"被防护服务",验证 WAF 网关透传的 4 个维度:

1. **Host 头路由** —— 校验并回显 `Host`(网关设的被防护域名),不匹配返回 400
2. **HTTP / HTTPS** —— 两协议独立监听,网关↔后端可 http 也可 https
3. **回源 TLS / mTLS** —— 网关用 trust CA 校验后端证书;后端再校验网关客户端证书(证网关身份)。在传输层,与业务认证完全独立
4. **业务回源认证(网关→后端)** —— Basic / Bearer Token / JWT / API Key / 自定义 header,互不替代 mTLS;健康探测与业务凭据互不继承

纯 Go 标准库,零依赖,编译成单个静态二进制即可部署。

---

## 1. 目录结构

| 文件 | 作用 |
|------|------|
| `main.go` | 服务本体(HTTP + HTTPS/mTLS + 5 种业务认证) |
| `main_test.go` | 自包含集成测试(内存生成证书,`go test ./...` 全绿) |
| `gen-cert.sh` | 一键生成一套自测证书(需 openssl) |
| `gen-jwt.py` | 生成 HS256 JWT,供 JWT 认证测试 |
| `deploy-15.sh` | 一键平铺部署 15 种「传输层×认证」组合(端口 40051–40065) |
| `README.md` | 本文档(全部说明) |

---

## 2. 文件与生成(部署到服务器需要哪些、怎么来、各是什么)

### 2.1 远程必要文件(传到服务器的)

| 文件 | 是远程必要的吗 | 用途 |
|------|----------------|------|
| `origin-test-linux-amd64` | ✅ 必须 | 二进制,直接运行 |
| `certs/server.pem` + `certs/server.key` | ✅ 必须(开 TLS/mTLS 形态时) | 被防护服务自身的证书/私钥,后端用它对外提供 TLS;被网关 trust CA 校验 |
| `certs/ca.pem` | ✅ 必须(开 mTLS 形态时) | 当作 `-client-ca`,后端用它**校验网关客户端证书**;同一个 CA 也是网关校验后端证书的 trust CA |
| `certs/client.pem` + `certs/client.key` | ❌ 不需要放后端 | **网关端**的客户端证书/私钥(网关出示给后端证明身份);后端只认签发它的 `ca.pem` |
| `certs/ca.key` | ❌ 绝不上传 | 根 CA 私钥,仅生成证书时用,远程不需要 |

> 一句话:后端服务器上需要 **二进制 + `server.pem` + `server.key` + `ca.pem`**(外加 `deploy-15.sh`、`gen-jwt.py` 按需);`client.*` 和 `ca.key` 不给后端。

### 2.2 二进制怎么生成(在你有 Go 的机器上,针对服务器架构)

```bash
# x86_64 服务器
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o origin-test-linux-amd64 .
# ARM64 服务器
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o origin-test-linux-arm64 .
```
输出:`origin-test-linux-amd64`,`statically linked` 静态二进制(约 7~8 MB),裸 Linux 直接跑,无需 Go 运行时。

### 2.3 证书怎么生成、输出什么

```bash
./gen-cert.sh            # 需要本机有 openssl; 服务器不需要 openssl, 证书传过去即可
```

生成到 `certs/`,共 6 个文件:

| 输出文件 | 内容 | 谁持有 |
|----------|------|--------|
| `ca.pem` / `ca.key` | 根 CA 证书 / 根 CA 私钥 | `ca.pem`: 网关(trust CA)+ 后端(`-client-ca`); `ca.key` 仅本地保管 |
| `server.pem` / `server.key` | 被防护后端服务证书 / 私钥(受 `ca` 签发,SAN: `svc.example.com`,`localhost`,`127.0.0.1`) | **后端**,`-cert` / `-key` |
| `client.pem` / `client.key` | 网关客户端证书 / 私钥(受 `ca` 签发,用于客户端认证) | **网关端**,对后端出示 |

> 若你真实网关的客户端证书由**别的 CA**签发,把 `-client-ca` 指向"签发网关客户端证书的那个 CA"即可,不必用这套自签 CA。

### 2.4 上传命令(Mac → 服务器)

```bash
scp origin-test-linux-amd64 certs/server.pem certs/server.key certs/ca.pem \
    deploy-15.sh gen-jwt.py sgw@<IP>:/opt/origin-test/
```
> 不带 `ca.key`、`client.*`到后端服务器。

---

## 3. 构建与本地运行(开发机)

```bash
go build -o origin-test .
./gen-cert.sh
# 单实例示例(任选一种认证)
./origin-test -listen-http :8080 -listen-https :8443 \
  -cert certs/server.pem -key certs/server.key -client-ca certs/ca.pem \
  -allow-host svc.example.com \
  -auth-basic-user svcuser -auth-basic-pass svcpass
```

**测试**:`go test ./...`(在内存里生成 CA + 服务证书 + 网关证书,自包含,不需 openssl)。

---

## 4. URI 清单(给网关做路由/健康检查配置)

| URI | 用途 | 认证 |
|-----|------|------|
| `/` 及任意业务路径 | 业务入口:浏览器→HTML 状态页,工具/脚本→JSON | Host + 业务认证 |
| `/health` `/healthz` `/readyz` `/livez` | 网关上游健康检查(四名等价,K8s/网关惯用) | **免 Host / 免认证** |

- 健康探测就绪返回 **200 `ok`**;`-ready=false` 启动则返回 **503**,可验证网关把不健康上游摘除。
- `/healthz` 探活不打凭据即对应"健康探测与业务凭据互不继承"。

---

## 5. 业务回源认证(操作手册)

### 5.1 每种认证,后端到底校验什么?

| 方式 | 后端校验的请求头 | 后端启动参数 | 在网关里填什么 | 校验本质 |
|------|------------------|----------------|----------------|----------|
| **Basic** | `Authorization: Basic base64(用户名:密码)` | `-auth-basic-user` / `-auth-basic-pass` | 用户名 / 密码 | 明文 base64 相等 |
| **Bearer Token** | `Authorization: Bearer <token本体>` | `-auth-bearer-token` | 一段固定字符串(如 `mytoken`) | 字符串**精确相等** |
| **JWT** | `Authorization: Bearer <jwt>` | `-auth-jwt-secret` | 由密钥**签发**的 JWT | HMAC-SHA256 **签名校验** + 过期检查 |
| **API Key** | `<头名>: <值>`(默认 `X-Api-Key`) | `-auth-api-key`(+`-auth-api-key-header`) | 头名 + 值 | 头名与值精确相等 |
| **自定义 header** | `<任意头名>: <值>` | `-auth-custom-header` / `-auth-custom-value` | 任意头名 + 值 | 头名与值精确相等 |

服务启动时会把**实际启用的一套校验规则打印到日志**,照着回填网关即可。

### 5.2 默认参考凭据集

```bash
./origin-test -listen-http :8080 -listen-https :8443 \
  -cert certs/server.pem -key certs/server.key -client-ca certs/ca.pem \
  -allow-host svc.example.com
  # 任选一行启用, 不要全部开(AND 会互相挡):
  -auth-basic-user svcuser -auth-basic-pass svcpass        # ① Basic
  -auth-bearer-token mytoken                               # ② Bearer Token
  -auth-jwt-secret mysecret                                # ③ JWT(HS256密钥)
  -auth-api-key myapikey -auth-api-key-header X-Api-Key     # ④ API Key
  -auth-custom-header X-Edge-Auth -auth-custom-value edge1  # ⑤ 自定义 header
```

| 场景 | 网关里填 | 后端收到的头 |
|------|----------|--------------|
| Basic | 用户名 `svcuser` 密码 `svcpass` | `Authorization: Basic c3Zj...` |
| Bearer | Token `mytoken`(只填本体) | `Authorization: Bearer mytoken` |
| JWT | 密钥 `mysecret` 签发的 JWT | `Authorization: Bearer eyJ...` |
| API Key | Header名 `X-Api-Key` / 值 `myapikey` | `X-Api-Key: myapikey` |
| 自定义 | 头 `X-Edge-Auth` / 值 `edge1` | `X-Edge-Auth: edge1` |

### 5.3 逐个说明

**② Bearer Token** —— 网关让你填的就是固定明文字符串,后端去 `Bearer ` 前缀后精确相等,无加密无过期。
- 网关填 `mytoken`;后端 `-auth-bearer-token mytoken`。
- Postman:Authorization 选 **Bearer Token**,Token 框填 `mytoken`。
- curl:`curl -H 'Authorization: Bearer mytoken' http://127.0.0.1:8080/`

**③ JWT —— 与 Bearer Token 的本质区别**(两者都走 `Authorization: Bearer`,但校验逻辑完全不同):

| | Bearer Token | JWT |
|---|---|---|
| Token 是什么 | 一段明文常量 | `header.payload.signature` 三段式 |
| 校验方式 | 字符串精确相等 | 用密钥重算 HMAC-SHA256 比对**签名** + 检查 `exp` **过期** |
| 谁拿到都能用吗 | 能 | 不能,改 payload 签名即失效 |
| 网关侧配什么 | 固定值 | 与后端相同的**密钥**,用它签发/校验 |

所以 JWT 不是随手填的字符串,必须用 `-auth-jwt-secret` 同一个密钥签出来。生成测试用 JWT:
```bash
python3 gen-jwt.py mysecret                                  # 默认 sub=test-client, 1小时有效
python3 gen-jwt.py mysecret '{"sub":"alice","role":"admin"}'  # 自定义 claims
TOKEN=$(python3 gen-jwt.py mysecret)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/
```
过期验证:`python3 gen-jwt.py mysecret '{"exp":1700000000}'` → 401 `jwt failed: expired`。

**④ API Key** —— 后端校验同一个头名与值:
- 网关填 Header Name `X-Api-Key` / Value `myapikey`;后端 `-auth-api-key myapikey`(换头名加 `-auth-api-key-header <名字>`)。
- Postman:API Key 类型;curl:`curl -H 'X-Api-Key: myapikey' http://127.0.0.1:8080/`

**⑤ 自定义 header** —— 机制同 API Key,但名字随意,用于任意业务自定义头:后端 `-auth-custom-header X-Edge-Auth -auth-custom-value edge1`;Postman 在 Headers 里加一行 `X-Edge-Auth: edge1`。

### 5.4 看响应判断

通过 → **200**,JSON/页面里 `auth_passed` 列出本次通过的认证;被拦 → **401**,body 是具体原因(`api key (X-Api-Key) failed`、`jwt failed: bad signature` 等;401 时没有 `auth_passed`)。

### 5.5 常见坑

- **一次只开一种**——多开是 AND,浏览器/Postman 通常只带一种 → 一直 401。
- **Postman Basic/Bearer 会覆盖 `Authorization` 头**,别同时手动加。
- **JWT secret 必须和网关一致**,否则 `bad signature`。
- **健康探测 `/healthz` 不校验任何凭据**(验证"健康探测与业务凭据互不继承"时用)。

---

## 6. 服务器多形态部署

传输层(明文 HTTP / 单向 TLS / 双向 mTLS)× 业务认证(5 种),平铺开 = **15 种组合,每个组合一个实例、一个端口**。

### 6.1 三形态对应端口与网关要求(单独部署时)

| 形态 | 传输层 | 端口 | 关键参数 | 网关要求 |
|------|--------|------|----------|----------|
| **① HTTP + 业务认证** | 无回源TLS | `:8080` | 无证书参数 | 网关→后端走 http,注入业务认证 |
| **② 回源TLS(单向)+ 业务认证** | TLS | `:8443` | `-cert/-key` | 网关 trust CA 校验后端证书;网关不出示证书 |
| **③ 回源mTLS(双向)+ 业务认证** | mTLS | `:8444` | `-cert/-key/-client-ca` | 网关校验后端证书**且**出示客户端证书 |

### 6.2 一键部署 15 个(`deploy-15.sh`)

把 15 种组合一次性平铺启动,端口 **40051–40065**(http-basic、http-bearer、…、mtls-custom 顺序排列)。

```bash
./deploy-15.sh            # 启动全部 15 个
./deploy-15.sh start      # 同上
./deploy-15.sh stop       # 停止全部
./deploy-15.sh restart    # 重启
./deploy-15.sh status     # 列出 15 个实例的端口/传输/认证/存活
./deploy-15.sh verify     # 逐一探活 /healthz(mTLS 端自动带 client.pem)
```

- 每个实例独立的 PID(`run/*.pid`)和日志(`run/*.log`)。
- 覆盖:`BIN=<路经>` 换二进制(本地自测 `BIN=./origin-test`),`ALLOW_HOST=` 改放行域名(默认 `svc.example.com`)。
- `deploy-15.sh` 自检:缺证书会提示你不要硬跑,并指向上面的生成章节。
- 同一服务器三种形态同时跑没问题(端口互不冲突)。

**15 个组合的端口映射:**
| | basic | bearer | jwt | apikey | custom |
|---|---|---|---|---|---|
| **http** | 40051 | 40052 | 40053 | 40054 | 40055 |
| **tls** | 40056 | 40057 | 40058 | 40059 | 40060 |
| **mtls** | 40061 | 40062 | 40063 | 40064 | 40065 |

各组合用 5.2 节的默认凭据集:Basic=`svcuser/svcpass`、Bearer=`mytoken`、JWT 密钥=`mysecret`、APIKey=`myapikey`、自定义=`X-Edge-Auth: edge1`。

> mTLS 的 `/healthz` 也要客户端证书(`verify` 已带上);网关探活 mTLS 上游同样要配客户端证书。

### 6.3 systemd 常驻(三个形态 = 三个 unit)

`/etc/systemd/system/origin-svc@.service`(`%i` 传端口):
```ini
[Unit]
Description=origin-test origin (form %i)
After=network.target

[Service]
WorkingDirectory=/opt/origin-test
# ③ mTLS 示例; 换形态改这一段
#   ③ mTLS:   后面 -client-ca ...
#   ② 单向TLS:去掉 -client-ca ...
#   ① 明文HTTP:-listen-http :%i https关掉
ExecStart=/opt/origin-test/origin-test-linux-amd64 \
    -listen-http "" -listen-https :%i \
    -cert certs/server.pem -key certs/server.key -client-ca certs/ca.pem \
    -allow-host svc.example.com -auth-basic-user svcuser -auth-basic-pass svcpass
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl enable --now origin-svc@8444     # ③ mTLS
sudo systemctl list-units 'origin-svc@*' --all
```

---

## 7. 安全提醒

- 只开放需要的内网端口;`-listen-*` 尽量绑内网 IP(如 `10.0.0.5:8080`)。
- 私钥 `server.key`、`client.key`、`ca.key` 不要放到客户端/公网侧。
- 仅联调用,验证完可删,别当生产服务。