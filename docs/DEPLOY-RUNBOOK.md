# light-memo 上线实操记录（已真实执行）

这份文档记录 **2026-10-12 把 light-memo 部署到 111.230.141.73 的全过程**，
每一条命令都实际执行过，输出是真实的。你可以照着复现，也可以当排查手册用。

## 0. 最终状态

| 项目 | 值 |
|---|---|
| 访问地址 | **https://111.230.141.73** |
| 服务器 | 腾讯云 · Ubuntu 22.04.4 LTS · x86_64 · 2 核 2GB · 40G 磁盘 |
| Docker | 27.0.3 + Compose v2.28.1（已开机自启） |
| 容器 | `memo-api`（Go，healthy）、`memo-web`（Nginx，80+443） |
| 数据库 | SQLite，位于具名卷 `light-memo_memo-data` |
| 部署目录 | `/srv/light-memo/src` |
| 证书 | 自签证书 `/srv/light-memo/certs`（有效期 365 天） |
| 初始密码 | `Memo@7xKq2Lp9` ← **请登录后立即修改** |
| 自动备份 | 每天 04:00，存 `/srv/backups/memo`，保留 7 份 |

---

## 1. 环境探测

```bash
ssh -i ~/.ssh/light_memo_deploy root@111.230.141.73 \
  'cat /etc/os-release | grep -E "^(NAME|VERSION)"; nproc; free -m | head -2;
   df -h / | tail -1; ss -tlnp | grep -E ":80 |:443 |:22 "; docker version --format "{{.Server.Version}}"'
```

实际输出：

```
NAME="Ubuntu"          VERSION="22.04.4 LTS (Jammy Jellyfish)"
2                                     # CPU 核数
Mem:  1963  total   347 used   1454 available
/dev/vda2   40G  5.9G  32G  16% /
LISTEN  0.0.0.0:22  sshd              # 只有 22 在监听，80/443 空闲
27.0.3                                # Docker 版本
```

**为什么要先看**：`ss -tlnp` 确认 80/443 没被占用，否则后面容器起不来；
`free -m` 决定能不能在服务器上编译前端（本项目前端构建峰值约 1GB，2GB 内存刚好够）。

---

## 2. 加 swap（内存只有 2G，保险）

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
swapon --show
```

输出：

```
NAME      TYPE SIZE USED PRIO
/swapfile file   2G   0B   -2
```

顺手验证镜像能不能拉下来（腾讯云机器已自带内网镜像源 `mirror.ccs.tencentyun.com`）：

```bash
docker pull alpine:3.22
```

输出末尾：`Status: Downloaded newer image for alpine:3.22` ✅

---

## 3. 上传源码（tar 走 ssh，不需要 rsync）

```bash
cd D:/rj/light-memo
tar czf - \
  --exclude='.git' --exclude='node_modules' --exclude='dist' \
  --exclude='*.db' --exclude='*.db-shm' --exclude='*.db-wal' --exclude='.env' \
  . | ssh -i ~/.ssh/light_memo_deploy root@111.230.141.73 \
      "mkdir -p /srv/light-memo/src && tar xzf - -C /srv/light-memo/src"
```

输出：`上传完成 / backend deploy docker-compose.yml docs frontend README.md / 756K`

> 排除 `.git`、`node_modules`、`dist` 是关键：不排除的话要传几十 MB，且会把本地
> 编译产物带上去。数据卷里的 db 文件更不能覆盖。

---

## 4. 构建后端镜像（第一次失败 + 修复）

```bash
ssh root@111.230.141.73 'cd /srv/light-memo/src && docker compose -p light-memo build api'
```

### ❌ 失败 1：`"/go.sum": not found`

```
#10 [api builder 3/6] COPY go.mod go.sum ./
#10 ERROR: failed to calculate checksum ... "/go.sum": not found
```

**原因**：`docker-compose.yml` 里 api 的构建上下文写成了仓库根目录 `.`，
而 `backend/Dockerfile` 里是 `COPY go.mod go.sum ./` —— 在根目录当然找不到。

**修复**：把 api 的构建上下文改成 `./backend`（上下文越小构建也越快）：

```yaml
  api:
    build:
      context: ./backend      # ← 原来是 .
      dockerfile: Dockerfile
```

### ❌ 失败 2：`proxy.golang.org` 超时

```
#11 210.3 go: github.com/dustin/go-humanize@v1.0.1:
     Get "https://proxy.golang.org/...": dial tcp 142.251.33.209:443: i/o timeout
```

**原因**：国内服务器访问 Go 官方模块代理被墙，卡了 210 秒后超时。

**修复**：Dockerfile 里加国内代理（放在 `go mod download` **之前**，否则不生效）：

```dockerfile
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY} GOSUMDB=sum.golang.google.cn
COPY go.mod go.sum ./
RUN go mod download
```

### ✅ 成功

```
#13 [api builder 6/6] RUN go build -trimpath -ldflags='-s -w' -o /out/memo-api ./cmd/memo-api
#13 DONE 37.9s
#16 naming to ghcr.io/moyongdian/light-memo/memo-api:latest done
```

---

## 5. 构建前端镜像

```bash
ssh root@111.230.141.73 \
  'cd /srv/light-memo/src && SITE_URL=http://111.230.141.73 docker compose -p light-memo build web'
```

输出：

```
#13 3.429 dist/assets/index-BmnlkFdI.js              119.80 kB │ gzip:  38.94 kB
#13 3.429 dist/assets/AntdIcon-B6Ob7h3u.js           715.96 kB │ gzip: 235.76 kB
#13 3.431 ✓ built in 1.26s
#17 naming to ghcr.io/moyongdian/light-memo/memo-web:latest done
```

> `SITE_URL` 会在构建时写死进前端产物（`VITE_API_BASE_URL`），
> 后面换成 HTTPS 后必须**重新构建**，只改环境变量没用。

---

## 6. 初始化管理员密码

```bash
printf 'Memo@7xKq2Lp9\nMemo@7xKq2Lp9\n' | ssh -tt root@111.230.141.73 \
  'cd /srv/light-memo/src && docker compose -p light-memo run --rm api init'
```

输出：

```
 ✔ Network light-memo_default     Created
 ✔ Volume "light-memo_memo-data"  Created
Password:
Confirm password:
Password initialized.
```

两个关键点：
- **`-tt` 必须有**：`init` 用 `term.ReadPassword` 读密码，没有伪终端会报
  `password initialization requires an interactive terminal`
- **`run --rm` 会覆盖镜像的默认 `CMD`**：镜像是 `ENTRYPOINT [memo-api] CMD ["serve"]`，
  这里把 CMD 换成 `init`，跑完即删容器

---

## 7. 启动服务

```bash
ssh root@111.230.141.73 'cd /srv/light-memo/src && docker compose -p light-memo up -d'
docker compose -p light-memo ps
```

输出：

```
 Container memo-api  Healthy
 Container memo-web  Started
NAME       IMAGE                    STATUS                    PORTS
memo-api   .../memo-api:latest      Up 16 seconds (healthy)   8080/tcp
memo-web   .../memo-web:latest      Up 10 seconds             0.0.0.0:80->80/tcp
```

注意 `memo-api` 只写了 `expose: 8080`（容器间可见），**没有映射到宿主机**，
公网直接访问不到后端，只能经由 Nginx 反代——这是有意为之的安全设计。

---

## 8. 冒烟测试（先 HTTP）

```bash
curl http://111.230.141.73/healthz          # {"status":"ok"}
curl -o /dev/null -w "%{http_code}" http://111.230.141.73/     # 200
curl -o /dev/null -w "%{http_code}" http://111.230.141.73/api/v1/auth/session   # 401（未登录，符合预期）
```

到这一步网站已经能打开了，但**登录后会立刻掉线**，见第 9 步。

---

## 9. 上 HTTPS（这步不做，登录功能等于废的）

### 9.1 为什么必须 HTTPS

后端 `internal/session/session.go`：

```go
http.SetCookie(w, &http.Cookie{... Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
```

`Secure: true` = 浏览器只在 HTTPS 下保存该 Cookie。**纯 HTTP 登录会成功但存不住 Cookie**，
刷新就回到登录页。

### 9.2 ❌ 尝试 Let's Encrypt（失败，原因很重要）

```bash
docker compose -p light-memo stop web        # 腾出 80 端口
certbot certonly --standalone -d 111.230.141.73.nip.io -m 2260688132@qq.com --agree-tos
```

失败：

```
Detail: 111.230.141.73: Fetching http://111.230.141.73.nip.io/.well-known/acme-challenge/...:
        Connection reset by peer
```

排查发现访问 nip.io 域名时被拦截：

```bash
curl -v http://111.230.141.73.nip.io/
< HTTP/1.1 302
< Location: https://dnspod.qcloud.com/static/webblock.html?d=111.230.141.73.nip.io
```

**结论：腾讯云对未备案域名做了访问拦截（DNSPod webblock）**。
所以在中国大陆的云主机上：
- 用 nip.io / sslip.io 这类免费动态域名 → 会被拦截，Let's Encrypt 的 HTTP-01 校验也过不去
- 想用免费证书 → 必须有一个**已完成 ICP 备案**的域名

### 9.3 ✅ 改用自签证书

```bash
mkdir -p /srv/light-memo/certs
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /srv/light-memo/certs/privkey.pem \
  -out   /srv/light-memo/certs/fullchain.pem \
  -days 365 -subj "/CN=111.230.141.73" \
  -addext "subjectAltName=IP:111.230.141.73"
```

写 `docker-compose.override.yml`（不动主配置，override 会自动合并）：

```yaml
services:
  web:
    ports:
      - "443:443"
    volumes:
      - /srv/light-memo/certs:/etc/nginx/certs:ro
      - ./deploy/nginx/memo-ip-tls.conf:/etc/nginx/conf.d/default.conf:ro
```

用 HTTPS 地址重新构建前端并重启：

```bash
SITE_URL=https://111.230.141.73 docker compose -p light-memo build web
docker compose -p light-memo up -d
```

### 9.4 验证

```bash
curl -kfsS https://127.0.0.1/healthz                    # {"status":"ok"}
curl -k -o /dev/null -w "%{http_code}" https://127.0.0.1/    # 200
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}" http://127.0.0.1/
# 301 -> https://127.0.0.1/

# 登录接口实测
curl -k -i -X POST https://127.0.0.1/api/v1/auth/login \
  -H "Content-Type: application/json" -H "X-Memo-CSRF: 1" \
  -d '{"password":"Memo@7xKq2Lp9"}'
```

返回：

```
HTTP/2 204
set-cookie: __Host-memo_session=luXwtPMVrElvNkyk8ml39GfQwnLV...;
            Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Strict
```

拿到 Cookie 了，登录链路通 ✅

公网实测（从外网）：

```
https://111.230.141.73/           → 200
https://111.230.141.73/healthz    → {"status":"ok"}
http://111.230.141.73/            → 301 → https://111.230.141.73/
```

> 浏览器首次打开会提示「您的连接不是私密连接」→ 点 **高级 → 继续访问** 即可。
> 自签证书只影响信任提示，加密强度是一样的。

---

## 10. 配置每日自动备份

```bash
cat > /usr/local/bin/memo-backup.sh <<"EOF"
#!/usr/bin/env bash
set -e
DIR=/srv/backups/memo
mkdir -p "$DIR"
cd /srv/light-memo/src
docker compose -p light-memo stop api
docker run --rm -v light-memo_memo-data:/data -v "$DIR":/backup alpine \
  tar czf "/backup/memo-$(date +%F).tar.gz" -C /data .
docker compose -p light-memo start api
ls -1t "$DIR"/memo-*.tar.gz | tail -n +8 | xargs -r rm -f
EOF
chmod +x /usr/local/bin/memo-backup.sh
( crontab -l 2>/dev/null | grep -v memo-backup
  echo "0 4 * * * /usr/local/bin/memo-backup.sh >> /var/log/memo-backup.log 2>&1" ) | crontab -
```

立即跑一次验证：`/usr/local/bin/memo-backup.sh` → 生成 `memo-2026-10-12.tar.gz`（1.7K）

> 卷名是 `light-memo_memo-data`（`docker-compose -p` 指定的项目名 + 卷名），
> 用 `docker volume ls` 确认。停服再打包是为了拿到一致的快照（SQLite 有 WAL 文件）。

---

## 11. 日常运维速查

```bash
ssh root@111.230.141.73
cd /srv/light-memo/src

docker compose -p light-memo ps                  # 状态
docker compose -p light-memo logs -f             # 全部日志
docker compose -p light-memo logs -f api         # 只看后端
docker compose -p light-memo restart web         # 重启前端
docker compose -p light-memo exec web nginx -t   # 校验 Nginx 配置
docker stats                                     # 资源占用
docker system df                                 # 磁盘占用

curl -kfsS https://127.0.0.1/healthz             # 健康检查
ls -lh /srv/backups/memo/                        # 看备份
```

### 更新代码（以后改完代码这样上线）

```bash
# 本机执行
cd D:/rj/light-memo
tar czf - --exclude='.git' --exclude='node_modules' --exclude='dist' \
  --exclude='*.db*' --exclude='.env' . \
  | ssh -i ~/.ssh/light_memo_deploy root@111.230.141.73 \
      "tar xzf - -C /srv/light-memo/src"

# 服务器上重建对应服务
ssh root@111.230.141.73 'cd /srv/light-memo/src && \
  SITE_URL=https://111.230.141.73 docker compose -p light-memo up -d --build'
```

只改了后端就 `build api`，只改前端就 `build web`，别每次都全量重建。

### 回滚

```bash
docker compose -p light-memo down
# 恢复备份（会覆盖当前数据，先确认）
docker compose -p light-memo stop api
docker run --rm -v light-memo_memo-data:/data -v /srv/backups/memo:/backup alpine \
  sh -c 'rm -rf /data/* && tar xzf /backup/memo-2026-10-12.tar.gz -C /data'
docker compose -p light-memo start api
```

### 恢复出厂（清空数据重来）

```bash
docker compose -p light-memo down -v      # -v 会删掉数据卷，慎用！
```

---

## 12. 待办 / 后续优化

1. **改掉初始密码**：登录后进设置页修改，或用
   `PUT /api/v1/auth/password`（需 `X-Memo-CSRF: 1` + `Content-Type: application/json`）
2. **换成正式证书**：拿到**已备案域名**后：
   ```bash
   docker compose -p light-memo stop web
   certbot certonly --standalone -d 你的域名.com
   # 然后把 override 里的证书目录改成 /etc/letsencrypt，conf 换成 memo-tls.conf.example
   # 并重新构建前端：SITE_URL=https://你的域名.com docker compose build web
   ```
3. **配 GitHub Actions CI/CD**：现在用的是"本地打包上传"的土办法。
   配好 Secrets 后就能 `git push` 自动上线，见 `docs/DEPLOY-DOCKER.md` 第 5 步。
4. **加 swap 后内存仍偏紧**：前端构建是在服务器上做的，2GB 勉强够。
   迁到 CI 构建（云端编译、服务器只拉取）会更稳。

---

## 附：本次踩坑清单

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | 构建上下文路径错 | `/go.sum: not found` | api 的 `build.context` 改 `./backend` |
| 2 | Go 模块代理被墙 | `proxy.golang.org i/o timeout`（卡 210s） | `GOPROXY=https://goproxy.cn,direct` |
| 3 | 未备案域名被云厂商拦截 | nip.io 请求 302 到 `dnspod.qcloud.com/webblock` | 换备案域名，或先用自签证书 |
| 4 | Secure Cookie + HTTP | 登录成功但刷新掉线 | 必须 HTTPS |
| 5 | 交互式 init | `requires an interactive terminal` | `ssh -tt` + `printf 'pwd\npwd\n'` 喂进去 |
| 6 | 前端 API 地址是构建期常量 | 换 HTTPS 后前端还在请求 http | 改 `SITE_URL` 后重新 build 前端镜像 |
