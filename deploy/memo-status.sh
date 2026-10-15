#!/bin/bash
# light-memo 服务器状态总览
# 用法：bash /tmp/memo-status.sh
echo "########## 容器状态 ##########"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "########## compose 项目 ##########"
docker compose ls -a

echo
echo "########## 端口监听（80/443/22/8090）##########"
ss -tlnp | grep -E ':(80|443|22|8090)\s' || echo "(无)"

echo
echo "########## 本地冒烟测试 ##########"
printf '  healthz : '; curl -kfsS https://127.0.0.1/healthz 2>&1 || echo "失败"
printf '  首页    : '; curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1/ 2>&1; echo
printf '  API     : '; curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1/api/v1/auth/session 2>&1; echo
printf '  HTTP跳转: '; curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' http://127.0.0.1/ 2>&1; echo

echo
echo "########## 磁盘 / 内存 ##########"
df -h / | tail -1
free -m | head -2

echo
echo "########## 镜像 ##########"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E 'memo|REPOSITORY'

echo
echo "########## 备份 ##########"
ls -lh /srv/backups/memo/ 2>/dev/null | tail -5 || echo "(无备份目录)"
