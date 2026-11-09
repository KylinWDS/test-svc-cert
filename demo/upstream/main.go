// sa-gateway 演示上游：单进程提供四种回源形态 + 可视页面
//
//	:8080 HTTP  页面/JSON
//	:8443 HTTPS 页面/JSON（TLS，证书来自 CERT_DIR/upstream）
//	:9090 gRPC  demo.DemoService/Echo（h2c）
//	:9091 gRPCS demo.SecureDemoService/Echo（TLS）
//
// 无 protoc/codegen：消息为普通结构体 + protowire 手写编解码（字段号与 proto/demo.proto
// 一致），grpc.ForceServerCodec 注入 —— 构建期零代码生成、依赖 vendor 提交、零网络。
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/protobuf/encoding/protowire"
)

// ---- 消息类型（字段号与 proto/demo.proto 严格一致） ----

// EchoRequest: field 1 = string data
type EchoRequest struct {
	Data string
}

// EchoResponse: data=1, server=2, timestamp=3
type EchoResponse struct {
	Data      string
	Server    string
	Timestamp int64
}

// demoCodec: 手写 proto 线格式编解码（替代 protoc 生成物）。
type demoCodec struct{}

func (demoCodec) Name() string { return "proto" }

func (demoCodec) Marshal(v interface{}) ([]byte, error) {
	switch m := v.(type) {
	case *EchoResponse:
		b := []byte{}
		b = appendStr(b, 1, m.Data)
		b = appendStr(b, 2, m.Server)
		if m.Timestamp != 0 {
			b = protowire.AppendTag(b, 3, protowire.VarintType)
			b = protowire.AppendVarint(b, uint64(m.Timestamp))
		}
		return b, nil
	default:
		return nil, fmt.Errorf("demoCodec: unsupported marshal type %T", v)
	}
}

func (demoCodec) Unmarshal(b []byte, v interface{}) error {
	switch m := v.(type) {
	case *EchoRequest:
		m.Data = ""
		for len(b) > 0 {
			num, typ, n := protowire.ConsumeTag(b)
			if n < 0 {
				return errors.New("demoCodec: bad tag")
			}
			b = b[n:]
			if num == 1 && typ == protowire.BytesType {
				s, n := protowire.ConsumeString(b)
				if n < 0 {
					return errors.New("demoCodec: bad string")
				}
				m.Data, b = s, b[n:]
				continue
			}
			n = protowire.ConsumeFieldValue(num, typ, b)
			if n < 0 {
				return errors.New("demoCodec: bad field value")
			}
			b = b[n:]
		}
		return nil
	default:
		return fmt.Errorf("demoCodec: unsupported unmarshal type %T", v)
	}
}

func appendStr(b []byte, num protowire.Number, s string) []byte {
	if s == "" {
		return b
	}
	b = protowire.AppendTag(b, num, protowire.BytesType)
	return protowire.AppendString(b, s)
}

type env struct {
	httpPort, httpsPort, grpcPort, grpcsPort, certDir, hostname string
}

func main() {
	e := env{
		httpPort:  getenv("HTTP_PORT", "8080"),
		httpsPort: getenv("HTTPS_PORT", "8443"),
		grpcPort:  getenv("GRPC_PORT", "9090"),
		grpcsPort: getenv("GRPCS_PORT", "9091"),
		certDir:   getenv("CERT_DIR", "/certs"),
		hostname:  getenv("HOSTNAME", "demo-upstream"),
	}

	errc := make(chan error, 4)

	// 明文 HTTP
	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/", page(e, "HTTP  :"+e.httpPort, false))
		srv := &http.Server{Addr: ":" + e.httpPort, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
		log.Printf("[upstream] http  listening :%s", e.httpPort)
		errc <- srv.ListenAndServe()
	}()

	// TLS HTTPS
	go func() {
		cert, err := tls.LoadX509KeyPair(e.certDir+"/upstream/server.chain.crt", e.certDir+"/upstream/server.key")
		if err != nil {
			errc <- fmt.Errorf("load upstream server cert: %w", err)
			return
		}
		mux := http.NewServeMux()
		mux.HandleFunc("/", page(e, "HTTPS :"+e.httpsPort, true))
		srv := &http.Server{
			Addr:              ":" + e.httpsPort,
			Handler:           mux,
			ReadHeaderTimeout: 10 * time.Second,
			TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}},
		}
		log.Printf("[upstream] https listening :%s", e.httpsPort)
		errc <- srv.ListenAndServeTLS("", "")
	}()

	// 明文 gRPC（demo.DemoService）
	go func() {
		lis, err := net.Listen("tcp", ":"+e.grpcPort)
		if err != nil {
			errc <- err
			return
		}
		s := grpc.NewServer(grpc.ForceServerCodec(demoCodec{}))
		registerEcho(s, "demo.DemoService", "gRPC  :"+e.grpcPort+" @"+e.hostname, nil)
		log.Printf("[upstream] grpc   listening :%s (demo.DemoService/Echo)", e.grpcPort)
		errc <- s.Serve(lis)
	}()

	// TLS gRPC（demo.SecureDemoService）
	go func() {
		cert, err := tls.LoadX509KeyPair(e.certDir+"/upstream/server.chain.crt", e.certDir+"/upstream/server.key")
		if err != nil {
			errc <- fmt.Errorf("load upstream server cert: %w", err)
			return
		}
		lis, err := net.Listen("tcp", ":"+e.grpcsPort)
		if err != nil {
			errc <- err
			return
		}
		s := grpc.NewServer(grpc.ForceServerCodec(demoCodec{}),
			grpc.Creds(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}})))
		registerEcho(s, "demo.SecureDemoService", "gRPCS :"+e.grpcsPort+" @"+e.hostname, nil)
		log.Printf("[upstream] grpcs  listening :%s (demo.SecureDemoService/Echo)", e.grpcsPort)
		errc <- s.Serve(lis)
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errc:
		log.Fatalf("[upstream] exit: %v", err)
	case <-stop:
		log.Printf("[upstream] shutting down")
	}
}

// registerEcho: 手写注册单一 Echo 一元方法（业务逻辑全在 MethodDesc.Handler）。
func registerEcho(s *grpc.Server, serviceName, label string, _ interface{}) {
	s.RegisterService(&grpc.ServiceDesc{
		ServiceName: serviceName,
		Methods: []grpc.MethodDesc{{
			MethodName: "Echo",
			Handler: func(srv interface{}, ctx context.Context, dec func(interface{}) error, _ grpc.UnaryServerInterceptor) (interface{}, error) {
				in := new(EchoRequest)
				if err := dec(in); err != nil {
					return nil, err
				}
				return &EchoResponse{Data: in.Data, Server: label, Timestamp: time.Now().UnixMilli()}, nil
			},
		}},
		Streams:  []grpc.StreamDesc{},
		Metadata: "demo.proto",
	}, nil) // impl nil：跳过 HandlerType 反射检查
}

// ---- HTTP 页面 ----

func page(e env, label string, secure bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/info" {
			info := map[string]any{
				"backend":    label,
				"proto":      r.Proto,
				"method":     r.Method,
				"host":       r.Host,
				"path":       r.URL.Path,
				"remoteAddr": r.RemoteAddr,
				"tls":        secure,
				"headers":    r.Header,
				"timestamp":  time.Now().UnixMilli(),
			}
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_ = json.NewEncoder(w).Encode(info)
			return
		}
		serveHomePage(w, r, e, label, secure)
	}
}

func serveHomePage(w http.ResponseWriter, r *http.Request, e env, label string, secure bool) {
	var sb strings.Builder
	sb.WriteString(`<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>sa-gateway 演示上游</title><style>
body{font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:40px}
.card{max-width:860px;margin:0 auto;background:#1e293b;border-radius:14px;padding:32px;box-shadow:0 10px 30px rgba(0,0,0,.4)}
h1{margin:0 0 6px;font-size:26px;color:#7dd3fc}.tag{display:inline-block;padding:4px 12px;border-radius:999px;font-size:13px;font-weight:600;margin-bottom:22px}
.http{background:#064e3b;color:#6ee7b7}.https{background:#3b0764;color:#c4b5fd}
table{width:100%;border-collapse:collapse;font-size:14px;margin-top:10px}
td,th{padding:8px 10px;border-bottom:1px solid #334155;text-align:left}
th{color:#94a3b8;font-weight:500;width:180px}
code{background:#0f172a;padding:2px 6px;border-radius:6px;color:#fbbf24;font-size:13px}
.foot{margin-top:24px;color:#64748b;font-size:12px}
</style></head><body><div class="card">
<h1>sa-gateway 演示上游</h1>`)
	cls := "http"
	if secure {
		cls = "https"
	}
	fmt.Fprintf(&sb, `<span class="tag %s" id="backend">%s</span>
<table>
<tr><th>命中路径</th><td><code>%s</code></td></tr>
<tr><th>客户端协议</th><td>%s</td></tr>
<tr><th>Host</th><td>%s</td></tr>
<tr><th>到达时间</th><td>%s</td></tr>
</table>
<p style="margin-top:22px">试试 <code>/info</code> 查看本次请求的完整头部（含网关注入的 <code>x-forwarded-*</code>）。</p>
<div class="foot">该页面由演示上游服务直接渲染：同一进程提供 HTTP :%s / HTTPS :%s / gRPC :%s / gRPCS :%s 四种回源形态。</div>
</div></body></html>`,
		cls,
		html.EscapeString(label),
		html.EscapeString(r.URL.Path),
		html.EscapeString(r.Proto),
		html.EscapeString(r.Host),
		time.Now().Format("2006-01-02 15:04:05.000"),
		e.httpPort, e.httpsPort, e.grpcPort, e.grpcsPort)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(sb.String()))
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
