#!/bin/bash
# 验证当前部署的前端版本
echo "=== 当前 memo-web 容器用的镜像 ==="
docker inspect memo-web --format '{{.Config.Image}}'
docker inspect memo-web --format '镜像 ID: {{.Image}}'

echo
echo "=== 前端产物里是否含新增文案（GitHub Actions）==="
docker exec memo-web sh -c 'grep -l "GitHub Actions" /usr/share/nginx/html/assets/*.js 2>/dev/null' && echo "找到新版本标识" || echo "未找到"

echo
echo "=== 编译进去的 API 地址 ==="
docker exec memo-web sh -c 'grep -rho "https://111.230.141.73" /usr/share/nginx/html/assets/*.js 2>/dev/null | sort -u | head -2'

echo
echo "=== 可回滚的镜像标签 ==="
docker images --format '{{.Repository}}:{{.Tag}}  ({{.CreatedSince}})' | grep light-memo-deploy
