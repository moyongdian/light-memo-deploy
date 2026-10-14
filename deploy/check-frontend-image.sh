#!/bin/bash
# 验证前端镜像产物中编译进去的 API 地址
IMG=ghcr.io/moyongdian/light-memo/memo-web:latest

echo "=== 产物文件列表 ==="
docker run --rm --entrypoint ls "$IMG" -la /usr/share/nginx/html/

echo
echo "=== 编译进去的 API 地址（https 应出现）==="
docker run --rm --entrypoint sh "$IMG" -c 'grep -rho "https://111.230.141.73" /usr/share/nginx/html/assets/ | sort -u | head -5'

echo
echo "=== 是否残留 localhost（预期：无输出）==="
docker run --rm --entrypoint sh "$IMG" -c 'grep -rl "localhost" /usr/share/nginx/html/assets/ 2>/dev/null | head -5; echo "[检查完毕]"'
