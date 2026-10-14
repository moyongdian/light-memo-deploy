#!/bin/bash
# 验证 override 合并结果：web 服务应有 80 + 443 两个端口，以及证书和配置挂载
cd /srv/light-memo/src || exit 1

echo "=== web 服务的 ports / volumes / depends_on ==="
docker compose -p light-memo config | awk '/^  web:/{f=1} f' | grep -E "ports:|volumes:|published|target:|source:|/srv/|/etc/nginx|condition" | head -30

echo
echo "=== 关键判定 ==="
PORTS=$(docker compose -p light-memo config | awk '/^  web:/{f=1} f' | grep -c "published")
echo "web 端口映射数量: $PORTS  (期望 2 = 80 与 443)"
