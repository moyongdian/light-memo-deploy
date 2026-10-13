#!/usr/bin/env bash
#
# 方案 B：不经 GitHub / GHCR，直接从本地把项目推到服务器构建并启动。
# 适合：还没有配好 GitHub Actions、或者想先在服务器上验证跑通。
#
# 用法（在本机 Git Bash / Linux / macOS 执行）：
#   SITE_URL=http://1.2.3.4 bash deploy/deploy-from-local.sh root@1.2.3.4
#   SITE_URL=https://memo.example.com bash deploy/deploy-from-local.sh root@1.2.3.4 22
#
# 可选环境变量：
#   SITE_URL      站点对外地址（构建前端时用，必填）
#   REMOTE_DIR    服务器部署目录，默认 /srv/light-memo
#   INIT_PASSWORD 若设置，则自动初始化管理员密码（否则交互输入）
#
set -euo pipefail

TARGET="${1:?用法: bash deploy/deploy-from-local.sh <user@host> [端口]}"
PORT="${2:-22}"
REMOTE_DIR="${REMOTE_DIR:-/srv/light-memo}"
SITE_URL="${SITE_URL:?请设置 SITE_URL，例如 http://1.2.3.4}"
SSH="ssh -p $PORT -o StrictHostKeyChecking=no"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 目标：$TARGET（目录 $REMOTE_DIR，站点 $SITE_URL）"

echo "==> 1/5 打包并上传源码（排除 node_modules / .git / 数据库）"
cd "$ROOT_DIR"
tar czf - \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='dist' \
  --exclude='*.db' \
  --exclude='*.db-shm' \
  --exclude='*.db-wal' \
  --exclude='.env' \
  . | $SSH "$TARGET" "mkdir -p $REMOTE_DIR/src && tar xzf - -C $REMOTE_DIR/src"

echo "==> 2/5 检查服务器 Docker 是否就绪"
$SSH "$TARGET" '
  if ! command -v docker >/dev/null 2>&1; then
    echo "服务器上没有 Docker，请先执行：bash '"$REMOTE_DIR"'/src/deploy/server-init.sh"
    exit 1
  fi
  docker version --format "Docker {{.Server.Version}} OK"
'

echo "==> 3/5 构建并启动容器（首次较慢，之后有缓存）"
$SSH "$TARGET" "cd $REMOTE_DIR/src && \
  docker compose -p light-memo up -d --build"

echo "==> 4/5 等待健康检查通过"
$SSH "$TARGET" '
  for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1/healthz >/dev/null 2>&1; then
      echo "healthz OK"; exit 0
    fi
    sleep 2
  done
  echo "健康检查超时，下面看日志："
  docker compose -p light-memo ps
  docker compose -p light-memo logs --tail 50
  exit 1
'

echo "==> 5/5 初始化管理员密码"
if [ -n "${INIT_PASSWORD:-}" ]; then
  # init 需要交互终端，用 -tt 强制分配 PTY，再把密码喂进去
  printf '%s\n%s\n' "$INIT_PASSWORD" "$INIT_PASSWORD" \
    | ssh -tt -p "$PORT" -o StrictHostKeyChecking=no \
      "$TARGET" "cd $REMOTE_DIR/src && docker compose -p light-memo run --rm api init"
else
  echo "请手动执行（需要交互输入密码）："
  echo "  ssh -t -p $PORT $TARGET 'cd $REMOTE_DIR/src && docker compose -p light-memo run --rm api init'"
fi

cat <<TIP

🎉 部署完成。

访问 $SITE_URL 验证。

常用命令（在服务器上）：
  cd $REMOTE_DIR/src
  docker compose -p light-memo logs -f        # 看日志
  docker compose -p light-memo ps             # 看状态
  docker compose -p light-memo down           # 停止
TIP
