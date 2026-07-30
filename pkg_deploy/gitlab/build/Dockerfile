# GitLab CE Dockerfile — 基于官方镜像定制（适用于离线/内网场景）
# 官方镜像已包含所有依赖，此 Dockerfile 仅做定制化

ARG GITLAB_VERSION=19.3.0-pre
FROM gitlab/gitlab-ce:${GITLAB_VERSION}

# 可选：预装额外工具
# RUN apt-get update && apt-get install -y vim curl net-tools && rm -rf /var/lib/apt/lists/*

EXPOSE 80 443 22
