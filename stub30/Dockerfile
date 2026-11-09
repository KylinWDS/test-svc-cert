# 30 端口测试桩镜像：origin（HTTP 家族 15 实例）+ stubgrpc（gRPC 家族 15 listeners）
# 无 protoc/codegen：gRPC 消息编解码为手写 protowire codec（字段号与 protos/stub.proto 一致）
# 依赖策略：不提交 vendor；模块经 goproxy.cn 下载并由 go.sum 锁定完整性，
# GOMODCACHE/GOCACHE 用 BuildKit 缓存挂载——首次构建需网络，之后命中缓存
FROM golang:1.23-alpine AS build
ENV GOPROXY=https://goproxy.cn,direct GOSUMDB=off GOFLAGS=-mod=mod
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd ./cmd
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /usr/local/bin/origin ./cmd/origin \
 && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /usr/local/bin/stubgrpc ./cmd/stubgrpc

FROM alpine/openssl:3.3.1
RUN adduser -D -u 10001 demo
COPY --from=build /usr/local/bin/origin /usr/local/bin/stubgrpc /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
EXPOSE 40051-40080
ENTRYPOINT ["sh", "/entrypoint.sh"]
