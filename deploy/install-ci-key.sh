#!/bin/bash
# 把 GitHub Actions 部署公钥装入服务器的 authorized_keys
# 使用 command= 限制：这把密钥只能执行部署脚本，不能开 shell（最小权限原则）
set -euo pipefail

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGIeG/FlDiCX08AYS5C2YE49v5+s13jBSrhBFc8CUtA github-actions-deploy"

SSH_DIR=/root/.ssh
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# 幂等：先移除旧的同名条目，再加新的
sed -i '/github-actions-deploy/d' "$AUTH_KEYS"
echo "$PUBKEY" >> "$AUTH_KEYS"

echo "=== 当前 authorized_keys 条目 ==="
awk '{print NR": "$1" ... "$NF}' "$AUTH_KEYS"
echo
echo "=== 权限检查（必须 700 / 600）==="
ls -ld "$SSH_DIR"
ls -l "$AUTH_KEYS"
