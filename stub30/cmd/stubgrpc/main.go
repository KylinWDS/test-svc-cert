// stubgrpc: 演示网关 30 端口测试桩的 gRPC 侧（18 listeners）。
//
// 传输 {grpc 明文 / grpcs 单向TLS / grpcmtls 双向mTLS} × 认证 {basic/bearer/jwt/apikey/custom}
// = 15 个独立监听（段内 +15..+29）；另有 3 个免认证透传变体 none（段内 +30..+32）。
// 与 origin-test（HTTP 侧 15 端口 40051–40065）语义对齐：
//
//   - 认证凭据从 gRPC metadata 读取（HTTP/2 头小写）：
//     basic   → authorization: Basic base64(user:pass)
//     bearer  → authorization: Bearer mytoken
//     jwt     → authorization: Bearer <HS256 JWT>（验签 + exp，移植 origin-test verifyHS256JWT）
//     apikey  → x-api-key: myapikey
//     custom  → x-edge-auth: edge1
//   - 认证失败 → codes.Unauthenticated，message 与 HTTP 版一致
//   - none 变体（{grpc,grpcs,grpcmtls}.none.Stub）跳过业务认证 —— 凭据透传场景/纯传输验证
//   - mTLS listener 强制校验网关客户端证书（ClientCAs = demo CA），回显证书 Subject
//   - 回显字段与 protos/stub.proto EchoResponse 对齐（auth_passed/host/scheme/client_dn/fwd_*）
//
// 服务名即路由键：/grpc.basic.Stub/Echo 等由网关 PREFIX 路由到对应上游。
//
// 无 protoc/codegen：消息类型为普通结构体，编解码用 protowire 手写（字段号与 stub.proto
// 一致），经 grpc.ForceServerCodec 注入 —— 构建期零代码生成、零网络（依赖 vendor 提交）。
// 客户端（grpcurl）仍按 stub.proto 描述符调用，线上字节格式完全一致。
package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protowire"
)

// ---- 消息类型（字段号与 protos/stub.proto 严格一致） ----

// EchoRequest: field 1 = string data
type EchoRequest struct {
	Data string
}

// EchoResponse: 联调回显（语义与 origin-test HTTP 版 view 对齐）
type EchoResponse struct {
	Data       string   // 1
	Server     string   // 2
	Timestamp  int64    // 3
	AuthPassed []string // 4 (repeated string)
	Host       string   // 5
	Scheme     string   // 6
	ClientDn   string   // 7
	FwdFor     string   // 8
	FwdProto   string   // 9
}

// stubCodec: 手写 proto 线格式编解码（protowire），替代 protoc 生成的 marshal/unmarshal。
type stubCodec struct{}

func (stubCodec) Name() string { return "proto" }

func (stubCodec) Marshal(v interface{}) ([]byte, error) {
	switch m := v.(type) {
	case *EchoResponse:
		b := []byte{}
		b = appendStr(b, 1, m.Data)
		b = appendStr(b, 2, m.Server)
		if m.Timestamp != 0 {
			b = protowire.AppendTag(b, 3, protowire.VarintType)
			b = protowire.AppendVarint(b, uint64(m.Timestamp))
		}
		for _, s := range m.AuthPassed {
			b = appendStr(b, 4, s)
		}
		b = appendStr(b, 5, m.Host)
		b = appendStr(b, 6, m.Scheme)
		b = appendStr(b, 7, m.ClientDn)
		b = appendStr(b, 8, m.FwdFor)
		b = appendStr(b, 9, m.FwdProto)
		return b, nil
	default:
		return nil, fmt.Errorf("stubCodec: unsupported marshal type %T", v)
	}
}

func (stubCodec) Unmarshal(b []byte, v interface{}) error {
	switch m := v.(type) {
	case *EchoRequest:
		m.Data = ""
		for len(b) > 0 {
			num, typ, n := protowire.ConsumeTag(b)
			if n < 0 {
				return errors.New("stubCodec: bad tag")
			}
			b = b[n:]
			if num == 1 && typ == protowire.BytesType {
				s, n := protowire.ConsumeString(b)
				if n < 0 {
					return errors.New("stubCodec: bad string")
				}
				m.Data, b = s, b[n:]
				continue
			}
			n = protowire.ConsumeFieldValue(num, typ, b)
			if n < 0 {
				return errors.New("stubCodec: bad field value")
			}
			b = b[n:]
		}
		return nil
	default:
		return fmt.Errorf("stubCodec: unsupported unmarshal type %T", v)
	}
}

func appendStr(b []byte, num protowire.Number, s string) []byte {
	if s == "" {
		return b // proto3 默认值省略
	}
	b = protowire.AppendTag(b, num, protowire.BytesType)
	return protowire.AppendString(b, s)
}

// ---- 认证规则（与 origin-test 默认凭据集一致） ----

type authSpec struct {
	name  string // auth_passed 回显值
	check func(md metadata.MD) error
}

func buildAuths() map[string]*authSpec {
	const (
		basicUser, basicPass = "svcuser", "svcpass"
		bearerToken          = "mytoken"
		jwtSecret            = "mysecret"
		apiKeyHeader         = "x-api-key"
		apiKey               = "myapikey"
		customHeader         = "x-edge-auth"
		customValue          = "edge1"
	)
	return map[string]*authSpec{
		"basic": {name: "basic", check: func(md metadata.MD) error {
			u, p, ok := parseBasic(first(md, "authorization"))
			if !ok || u != basicUser || p != basicPass {
				return errors.New("basic auth failed")
			}
			return nil
		}},
		"bearer": {name: "bearer", check: func(md metadata.MD) error {
			if bearerOf(first(md, "authorization")) != bearerToken {
				return errors.New("bearer auth failed")
			}
			return nil
		}},
		"jwt": {name: "jwt", check: func(md metadata.MD) error {
			if err := verifyHS256JWT(bearerOf(first(md, "authorization")), jwtSecret); err != nil {
				return fmt.Errorf("jwt failed: %w", err)
			}
			return nil
		}},
		"apikey": {name: "api-key", check: func(md metadata.MD) error {
			if first(md, apiKeyHeader) != apiKey {
				return fmt.Errorf("api key (%s) failed", apiKeyHeader)
			}
			return nil
		}},
		"custom": {name: "custom-header", check: func(md metadata.MD) error {
			if first(md, customHeader) != customValue {
				return fmt.Errorf("custom header (%s) failed", customHeader)
			}
			return nil
		}},
		// none: 免认证透传 —— 不校验任何业务凭据（auth_passed 回显 none(transparent)）。
		// 用途：纯协议/传输验证（网关 h1↔h2 互转、TLS 终止、mTLS 证书链）无需携带凭据；
		// grpcmtls.none 仍执行传输层 mTLS 客户端证书校验并回显 Subject。
		"none": {name: "none(transparent)", check: func(md metadata.MD) error {
			return nil
		}},
	}
}

// transport: gRPC 传输形态与端口基址（每 transport 起 5 个认证变体，端口 = basePort + 认证索引）。
type transport struct {
	pkg      string // 服务名前缀与路由键（grpc / grpcs / grpcmtls）
	basePort int    // 变体端口基址：grpc 40066 / grpcs 40071 / grpcmtls 40076
	port     string // 运行时按认证索引物化的最终端口（echo 回显用）
	cert     string // 空 = 明文
	key      string
	clientCA string // 非空 = mTLS（校验网关客户端证书）
	scheme   string
}

// buildTransports: 按 CERT_DIR 物化 TLS 路径、按 GRPC_PORT_BASE 物化端口基址
// （容器默认 /certs + 40066；裸机部署通过环境变量指向包内 certs/ 与平移后的端口段）。
func buildTransports(certDir string, grpcBase int) []transport {
	serverCert := certDir + "/upstream/server.chain.crt"
	serverKey := certDir + "/upstream/server.key"
	clientCA := certDir + "/certificates/demo-upstream-ca/1/ca.pem"
	return []transport{
		{pkg: "grpc", basePort: grpcBase, scheme: "grpc"},
		{pkg: "grpcs", basePort: grpcBase + 5, scheme: "grpcs", cert: serverCert, key: serverKey},
		{pkg: "grpcmtls", basePort: grpcBase + 10, scheme: "grpcs", cert: serverCert, key: serverKey, clientCA: clientCA},
	}
}

// authKeys: 有序认证清单（端口绑定顺序与 origin-test 的 basic/bearer/jwt/apikey/custom 一致）。
var authKeys = []string{"basic", "bearer", "jwt", "apikey", "custom"}

func main() {
	auths := buildAuths()
	// GRPC_PORT_BASE: gRPC 家族端口基址（默认 40066；与 stub-30.sh 的 PORT_BASE+15 对应）
	grpcBase, err := strconv.Atoi(getenv("GRPC_PORT_BASE", "40066"))
	if err != nil || grpcBase < 1024 {
		log.Fatalf("[stubgrpc] invalid GRPC_PORT_BASE: %v", err)
	}
	transports := buildTransports(getenv("CERT_DIR", "/certs"), grpcBase)
	errc := make(chan error, len(transports)*(len(authKeys)+1))
	// serveVariant: 单个监听变体（服务名 = <pkg>.<authKey>.Stub，Echo → echo(spec)）。
	serveVariant := func(inst transport, authKey string, spec *authSpec, tlsCfg *tls.Config, suffix string) {
		go func() {
			lis, err := listenWithRetry(":"+inst.port, 3)
			if err != nil {
				errc <- err
				return
			}
			serviceName := inst.pkg + "." + authKey + ".Stub"
			opts := []grpc.ServerOption{grpc.ForceServerCodec(stubCodec{})}
			if tlsCfg != nil {
				opts = append(opts, grpc.Creds(credentials.NewTLS(tlsCfg)))
			}
			s := grpc.NewServer(opts...)
			s.RegisterService(&grpc.ServiceDesc{
				ServiceName: serviceName,
				Methods: []grpc.MethodDesc{{
					MethodName: "Echo",
					Handler:    echoMethod(inst, spec),
				}},
				Streams:  []grpc.StreamDesc{},
				Metadata: "stub.proto",
			}, nil) // impl 传 nil：跳过 HandlerType 反射检查；业务逻辑全在 MethodDesc.Handler
			log.Printf("[stubgrpc] %-9s %-6s listening :%s (%s/Echo%s)", inst.pkg, authKey, inst.port, serviceName, suffix)
			errc <- s.Serve(lis)
		}()
	}
	for i, t := range transports {
		tlsCfg, err := transportTLS(t)
		if err != nil {
			log.Fatalf("[stubgrpc] %s: %v", t.pkg, err)
		}
		for j, authKey := range authKeys {
			inst := t // 每变体独立实例：端口按认证索引递增（段内 +15..+19 / +20..+24 / +25..+29）
			inst.port = fmt.Sprintf("%d", t.basePort+j)
			serveVariant(inst, authKey, auths[authKey], tlsCfg, "")
		}
		// 免认证透传变体（none）：端口 = 段内 +30..+32（grpcBase+15..+17）——不破坏既有 30 端口矩阵。
		inst := t
		inst.port = fmt.Sprintf("%d", grpcBase+15+i)
		serveVariant(inst, "none", auths["none"], tlsCfg, ", auth-free")
	}
	// 18 个 goroutine，任一失败立即退出；全部正常则阻塞等待
	for i := 0; i < cap(errc); i++ {
		if err := <-errc; err != nil {
			log.Fatalf("[stubgrpc] exit: %v", err)
		}
	}
	select {}
}

// listenWithRetry: 绑定失败重试（瞬时占用如前一轮进程尚未完全释放时自愈）。
func listenWithRetry(addr string, retries int) (net.Listener, error) {
	var last error
	for i := 0; i < retries; i++ {
		if i > 0 {
			log.Printf("[stubgrpc] %s bind failed (%v), retrying in 2s (%d/%d)...", addr, last, i, retries)
			time.Sleep(2 * time.Second)
		}
		l, err := net.Listen("tcp", addr)
		if err == nil {
			return l, nil
		}
		last = err
	}
	return nil, last
}

// echoMethod: 一元方法 Handler —— 解码 EchoRequest 并转交业务回显（签名同 grpc-go 内部 methodHandler）。
func echoMethod(t transport, spec *authSpec) func(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	return func(srv interface{}, ctx context.Context, dec func(interface{}) error, _ grpc.UnaryServerInterceptor) (interface{}, error) {
		in := new(EchoRequest)
		if err := dec(in); err != nil {
			return nil, err
		}
		return echo(ctx, t, spec, in)
	}
}

// echo: 业务回显 —— 先校验业务认证（失败 Unauthenticated），再组装联调信息。
func echo(ctx context.Context, t transport, spec *authSpec, in *EchoRequest) (*EchoResponse, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	if err := spec.check(md); err != nil {
		return nil, status.Error(codes.Unauthenticated, err.Error())
	}

	var clientDN string
	if t.clientCA != "" {
		clientDN = peerDN(ctx) // mTLS: 回显网关客户端证书 Subject
	}
	return &EchoResponse{
		Data:       in.Data,
		Server:     t.scheme + " :" + t.port + " @" + hostname(),
		Timestamp:  time.Now().UnixMilli(),
		AuthPassed: []string{spec.name},
		Host:       first(md, ":authority"),
		Scheme:     t.scheme,
		ClientDn:   clientDN,
		FwdFor:     first(md, "x-forwarded-for"),
		FwdProto:   first(md, "x-forwarded-proto"),
	}, nil
}

// ---- 认证工具（与 origin-test 语义逐字对齐） ----

func first(md metadata.MD, k string) string {
	if vs := md.Get(k); len(vs) > 0 {
		return vs[0]
	}
	return ""
}

func bearerOf(h string) string {
	if len(h) > 7 && strings.EqualFold(h[:7], "Bearer ") {
		return h[7:]
	}
	return h
}

func parseBasic(v string) (string, string, bool) {
	if len(v) < 6 || !strings.EqualFold(v[:6], "Basic ") {
		return "", "", false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(v[6:]))
	if err != nil {
		return "", "", false
	}
	i := strings.IndexByte(string(raw), ':')
	if i < 0 {
		return "", "", false
	}
	return string(raw[:i]), string(raw[i+1:]), true
}

// verifyHS256JWT: 仅 stdlib 的 HS256 JWT 校验（signature + exp），移植自 origin-test。
func verifyHS256JWT(token, secret string) error {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return errors.New("not a jwt")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return errors.New("bad signature encoding")
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return errors.New("bad signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return errors.New("bad payload")
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return errors.New("bad claims")
	}
	if claims.Exp > 0 && claims.Exp < time.Now().Unix() {
		return errors.New("expired")
	}
	return nil
}

// ---- TLS / mTLS ----

func transportTLS(t transport) (*tls.Config, error) {
	if t.cert == "" {
		return nil, nil
	}
	cert, err := tls.LoadX509KeyPair(t.cert, t.key)
	if err != nil {
		return nil, fmt.Errorf("load server cert: %w", err)
	}
	tc := &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}}
	if t.clientCA != "" {
		pem, err := os.ReadFile(t.clientCA)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, errors.New("client-ca: 未解析到有效证书")
		}
		tc.ClientAuth = tls.RequireAndVerifyClientCert
		tc.ClientCAs = pool
	}
	return tc, nil
}

// peerDN: 从连接的 TLS 状态取对端（网关）客户端证书 Subject。
func peerDN(ctx context.Context) string {
	p, ok := peer.FromContext(ctx)
	if !ok {
		return ""
	}
	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.PeerCertificates) == 0 {
		return ""
	}
	return tlsInfo.State.PeerCertificates[0].Subject.String()
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "demo-stub"
	}
	return h
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
