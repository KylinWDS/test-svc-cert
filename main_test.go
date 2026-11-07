package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

// 自包含集成冒烟: 在内存里生成 CA + 被防护服务证书 + 网关客户端证书,不依赖 openssl。
func genTestCerts(t *testing.T) (pool *x509.CertPool, serverTLSCert tls.Certificate, gatewayCert tls.Certificate) {
	t.Helper()
	now := time.Now()
	newTpl := func(sn int64, cn string, ext []x509.ExtKeyUsage, dns []string, ip []net.IP) *x509.Certificate {
		return &x509.Certificate{
			SerialNumber:          big.NewInt(sn),
			Subject:               pkix.Name{CommonName: cn},
			NotBefore:             now.Add(-time.Hour),
			NotAfter:              now.Add(24 * time.Hour),
			KeyUsage:              x509.KeyUsageDigitalSignature,
			ExtKeyUsage:           ext,
			DNSNames:              dns,
			IPAddresses:           ip,
			BasicConstraintsValid: true,
		}
	}

	caPub, caKey, _ := ed25519.GenerateKey(rand.Reader)
	caTpl := newTpl(1, "Test WAF Root CA", nil, nil, nil)
	caTpl.IsCA, caTpl.KeyUsage = true, x509.KeyUsageCertSign|x509.KeyUsageDigitalSignature
	caDER, err := x509.CreateCertificate(rand.Reader, caTpl, caTpl, caPub, caKey)
	if err != nil {
		t.Fatalf("ca: %v", err)
	}
	caCert, _ := x509.ParseCertificate(caDER)
	pool = x509.NewCertPool()
	pool.AddCert(caCert)

	serverPub, serverKey, _ := ed25519.GenerateKey(rand.Reader)
	serverDER, err := x509.CreateCertificate(rand.Reader,
		newTpl(2, "svc.example.com", []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			[]string{"localhost", "svc.example.com"}, []net.IP{net.ParseIP("127.0.0.1")}),
		caCert, serverPub, caKey)
	if err != nil {
		t.Fatalf("server: %v", err)
	}
	serverTLSCert = tls.Certificate{Certificate: [][]byte{serverDER}, PrivateKey: serverKey}

	clientPub, clientKey, _ := ed25519.GenerateKey(rand.Reader)
	clientDER, err := x509.CreateCertificate(rand.Reader,
		newTpl(3, "gateway-client", []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, nil, nil),
		caCert, clientPub, caKey)
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	gatewayCert = tls.Certificate{Certificate: [][]byte{clientDER}, PrivateKey: clientKey}
	return pool, serverTLSCert, gatewayCert
}

// basicCfg: 主链路用 Http Basic(单认证, 贴近真实网关), 业务认证与 mTLS 独立。
func basicCfg() cfg {
	return cfg{allowedHosts: "svc.example.com", ready: true, basicUser: "svcuser", basicPass: "svcpass"}
}

func mkJWT(secret string, exp int64) string {
	b64 := func(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
	hdr := b64([]byte(`{"alg":"HS256","typ":"JWT"}`))
	if exp == 0 {
		exp = time.Now().Add(3600).Unix()
	}
	claims := b64([]byte(`{"sub":"t","exp":` + strconv.FormatInt(exp, 10) + `}`))
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(hdr + "." + claims))
	return hdr + "." + claims + "." + b64(mac.Sum(nil))
}

// 每种认证单独验证: cfg 只开一种认证, 请求只带对应凭据。
func TestEachAuthMethod(t *testing.T) {
	cases := []struct {
		name        string
		cfg         cfg
		authed, bad func(r *http.Request)
	}{
		{"basic", cfg{basicUser: "u", basicPass: "p"},
			func(r *http.Request) { r.SetBasicAuth("u", "p") },
			func(r *http.Request) { r.SetBasicAuth("u", "wrong") }},
		{"bearer", cfg{bearerToken: "tok"},
			func(r *http.Request) { r.Header.Set("Authorization", "Bearer tok") },
			func(r *http.Request) { r.Header.Set("Authorization", "Bearer nope") }},
		{"api-key", cfg{apiKey: "k", apiKeyHeader: "X-Api-Key"},
			func(r *http.Request) { r.Header.Set("X-Api-Key", "k") },
			func(r *http.Request) { r.Header.Set("X-Api-Key", "bad") }},
		{"jwt", cfg{jwtSecret: "s"},
			func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+mkJWT("s", 0)) },
			func(r *http.Request) {
				r.Header.Set("Authorization", "Bearer "+mkJWT("s", time.Now().Add(-10*time.Second).Unix()))
			}},
		{"custom-header", cfg{customHeader: "X-Edge-Auth", customValue: "edge1"},
			func(r *http.Request) { r.Header.Set("X-Edge-Auth", "edge1") },
			func(r *http.Request) { r.Header.Set("X-Edge-Auth", "edge2") }},
	}
	for _, tc := range cases {
		// 通过
		r := httptest.NewRequest("GET", "/x", nil)
		r.Host = "svc.example.com"
		tc.authed(r)
		if _, fail := checkAuth(tc.cfg, r); fail != "" {
			t.Errorf("%s: 合法凭据被拒: %s", tc.name, fail)
		}
		// 拒绝
		r2 := httptest.NewRequest("GET", "/x", nil)
		r2.Host = "svc.example.com"
		tc.bad(r2)
		if _, fail := checkAuth(tc.cfg, r2); fail == "" {
			t.Errorf("%s: 非法凭据应被拒", tc.name)
		}
	}
}

func TestHostCheck(t *testing.T) {
	c := basicCfg() // allowedHosts: svc.example.com
	if m := checkHost(c.allowedHosts, "svc.example.com"); m != "" {
		t.Error("bare host should pass: ", m)
	}
	if m := checkHost(c.allowedHosts, "svc.example.com:8443"); m != "" {
		t.Error("host with port should pass: ", m)
	}
	if m := checkHost(c.allowedHosts, "evil.com"); m == "" {
		t.Error("wrong host should fail")
	}
}

func TestReadiness(t *testing.T) {
	probe := func(ready bool, path string) int {
		c := cfg{ready: ready}
		s := httptest.NewServer(originHandler(c))
		defer s.Close()
		resp, err := s.Client().Get(s.URL + path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	// 就绪: 各探活 URI 均 200
	for _, p := range []string{"/health", "/healthz", "/readyz", "/livez"} {
		if c := probe(true, p); c != 200 {
			t.Errorf("ready %s: got %d, want 200", p, c)
		}
	}
	// 未就绪: 返回 503
	if c := probe(false, "/readyz"); c != 503 {
		t.Errorf("not-ready /readyz: got %d, want 503", c)
	}
}

func TestSmoke(t *testing.T) {
	pool, serverTLSCert, gatewayCert := genTestCerts(t)
	c := basicCfg()

	mux := originHandler(c) // 用生产 handler, 含 HTML 状态页

	httpSrv := httptest.NewServer(mux)
	defer httpSrv.Close()

	mtlsSrv := httptest.NewUnstartedServer(mux)
	mtlsSrv.TLS = &tls.Config{
		MinVersion:   tls.VersionTLS12,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
		Certificates: []tls.Certificate{serverTLSCert},
	}
	mtlsSrv.StartTLS()
	defer mtlsSrv.Close()

	// 网关侧客户端: 信任 CA(pool) + 出示网关证书 → 后端证明"这是网关"
	gtwClient := mtlsSrv.Client()
	tr := gtwClient.Transport.(*http.Transport)
	tr.TLSClientConfig.RootCAs = pool
	tr.TLSClientConfig.Certificates = []tls.Certificate{gatewayCert}

	do := func(cl *http.Client, url, host string, authed bool) int {
		req, _ := http.NewRequest("GET", url, nil)
		req.Host = host
		if authed {
			req.SetBasicAuth(c.basicUser, c.basicPass)
		}
		resp, err := cl.Do(req)
		if err != nil {
			t.Fatalf("%s %s: %v", url, host, err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	// 1. 健康探测, 无业务凭据 → 200 (健康探测不继承业务凭据)
	if code := do(httpSrv.Client(), httpSrv.URL+"/health", "svc.example.com", false); code != 200 {
		t.Errorf("health: got %d, want 200", code)
	}
	// 2. Host 不匹配 → 400 (缺 Host 头路由校验)
	if code := do(httpSrv.Client(), httpSrv.URL+"/x", "evil.com", true); code != 400 {
		t.Errorf("wrong host: got %d, want 400", code)
	}
	// 3. 缺业务认证 → 401
	if code := do(httpSrv.Client(), httpSrv.URL+"/x", "svc.example.com", false); code != 401 {
		t.Errorf("missing auth: got %d, want 401", code)
	}
	// 4. HTTP + Basic → 200
	if code := do(httpSrv.Client(), httpSrv.URL+"/x", "svc.example.com", true); code != 200 {
		t.Errorf("http basic: got %d, want 200", code)
	}
	// 5. HTTPS 未出示网关证书 → 握手失败 (未证明网关身份)
	noCert := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		RootCAs: pool, MinVersion: tls.VersionTLS12}}}
	if _, err := noCert.Get(mtlsSrv.URL + "/x"); err == nil {
		t.Error("mTLS without client cert should fail")
	}
	// 6. HTTPS + mTLS(出示网关证书) + Basic → 200 (身份+业务, 两链独立)
	if code := do(gtwClient, mtlsSrv.URL+"/x", "svc.example.com", true); code != 200 {
		t.Errorf("mTLS basic: got %d, want 200", code)
	}
	// 7. 浏览器 Accept:text/html → 渲染联调状态页
	req, _ := http.NewRequest("GET", httpSrv.URL+"/x", nil)
	req.Host = "svc.example.com"
	req.SetBasicAuth(c.basicUser, c.basicPass)
	req.Header.Set("Accept", "text/html")
	hr, err := httpSrv.Client().Do(req)
	if err != nil {
		t.Fatalf("html req: %v", err)
	}
	body, _ := io.ReadAll(hr.Body)
	hr.Body.Close()
	if hr.StatusCode != 200 || !bytes.Contains(body, []byte("联调成功")) {
		t.Errorf("html page: status=%d, missing 联调成功", hr.StatusCode)
	}
}
