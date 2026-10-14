#!/usr/bin/env bash
# light-memo 服务器端部署脚本
#
# 用途：由 GitHub Actions 通过 SSH 调用，也可手动执行。
# 设计原则：幂等（重复执行结果一致）、失败即停（set -e）、自带冒烟测试。
#
# 使用方式：
#   IMAGE_BASE=ghcr.io/用户名/仓库 TAG=abc1234 ./deploy.sh
#   不带参数时使用默认值（便于手动测试）

set -euo pipefail

DEPLOY_DIR=/srv/light-memo/src
cd "$DEPLOY_DIR"

# 镜像地址与标签：环境变量优先，否则用默认值
export IMAGE_BASE="${IMAGE_BASE:-ghcr.io/moyongdian/light-memo-deploy}"
export TAG="${TAG:-latest}"

echo "==> 开始部署"
echo "    目录: $DEPLOY_DIR"
echo "    镜像: $IMAGE_BASE"
echo "    标签: $TAG"

# 私有镜像仓库需要登录；公开仓库可跳过（GHCR_TOKEN 为空时不执行）
if [ -n "${GHCR_TOKEN:-}" ]; then
  echo "==> 登录 GHCR"
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:?GHCR_USER 未设置}" --password-stdin
fi

echo "==> 拉取镜像"
docker compose -p light-memo pull

echo "==> 重启服务"
docker compose -p light-memo up -d --remove-orphans

echo "==> 清理悬空镜像"
docker image prune -f >/dev/null

echo "==> 等待服务健康"
for i in $(seq 1 20); do
  if curl -kfsS https://127.0.0.1/healthz >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "!! 健康检查超时（60 秒），部署失败"
    docker compose -p light-memo ps
    docker compose -p light-memo logs api --tail 30
    exit 1
  fi
  sleep 3
done

echo "==> 冒烟测试"
docker compose -p light-memo ps
curl -kfsS https://127.0.0.1/healthz && echo " ==> healthz OK"
curl -k -s -o /dev/null -w "    首页 HTTP %{http_code}\n" https://127.0.0.1/
echo "==> 部署完成"
