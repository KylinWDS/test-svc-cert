// origin-test: 被防护微服务测试桩。
// 用于网关(WAF)透传联调:
//   - 校验并回显 Host 头(请求路由来源)
//   - 同时提供 HTTP / HTTPS(mTLS)监听
//   - 回源 TLS 与业务 HTTP 认证彼此独立配置
//   - 业务认证: Basic / Bearer / API key / JWT(HS256)/ 自定义 header
//   - /health /readyz 健康探测不走业务认证
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"strconv"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

type cfg struct {
	listenHTTP, listenHTTPS     string
	certFile, keyFile, clientCA string
	allowedHosts                string
	basicUser, basicPass        string
	bearerToken                 string
	apiKey, apiKeyHeader        string
	jwtSecret                   string
	customHeader, customValue   string
	ready                       bool // 就绪状态; false 时健康探测返回 503
}

func main() {
	var c cfg
	flag.StringVar(&c.listenHTTP, "listen-http", ":8080", "HTTP 监听地址, 空则不启动")
	flag.StringVar(&c.listenHTTPS, "listen-https", ":8443", "HTTPS 监听地址, 空则不启动")
	flag.StringVar(&c.certFile, "cert", "", "服务器证书 PEM (被防护服务证书, 由网关 trust CA 校验)")
	flag.StringVar(&c.keyFile, "key", "", "服务器私钥 PEM")
	flag.StringVar(&c.clientCA, "client-ca", "", "客户端CA PEM; 设置后要求 mTLS (校验网关客户端证书, 证明网关身份)")
	flag.StringVar(&c.allowedHosts, "allow-host", "", "允许的 Host, 逗号分隔; 空则不校验")
	flag.StringVar(&c.basicUser, "auth-basic-user", "", "Http Basic 认证: 用户名")
	flag.StringVar(&c.basicPass, "auth-basic-pass", "", "Http Basic 认证: 密码")
	flag.StringVar(&c.bearerToken, "auth-bearer-token", "", "Bearer Token 认证: 期望值")
	flag.StringVar(&c.apiKey, "auth-api-key", "", "API key 认证: 期望值")
	flag.StringVar(&c.apiKeyHeader, "auth-api-key-header", "X-Api-Key", "API key 认证: 请求头名")
	flag.StringVar(&c.jwtSecret, "auth-jwt-secret", "", "JWT 认证: HS256 校验密钥")
	flag.StringVar(&c.customHeader, "auth-custom-header", "", "自定义 header 认证: 请求头名")
	flag.StringVar(&c.customValue, "auth-custom-value", "", "自定义 header 认证: 期望值")
	flag.BoolVar(&c.ready, "ready", true, "就绪状态; false 时健康探测返回 503(验证网关摘除不健康上游)")
	flag.Parse()

	log.Printf("允许的 Host: %s", c.allowedHosts)
	log.Print(authSummary(c))
	if c.clientCA != "" {
		log.Printf("回源 TLS/mTLS: 已开启, 校验网关客户端证书(CA: %s)", c.clientCA)
	}

	h := originHandler(c)

	started := false
	if c.listenHTTPS != "" {
		if c.certFile == "" || c.keyFile == "" {
			log.Fatal("HTTPS 需要 -cert 和 -key")
		}
		tc, err := tlsConfig(c)
		if err != nil {
			log.Fatal(err)
		}
		srv := &http.Server{Addr: c.listenHTTPS, Handler: h, TLSConfig: tc}
		go func() {
			if c.clientCA != "" {
				log.Printf("HTTPS/mTLS listening on %s (要求网关客户端证书)", c.listenHTTPS)
			} else {
				log.Printf("HTTPS(TLS 单向) listening on %s", c.listenHTTPS)
			}
			log.Fatal(srv.ListenAndServeTLS(c.certFile, c.keyFile))
		}()
		started = true
	}
	if c.listenHTTP != "" {
		go func() {
			log.Printf("HTTP listening on %s", c.listenHTTP)
			log.Fatal(http.ListenAndServe(c.listenHTTP, h))
		}()
		started = true
	}
	if !started {
		log.Fatal("未启用任何监听")
	}
	select {}
}

// originHandler: 业务入口。校验 Host → 校验业务认证 → 回显联调状态。
func originHandler(c cfg) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 健康探测: 免 Host / 免业务认证; 未就绪时返回 503 供网关摘除上游
		if isHealthPath(r.URL.Path) {
			w.Header().Set("Content-Type", "text/plain")
			if !c.ready {
				http.Error(w, "not ready", http.StatusServiceUnavailable)
				return
			}
			fmt.Fprintln(w, "ok")
			return
		}

		if msg := checkHost(c.allowedHosts, r.Host); msg != "" {
			http.Error(w, msg, http.StatusBadRequest)
			return
		}

		passed, fail := checkAuth(c, r)
		if fail != "" {
			w.Header().Set("WWW-Authenticate", `Basic realm="origin"`)
			http.Error(w, fail, http.StatusUnauthorized)
			return
		}

		scheme, clientDN := "http", ""
		if r.TLS != nil {
			scheme = "https"
			if len(r.TLS.PeerCertificates) > 0 {
				clientDN = r.TLS.PeerCertificates[0].Subject.String()
			}
		}

		v := view{
			ProbeAt:    time.Now().Format("2006-01-02 15:04:05"),
			Method:     r.Method,
			Path:       r.URL.Path,
			Host:       r.Host, // 网关透传的 Host 头
			Scheme:     scheme,
			ClientIP:   r.RemoteAddr,
			ClientDN:   clientDN, // mTLS 客户端(网关)证书 Subject
			AuthPassed: passed,
			FwdFor:     r.Header.Get("X-Forwarded-For"),
			FwdProto:   r.Header.Get("X-Forwarded-Proto"),
			UA:         r.Header.Get("User-Agent"),
		}

		// —— 业务端点分发：认证通过后按路径返回真实内容（页面/JSON/文件，均可浏览器回显）——
		switch {
		case r.URL.Path == "/info":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(v)
			return
		case r.URL.Path == "/json":
			writeSampleJSON(w, v)
			return
		case strings.HasPrefix(r.URL.Path, "/echo/"):
			writeEcho(w, r, v, strings.TrimPrefix(r.URL.Path, "/echo/"))
			return
		case r.URL.Path == "/file":
			writeFileSample(w, v)
			return
		}

		// 浏览器访问 → 渲染联调状态页; 工具/脚本 → JSON
		if strings.Contains(r.Header.Get("Accept"), "text/html") {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			if err := pageTpl.Execute(w, v); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(v)
	})
}

// writeSampleJSON: 结构化业务样例数据（浏览器直接渲染，接口测试取真实值）。
func writeSampleJSON(w http.ResponseWriter, v view) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]any{
		"code":    0,
		"message": "ok",
		"backend": map[string]any{
			"host":  v.Host,
			"path":  v.Path,
			"auth":  v.AuthPassed,
			"mtls":  v.ClientDN != "",
			"tls":   v.Scheme == "https",
		},
		"data": []map[string]any{
			{"id": 1001, "name": "order-alpha", "amount": 128.50, "status": "PAID"},
			{"id": 1002, "name": "order-beta", "amount": 64.00, "status": "PENDING"},
			{"id": 1003, "name": "order-gamma", "amount": 512.75, "status": "SHIPPED"},
		},
		"total":       3,
		"probe_time":  v.ProbeAt,
		"fwd_for":     v.FwdFor,
		"fwd_proto":   v.FwdProto,
	})
}

// writeEcho: 路径参数 + query 全量回显（JSON），供接口测试断言透传正确性。
func writeEcho(w http.ResponseWriter, r *http.Request, v view, value string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]any{
		"echo":       value,
		"query":      r.URL.Query(),
		"method":     r.Method,
		"backend":    map[string]any{"host": v.Host, "auth": v.AuthPassed, "scheme": v.Scheme, "client_dn": v.ClientDN},
		"headers":    r.Header,
		"timestamp":  time.Now().UnixMilli(),
	})
}

// writeFileSample: 返回真实文件内容（CSV），浏览器触发下载、curl 可取正文。
func writeFileSample(w http.ResponseWriter, v view) {
	body := fmt.Sprintf(
		"id,name,amount,status,backend_host,auth_passed\r\n"+
			"1001,order-alpha,128.50,PAID,%s,%s\r\n"+
			"1002,order-beta,64.00,PENDING,%s,%s\r\n"+
			"1003,order-gamma,512.75,SHIPPED,%s,%s\r\n",
		v.Host, strings.Join(v.AuthPassed, "|"),
		v.Host, strings.Join(v.AuthPassed, "|"),
		v.Host, strings.Join(v.AuthPassed, "|"))
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="sample-orders.csv"`)
	w.Header().Set("X-Content-Length", strconv.Itoa(len(body)))
	fmt.Fprint(w, body)
}

// authSummary: 启动时打印实际启用的业务认证与后端校验规则, 便于回填网关配置。
func authSummary(c cfg) string {
	var s []string
	if c.basicUser != "" || c.basicPass != "" {
		s = append(s, "Basic(user="+c.basicUser+", pass="+c.basicPass+")")
	}
	if c.bearerToken != "" {
		s = append(s, "BearerToken(expect="+c.bearerToken+") -> 校验 Authorization: Bearer <token>")
	}
	if c.apiKey != "" {
		s = append(s, "APIKey(header="+c.apiKeyHeader+", value="+c.apiKey+")")
	}
	if c.jwtSecret != "" {
		s = append(s, "JWT(HS256, secret="+c.jwtSecret+", 校验签名+exp) -> Authorization: Bearer <jwt>")
	}
	if c.customHeader != "" {
		s = append(s, "CustomHeader("+c.customHeader+"="+c.customValue+")")
	}
	if len(s) == 0 {
		return "业务认证: 未启用(任何人可访问业务路径)"
	}
	return "业务认证: " + strings.Join(s, " | ")
}

// isHealthPath: 网关惯用探活 URI, 均免认证。
func isHealthPath(p string) bool {
	switch p {
	case "/health", "/healthz", "/readyz", "/livez":
		return true
	}
	return false
}

func checkHost(allowed, host string) string {
	if allowed == "" {
		return ""
	}
	host = stripPort(host) // Host 头可能带端口, 匹配主机名
	for _, a := range strings.Split(allowed, ",") {
		if strings.EqualFold(strings.TrimSpace(a), host) {
			return ""
		}
	}
	return fmt.Sprintf("host not allowed: %s (allowed: %s)", host, allowed)
}

func stripPort(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		return h
	}
	return host
}

func checkAuth(c cfg, r *http.Request) ([]string, string) {
	var passed []string
	if c.basicUser != "" || c.basicPass != "" {
		u, p, ok := r.BasicAuth()
		if !ok || u != c.basicUser || p != c.basicPass {
			return passed, "basic auth failed"
		}
		passed = append(passed, "basic")
	}
	if c.bearerToken != "" {
		if bearer(r) != c.bearerToken {
			return passed, "bearer auth failed"
		}
		passed = append(passed, "bearer")
	}
	if c.apiKey != "" {
		if r.Header.Get(c.apiKeyHeader) != c.apiKey {
			return passed, "api key (" + c.apiKeyHeader + ") failed"
		}
		passed = append(passed, "api-key")
	}
	if c.jwtSecret != "" {
		if err := verifyHS256JWT(bearer(r), c.jwtSecret); err != nil {
			return passed, "jwt failed: " + err.Error()
		}
		passed = append(passed, "jwt")
	}
	if c.customHeader != "" {
		if r.Header.Get(c.customHeader) != c.customValue {
			return passed, "custom header (" + c.customHeader + ") failed"
		}
		passed = append(passed, "custom-header")
	}
	return passed, ""
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "Bearer ") {
		return h[7:]
	}
	return h
}

// verifyHS256JWT: 仅 stdlib 实现的 HS256 JWT 校验(signature + exp)。
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

// view: 响应给调用方(JSON)和浏览器(HTML)的联调信息。
type view struct {
	ProbeAt    string   `json:"probe_time"`
	Method     string   `json:"method"`
	Path       string   `json:"path"`
	Host       string   `json:"host"`   // 网关透传的 Host 头
	Scheme     string   `json:"scheme"` // http | https
	ClientIP   string   `json:"client_ip"`
	ClientDN   string   `json:"client_dn,omitempty"` // mTLS 客户端证书 Subject; 空=未要求/未提供
	AuthPassed []string `json:"auth_passed"`         // 本次通过的业务认证: basic/bearer/api-key/jwt/custom-header
	FwdFor     string   `json:"x_forwarded_for,omitempty"`
	FwdProto   string   `json:"x_forwarded_proto,omitempty"`
	UA         string   `json:"user_agent,omitempty"`
}

var pageTpl = template.Must(template.New("page").Parse(htmlPage))

const htmlPage = `<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>origin-test 联调状态</title>
<style>
  body{font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:#f5f6f8;margin:0;padding:40px 16px;color:#1f2329}
  .card{max-width:720px;margin:0 auto;background:#fff;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08);overflow:hidden}
  .head{padding:20px 28px;color:#fff;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  .ok{background:#18a058}.badge{background:rgba(255,255,255,.22);padding:2px 10px;border-radius:999px;font-size:13px}
  .body{padding:26px 28px}
  h1{font-size:20px;margin:0}
  table{width:100%;border-collapse:collapse;margin-top:4px}
  th,td{text-align:left;padding:9px 6px;border-bottom:1px solid #eee;font-size:14px}
  th{color:#888;width:130px;font-weight:500}
  td{word-break:break-all}
  .tag{display:inline-block;background:#e8f3ff;color:#0b5cad;border:1px solid #bcd9ff;border-radius:6px;padding:2px 10px;margin:2px 4px 2px 0;font-size:13px}
  .hint{color:#888;font-size:13px;margin-top:18px}
  code{background:#f0f1f3;padding:1px 6px;border-radius:4px;font-size:13px}
</style></head><body>
<div class="card">
  <div class="head ok"><h1>联调成功 ✓</h1><span class="badge">{{.Scheme}}</span>
    {{if .ClientDN}}<span class="badge">mTLS ✓ 网关身份已认证</span>{{end}}
  </div>
  <div class="body">
    <table>
      <tr><th>探测时间</th><td>{{.ProbeAt}}</td></tr>
      <tr><th>网关透传 Host</th><td><code>{{.Host}}</code></td></tr>
      <tr><th>来源地址</th><td>{{.ClientIP}}</td></tr>
      <tr><th>请求</th><td>{{.Method}} {{.Path}}</td></tr>
      <tr><th>业务认证通过</th><td>
        {{range .AuthPassed}}<span class="tag">{{.}}</span>{{else}}<span class="hint">未启用</span>{{end}}
      </td></tr>
      <tr><th>X-Forwarded-For</th><td>{{if .FwdFor}}{{.FwdFor}}{{else}}-{{end}}</td></tr>
      <tr><th>X-Forwarded-Proto</th><td>{{if .FwdProto}}{{.FwdProto}}{{else}}-{{end}}</td></tr>
      <tr><th>客户端证书 Subject</th><td>{{if .ClientDN}}{{.ClientDN}}{{else}}未要求 / 未提供{{end}}</td></tr>
      <tr><th>User-Agent</th><td>{{if .UA}}{{.UA}}{{else}}-{{end}}</td></tr>
    </table>
    <div class="hint">业务接口（均需业务认证，返回真实值）：<code>/json</code> 结构化数据 · <code>/echo/&lt;任意值&gt;</code> 回显 · <code>/file</code> CSV 文件下载 · <code>/info</code> 请求头回显 · <code>/healthz</code> 免认证探活。</div>
    <div class="hint">连接已验证: 浏览器 → 网关(<code>Host={{.Host}}</code>) → 后端回源 <code>{{.Scheme}}</code>{{if .ClientDN}} + mTLS{{end}}。</div>
  </div>
</div></body></html>`

func tlsConfig(c cfg) (*tls.Config, error) {
	tc := &tls.Config{MinVersion: tls.VersionTLS12}
	if c.clientCA != "" {
		pemBytes, err := os.ReadFile(c.clientCA)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pemBytes) {
			return nil, errors.New("client-ca: 未解析到有效证书")
		}
		tc.ClientAuth = tls.RequireAndVerifyClientCert
		tc.ClientCAs = pool
	}
	return tc, nil
}
