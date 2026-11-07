#!/usr/bin/env python3
"""生成一个 HS256 JWT, 用于测试 origin-test 服务的 -auth-jwt-secret."""
import base64, hashlib, hmac, json, sys, time

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def main() -> None:
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: gen-jwt.py <secret> [claims_json]")
    secret, claims = sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "{}"
    header = {"alg": "HS256", "typ": "JWT"}
    payload = json.loads(claims)
    payload.setdefault("exp", int(time.time()) + 3600)  # 默认1小时有效
    payload.setdefault("sub", "test-client")
    signing = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}"
    sig = hmac.new(secret.encode(), signing.encode(), hashlib.sha256).digest()
    print(signing + "." + b64(sig))

if __name__ == "__main__":
    main()