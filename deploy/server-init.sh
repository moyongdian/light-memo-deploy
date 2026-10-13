#!/usr/bin/env bash
# 服务器一次性初始化：安装 Docker、准备部署目录、开放端口
# 支持 Ubuntu 22.04/24.04、Debian 12（root 用户执行）
#
#   curl -fsSL <raw 地址> | sudo bash
#   或者：sudo bash deploy/server-init.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/light-memo}"

echo "==> 1/4 安装 Docker（官方源）"
if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "Docker 已安装，跳过"
fi

echo "==> 2/4 启动 Docker 并设置开机自启"
systemctl enable --now docker
docker version --format 'Docker {{.Server.Version}} 就绪'

# 国内服务器拉 Docker Hub 经常超时，配一个镜像加速器（可设 REGISTRY_MIRROR="" 跳过）
if [ -n "${REGISTRY_MIRROR:-https://docker.m.daocloud.io}" ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<JSON
{
  "registry-mirrors": ["${REGISTRY_MIRROR}"]
}
JSON
  systemctl restart docker
  echo "已配置镜像加速器：$REGISTRY_MIRROR"
fi

echo "==> 3/4 准备部署目录 $APP_DIR"
mkdir -p "$APP_DIR/deploy/nginx"

echo "==> 4/4 防火墙放行 80/443（有 ufw 的话）"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp    comment 'SSH'      || true
  ufw allow 80/tcp    comment 'HTTP'     || true
  ufw allow 443/tcp   comment 'HTTPS'    || true
  echo "ufw 规则已添加（如未启用 ufw 请忽略）"
fi

cat <<TIP

✅ 初始化完成。

注意：云服务器还要去【控制台 → 安全组/防火墙】放行 80（和 443）端口，
这一步在云厂商控制台做，不是服务器里做 —— 新手最常卡在这里。

下一步：
  1. 把部署用的 SSH 公钥放进 ~/.ssh/authorized_keys
  2. 手动把 docker-compose.yml 和 deploy/nginx/ 放到 $APP_DIR
  3. cd $APP_DIR && docker compose up -d --build
TIP
