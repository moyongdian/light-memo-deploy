# CI/CD 上线清单（明天执行）

> 本文档是 2026-10-15 准备就绪、待执行的最后一步。所有前置工作已完成并验证。

## 当前状态（已验证）

| 项目 | 状态 |
|---|---|
| 网站 | https://111.230.141.73 在线，HTTPS 正常 |
| 容器 | `memo-web`（80/443）、`memo-api`（内网 8080，healthy） |
| 数据卷 | `light-memo_memo-data`（SQLite 已初始化密码） |
| 服务器端部署脚本 | `/srv/light-memo/deploy.sh`（已验证语法、失败安全性） |
| CI 专用 SSH 密钥 | `~/.ssh/light_memo_ci` 已生成，公钥已装入服务器 `authorized_keys` 第 4 条 |
| 本地待推送提交 | `0ecaa6b`（修复 CI 的 4 个问题） |
| 故障演练 | 已验证：拉取失败时脚本立即停止，线上服务不受影响 |

## 第 1 步：配置 GitHub

地址：https://github.com/moyongdian/light-memo-deploy/settings/secrets/actions

### Secrets（5 个）

| Name | Value |
|---|---|
| `SERVER_HOST` | `111.230.141.73` |
| `SERVER_USER` | `root` |
| `SERVER_SSH_KEY` | 私钥全文，从 `C:\Users\Lenovo\.ssh\light_memo_ci` 复制，**必须含首尾 BEGIN/END 行** |
| `SERVER_PORT` | `22` |
| `SERVER_DIR` | `/srv/light-memo/src` |

### Variables（2 个）

| Name | Value |
|---|---|
| `SITE_URL` | `https://111.230.141.73` |
| `DEPLOY_ENABLED` | `true` |

## 第 2 步：推送触发

```powershell
cd D:\rj\light-memo
git push
```

## 第 3 步：观察 Actions

https://github.com/moyongdian/light-memo-deploy/actions

预期两个 Job：
1. `build` —— 构建两个镜像并推送到 `ghcr.io/moyongdian/light-memo-deploy/`
2. `deploy` —— SSH 到服务器执行 `/srv/light-memo/deploy.sh`

## 已知的预期问题

### 问题：GHCR 包默认私有

**现象**：服务器执行 `docker compose pull` 时报 `denied`。

**原因**：仓库是 Public，但 **GHCR 包的可见性独立设置，默认 Private**。

**解决方案（二选一）**：

**方案 A（简单）**：把包设为 Public
1. 第一次 CI 构建成功后，访问 https://github.com/moyongdian?tab=packages
2. 点开 `light-memo-deploy/memo-api` → Package settings → Change visibility → Public
3. 对 `memo-web` 重复

**方案 B（严谨）**：用 Token 登录
1. 创建 PAT（勾 `read:packages`）
2. 加为 Secret：`GHCR_TOKEN`
3. workflow 里已有 `if [ -n "$GHCR_TOKEN" ]` 分支会自动登录

> 当前 workflow 用的是 `secrets.GITHUB_TOKEN`，它在**服务器上**无效（只对 Actions 运行环境有效）。所以方案 A 更省事。

### 问题：镜像地址变更导致首次拉取较慢

新镜像地址 `ghcr.io/moyongdian/light-memo-deploy/*` 与服务器上已有的旧镜像（`ghcr.io/moyongdian/light-memo/*`）不同，所以首次部署会完整下载约 70MB。

## 回滚方法

镜像同时打了 `latest` 和 `sha-<7位>` 两个标签。回滚：

```bash
ssh root@111.230.141.73
cd /srv/light-memo/src
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=<旧的7位sha> bash /srv/light-memo/deploy.sh
```

## 常用运维命令

```bash
# 状态总览（本次新建的脚本）
bash /tmp/memo-status.sh

# 重新上传状态脚本（如果 /tmp 被清理）
# 在本地执行：
# scp -i "$env:USERPROFILE\.ssh\light_memo_ci" deploy/memo-status.sh root@111.230.141.73:/tmp/

# 查看日志
cd /srv/light-memo/src
docker compose -p light-memo logs -f api
docker compose -p light-memo logs -f web

# 手动执行一次部署
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=latest bash /srv/light-memo/deploy.sh
```
