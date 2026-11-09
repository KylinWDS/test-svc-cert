# Envoy 网关镜像：把导出器产物 bootstrap.docker.json 烧进镜像
# 前置：先运行配置导出器生成 demo/output/bootstrap.docker.json（见 README）
FROM envoyproxy/envoy:v1.37.1
COPY output/bootstrap.docker.json /etc/envoy/envoy.json
