# grpcurl 客户端镜像：静态 grpcurl 二进制（官方 distroless 镜像提取）+ alpine 完整用户态
# 烧入 stub.proto + 15 个变体描述符；常驻模式供验证脚本 docker exec 复用
FROM fullstorydev/grpcurl:v1.9.1 AS bin
FROM alpine/openssl:3.3.1
COPY --from=bin /bin/grpcurl /usr/local/bin/grpcurl
COPY stub/protos/ /protos/
COPY upstream/proto/demo.proto /protos/demo.proto
ENTRYPOINT ["sleep", "3600"]
