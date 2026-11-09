# 四合一演示上游：HTTP 页面/HTTPS/gRPC/gRPCS 单进程
# 无 protoc/codegen：gRPC 消息编解码为手写 protowire codec（字段号与 proto/demo.proto 一致）
# 依赖策略：不提交 vendor；模块经 goproxy.cn 下载并由 go.sum 锁定完整性，
# GOMODCACHE/GOCACHE 用 BuildKit 缓存挂载——首次构建需网络，之后命中缓存
FROM golang:1.23-alpine AS build
ENV GOPROXY=https://goproxy.cn,direct GOSUMDB=off GOFLAGS=-mod=mod
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /demo-upstream .

FROM alpine/openssl:3.3.1
RUN adduser -D -u 10001 demo
COPY --from=build /demo-upstream /demo-upstream
USER demo
EXPOSE 8080 8443 9090 9091
ENTRYPOINT ["/demo-upstream"]
