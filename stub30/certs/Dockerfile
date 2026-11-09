# 证书生成镜像：把 gen.sh 烧进镜像，避免宿主机 bind mount（Docker 文件共享限制）
FROM alpine/openssl:3.3.1
COPY gen.sh /usr/local/bin/gen.sh
ENTRYPOINT ["sh", "/usr/local/bin/gen.sh"]
