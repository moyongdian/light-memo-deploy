# light-memo 部署实战：Docker + Nginx + GitHub Actions

> 从一台裸机云服务器到全自动 CI/CD 的完整实操记录。
> 服务器：腾讯云 Ubuntu 22.04（2 核 2G，40G 盘）
> 公网 IP：`111.230.141.73`
> 时间跨度：2026-10-12 ～ 2026-10-15

---

## 目录

- [第一部分：成果总览](#第一部分成果总览)
- [第二部分：架构原理](#第二部分架构原理)
- [第三部分：完整操作步骤](#第三部分完整操作步骤)
- [第四部分：踩坑与排查手册](#第四部分踩坑与排查手册)
- [第五部分：日常运维](#第五部分日常运维)
- [第六部分：安全清单](#第六部分安全清单)

---

# 第一部分：成果总览

## 最终状态

| 项目 | 状态 |
|---|---|
| 网站 | https://111.230.141.73 （HTTPS 自签证书） |
| 容器 | `memo-web`（Nginx，占用 80/443）、`memo-api`（Go 后端，仅内网） |
| 数据 | Docker 卷 `light-memo_memo-data`（SQLite） |
| 镜像仓库 | `ghcr.io/moyongdian/light-memo-deploy/` |
| 自动部署 | push 到 `main` → 构建 → 推送 GHCR → SSH 部署 |
| 回滚 | 按 commit SHA 指定镜像标签，30 秒完成 |
| 备份 | 每天 04:00 自动备份到 `/srv/backups/memo/` |

## 验证命令（一条命令看全貌）

```bash
bash /tmp/memo-status.sh
```

---

# 第二部分：架构原理

## 2.1 整体链路

```
本地 git push
     │
     ▼
┌─────────────────────────────────────────┐
│  GitHub Actions (ubuntu-latest)          │
│  Job: build                              │
│    1. checkout                           │
│    2. docker buildx 构建两个镜像          │
│    3. 推送到 ghcr.io/<user>/<repo>/      │
│         memo-api:<sha>  和  :latest      │
│         memo-web:<sha>  和  :latest      │
└──────────────┬──────────────────────────┘
               │ Job: deploy（needs: build）
               ▼
┌─────────────────────────────────────────┐
│  appleboy/scp-action                     │
│    同步 docker-compose.yml + override    │
│    + nginx 配置 + 部署脚本                │
└──────────────┬──────────────────────────┘
               ▼
┌─────────────────────────────────────────┐
│  appleboy/ssh-action                     │
│    ssh → 服务器执行 deploy.sh             │
│      docker compose pull                 │
│      docker compose up -d                │
│      轮询健康检查（最多 60 秒）            │
└──────────────┬──────────────────────────┘
               ▼
        用户访问 https://111.230.141.73
```

## 2.2 为什么这样设计

| 设计 | 原因 |
|---|---|
| **镜像在 CI 构建** | 服务器只有 2G 内存，本地构建前端（Vite）容易 OOM |
| **推送到 GHCR** | GitHub 自带的镜像仓库，免费，私有仓库也可用 |
| **两个标签（sha + latest）** | sha 标签用于**精确回滚**，latest 用于日常部署 |
| **部署逻辑放服务器脚本** | 便于手动执行同样的流程，也便于在服务器上调试 |
| **overrid 文件分离** | 基础 compose 通用，override 承载服务器特有的 443/证书配置 |

## 2.3 关键文件职责

| 文件 | 职责 |
|---|---|
| `.github/workflows/deploy.yml` | CI/CD 主流程 |
| `docker-compose.yml` | 服务编排（基础版，可通用） |
| `deploy/docker-compose.override.yml` | 服务器特有配置（443 端口、证书挂载） |
| `deploy/nginx/` | Nginx 配置（HTTP 跳转 + HTTPS 服务） |
| `deploy/server-deploy.sh` | 服务器端部署脚本（CI 和手动共用） |
| `deploy/memo-status.sh` | 状态总览脚本 |

---

# 第三部分：完整操作步骤

## 阶段 0：准备工作

### 0.1 确认服务器信息

```bash
# 登录服务器
ssh root@111.230.141.73

# 系统版本
cat /etc/os-release | head -2
# Ubuntu 22.04.x LTS

# 资源
nproc && free -m | head -2 && df -h /
```

### 0.2 检查已占用端口

**这一步很重要** —— 我们的服务要用 80/443，必须先确认没被占用。

```bash
ss -tlnp | grep -E ':(80|443|8080|8090)\s'
```

**实测输出（2026-10-12）**：

```
LISTEN 0 4096 0.0.0.0:8090 0.0.0.0:*  users:(("1panel-core",pid=829,fd=12))
LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*  users:(("docker-proxy",pid=...))
```

**发现 1Panel 和 Zabbix 在运行**：

| 服务 | 端口 | 说明 |
|---|---|---|
| 1Panel | 8090 | 服务器管理面板 |
| Zabbix nginx | 8080 | 监控系统 |
| Zabbix server | 10051 | 监控数据 |
| MySQL | 3306 | 1Panel 装的数据库 |

**结论**：80/443 空闲，可以使用。但**必须小心不要动这些服务**。

---

## 阶段 1：安全拆除旧环境

> ⚠️ **本阶段会删除数据。执行前必须备份。**

### 1.1 先备份（不可跳过）

```bash
mkdir -p /srv/backups/memo
docker run --rm \
  -v light-memo_memo-data:/data:ro \
  -v /srv/backups/memo:/backup \
  alpine tar czf /backup/pre-wipe-$(date +%F-%H%M).tar.gz -C /data .
```

**验证备份非空**：

```bash
ls -lh /srv/backups/memo/
tar tzf /srv/backups/memo/pre-wipe-*.tar.gz | head
```

### 1.2 按顺序拆除

**顺序很重要**：容器 → 网络 → 卷 → 镜像 → 构建缓存。

```bash
# 停止并删除容器 + 网络
docker compose -p light-memo down

# 删除数据卷
docker volume rm light-memo_memo-data

# 删除镜像
docker rmi $(docker images --format '{{.ID}}' | grep -f <(docker images --format '{{.Repository}}:{{.Tag}}' | grep light-memo)) 2>/dev/null

# 清理构建缓存（回收空间最多的一步）
docker builder prune -af
```

### 1.3 验证拆除干净

```bash
docker ps -a | grep memo          # 应为空
docker volume ls | grep memo      # 应为空
docker images | grep memo         # 应为空
```

**实测回收**：约 1.3GB。

---

## 阶段 2：清理 git 历史中的密码

> ⚠️ **如果你从未把密码提交进 git，可跳过本阶段。**

### 2.1 问题背景

仓库里 `docs/SSH-LOGIN-XSHELL.md` 含明文服务器密码。发现它出现在 **12 处**历史提交中。

**关键教训**：`git rm --cached` **不能**清除历史。删除操作的 diff 里**同样包含密码**，反而让泄露点变多。

### 2.2 用 git-filter-repo 改写历史

```bash
# 安装
pip install git-filter-repo

# 备份原始仓库（重要！）
cp -r D:\rj\light-memo D:\rj\light-memo-backup

# 从所有历史中彻底删除该文件
git filter-repo --path docs/SSH-LOGIN-XSHELL.md --invert-paths --force
```

**验证**：

```bash
git log --all --oneline -- docs/SSH-LOGIN-XSHELL.md    # 应为空
git rev-list --all --objects | grep -i "SSH-LOGIN"     # 应为空
```

### 2.3 防复发

```bash
echo "docs/SSH-LOGIN-XSHELL.md" >> .gitignore
```

---

## 阶段 3：服务器环境准备

### 3.1 安装 Docker

```bash
# 检查是否已安装
docker --version
docker compose version
```

**如果已安装但普通用户无权限**：

```bash
sudo usermod -aG docker $USER
newgrp docker          # 或重新登录
```

> 💡 **不要用 `2>/dev/null` 掩盖错误**。教学过程中曾用 `docker --version 2>/dev/null || echo "未安装"`，结果把 `permission denied` 误报成"未安装"，浪费排查时间。

### 3.2 创建目录结构

```bash
mkdir -p /srv/light-memo/src
mkdir -p /srv/light-memo/certs
mkdir -p /srv/backups/memo
```

### 3.3 生成自签证书

```bash
cd /srv/light-memo/certs
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout server.key \
  -out server.crt \
  -subj "/C=CN/ST=Guangdong/L=Shenzhen/O=LightMemo/CN=111.230.141.73" \
  -addext "subjectAltName=IP:111.230.141.73"

chmod 600 server.key
```

**为什么用自签证书**：IP 地址无法申请免费证书（Let's Encrypt 不签 IP）。自签证书浏览器会警告，但加密有效。

---

## 阶段 4：编写部署配置

### 4.1 `docker-compose.yml`（基础编排）

```yaml
services:
  api:
    image: ${IMAGE_BASE}/memo-api:${TAG:-latest}
    container_name: memo-api
    restart: unless-stopped
    volumes:
      - memo-data:/data
    environment:
      MEMO_DATA_DIR: /data
    expose:
      - "8080"           # 仅容器网络内可见，不映射到宿主机
    healthcheck:
      test: ["CMD", "/app/memo", "healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    networks: [memo-net]

  web:
    image: ${IMAGE_BASE}/memo-web:${TAG:-latest}
    container_name: memo-web
    restart: unless-stopped
    ports:
      - "80:80"
    depends_on:
      api:
        condition: service_healthy
    networks: [memo-net]

volumes:
  memo-data:

networks:
  memo-net:
    driver: bridge
```

> **注意 `expose` vs `ports`**：`expose` 只在容器网络内暴露端口，不占用宿主机端口。这正是我们避开 8080 冲突（Zabbix 占用）的原因。

### 4.2 `deploy/docker-compose.override.yml`（服务器特有）

```yaml
services:
  web:
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./deploy/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /srv/light-memo/certs/server.crt:/etc/nginx/certs/server.crt:ro
      - /srv/light-memo/certs/server.key:/etc/nginx/certs/server.key:ro
```

**为什么分离**：基础 compose 文件可以通用（本地开发、其他服务器），override 承载当前服务器特有的路径和证书。

### 4.3 `deploy/nginx/nginx.conf`

```nginx
# 80 端口：全部跳转到 HTTPS
server {
    listen 80;
    server_name _;

    location / {
        return 301 https://$host$request_uri;
    }
}

# 443 端口：HTTPS 服务
server {
    listen 443 ssl;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /usr/share/nginx/html;
    index index.html;

    # 前端：SPA 路由回退
    location / {
        try_files $uri $uri/ /index.html;
    }

    # 后端 API 反向代理
    location /api/ {
        proxy_pass http://api:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 健康检查透传
    location /healthz {
        proxy_pass http://api:8080/healthz;
    }
}
```

> ⚠️ **`return 301` 的后果**：加了跳转后，任何用 `http://` 做的健康检查都会失败（curl 不加 `-L` 不跟随跳转）。这个坑在 CI 里真实踩到过。

---

## 阶段 5：首次手动部署

### 5.1 上传代码

**Windows 下注意**：不要用 `tar czf - ... | ssh ...` 管道。

```powershell
# ❌ 错误做法：PowerShell 管道传文本对象，会破坏二进制
tar czf - backend | ssh root@1.2.3.4 "tar xzf - -C /srv"

# ✅ 正确做法：分两步
tar czf source.tar.gz -C D:\rj\light-memo backend frontend docker-compose.yml deploy
scp source.tar.gz root@111.230.141.73:/tmp/
ssh root@111.230.141.73 "mkdir -p /srv/light-memo/src && tar xzf /tmp/source.tar.gz -C /srv/light-memo/src"
```

> **根因**：PowerShell 的 `|` 传递 .NET 对象，Linux 的 `|` 传递字节流。跨平台管道传二进制必然损坏，典型报错是 `gzip: stdin: not in gzip format`。

### 5.2 首次启动（本地构建模式）

服务器上已有源码时，可以先本地构建，不依赖镜像仓库：

```bash
cd /srv/light-memo/src
docker compose -p light-memo build
docker compose -p light-memo up -d
```

### 5.3 初始化数据

如果数据库为空，API 会生成随机初始密码。**必须及时获取**：

```bash
docker compose -p light-memo logs api | grep -i password
```

> 或者预先通过环境变量设置密码，避免依赖日志。

### 5.4 冒烟测试

```bash
curl -kfsS https://127.0.0.1/healthz          # {"status":"ok"}
curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1/          # 200
curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1/api/v1/auth/session   # 401（未登录，正常）
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://127.0.0.1/        # 301 -> https://...
```

**四个都符合预期才算成功**。

---

## 阶段 6：编写服务器端部署脚本

**文件**：`deploy/server-deploy.sh` → 部署到 `/srv/light-memo/deploy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail          # ← 生命线，缺一不可

SRC_DIR="${SRC_DIR:-/srv/light-memo/src}"
IMAGE_BASE="${IMAGE_BASE:?IMAGE_BASE 未设置}"
TAG="${TAG:-latest}"

echo "==> 开始部署"
echo "    目录: $SRC_DIR"
echo "    镜像: $IMAGE_BASE"
echo "    标签: $TAG"

cd "$SRC_DIR"

# 如果提供了 GHCR_TOKEN 就登录（公开镜像不需要）
if [ -n "${GHCR_TOKEN:-}" ]; then
  echo "==> 登录 GHCR"
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
fi

echo "==> 拉取镜像"
IMAGE_BASE="$IMAGE_BASE" TAG="$TAG" docker compose pull

echo "==> 启动服务"
IMAGE_BASE="$IMAGE_BASE" TAG="$TAG" docker compose up -d --remove-orphans

echo "==> 等待健康检查（最多 60 秒）"
for i in $(seq 1 30); do
  code=$(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1/healthz || true)
  if [ "$code" = "200" ]; then
    echo "==> 部署成功"
    docker compose ps
    exit 0
  fi
  sleep 2
done

echo "!! 健康检查超时，输出日志："
docker compose -p light-memo logs --tail=50 api
docker compose -p light-memo logs --tail=50 web
exit 1
```

### 三个关键点

**1. `set -euo pipefail`**

| 参数 | 作用 |
|---|---|
| `-e` | 任一命令失败立即退出 |
| `-u` | 使用未定义变量报错 |
| `-o pipefail` | 管道中任一环节失败即算失败 |

**没有这行会发生什么**：镜像拉取失败后脚本继续执行 `up -d`，用**旧镜像**重建容器 → 网站短暂中断 → **脚本还报告"成功"**。这比直接报错危险得多。

**2. `--remove-orphans`**

只清理**同一 compose 项目内**的孤儿容器。**不会影响其他项目**（实测：1Panel 的 mysql、zabbix 完全未受影响）。

**3. 健康检查用 `https`**

因为 80 端口只做 301 跳转。

---

## 阶段 7：配置 CI 专用 SSH 密钥

### 7.1 生成密钥

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\light_memo_ci" -N '""' -C "github-actions-deploy"
```

### 7.2 安装公钥到服务器

```bash
# 服务器上执行
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "ssh-ed25519 AAAA... github-actions-deploy" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

### 7.3 验证

```powershell
ssh -i "$env:USERPROFILE\.ssh\light_memo_ci" root@111.230.141.73 'echo OK'
```

### 7.4 安全原则

> **先建立替代通道，再撤销旧通道。**

顺序：
1. 生成新密钥
2. 验证新密钥可用
3. **才**撤销旧密钥
4. 最后处理密码

**永远不要"先断后接"** —— 那会把自己锁在门外。

---

## 阶段 8：编写 CI/CD 工作流

**文件**：`.github/workflows/deploy.yml`

```yaml
name: Build & Deploy (Docker)

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy-docker
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write          # 推 GHCR 必需
    outputs:
      image-base: ${{ steps.vars.outputs.image-base }}
      tag: ${{ steps.vars.outputs.tag }}
    steps:
      - uses: actions/checkout@v4

      - name: 计算镜像名和标签
        id: vars
        run: |
          # GHCR 要求全小写
          echo "image-base=ghcr.io/$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_OUTPUT"
          echo "tag=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - name: 登录 GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}     # 自动发放

      - name: 构建并推送 memo-api
        uses: docker/build-push-action@v6
        with:
          context: ./backend                        # ← 必须是 ./backend
          file: backend/Dockerfile
          push: true
          tags: |
            ${{ steps.vars.outputs.image-base }}/memo-api:latest
            ${{ steps.vars.outputs.image-base }}/memo-api:${{ steps.vars.outputs.tag }}
          cache-from: type=gha,scope=memo-api
          cache-to: type=gha,mode=max,scope=memo-api

      - name: 构建并推送 memo-web
        uses: docker/build-push-action@v6
        with:
          context: .
          file: frontend/Dockerfile
          push: true
          build-args: |
            VITE_API_BASE_URL=${{ vars.SITE_URL }}
          tags: |
            ${{ steps.vars.outputs.image-base }}/memo-web:latest
            ${{ steps.vars.outputs.image-base }}/memo-web:${{ steps.vars.outputs.tag }}
          cache-from: type=gha,scope=memo-web
          cache-to: type=gha,mode=max,scope=memo-web

  deploy:
    needs: build
    runs-on: ubuntu-latest
    if: ${{ vars.DEPLOY_ENABLED == 'true' }}    # 开关，方便只验证构建
    steps:
      - uses: actions/checkout@v4

      - name: 同步编排文件与 Nginx 配置
        uses: appleboy/scp-action@v0.1.7
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          port: ${{ secrets.SERVER_PORT }}
          source: "docker-compose.yml,deploy/nginx/,deploy/docker-compose.override.yml,deploy/server-deploy.sh"
          target: ${{ secrets.SERVER_DIR }}

      - name: 拉取新镜像并重启
        uses: appleboy/ssh-action@v1.0.3
        env:
          IMAGE_BASE: ${{ needs.build.outputs.image-base }}
          TAG: ${{ needs.build.outputs.tag }}
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          port: ${{ secrets.SERVER_PORT }}
          envs: IMAGE_BASE,TAG
          command_timeout: 10m
          script: |
            set -e
            export IMAGE_BASE TAG
            bash /srv/light-memo/deploy.sh
```

### 需要配置的 Secrets 和 Variables

**Secrets**（Settings → Secrets and variables → Actions → Secrets）：

| Name | 值 |
|---|---|
| `SERVER_HOST` | `111.230.141.73` |
| `SERVER_USER` | `root` |
| `SERVER_SSH_KEY` | 私钥全文（含 BEGIN/END 行） |
| `SERVER_PORT` | `22` |
| `SERVER_DIR` | `/srv/light-memo/src` |

**Variables**（同页面 Variables 标签）：

| Name | 值 | 说明 |
|---|---|---|
| `SITE_URL` | `https://111.230.141.73` | 不带结尾斜杠 |
| `DEPLOY_ENABLED` | `true` | 必须恰好是 `true` |

---

## 阶段 9：故障演练（部署前必做）

> **部署脚本最重要的品质不是"能成功"，而是"失败时不出事"。**

### 9.1 故意用不存在的镜像测试

```bash
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=test-notexist bash /srv/light-memo/deploy.sh
```

**预期输出**：

```
==> 拉取镜像
ERROR: ... denied
（脚本在此停止，不执行 up -d）
```

**关键验证**：

```bash
bash /tmp/memo-status.sh
```

**容器必须还是 `Up 44 hours`** —— 时间戳不变说明**从未被重启**。

### 9.2 这次演练暴露的真实价值

如果脚本没有 `set -e`，它会：
1. 拉取失败但继续执行
2. `up -d` 用**旧镜像**重建容器
3. **网站短暂中断**
4. **返回退出码 0，CI 显示绿色**

**这比直接报错危险得多** —— 你以为上线了，其实没有。

---

## 阶段 10：首次 CI/CD + 回滚演练

### 10.1 推送触发

```bash
git add . && git commit -m "..." && git push
```

### 10.2 观察 Actions

https://github.com/<user>/<repo>/actions

**预期**：21 个步骤全绿，耗时约 250 秒。

### 10.3 验证服务器真的更新了

```bash
bash /tmp/check-deployed-version.sh
```

**关键证据**：镜像标签是 **commit SHA**

```
ghcr.io/moyongdian/light-memo-deploy/memo-web:b0467fb     ← 与 git push 的 commit 一致
```

### 10.4 回滚演练

```bash
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=372feb8 bash /srv/light-memo/deploy.sh
```

**这就是回滚的全部** —— 把标签指回旧版本，30 秒完成。

**验证回滚成功**：

```bash
bash /tmp/check-deployed-version.sh
```

看两点：
1. 镜像标签变回了旧 SHA
2. **镜像 ID 变了**（证明真的换了镜像，不只是改了标签）

---

# 第四部分：踩坑与排查手册

## 4.1 CI/CD 相关的坑

### 坑 1：后端构建上下文错误

| | |
|---|---|
| **现象** | `failed to solve: ... /go.sum: not found` |
| **原因** | `context: .`（仓库根目录），但 `go.mod` 在 `backend/` |
| **修复** | `context: ./backend` |

**证据**：修复前的运行 #1 失败于「构建并推送 memo-api」，修复后的 #2 全绿。

### 坑 2：健康检查因 301 跳转失败

| | |
|---|---|
| **现象** | 冒烟测试失败，但网站实际正常 |
| **原因** | `curl -fsS http://127.0.0.1/healthz` —— 80 端口返回 301，`-f` 把 301 当成功但**返回体为空** |
| **修复** | 改用 `curl -kfsS https://127.0.0.1/healthz` |

### 坑 3：override 文件未同步导致 HTTPS 消失

| | |
|---|---|
| **现象** | CI 部署后 443 端口消失 |
| **原因** | `scp-action` 只传了 `docker-compose.yml`，没传 `docker-compose.override.yml` |
| **修复** | source 里加上 `deploy/docker-compose.override.yml` |

**这是最危险的一个** —— 短期可能不报错（旧文件还在），但一旦重新 clone 或清目录，**HTTPS 会悄悄消失**。

### 坑 4：使用了不存在的 Secret

| | |
|---|---|
| **现象** | GHCR 登录被跳过 |
| **原因** | `secrets.GHCR_TOKEN` 未配置，值为空字符串 |
| **修复** | 改用自动发放的 `secrets.GITHUB_TOKEN` |

### 坑 5：无关的 workflow 制造噪音

| | |
|---|---|
| **现象** | 每次 push 都有一条失败记录 |
| **原因** | `deploy-frontend.yml` 的 `on: push:` 无分支限制，且缺 `EDGEONE_API_TOKEN` |
| **修复** | 改为仅 `workflow_dispatch` |

## 4.2 网络与传输的坑

### 坑 6：PowerShell 管道破坏二进制

| | |
|---|---|
| **现象** | `gzip: stdin: not in gzip format` |
| **原因** | PowerShell `\|` 传 .NET 对象，Linux `\|` 传字节流 |
| **修复** | 分两步：先 `tar` 到文件，再 `scp` |

### 坑 7：Windows 换行符破坏 Shell 脚本

| | |
|---|---|
| **现象** | `bash: $'\r': command not found` |
| **原因** | 文件是 CRLF 换行 |
| **修复** | 上传后执行 `sed -i 's/\r$//' 脚本.sh` |

## 4.3 排查方法论

### 原则 1：不要用 `2>/dev/null` 掩盖错误

**真实教训**：

```bash
# ❌ 这样做
docker --version 2>/dev/null || echo "未安装"
# 输出：未安装     ← 误导！其实是 permission denied

# ✅ 应该这样
docker --version
# 输出：permission denied while trying to connect to the Docker daemon socket
```

**`2>/dev/null` 会把"权限错误"伪装成"未安装"**，导致排查方向完全错误。

### 原则 2：读原始数据，不要信中间层

**真实教训**：终端显示的中文乱码（GBK 编码问题）让人误判配置文件被写坏。

```powershell
# 用 Format-Hex 看真实字节
Format-Hex .gitignore | Select-Object -First 3
```

结果发现文件**完全正常**，是终端渲染问题，不是文件问题。

### 原则 3：用退出码而非输出判断成功

```bash
if some_command; then
  echo "成功"       # 基于退出码，可靠
fi

output=$(some_command)
if [[ "$output" == *"OK"* ]]; then   # 基于文本匹配，脆弱
```

### 原则 4：加 `-v` 看握手细节

```bash
ssh -v -i key root@host        # 逐行看认证过程
curl -v https://host/          # 看请求响应头
docker compose --dry-run up    # 看会做什么
```

---

# 第五部分：日常运维

## 5.1 常用命令

```bash
# 状态总览
bash /tmp/memo-status.sh

# 查看日志
cd /srv/light-memo/src
docker compose -p light-memo logs -f api
docker compose -p light-memo logs --tail=100 web

# 重启
docker compose -p light-memo restart

# 手动部署指定版本
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=<sha> bash /srv/light-memo/deploy.sh
```

## 5.2 回滚流程

```bash
# 1. 查看可用的历史版本
docker images | grep light-memo-deploy

# 2. 回滚到指定 commit
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=<7位sha> bash /srv/light-memo/deploy.sh

# 3. 验证
bash /tmp/check-deployed-version.sh
```

## 5.3 备份

**当前自动备份**（cron `0 4 * * *`）：

```bash
cat /usr/local/bin/memo-backup.sh
crontab -l | grep memo
```

**手动备份**：

```bash
docker run --rm \
  -v light-memo_memo-data:/data:ro \
  -v /srv/backups/memo:/backup \
  alpine tar czf /backup/manual-$(date +%F-%H%M).tar.gz -C /data .
```

**恢复**：

```bash
docker compose -p light-memo down
docker run --rm \
  -v light-memo_memo-data:/data \
  -v /srv/backups/memo:/backup \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/<备份文件> -C /data"
docker compose -p light-memo up -d
```

## 5.4 清理空间

```bash
docker system df              # 查看占用
docker image prune -a         # 删除未使用镜像（会删掉旧版本，回滚能力丢失！）
docker builder prune          # 清理构建缓存
```

> ⚠️ **`docker image prune -a` 会删除旧版本镜像，导致无法回滚**。建议保留最近 3～5 个版本，手动指定删除。

---

# 第六部分：安全清单

## 6.1 已完成的加固

| 项目 | 状态 |
|---|---|
| 密码从 git 历史清除 | ✅ 用 filter-repo 改写 |
| 使用独立 CI 密钥 | ✅ `github-actions-deploy` |
| 撤销临时密钥 | ✅ 删除 `workbuddy-deploy` |
| 更换服务器密码 | ✅ 2026-10-15 执行 |
| 敏感文档加 `.gitignore` | ✅ |
| HTTPS 加密传输 | ✅ 自签证书 |

## 6.2 密钥管理原则

### 当前服务器上的密钥

| 注释 | 用途 | 建议 |
|---|---|---|
| `root@VM-66-189-ubuntu` | 腾讯云控制台注入 | 保留（救援通道） |
| `xshell` | 本人登录 | 保留 |
| `github-actions-deploy` | CI 部署 | 保留 |

### 轮换密钥的正确顺序

```
1. 生成新密钥
2. 安装公钥到服务器
3. 验证新密钥可用        ← 关键，不能跳
4. 撤销旧密钥
5. 验证旧密钥确实失效
```

## 6.3 待办事项

| 项目 | 优先级 | 说明 |
|---|---|---|
| 关闭密码登录 | 中 | 确认密钥稳定后 `PasswordAuthentication no` |
| 定期轮换 CI 密钥 | 低 | 建议每 6～12 个月 |
| 考虑使用正式域名 + Let's Encrypt | 低 | 避免浏览器证书警告 |
| 备份异地存储 | 中 | 当前备份与数据在同一台机器 |

## 6.4 `.gitignore` 必备条目

```gitignore
# 密钥与证书
*.pem
*.key
deploy/keys/
deploy/certs/

# 环境变量
.env
.env.local

# 含敏感信息的文档
docs/SSH-LOGIN-XSHELL.md
```

---

# 附录 A：命令速查

## Docker

```bash
docker ps -a                                    # 所有容器
docker compose -p <项目> ps                      # 项目容器
docker compose -p <项目> logs -f <服务>          # 实时日志
docker compose -p <项目> down                    # 停止并删除
docker inspect <容器> --format '{{.Config.Image}}'  # 容器用的镜像
docker images --format '{{.Repository}}:{{.Tag}}'
docker volume ls | grep <项目>
docker exec -it <容器> sh                       # 进入容器
```

## 系统

```bash
ss -tlnp | grep -E ':(80|443)\s'    # 端口占用
df -h / && free -m | head -2        # 磁盘内存
systemctl status docker             # Docker 服务
journalctl -u docker --since "1 hour ago"
```

## Git

```bash
git filter-repo --path <文件> --invert-paths --force   # 从历史删除文件
git rev-list --all --objects | grep -i "<敏感词>"       # 检查历史残留
```

---

# 附录 B：本次部署实测数据

| 指标 | 数值 |
|---|---|
| CI 总耗时 | 247 秒 |
| 后端镜像大小 | 20.3 MB |
| 前端镜像大小 | 49.3 MB |
| 服务器资源 | 2 核 2G，40G 盘（用 12G / 30%） |
| 磁盘回收（清理构建缓存） | 约 1.3 GB |
| 回滚耗时 | 约 30 秒 |
| 健康检查等待上限 | 60 秒 |

## 镜像标签示例

```
ghcr.io/moyongdian/light-memo-deploy/memo-web:b0467fb    ← 当前版本
ghcr.io/moyongdian/light-memo-deploy/memo-web:372feb8    ← 可回滚版本
ghcr.io/moyongdian/light-memo-deploy/memo-web:latest
```

---

# 附录 C：教学过程中的关键教训

| # | 教训 | 场景 |
|---|---|---|
| 1 | `set -euo pipefail` 是脚本生命线 | 故障演练证明：镜像拉不到时立即停止，容器 44 小时未重启 |
| 2 | `git rm` 删不掉历史里的密钥 | 删除提交的 diff 里同样含密码，泄露点从 4 处变 12 处 |
| 3 | 不要用 `2>/dev/null` 掩盖错误 | 把 `permission denied` 误报成"未安装" |
| 4 | 读原始数据，不信中间层 | 终端 GBK 乱码让人误判文件损坏，`Format-Hex` 一看便知 |
| 5 | 跨平台管道不能传二进制 | PowerShell `\|` 传对象，导致 `not in gzip format` |
| 6 | 先建立替代通道，再撤销旧通道 | 凭据轮换的铁律，否则把自己锁在门外 |
| 7 | 部署脚本要演练失败路径 | "失败时不出事"比"能成功"更重要 |
| 8 | `expose` 不占宿主机端口 | 用它避开了与 Zabbix 的 8080 冲突 |
| 9 | 同一 commit 打两个镜像标签 | `sha` 用于精确回滚，`latest` 用于日常部署 |
| 10 | 改造前先确认无关服务不受影响 | 1Panel 的 mysql/zabbix 全程 `Up 38 hours` 未受干扰 |
