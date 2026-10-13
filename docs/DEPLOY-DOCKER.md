# 从零部署 light-memo：Docker + Nginx + GitHub Actions 实战教程

这份文档按"能跑通"的顺序写，每一步都告诉你**做什么、为什么、怎么验证**。
跟着做完，你会掌握一套真实项目在用的自动化部署链路。

---

## 0. 先搞明白整体架构

```
                         ┌──────────────────── 你的云服务器 ────────────────────┐
   浏览器                 │                                                     │
  ┌────────┐   80/443    │   ┌─────────────────────────────────────────────┐  │
  │ 用户    │ ──────────►│   │  Docker Compose 网络（内网）                  │  │
  └────────┘             │   │                                             │  │
                         │   │  ┌─────────────┐      ┌────────────────┐   │  │
                         │   │  │  memo-web   │      │    memo-api    │   │  │
                         │   │  │  (Nginx)    │─────►│    (Go 二进制)  │   │  │
                         │   │  │  静态 SPA    │ :8080│   SQLite 数据库 │   │  │
                         │   │  └─────────────┘      └───────┬────────┘   │  │
                         │   │        ▲                      │            │  │
                         │   └────────┼──────────────────────┼────────────┘  │
                         │            │                      ▼                │
                         │      /api/* 反代          memo-data 数据卷          │
                         │                          （容器删了数据还在）        │
                         └─────────────────────────────────────────────────────┘

   GitHub 仓库 ──push──► GitHub Actions ──构建镜像──► GHCR 镜像仓库
                                  │
                                  └──SSH──► 服务器 docker compose pull && up -d
```

三个角色要分清：

| 角色 | 干什么 | 为什么不直接在服务器上编译 |
|---|---|---|
| **GitHub Actions** | 拉代码 → 构建 Docker 镜像 → 推到 GHCR → SSH 通知服务器 | 服务器 CPU/内存小，编译前端容易 OOM |
| **GHCR**（GitHub 容器仓库） | 存镜像，带版本号 | 相当于"制品仓库"，可回滚 |
| **服务器** | 只负责 `docker compose pull` + 重启 | 部署动作越简单越不容易出错 |

---

## 1. 前置准备清单

**本地（你的电脑）**
- [ ] Git（已有）
- [ ] Docker Desktop（Windows/Mac）或 Docker Engine（Linux）
  → 验证：`docker version` 和 `docker compose version`

**服务器**
- [ ] Ubuntu 22.04 / 24.04 或 Debian 12（其他发行版也行，安装命令略不同）
- [ ] 内存 ≥ 1GB（CI 构建模式下 1GB 就够；若要在服务器上本地构建前端，建议 2GB）
- [ ] 有公网 IP，且**云厂商控制台的安全组**放行了 22 / 80 / 443
  ⚠️ 这一步在云厂商网页控制台做，不是在服务器里做。80 端口没放行 = 浏览器打不开，新手最常卡在这。
- [ ] 服务器 80 端口没有被已有的 nginx/apache 占用
  → 检查：`sudo ss -tlnp | grep ':80'`

**GitHub**
- [ ] 一个仓库（可以用原来的 `light-memo`，也可以新建）

---

## 1.5 两条部署路径，选一条走

| | 路径 A：CI/CD 自动（第 2~6 步） | 路径 B：本地直推服务器 |
|---|---|---|
| 流程 | push → Actions 构建 → GHCR → SSH 拉取 | 本地打包上传 → 服务器本地构建 → 启动 |
| 需要 | GitHub 仓库 + Secrets 配置 | 只要 SSH 能连上服务器 |
| 服务器压力 | 只 pull，1GB 内存够 | 要在服务器上编译前端，建议 ≥2GB 内存 |
| 适合 | 长期迭代、团队协作、正式环境 | 快速验证、机器配置低、GitHub 还没配好 |

路径 B 一行命令搞定（在本机执行）：

```bash
SITE_URL=http://1.2.3.4 bash deploy/deploy-from-local.sh root@1.2.3.4
```

它会：打包源码（排除 node_modules/.git）→ 上传到 `/srv/light-memo/src` → `docker compose up -d --build` → 轮询 `/healthz` → 初始化密码。

---

## 2. 第一步：代码整理入库

项目已经在工作区根目录，并已加入部署文件。现在初始化 Git：

```bash
cd D:/rj/light-memo
git init -b main
git add .
git commit -m "chore: 添加 Docker / Nginx / CI 部署配置"
```

在 GitHub 建好空仓库后（不要勾选 README/.gitignore），关联并推送：

```bash
git remote add origin git@github.com:<你的用户名>/light-memo.git
git push -u origin main
```

> 用 SSH 地址更省事。没配 SSH key 的话用 HTTPS 地址 + Personal Access Token。

**这一步结束你有了什么**：仓库里现在有 `backend/Dockerfile`、`frontend/Dockerfile`、`docker-compose.yml`、`deploy/nginx/`、`deploy/server-init.sh`、`.github/workflows/deploy.yml`。

---

## 3. 第二步：本地先把容器跑起来（强烈建议，别跳过）

在推给服务器之前，先在自己电脑上验证 Dockerfile 写得对不对 —— 本地改一行代码就能重来，服务器上排查要慢十倍。

```bash
# 复制环境变量模板，改成你的值（本地跑就填 http://localhost）
cp .env.example .env

# 构建并后台启动（第一次会慢，要下载基础镜像 + 装依赖）
docker compose up -d --build

# 看构建/启动过程
docker compose logs -f
```

初始化管理员密码（**只需要做一次**）：

```bash
docker compose run --rm api init
```

> 这个命令会交互提示你输入密码并确认。`compose run` 默认分配 TTY，所以能正常交互。
> 如果报 `password initialization requires an interactive terminal`，说明终端没分配 TTY（常见于某些 CI/管道环境）。

验证：

```bash
curl http://localhost/healthz          # 应返回 {"status":"ok"}
docker compose ps                      # 两个容器都应是 Up (healthy)
```

浏览器打开 `http://localhost` → 能看到登录页就成功了。

确认没问题后关掉本地环境，把端口留给服务器那套：

```bash
docker compose down
```

---

## 4. 第三步：服务器初始化

SSH 登录服务器，跑初始化脚本（或手动执行里面的命令）：

```bash
ssh root@<你的公网IP>

# 方式 A：脚本一条龙
bash deploy/server-init.sh

# 方式 B：只装 Docker（Ubuntu 官方源）
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

验证 Docker 装好了：

```bash
docker run --rm hello-world          # 能看到 "Hello from Docker!" 就 OK
docker compose version
```

然后把编排文件放到服务器（CI 以后会自动同步，第一次手动放一次）：

```bash
mkdir -p /srv/light-memo/deploy/nginx
# 在你本机执行（把文件传上去）：
scp docker-compose.yml root@<IP>:/srv/light-memo/
scp -r deploy/nginx/* root@<IP>:/srv/light-memo/deploy/nginx/
```

---

## 5. 第四步：配置 GitHub Actions 的密钥与变量

进仓库页面 → **Settings → Secrets and variables → Actions**，两处都要配。

### Variables（明文变量，New repository variable）

| 名字 | 示例值 | 说明 |
|---|---|---|
| `SITE_URL` | `http://1.2.3.4` | 站点对外地址，**不带 /api、不带结尾斜杠**。它会在构建前端镜像时写死进产物 |
| `DEPLOY_ENABLED` | `true` | 等于 `true` 才会真正部署到服务器。先不填，等服务器就绪再填 |

### Secrets（加密密钥，New repository secret）

| 名字 | 示例值 | 说明 |
|---|---|---|
| `SERVER_HOST` | `1.2.3.4` | 服务器公网 IP 或域名 |
| `SERVER_USER` | `root` | SSH 登录用户名 |
| `SERVER_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | **私钥全文**，含首尾行。建议专门为部署生成一对新 key |
| `SERVER_PORT` | `22` | SSH 端口（非默认时必填） |
| `SERVER_DIR` | `/srv/light-memo` | 服务器上的部署目录 |
| `GHCR_TOKEN` | `github_pat_xxx` | 可选。镜像仓库设成私有时才需要（PAT 勾 `read:packages`） |

生成部署专用 SSH key（在你本机执行）：

```bash
ssh-keygen -t ed25519 -C "deploy" -f ~/.ssh/light_memo_deploy
# 公钥放到服务器
ssh-copy-id -i ~/.ssh/light_memo_deploy.pub root@<IP>
# 私钥内容粘到 GitHub Secret SERVER_SSH_KEY
cat ~/.ssh/light_memo_deploy
```

**让镜像仓库可被服务器拉取**（选一个）：
- 简单：进仓库 → Packages → 你的镜像 → Package settings → 把可见性改成 **Public**（这样就不用配 `GHCR_TOKEN`）
- 严谨：保持 Private，创建只勾 `read:packages` 的 PAT 填进 `GHCR_TOKEN`

---

## 6. 第五步：触发第一次自动部署

```bash
# 随便改点东西并提交
git commit --allow-empty -m "chore: 触发首次部署"
git push
```

打开仓库 → **Actions** 标签，你会看到 `Build & Deploy (Docker)` 在跑：

1. `build` job：编译后端 → 推镜像 → 编译前端 → 推镜像（每个约 2-5 分钟，第二次起有缓存会快很多）
2. `deploy` job：`DEPLOY_ENABLED=true` 时才跑，SSH 到服务器拉镜像重启

部署完在服务器验证：

```bash
cd /srv/light-memo
docker compose ps                # 两个容器 Up
docker compose logs -f api       # 看后端日志
curl http://127.0.0.1/healthz    # {"status":"ok"}
```

浏览器打开 `http://<你的公网IP>` → 登录页出现 ✅

**第一次登录前，必须先初始化密码**（数据库是新的，还没密码）：

```bash
ssh -t root@<IP> 'cd /srv/light-memo && docker compose run --rm api init'
# -t 很重要：强制分配 TTY，否则交互式输入密码会失败
```

> ⚠️ **如果打开页面能登录但刷新就掉线，请看第 7 步**。这是本项目的一个硬约束。

---

## 7. 第六步（必看）：为什么一定要上 HTTPS

后端登录 Cookie 是这样设置的（`internal/session/session.go`）：

```go
Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode
```

`Secure: true` 意味着**浏览器只在 HTTPS 下才会保存这个 Cookie**。
所以纯 HTTP 访问时，登录接口返回 200，但浏览器把 Cookie 扔了 —— 表现就是"登录成功、一刷新回到登录页"。

两条路：

### 方案 A：没有域名？用 nip.io 白嫖一个

`nip.io` 是免费的泛解析 DNS：`1.2.3.4.nip.io` 会自动解析到 `1.2.3.4`。
有了"域名"就能申请 Let's Encrypt 正式证书，不用花钱买域名。

```bash
# 服务器上安装 certbot
sudo apt-get install -y certbot

# 临时停掉占用 80 端口的容器，让 certbot 用 standalone 模式签发
cd /srv/light-memo && docker compose stop web

sudo certbot certonly --standalone -d 1.2.3.4.nip.io \
  --agree-tos -m you@example.com

docker compose start web
```

证书在 `/etc/letsencrypt/live/1.2.3.4.nip.io/`。

### 方案 B：有自己的域名

把域名 A 记录解析到服务器 IP，同样用上面的 certbot 命令换成你的域名。

### 切换到 HTTPS

1. 用 `deploy/nginx/memo-tls.conf.example` 覆盖 `deploy/nginx/memo.conf`，把里面的 `example.com` 全换成你的域名
2. `docker-compose.yml` 里 web 服务加上 443 端口和证书挂载：

```yaml
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
```

3. 修改 `SITE_URL` 变量为 `https://你的域名`，提交推送 → CI 会用新地址重新构建前端（**必须**，因为 API 地址被编译进产物了）

证书续期（Let's Encrypt 90 天有效期）：

```bash
sudo certbot renew --pre-hook "cd /srv/light-memo && docker compose stop web" \
                   --post-hook "cd /srv/light-memo && docker compose start web"
# 加到 crontab，每月检查一次
echo "0 3 1 * * certbot renew --quiet --pre-hook '...' --post-hook '...'" | sudo crontab -
```

---

## 8. 日常运维

### 日常发布流程（以后就这一句）

```bash
git add . && git commit -m "feat: xxx" && git push
# 然后去 Actions 页面看进度，绿了就上线了
```

### 回滚到上一个版本

镜像同时打了 `latest` 和 `sha-<7位>` 两个标签，回滚就是把 `TAG` 指回去：

```bash
cd /srv/light-memo
TAG=<上次的7位sha> docker compose up -d
```

### 备份数据库（SQLite 在具名卷里）

```bash
# 推荐：停服务后整卷打包（保证一致性）
docker compose stop api
docker run --rm -v light-memo_memo-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/memo-$(date +%F).tar.gz -C /data .
docker compose start api
```

> 卷名是 `项目目录名_memo-data`，用 `docker volume ls` 确认。

### 常用排错命令

```bash
docker compose logs -f            # 全部日志
docker compose logs -f api        # 只看后端
docker compose ps                 # 状态 + 健康检查
docker compose exec web nginx -t  # 校验 Nginx 配置语法
docker compose exec web sh        # 进容器看文件
docker stats                      # 看 CPU/内存
docker system df                  # 磁盘占用

curl -i http://127.0.0.1/healthz         # 后端通不通
curl -i http://127.0.0.1/api/v1/auth/session   # 反代通不通
```

### 常见故障对照表

| 现象 | 原因 | 排查 |
|---|---|---|
| 浏览器打不开 | 云厂商安全组没开 80 | 控制台确认；服务器 `curl 127.0.0.1` 正常则就是外部防火墙问题 |
| 502 Bad Gateway | Nginx 连不上后端 | `docker compose logs api`；后端默认监听 127.0.0.1 会连不上，必须 `0.0.0.0` |
| `host not found in upstream "api"` | Nginx 启动时后端还没起来 / DNS 没配 | 已用 `resolver 127.0.0.11` + 变量方式规避；确认两者在同一 compose 网络 |
| 登录成功但刷新掉线 | HTTP 下 Secure Cookie 被丢弃 | 上 HTTPS（第 7 步） |
| 前端请求打到 localhost:8080 | `VITE_API_BASE_URL` 构建时没设对 | 改 `SITE_URL` 后**重新构建前端镜像**，不能只改运行时环境变量 |
| 403 Forbidden | CSRF 头缺失或 Content-Type 不对 | 后端要求 `X-Memo-CSRF: 1` + `application/json`，走同源反代一般不会触发 |
| 容器反复重启 | 数据库没初始化 | 先跑 `docker compose run --rm api init` |

---

## 9. 知识点复盘：这套东西到底学了什么

### Docker

- **多阶段构建**：编译环境（Go/Node 工具链）和运行时环境分离，最终镜像只有几十 MB
- **层缓存**：先 `COPY` 依赖清单再装依赖，改代码时不重复装依赖，构建从 3 分钟变 20 秒
- **具名卷 volume**：容器是无状态的，数据必须挂卷；删容器数据不丢
- **容器网络**：compose 里服务名就是主机名，`http://api:8080` 直接可达
- **非 root 运行**：`USER memo`，容器被攻破也拿不到 root
- **健康检查**：`healthcheck` + `depends_on: condition: service_healthy`，保证启动顺序
- **构建时 vs 运行时变量**：`ARG` 只在构建期有效；前端 `VITE_*` 被硬编码进产物，改值必须重新构建

### Nginx

- **反向代理**：`proxy_pass` 把 `/api/` 转给后端，前后端同源，规避跨域和 Cookie 问题
- **SPA 回退**：`try_files $uri $uri/ /index.html`，让前端路由接管 `/login` 这类路径
- **静态资源缓存策略**：带 hash 的 `/assets/` 一年强缓存，HTML 入口 `no-cache`
- **Docker DNS 陷阱**：`resolver 127.0.0.11` + 变量形式的 `proxy_pass`，后端换 IP 自动重新解析
- **`add_header` 继承陷阱**：子 location 里出现 `add_header` 会覆盖上层全部，所以要 `include` 公共片段
- **安全头**：CSP / nosniff / X-Frame-Options / Referrer-Policy

### CI/CD

- **构建与部署分离**：构建在 CI（资源充足、有缓存），部署只做 `pull` + `up -d`
- **制品仓库 GHCR**：每个 commit 一个 sha 标签，随时可回滚
- **Secrets vs Variables**：密钥走 Secrets 加密，普通配置走 Variables 明文
- **冒烟测试**：部署完自动 `curl /healthz`，不健康就让 workflow 变红

---

## 附：文件清单

| 文件 | 作用 |
|---|---|
| `backend/Dockerfile` | 后端多阶段构建镜像 |
| `frontend/Dockerfile` | 前端 pnpm 构建 + Nginx 托管 |
| `docker-compose.yml` | 编排两个服务 + 数据卷 |
| `deploy/nginx/memo.conf` | Nginx 站点配置（HTTP） |
| `deploy/nginx/memo-tls.conf.example` | Nginx 站点配置（HTTPS 示例） |
| `deploy/nginx/security-headers.conf` | 安全响应头片段 |
| `deploy/nginx/proxy-params.conf` | 反代通用参数 |
| `deploy/server-init.sh` | 服务器一键初始化 |
| `.github/workflows/deploy.yml` | CI/CD 流水线 |
| `deploy/deploy-from-local.sh` | 路径 B：不经 GitHub，本地直推服务器部署 |
| `.env.example` | 本地环境变量模板 |

---

## 附二：让别人（或 AI）代部署时，需要提供什么 + 怎么拿到

### 必给（缺一不可）

**1. 服务器公网 IP**
- 阿里云 / 腾讯云 / 华为云控制台 → 实例 / 云服务器列表 → 复制「公网 IP」
- 注意不是 `192.168.x.x`、不是 `10.x.x.x`，那都是内网地址

**2. SSH 登录权限**（二选一）

方式一（推荐，最省事）：把下面这把公钥加到服务器的授权列表里。
在服务器上执行一句：

```bash
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB9NS5ap9iexfOSnJ1pJ+ekV0wyL4irVpjTXoF7IKZ5u workbuddy-deploy' >> ~/.ssh/authorized_keys
```

方式二：给 root 密码（在云控制台「重置密码」里设），但密码会经过我这边，安全性差一些。

**3. SSH 端口**（默认 22，改过的话要说明）

**4. 安全组放行端口**
- 控制台 → 安全组 / 防火墙 → 入站规则 → 放行 TCP **22、80、443**
- 这一步不做，SSH 连不上、网站也打不开

### 可选

**5. 域名**（有就给，没有就用 IP；没有域名也能上 HTTPS，见第 7 步的 nip.io 方案）

**6. GitHub 仓库地址 + 有推送权限的 Token**（只有走路径 A 的 CI/CD 才需要）
- 地址形如 `https://github.com/<用户名>/light-memo.git`
- Token：GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → 勾选 `repo`、`write:packages`

### 给我时按这个格式贴过来就行

```
服务器IP：1.2.3.4
SSH用户：root
SSH端口：22
授权方式：已把公钥写进 authorized_keys / 密码：xxxx
域名：无（或 memo.example.com）
GitHub：https://github.com/xxx/light-memo.git   Token：ghp_xxx（可选）
```

### 拿到之后我会做（你也可以照着自查）

```bash
# 1. 连通性与环境探测
ssh root@1.2.3.4 'uname -a; nproc; free -m; df -h /; ss -tlnp | grep -E ":80|:22"'

# 2. 装 Docker（幂等，已装会跳过）
bash deploy/server-init.sh

# 3. 上传并构建启动
SITE_URL=http://1.2.3.4 bash deploy/deploy-from-local.sh root@1.2.3.4

# 4. 初始化密码（交互）
ssh -t root@1.2.3.4 'cd /srv/light-memo/src && docker compose -p light-memo run --rm api init'

# 5. 冒烟验证
curl -fsS http://1.2.3.4/healthz
curl -fsS -o /dev/null -w '%{http_code}\n' http://1.2.3.4/
```

### 常见获取失败排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `ssh: connect to host ... timed out` | 安全组没放行 22，或 IP 填错 | 控制台检查安全组；确认用的是公网 IP |
| `Permission denied (publickey)` | 公钥没写进服务器 | 重新执行上面那句 `echo ... >> ~/.ssh/authorized_keys`，注意别漏引号 |
| 能 SSH 但网页打不开 | 安全组没放行 80 | 控制台加 80 端口入站规则 |
| `docker: command not found` | Docker 没装 | 跑 `deploy/server-init.sh` |
