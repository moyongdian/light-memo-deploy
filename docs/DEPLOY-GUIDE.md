# light-memo 部署实战教程：Docker + Nginx + GitHub Actions

> **从零开始，把项目部署到云服务器，并实现自动部署**
>
> 服务器：腾讯云 Ubuntu 22.04（2 核 2G / 40G 磁盘）
> 公网 IP：`111.230.141.73`
>
> 本教程每一步都包含：**做什么 → 命令逐行解释 → 预期输出 → 如何验证 → 出错了怎么排查**

---

# 目录

- [开始之前：你需要准备什么](#开始之前你需要准备什么)
- [第一章 基础概念：先搞懂在做什么](#第一章-基础概念先搞懂在做什么)
- [第二章 检查服务器现状](#第二章-检查服务器现状)
- [第三章 备份数据（不可跳过）](#第三章-备份数据不可跳过)
- [第四章 拆除旧环境](#第四章-拆除旧环境)
- [第五章 准备服务器环境](#第五章-准备服务器环境)
- [第六章 编写部署配置文件](#第六章-编写部署配置文件)
- [第七章 首次手动部署](#第七章-首次手动部署)
- [第八章 配置 HTTPS](#第八章-配置-https)
- [第九章 编写自动部署脚本](#第九章-编写自动部署脚本)
- [第十章 配置 SSH 密钥](#第十章-配置-ssh-密钥)
- [第十一章 编写 GitHub Actions 工作流](#第十一章-编写-github-actions-工作流)
- [第十二章 配置 GitHub Secrets](#第十二章-配置-github-secrets)
- [第十三章 触发自动部署](#第十三章-触发自动部署)
- [第十四章 回滚](#第十四章-回滚)
- [第十五章 日常运维](#第十五章-日常运维)
- [第十六章 排错手册](#第十六章-排错手册)
- [附录](#附录)

---

# 开始之前：你需要准备什么

## 需要的东西

| 项目 | 说明 |
|---|---|
| 一台云服务器 | 本教程用腾讯云 Ubuntu 22.04，2 核 2G |
| 服务器公网 IP | 本教程为 `111.230.141.73` |
| SSH 客户端 | Windows 上用 Xshell 或 PowerShell 自带的 `ssh` |
| GitHub 账号 | 用于存放代码和运行自动部署 |
| 项目代码 | 本教程是 light-memo（Go 后端 + React 前端） |

## 项目结构

```
light-memo/
├── backend/                    # Go 后端
│   ├── Dockerfile
│   ├── go.mod
│   └── main.go
├── frontend/                   # React 前端
│   ├── Dockerfile
│   ├── package.json
│   └── src/
├── deploy/                     # 部署相关文件
│   ├── nginx/                  # Nginx 配置
│   │   └── nginx.conf
│   ├── docker-compose.override.yml
│   └── server-deploy.sh
├── docker-compose.yml          # 容器编排
└── .github/workflows/
    └── deploy.yml              # 自动部署流程
```

---

# 第一章 基础概念：先搞懂在做什么

> 这一章不执行命令，但**必须看懂**，否则后面的命令只是照抄。

## 1.1 三个工具分别在干什么

### Docker：把程序和运行环境打包在一起

**问题**：你的程序在本地能跑，传到服务器上却报错 —— 因为服务器上没装 Go、或者 Node 版本不对、或者缺某个系统库。

**Docker 的解法**：把「程序 + 它需要的一切依赖」打包成一个**镜像**（image），在任何装了 Docker 的机器上都能直接运行。

| 概念 | 类比 | 说明 |
|---|---|---|
| **镜像 image** | 光盘 | 只读的模板，包含程序和环境 |
| **容器 container** | 正在播放的光盘 | 镜像运行起来的实例 |
| **Dockerfile** | 制作光盘的说明书 | 描述怎么构建镜像 |
| **数据卷 volume** | 移动硬盘 | 容器删了数据还在，用于存数据库 |

**为什么容器删了数据会丢**：容器是临时的。要持久保存的数据必须放在**数据卷**里。

### Nginx：负责接收用户请求

**Nginx 是 Web 服务器**，作用是：

1. **把网页发给用户** —— 用户访问 `https://111.230.141.73`，Nginx 返回前端页面文件
2. **转发 API 请求** —— 页面里的 `/api/xxx` 请求，Nginx 转给后端程序处理
3. **处理 HTTPS 加密** —— 负责证书和加密解密

**为什么需要它**：后端程序（Go）只监听内部的 8080 端口，不直接对外。外面统一由 Nginx 接待，再按路径分发给不同的服务。这叫**反向代理**。

```
用户浏览器
    │  https://111.230.141.73/
    ▼
┌─────────┐
│  Nginx  │  监听 80 和 443
└────┬────┘
     │
     ├─── 路径是 /        → 返回前端页面文件
     │
     └─── 路径是 /api/    → 转发给后端 (api:8080)
                            │
                            ▼
                       ┌─────────┐
                       │ Go 后端 │  只监听内部 8080
                       └─────────┘
```

### GitHub Actions：自动帮你部署

**手动部署的痛点**：每次改完代码，都要手动构建、上传、重启，步骤多且容易忘。

**GitHub Actions 的解法**：你只要 `git push`，它自动完成：

1. 检出代码
2. 构建 Docker 镜像
3. 推送镜像到镜像仓库
4. 通过 SSH 连到你的服务器
5. 执行部署脚本重启服务

**关键概念**：

| 概念 | 说明 |
|---|---|
| **workflow（工作流）** | 一个自动化流程，写在 `.github/workflows/*.yml` |
| **job（任务）** | 工作流里的一组步骤，可以多个 job 串行或并行 |
| **step（步骤）** | job 里的一个动作，比如「检出代码」 |
| **runner** | 执行这些步骤的机器，GitHub 免费提供 |
| **secrets** | 敏感信息（密码、密钥），加密存储，日志里自动打码 |
| **vars** | 普通变量（比如网站地址），不加密 |

## 1.2 完整链路（最重要的一张图）

```
【你的电脑】
    git push
        │
        ▼
【GitHub】
    ┌──────────────────────────────────┐
    │ Job 1: build（构建）              │
    │   1. 检出代码                     │
    │   2. 构建两个镜像                 │
    │      - memo-api（后端）           │
    │      - memo-web（前端+Nginx）     │
    │   3. 推送到镜像仓库 GHCR          │
    └──────────────┬───────────────────┘
                   │ 构建成功才继续
                   ▼
    ┌──────────────────────────────────┐
    │ Job 2: deploy（部署）             │
    │   1. 复制 compose 和 nginx 配置   │
    │      到服务器                      │
    │   2. SSH 连到服务器               │
    │   3. 执行部署脚本                 │
    └──────────────┬───────────────────┘
                   │
                   ▼
【你的服务器 111.230.141.73】
    docker compose pull     ← 拉取新镜像
    docker compose up -d    ← 用新镜像重启
    健康检查                ← 确认服务正常
                   │
                   ▼
           用户访问网站
```

## 1.3 为什么这样设计

| 设计 | 原因 |
|---|---|
| **镜像在 GitHub 的机器上构建** | 你的服务器只有 2G 内存，构建前端（Vite）很可能内存不足崩溃 |
| **镜像推送到 GHCR** | GHCR 是 GitHub 自带的镜像仓库，免费；服务器从它下载，不用上传整个源码 |
| **用 commit SHA 做镜像标签** | 出问题时能精确回滚到任意历史版本 |
| **部署逻辑写成服务器上的脚本** | CI 和手动执行走同一套流程，行为一致，也方便在服务器上单独调试 |
| **证书和 443 配置放独立的 override 文件** | 基础配置文件通用，服务器特有的配置单独存放 |

---

# 第二章 检查服务器现状

> **目标**：在动手之前，先搞清楚服务器上有什么，避免踩到别人的地盘。

## 2.1 登录服务器

**在 Xshell 里新建连接**，或用命令行：

```bash
ssh root@111.230.141.73
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `ssh` | Secure Shell，加密的远程登录工具 |
| `root` | 登录的用户名，root 是 Linux 的最高权限用户 |
| `@` | 分隔用户名和主机 |
| `111.230.141.73` | 服务器的公网 IP |

**首次连接会提示**：

```
The authenticity of host '111.230.141.73' can't be established.
ED25519 key fingerprint is SHA256:xxxxx.
Are you sure you want to continue connecting (yes/no)?
```

这是**正常现象** —— SSH 在问你「这个服务器的身份我没见过，你确认要连吗」。输入 `yes` 回车。

> **原理**：SSH 会记住每台服务器的主机密钥，防止别人冒充你的服务器（中间人攻击）。第一次连接时它没有记录，所以要你确认。

## 2.2 查看系统信息

```bash
cat /etc/os-release | head -2
nproc && free -m | head -2 && df -h /
```

### 命令解释

| 命令 | 作用 |
|---|---|
| `cat /etc/os-release` | 查看系统版本信息 |
| `\| head -2` | 只看前 2 行 |
| `nproc` | 显示 CPU 核心数 |
| `free -m` | 显示内存使用，`-m` 表示以 MB 为单位 |
| `df -h /` | 显示根分区磁盘使用，`-h` 表示人类可读格式（G/M 而不是字节） |

### 预期输出

```
PRETTY_NAME="Ubuntu 22.04.4 LTS"      ← 系统版本
NAME="Ubuntu"

2                                     ← 2 个 CPU 核心
               total   used   free
Mem:            1963    864     97     ← 总内存 1963MB ≈ 2G
/dev/vda2        40G    12G    27G     ← 磁盘 40G，已用 12G
```

### 怎么判断

- 内存只有 2G → **不要在服务器上构建前端**，会内存不足
- 磁盘剩 27G → 够用，但要注意清理旧镜像

## 2.3 ⭐ 检查端口占用（本步最重要）

```bash
ss -tlnp | grep -E ':(80|443|8080|8090)\s'
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `ss` | socket statistics，查看网络连接（比老旧的 `netstat` 更快） |
| `-t` | 只看 TCP 连接 |
| `-l` | 只看 LISTEN（监听中）的连接 |
| `-n` | 显示端口数字，不解析成服务名（80 而不是 http） |
| `-p` | 显示占用端口的**进程** |
| `\| grep -E ':(80\|443\|8080\|8090)\s'` | 只显示这几个端口，`-E` 表示用正则表达式 |

### 预期输出

```
LISTEN 0 4096 0.0.0.0:8090 0.0.0.0:*  users:(("1panel-core",pid=829,fd=12))
LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*  users:(("docker-proxy",pid=390212,fd=4))
LISTEN 0 128  0.0.0.0:22   0.0.0.0:*  users:(("sshd",pid=57108,fd=3))
```

### 逐行解读

| 端口 | 占用者 | 是什么 | 能碰吗 |
|---|---|---|---|
| 8090 | `1panel-core` | 1Panel 服务器管理面板 | ❌ 不能动 |
| 8080 | `docker-proxy` | Zabbix 监控系统的 Nginx | ❌ 不能动 |
| 22 | `sshd` | SSH 服务本身 | ❌ 动了就断线 |
| 80 / 443 | **没出现** | **空闲，我们可用** | ✅ |

### 这一步救了我们

`0.0.0.0:8080` 被 Zabbix 占用了。如果我们的后端也映射 8080 到宿主机，**服务会启动失败**。

**解决方案**：后端用 `expose` 而不是 `ports`（见 6.1 节），让它只在容器内部可见。

### 出错了怎么查

**如果 80/443 被占用**：

```bash
# 查具体是谁占用
ss -tlnp | grep ':80\s'
# 或
lsof -i :80
```

看到 `pid=xxxx` 后：

```bash
ps -p xxxx -o pid,comm,args    # 查看这个进程是什么
```

**如果是你自己之前部署的服务**，停掉它：`docker compose -p <项目名> down`

**如果是系统服务**（比如 `apache2`、`nginx`）：`systemctl stop nginx && systemctl disable nginx`

> ⚠️ **绝对不要**直接 `kill -9` 一个你不认识的进程 —— 可能是系统关键服务。

## 2.4 查看 Docker 环境

```bash
docker --version
docker compose version
```

### 预期输出

```
Docker version 27.0.3, build 6625d65
Docker Compose version v2.29.0
```

### ⚠️ 这里有个坑

如果看到这样的报错：

```
permission denied while trying to connect to the Docker daemon socket
```

**这是权限问题，不是没装 Docker**。

**原因**：Docker 的守护进程 socket 文件 `/var/run/docker.sock` 默认只有 root 和 docker 组成员能访问。

**解决**：

```bash
sudo usermod -aG docker $USER    # 把当前用户加入 docker 组
newgrp docker                    # 让组权限立即生效（或重新登录）
docker ps                        # 再试，应该好了
```

### 血泪教训

**不要这样写**：

```bash
docker --version 2>/dev/null || echo "Docker 未安装"   # ❌ 错误做法
```

因为如果实际是权限错误，`2>/dev/null` 会把错误信息丢掉，然后输出「未安装」，**把你引向完全错误的排查方向**（你会去重装 Docker，而问题其实是权限）。

**正确做法**：

```bash
docker --version        # ✅ 让错误原样显示出来
```

> **记住这条原则**：`2>/dev/null` 是排查问题的大敌。它把错误藏起来，让你看不见真相。

## 2.5 查看现有的容器

```bash
docker ps -a
docker compose ls -a
```

### 命令解释

| 命令 | 作用 |
|---|---|
| `docker ps` | 列出**运行中**的容器 |
| `docker ps -a` | 列出**所有**容器（包括已停止的） |
| `docker compose ls -a` | 列出所有 compose 项目 |

### 预期输出

```
CONTAINER ID   IMAGE                    STATUS                    NAMES
a1b2c3d4e5f6   1panel/...               Up 35 hours (healthy)     1Panel-zabbix-server-hJqx-nginx
b2c3d4e5f6a1   mysql:8.0                Up 35 hours               1Panel-mysql-YGhm
c3d4e5f6a1b2   ghcr.io/.../memo-web     Up 2 days                  memo-web
```

### 要从中看出什么

| 观察 | 含义 |
|---|---|
| 有 `1Panel-*` 前缀的容器 | 这是 1Panel 管理的，**不要碰** |
| 有 `memo-*` 容器 | 这是我们之前部署的，本次要重建 |
| 其他不认识的容器 | 先查清楚是什么再决定，不确定就别动 |

**查看 compose 项目归属**：

```bash
docker compose ls -a
```

```
NAME            STATUS        CONFIG FILES
light-memo      running(2)    /srv/light-memo/src/docker-compose.yml
mysql           running(1)    /opt/1panel/apps/mysql/mysql/docker-compose.yml
zabbix-server   running(3)    /opt/1panel/apps/zabbix-server/.../docker-compose.yml
```

**每个 compose 项目是独立的**。对 `light-memo` 执行 `down` **不会影响** `mysql` 和 `zabbix-server`。

> **这是后面 `--remove-orphans` 参数安全的原因**：它只清理**同一个 compose 项目内**的孤儿容器。

---

# 第三章 备份数据（不可跳过）

> ⚠️ **下一章要删除数据。现在不备份，删了就找不回来了。**

## 3.1 理解数据存在哪里

先确认数据卷的名字：

```bash
docker volume ls | grep memo
```

### 预期输出

```
DRIVER    VOLUME NAME
local     light-memo_memo-data
```

### 命名规则解释

volume 名字是 `<compose项目名>_<卷名>` 拼起来的：

| 部分 | 值 | 来源 |
|---|---|---|
| `light-memo` | | compose 项目名（默认取目录名，或用 `-p` 指定） |
| `_` | | 分隔符 |
| `memo-data` | | `docker-compose.yml` 里 `volumes:` 定义的卷名 |

**所以 `docker-compose.yml` 里写的 `memo-data`，实际名字是 `light-memo_memo-data`。**

## 3.2 执行备份

```bash
mkdir -p /srv/backups/memo

docker run --rm \
  -v light-memo_memo-data:/data:ro \
  -v /srv/backups/memo:/backup \
  alpine tar czf /backup/pre-wipe-$(date +%F-%H%M).tar.gz -C /data .
```

### 逐行解释

**第 1 行：创建备份目录**

| 部分 | 含义 |
|---|---|
| `mkdir` | make directory，创建目录 |
| `-p` | 如果父目录不存在就一起创建，且目录已存在时不报错 |
| `/srv/backups/memo` | 目录路径，`/srv` 是放服务数据的惯例位置 |

**第 2～5 行：用一个临时容器打包数据**

| 部分 | 含义 |
|---|---|
| `docker run` | 运行一个容器 |
| `--rm` | 容器退出后**自动删除**，不留垃圾 |
| `-v light-memo_memo-data:/data:ro` | 把数据卷挂载到容器里的 `/data`，`:ro` = read-only 只读（**保护数据不被误改**） |
| `-v /srv/backups/memo:/backup` | 把宿主机的备份目录挂载到容器里的 `/backup` |
| `alpine` | 用 Alpine Linux 镜像（只有 5MB，专为这种小任务设计） |
| `tar czf ...` | 打包命令（见下） |
| `-C /data .` | 切换到 `/data` 目录，然后打包当前目录的所有内容 |

**`tar czf` 四个字母的意思**：

| 字母 | 含义 |
|---|---|
| `c` | create，创建新归档 |
| `z` | 用 gzip 压缩 |
| `f` | 后面跟的是文件名 |
| `$(date +%F-%H%M)` | 命令替换：插入当前时间，格式 `2026-10-15-1430` |

**为什么要用容器来打包**：因为备份的是一个**数据卷**，而数据卷不属于任何容器。用一个临时容器把它挂载进来，是最干净的做法。

## 3.3 验证备份有效 ⭐

**打包命令没报错，不代表备份能用。必须验证。**

```bash
ls -lh /srv/backups/memo/
```

### 预期输出

```
-rw-r--r-- 1 root root 1.8K Oct 15 14:30 pre-wipe-2026-10-15-1430.tar.gz
```

**看大小**：如果只有几十字节，说明是**空备份**（数据卷可能是空的，或者挂载点写错了）。

**看内容**：

```bash
tar tzf /srv/backups/memo/pre-wipe-*.tar.gz
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `tar tzf` | `t` = list，**列出**归档内容但不解压 |
| `*.tar.gz` | 通配符，匹配最新的备份文件 |

### 预期输出

```
./
./memo.db
./memo.db-wal
```

**必须看到你的实际数据文件**。如果输出是空的，或者只有 `./`，说明备份是空的，**不要继续下一步**。

### 出错了怎么查

| 现象 | 原因 | 解决 |
|---|---|---|
| 文件不存在 | 命令没执行成功 | 检查上面的报错信息 |
| 文件只有几十字节 | 数据卷是空的 | `docker volume inspect light-memo_memo-data` 看挂载点，确认卷名对不对 |
| `No such volume` | 卷名写错了 | `docker volume ls` 看实际名字 |

## 3.4 把备份下载到本地（双重保险）

```powershell
# 在你自己的电脑上执行
scp root@111.230.141.73:/srv/backups/memo/pre-wipe-*.tar.gz D:\backup\
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `scp` | secure copy，加密的远程复制 |
| `root@111.230.141.73:` | 源文件的远程位置 |
| `/srv/backups/...` | 远程路径 |
| `D:\backup\` | 本地目标路径 |

> **为什么还要下载一份**：备份和原数据在同一台机器上。如果磁盘坏了，两个都没了。

---

# 第四章 拆除旧环境

> ⚠️ **确认第三章的备份已验证有效，再执行本章。**

## 4.1 理解拆除的顺序

**必须按这个顺序**，因为存在依赖关系：

```
1. 停止并删除容器     ← 先停服务
      ↓
2. 删除网络           ← 容器不用网络了
      ↓
3. 删除数据卷         ← 容器不用卷了
      ↓
4. 删除镜像           ← 容器不用镜像了
      ↓
5. 清理构建缓存       ← 最后清垃圾
```

**如果顺序反了会怎样**：比如先删镜像，容器还在运行，Docker 会报 `image is being used by running container`，删不掉。

## 4.2 执行拆除

```bash
cd /srv/light-memo/src

# 停止并删除容器 + 网络
docker compose -p light-memo down

# 删除数据卷
docker volume rm light-memo_memo-data

# 删除我们的镜像
docker images --format '{{.Repository}}:{{.Tag}}' | grep light-memo | xargs -r docker rmi

# 清理构建缓存
docker builder prune -af
```

### 逐条解释

**`docker compose -p light-memo down`**

| 部分 | 含义 |
|---|---|
| `docker compose` | 调用 compose 子命令 |
| `-p light-memo` | 指定项目名为 light-memo（不写则用当前目录名） |
| `down` | 停止并删除该项目的**容器**和**网络** |

> **注意**：`down` **默认不删除数据卷**（这是保护措施）。所以下一步要手动删。

**`docker volume rm light-memo_memo-data`**

| 部分 | 含义 |
|---|---|
| `docker volume rm` | 删除数据卷 |
| `light-memo_memo-data` | 卷的完整名字（项目名_卷名） |

**`docker images --format ... | grep ... | xargs -r docker rmi`**

这是三个命令用管道串起来的：

| 部分 | 含义 |
|---|---|
| `docker images --format '{{.Repository}}:{{.Tag}}'` | 列出所有镜像，格式化为 `仓库:标签` |
| `\| grep light-memo` | 只保留含 light-memo 的行（**保护其他镜像**） |
| `\| xargs -r docker rmi` | 把每一行作为参数传给 `docker rmi`（删除镜像）；`-r` 表示如果没有输入就**不执行**（避免 `docker rmi` 无参数报错） |

**`docker builder prune -af`**

| 部分 | 含义 |
|---|---|
| `docker builder prune` | 清理构建缓存 |
| `-a` | all，删除**所有**缓存（不只是悬空的） |
| `-f` | force，不询问确认 |

**这一步回收的空间通常最多** —— 实测约 1.3GB。

## 4.3 验证拆除干净 ⭐

```bash
echo "--- 容器 ---"; docker ps -a | grep memo
echo "--- 数据卷 ---"; docker volume ls | grep memo
echo "--- 镜像 ---";   docker images | grep memo
echo "--- 网络 ---";   docker network ls | grep memo
```

### 预期输出

**四条命令都应该没有输出**。如果还有残留，说明没删干净。

### 出错了怎么查

| 现象 | 原因 | 解决 |
|---|---|---|
| 容器还在 | `down` 失败 | 看报错；可能是容器被其他东西依赖 |
| `volume is in use` | 还有容器在用 | 先 `docker ps -a \| grep memo` 确认容器都删了 |
| `image is being used` | 有容器（含已停止的）在用 | `docker ps -a` 找到后 `docker rm <容器ID>` |

## 4.4 确认其他服务没受影响 ⭐

**这一步极其重要** —— 证明我们的操作没有误伤别人。

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

### 预期输出

```
NAMES                            STATUS
1Panel-zabbix-server-hJqx-nginx  Up 35 hours (healthy)     ← 还在跑，时间没变
1Panel-mysql-YGhm                Up 35 hours               ← 还在跑，时间没变
```

**关键看 `Up 35 hours`** —— 如果时间变成 `Up 2 minutes`，说明**被重启了**，那就是误伤。

---

# 第五章 准备服务器环境

## 5.1 创建目录结构

```bash
mkdir -p /srv/light-memo/src
mkdir -p /srv/light-memo/certs
mkdir -p /srv/backups/memo
```

### 为什么用 `/srv`

Linux 文件系统有约定：

| 目录 | 用途 |
|---|---|
| `/bin`、`/usr/bin` | 系统程序 |
| `/etc` | 配置文件 |
| `/var` | 经常变化的数据（日志等） |
| `/home` | 用户主目录 |
| **`/srv`** | **服务数据（service）—— 我们的项目放这里** |
| `/tmp` | 临时文件，重启会清空 |

> ⚠️ **不要把项目放 `/tmp`** —— 重启就没了。也不要放 `/root` —— 那是 root 用户的家目录，混在一起不好管理。

### 最终目录结构

```
/srv/
├── light-memo/
│   ├── src/              # 项目源码和 compose 文件
│   ├── certs/            # HTTPS 证书
│   └── deploy.sh         # 部署脚本
└── backups/
    └── memo/             # 备份文件
```

## 5.2 上传项目代码

**在本地 Windows PowerShell 执行**。

### ⚠️ 这里有个大坑

**错误做法**（会失败）：

```powershell
tar czf - backend | ssh root@111.230.141.73 "tar xzf - -C /srv/light-memo/src"
```

**报错**：

```
gzip: stdin: not in gzip format
tar: Child returned status 1
```

### 为什么失败

| 系统 | `|` 管道传递的东西 |
|---|---|
| Linux / macOS | **字节流**（原始二进制数据） |
| Windows PowerShell | **.NET 文本对象** |

PowerShell 把 tar 输出的二进制数据当成**文本**来处理和传递，二进制被破坏了。接收端拿到的不是有效的 gzip 数据，所以报「不是 gzip 格式」。

> **记住**：跨平台的管道不能用来传二进制数据。

### 正确做法（分两步）

```powershell
# 第 1 步：先打包成文件
cd D:\rj\light-memo
tar czf source.tar.gz backend frontend docker-compose.yml deploy

# 第 2 步：用 scp 上传（scp 传的是字节流，不会损坏）
scp source.tar.gz root@111.230.141.73:/tmp/

# 第 3 步：在服务器上解压
ssh root@111.230.141.73 "mkdir -p /srv/light-memo/src && tar xzf /tmp/source.tar.gz -C /srv/light-memo/src"
```

### 验证上传

```bash
ls -la /srv/light-memo/src/
```

**应该看到** `backend`、`frontend`、`docker-compose.yml`、`deploy`。

---

# 第六章 编写部署配置文件

## 6.1 编写 `docker-compose.yml`

**文件位置**：`/srv/light-memo/src/docker-compose.yml`

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
      - "8080"
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

### 逐项解释

#### `image: ${IMAGE_BASE}/memo-api:${TAG:-latest}`

**这是最容易困惑的一行。**

| 部分 | 含义 |
|---|---|
| `${IMAGE_BASE}` | 环境变量，镜像地址前缀，如 `ghcr.io/moyongdian/light-memo-deploy` |
| `${TAG:-latest}` | 环境变量 TAG，**如果没设置就用 `latest`** |

**`${TAG:-latest}` 语法**：`:-` 表示「如果变量为空或未定义，用后面的默认值」。

**完整展开后**：

```
ghcr.io/moyongdian/light-memo-deploy/memo-api:latest
```

**为什么要用变量**：这样回滚时只要改 `TAG` 就能切换版本：

```bash
IMAGE_BASE=ghcr.io/... TAG=abc1234 docker compose up -d
# 会用 ghcr.io/.../memo-api:abc1234
```

#### `expose` vs `ports`（关键区别）

| 写法 | 效果 | 宿主机能否访问 |
|---|---|---|
| `ports: - "8080:8080"` | 把容器 8080 映射到宿主机 8080 | ✅ 能 |
| `expose: - "8080"` | 只在**容器网络内部**暴露 | ❌ 不能 |

**我们用 `expose` 的原因**：宿主机 8080 被 Zabbix 占用了（第二章发现的）。用 `expose` 就**不占用宿主机端口**，完全避免冲突。

**那 Nginx 怎么访问后端**：因为它们在同一容器网络 `memo-net` 里，Nginx 可以直接用**服务名**访问：

```nginx
proxy_pass http://api:8080;    # api 就是 compose 里的服务名
```

Docker 内置的 DNS 会把服务名 `api` 解析成容器 IP。

#### `healthcheck`（健康检查）

```yaml
healthcheck:
  test: ["CMD", "/app/memo", "healthcheck"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 10s
```

| 参数 | 含义 |
|---|---|
| `test` | 执行什么命令来检查，退出码 0 = 健康 |
| `interval: 30s` | 每 30 秒检查一次 |
| `timeout: 5s` | 单次检查超过 5 秒算失败 |
| `retries: 3` | 连续失败 3 次才标记为 unhealthy |
| `start_period: 10s` | 启动后 10 秒内不检查（给程序启动时间） |

**为什么需要**：后端启动需要时间。如果 Nginx 在数据库还没初始化好时就启动，用户会看到错误。

#### `depends_on` + `condition: service_healthy`

```yaml
depends_on:
  api:
    condition: service_healthy
```

**不加 `condition` 的 `depends_on` 只保证「容器启动了」，不保证「服务能用了」。**

加了 `condition: service_healthy` 后，Docker 会**等 api 的健康检查通过**，才启动 web。

| 写法 | 效果 |
|---|---|
| `depends_on: [api]` | 等 api 容器**启动**（可能程序还没就绪） |
| `condition: service_healthy` | 等 api **健康检查通过**（真正可用） |

#### `restart: unless-stopped`

| 值 | 含义 |
|---|---|
| `no` | 不自动重启（默认） |
| `always` | 总是重启（包括你手动停掉后） |
| `unless-stopped` | 自动重启，**但如果你手动 stop 了就不重启** |
| `on-failure` | 只在非正常退出时重启 |

**用 `unless-stopped` 的原因**：服务器重启后容器会自动起来（高可用），但你手动停止维护时不会自己又起来（可控）。

## 6.2 编写 `deploy/docker-compose.override.yml`

**文件位置**：`/srv/light-memo/src/docker-compose.override.yml`

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

### ⭐ 什么是 override 文件

Docker Compose 会**自动**读取这两个文件并**合并**：

| 顺序 | 文件 | 作用 |
|---|---|---|
| 1 | `docker-compose.yml` | 基础配置 |
| 2 | `docker-compose.override.yml` | **自动覆盖/补充**基础配置 |

**合并规则**：

| 类型 | 规则 |
|---|---|
| `ports`、`volumes`（列表） | **追加合并**（两边都有就都生效） |
| `image`、`environment`（映射） | **后者覆盖前者** |
| 只在一个文件里的 | 直接生效 |

**所以最终配置**是：

```yaml
web:
  ports:
    - "80:80"      # 来自基础文件
    - "443:443"    # 来自 override
  volumes:
    - ...nginx 配置    # 来自 override
    - ...证书          # 来自 override
```

### 为什么要拆成两个文件

| 场景 | 好处 |
|---|---|
| 本地开发 | 只有基础文件，不需要证书和 443 |
| 换服务器 | 只改 override，基础文件不动 |
| 代码仓库 | 基础文件通用，override 按环境定制 |

### ⚠️ 一个真实的坑

**CI 部署时必须把 override 文件也传上去。**

我们的 workflow 一开始只传了 `docker-compose.yml`，**没传 override**。短期不出问题（服务器上旧的 override 还在），但如果有人重新 clone 或者清了目录：

**443 端口会消失，HTTPS 直接挂掉，而且没有任何报错。**

修复方法是在 workflow 的 `source` 里加上：

```yaml
source: "docker-compose.yml,deploy/nginx/,deploy/docker-compose.override.yml,deploy/server-deploy.sh"
```

### 冒号语法解释（卷挂载）

```yaml
- ./deploy/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
```

| 部分 | 含义 |
|---|---|
| `./deploy/nginx/nginx.conf` | **宿主机**上的路径（`.` 是 compose 文件所在目录） |
| `:` | 分隔符 |
| `/etc/nginx/conf.d/default.conf` | **容器内**的路径 |
| `:ro` | read-only，容器只能读，不能改（**更安全**） |

**原理**：把宿主机的文件「映射」到容器里。容器里改了，宿主机也变（除非 `:ro`）—— 这叫**bind mount（绑定挂载）**。

**为什么证书用绝对路径**：证书在 `/srv/light-memo/certs/`，而不在项目目录里。用绝对路径更清晰。

## 6.3 编写 `deploy/nginx/nginx.conf`

**文件位置**：`/srv/light-memo/src/deploy/nginx/nginx.conf`

```nginx
# ============ 80 端口：全部跳转到 HTTPS ============
server {
    listen 80;
    server_name _;

    location / {
        return 301 https://$host$request_uri;
    }
}

# ============ 443 端口：HTTPS 服务 ============
server {
    listen 443 ssl;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /usr/share/nginx/html;
    index index.html;

    # 前端：单页应用路由回退
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

    # 健康检查
    location /healthz {
        proxy_pass http://api:8080/healthz;
    }
}
```

### 逐段解释

#### `listen 80` + `return 301`

```nginx
server {
    listen 80;
    return 301 https://$host$request_uri;
}
```

| 部分 | 含义 |
|---|---|
| `listen 80` | 监听 80 端口（HTTP） |
| `return 301` | 返回 301 永久重定向 |
| `https://$host$request_uri` | 目标地址 |
| `$host` | 用户请求的主机名（这里是 IP） |
| `$request_uri` | 用户请求的完整路径（含查询参数） |

**效果**：用户访问 `http://111.230.141.73/foo?x=1`，自动跳到 `https://111.230.141.73/foo?x=1`。

**为什么用 301 而不是 302**：

| 状态码 | 含义 | 浏览器行为 |
|---|---|---|
| 301 | 永久重定向 | **记住**，以后直接走 HTTPS |
| 302 | 临时重定向 | 每次都先请求 HTTP 再跳 |

#### ⚠️ `return 301` 带来的坑

加了跳转后，**任何用 `http://` 做的检查都会失败**：

```bash
curl -fsS http://127.0.0.1/healthz     # ❌ 失败
```

**原因**：
1. 80 端口返回 301
2. `curl` 默认**不跟随重定向**（要加 `-L`）
3. `-f` 把 301 当作成功（3xx 不算错误），但**响应体是空的**
4. 后续解析空响应 → 失败

**正确写法**：

```bash
curl -kfsS https://127.0.0.1/healthz   # ✅ 直接走 HTTPS
# -k 表示忽略自签证书警告
```

**这个坑在 CI 里真实踩到过** —— 部署脚本的健康检查用了 `http://`，导致部署「成功」了但脚本报失败。

#### `proxy_pass`（反向代理）

```nginx
location /api/ {
    proxy_pass http://api:8080;
}
```

| 部分 | 含义 |
|---|---|
| `location /api/` | 匹配所有以 `/api/` 开头的请求 |
| `proxy_pass http://api:8080` | 转发到 `api` 这个主机的 8080 端口 |
| `api` | **compose 里的服务名**，Docker DNS 自动解析 |

**这就是「反向代理」**：用户以为在跟 Nginx 说话，实际上 Nginx 把请求转给了后端。

**为什么需要**：
1. **隐藏后端** —— 后端不直接暴露，更安全
2. **统一入口** —— 前后端同一个域名端口，不用处理跨域
3. **负载均衡** —— 后端多了可以分发（本教程用不到）

#### `proxy_set_header` 四个头

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

| 头 | 作用 |
|---|---|
| `Host` | 传原始 Host，后端生成链接时用得到 |
| `X-Real-IP` | 传**真实客户端 IP**（否则后端看到的是 Nginx 的 IP） |
| `X-Forwarded-For` | 传代理链上的所有 IP |
| `X-Forwarded-Proto` | 告诉后端「用户用的是 https」（否则后端以为是 http，可能生成错误的跳转） |

**为什么重要**：没有这些头，后端的日志里所有请求都来自 Nginx 的 IP，**无法知道真实用户是谁**。

#### `try_files`（单页应用路由）

```nginx
location / {
    try_files $uri $uri/ /index.html;
}
```

| 部分 | 含义 |
|---|---|
| `$uri` | 先找**同名文件**（如 `/logo.png`） |
| `$uri/` | 再找**同名目录** |
| `/index.html` | 都没有 → 返回 `index.html` |

**为什么需要**：React 是**单页应用（SPA）**，路由由 JavaScript 在前端处理。

- 用户访问 `/notes/123`，Nginx 在磁盘上找不到这个文件
- 没有 `try_files` → **返回 404**
- 有 `try_files` → 返回 `index.html`，React 加载后自己解析路由，正确显示页面

## 6.4 生成 HTTPS 自签证书

**在服务器上执行**：

```bash
cd /srv/light-memo/certs

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout server.key \
  -out server.crt \
  -subj "/C=CN/ST=Guangdong/L=Shenzhen/O=LightMemo/CN=111.230.141.73" \
  -addext "subjectAltName=IP:111.230.141.73"

chmod 600 server.key
```

### 逐参数解释

| 参数 | 含义 |
|---|---|
| `req` | 处理证书请求（request） |
| `-x509` | 生成**自签证书**（而不是证书签名请求 CSR） |
| `-nodes` | **No DES**，不加密私钥（否则每次 Nginx 启动都要输密码） |
| `-days 3650` | 有效期 3650 天（约 10 年） |
| `-newkey rsa:2048` | 同时生成新的 2048 位 RSA 私钥 |
| `-keyout server.key` | 私钥输出文件 |
| `-out server.crt` | 证书输出文件 |
| `-subj "..."` | **非交互式**填写证书信息（否则会一个个问你） |
| `-addext "subjectAltName=IP:..."` | 添加扩展字段，声明此证书对**这个 IP** 有效 |

**`-subj` 各字段**：

| 字段 | 含义 | 我们的值 |
|---|---|---|
| `C` | Country 国家 | CN |
| `ST` | State 省 | Guangdong |
| `L` | Locality 城市 | Shenzhen |
| `O` | Organization 组织 | LightMemo |
| `CN` | Common Name 通用名 | 111.230.141.73 |

### ⭐ 为什么必须加 `subjectAltName`

**现代浏览器和程序不再认可 CN 字段**，只认 SAN（Subject Alternative Name）。

不加 `-addext "subjectAltName=IP:..."` 的话，访问时会报：

```
SSL: certificate subject name '111.230.141.73' does not match target host name
```

**注意是 `IP:` 而不是 `DNS:`** —— 因为我们的地址是 IP 不是域名。

### `chmod 600 server.key`

```bash
chmod 600 server.key
```

| 数字 | 权限 |
|---|---|
| 6 | 拥有者：读 + 写 |
| 0 | 组：无权限 |
| 0 | 其他人：无权限 |

**私钥泄露 = 别人可以冒充你的网站**，所以必须只有 root 能读。

### 验证证书

```bash
openssl x509 -in server.crt -noout -subject -dates -ext subjectAltName
```

**预期输出**：

```
subject=C = CN, ST = Guangdong, L = Shenzhen, O = LightMemo, CN = 111.230.141.73
notBefore=Oct 15 12:00:00 2026 GMT
notAfter=Oct 12 12:00:00 2036 GMT
X509v3 Subject Alternative Name:
    IP Address:111.230.141.73          ← 确认有这个
```

### 为什么用自签证书

| 方案 | 适用 |
|---|---|
| Let's Encrypt | **需要域名**，不签 IP 地址 |
| 云厂商免费证书 | 同样需要域名 |
| **自签证书** | ✅ 适用于 IP 访问 |

**自签的代价**：浏览器会显示「不安全」警告（因为证书不是受信任的机构签发的）。但**加密是真实有效的** —— 数据传输仍然加密，只是无法验证服务器身份。

**进入网站时会看到警告，点「高级」→「继续前往」即可。**

---

# 第七章 首次手动部署

> **目标**：先用最笨的方法确认一切正常，再上自动化。

## 7.1 构建并启动

```bash
cd /srv/light-memo/src

# 构建镜像（首次较慢，约 3-10 分钟）
docker compose -p light-memo build

# 启动
docker compose -p light-memo up -d
```

### 命令解释

**`docker compose build`**

读取 `Dockerfile` 构建镜像。

| 部分 | 含义 |
|---|---|
| `-p light-memo` | 项目名，决定了容器名前缀和卷名 |
| `build` | 构建所有服务的镜像 |

**`docker compose up -d`**

| 部分 | 含义 |
|---|---|
| `up` | 创建并启动容器 |
| `-d` | detached，后台运行（不占用终端） |

**不加 `-d` 会怎样**：日志会刷屏，按 `Ctrl+C` 就停掉服务了。

### 预期输出

```
[+] Running 3/3
 ✔ Network light-memo_memo-net  Created
 ✔ Container memo-api            Started
 ✔ Container memo-web            Started
```

### 出错了怎么查

**如果卡在 build 很久然后失败**：

```bash
free -m    # 看内存
```

**2G 内存构建前端很可能 OOM（内存不足）**。解决办法：
- 加 swap：`fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
- 或者**不在服务器上构建**，改用 CI 构建（这正是我们后面要做的）

## 7.2 获取初始密码

后端首次启动时，如果数据库为空，会初始化一个密码。

```bash
docker compose -p light-memo logs api | grep -i -E "password|密码"
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `logs` | 查看容器日志 |
| `api` | 服务名 |
| `\| grep -i -E "password\|密码"` | 过滤，`-i` 忽略大小写，`-E` 用正则 |

### 预期输出

```
初始化完成，管理员密码: xxxxxxxx
```

**⚠️ 立刻记下来** —— 日志可能被轮转清理。

## 7.3 ⭐ 冒烟测试

**「冒烟测试」** = 快速验证核心功能是否正常（名字来源于：硬件通电后如果冒烟，就不用继续测了）。

```bash
echo "1. 健康检查:";  curl -kfsS https://127.0.0.1/healthz; echo
echo "2. 首页:";      curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1/
echo "3. 未登录 API:"; curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1/api/v1/auth/session
echo "4. HTTP 跳转:";  curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://127.0.0.1/
```

### 命令解释

**`curl` 参数**：

| 参数 | 含义 |
|---|---|
| `-k` | insecure，忽略证书验证（自签证书必需） |
| `-f` | fail，HTTP 错误码时返回非零退出码 |
| `-s` | silent，不显示进度条 |
| `-S` | show-error，`-s` 时仍显示错误 |
| `-o /dev/null` | 丢弃响应体 |
| `-w '%{http_code}'` | 输出 HTTP 状态码 |
| `-w '%{redirect_url}'` | 输出重定向目标地址 |

**`-w` 格式串**：

| 占位符 | 含义 |
|---|---|
| `%{http_code}` | HTTP 状态码（200、404 等） |
| `%{redirect_url}` | 重定向的目标 URL |
| `\n` | 换行 |

### 预期输出

```
1. 健康检查:
{"status":"ok"}
2. 首页:
200
3. 未登录 API:
401
4. HTTP 跳转:
301 -> https://127.0.0.1/
```

### 四项都要符合预期才算成功

| # | 检查项 | 期望 | 说明 |
|---|---|---|---|
| 1 | 健康检查 | `{"status":"ok"}` | 后端活着 |
| 2 | 首页 | `200` | 前端页面能返回 |
| 3 | 未登录 API | **`401`** | **这是正常的！** 401 = 未授权，说明后端在工作，只是没登录 |
| 4 | HTTP 跳转 | `301 -> https://...` | 跳转配置生效 |

> **容易误解的一项**：第 3 项返回 401 **不是错误**。如果返回 200 反而有问题（说明不需要密码就能访问）。

### 出错了怎么查

| 现象 | 可能原因 | 排查命令 |
|---|---|---|
| 连接被拒绝 | 容器没起来 | `docker ps -a` |
| 健康检查非 200 | 后端启动失败 | `docker compose logs api` |
| 首页 502 | Nginx 连不上后端 | `docker compose logs web` |
| 首页 404 | 前端文件没打进镜像 | `docker exec memo-web ls /usr/share/nginx/html/` |
| SSL 错误 | 证书路径或权限问题 | `docker exec memo-web ls -l /etc/nginx/certs/` |

## 7.4 从外部访问测试

**在你自己的电脑上**：

```powershell
curl.exe -k https://111.230.141.73/healthz
```

**浏览器访问**：https://111.230.141.73

**会看到证书警告**（自签证书的正常现象）→ 点「高级」→「继续前往」。

### 如果外部访问不通，但服务器内 `curl 127.0.0.1` 正常

**问题在防火墙**，按顺序检查：

```bash
# 1. 服务器本地防火墙
ufw status                    # Ubuntu 的防火墙
iptables -L -n | head -20     # 底层防火墙规则

# 2. 确认服务在监听（不是只监听 localhost）
ss -tlnp | grep -E ':(80|443)\s'
```

**关键看监听地址**：

| 输出 | 含义 |
|---|---|
| `0.0.0.0:80` | ✅ 监听所有网卡，外部可访问 |
| `127.0.0.1:80` | ❌ **只监听本地**，外部访问不到 |

**如果服务器上一切正常，问题就在云厂商的安全组**：

腾讯云控制台 → 轻量应用服务器 → 你的实例 → **防火墙** → 添加规则：

| 协议 | 端口 | 来源 |
|---|---|---|
| TCP | 80 | 0.0.0.0/0 |
| TCP | 443 | 0.0.0.0/0 |

---

# 第八章 配置 HTTPS

> 如果你的证书和 Nginx 配置在第六章已经写好，这一步只是重启生效。

## 8.1 重启使配置生效

```bash
cd /srv/light-memo/src
docker compose -p light-memo restart web
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `restart` | 重启指定服务 |
| `web` | 只重启 web，不动 api |

**为什么不 `up -d`**：`up -d` 会检查所有服务，可能重建容器。`restart` 只重启，更快且影响更小。

**为什么必须重启**：Nginx 的配置文件是**启动时读取**的，改文件不会自动生效。

## 8.2 验证 HTTPS 生效

```bash
curl -k -I https://127.0.0.1/
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `-I` | 只请求响应头（HEAD 请求），不下载内容 |

### 预期输出

```
HTTP/2 200
server: nginx
content-type: text/html
```

**看到 `HTTP/2`** 说明 HTTP/2 启用成功（比 HTTP/1.1 更快）。

## 8.3 检查证书信息

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername 111.230.141.73 2>/dev/null | openssl x509 -noout -subject -dates -ext subjectAltName 2>/dev/null
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `echo \|` | 输入一个空行（`openssl s_client` 会等待输入） |
| `openssl s_client -connect host:port` | 作为客户端连接，建立 TLS 握手 |
| `-servername` | SNI 字段，告诉服务器我们想访问哪个主机 |
| `2>/dev/null` | 丢弃握手过程的大量输出 |
| `\| openssl x509 -noout ...` | 把证书拿出来解析 |

### 预期输出

```
subject=C = CN, ST = Guangdong, L = Shenzhen, O = LightMemo, CN = 111.230.141.73
notAfter=Oct 12 12:00:00 2036 GMT
X509v3 Subject Alternative Name:
    IP Address:111.230.141.73
```

**确认 `IP Address:111.230.141.73` 存在** —— 没有它浏览器会报证书不匹配。

---

# 第九章 编写自动部署脚本

> **目标**：把部署步骤固化成一个脚本，让 CI 和手动执行走同一套流程。

## 9.1 为什么需要脚本

**如果直接把命令写在 workflow 里**：

| 问题 | 说明 |
|---|---|
| 无法手动执行 | 想手动部署时，得从 yml 里抄命令 |
| 难以调试 | CI 环境不好进去排查 |
| 逻辑分散 | workflow 和服务器配置割裂 |

**写成脚本后**：

| 好处 | 说明 |
|---|---|
| CI 调用 `bash deploy.sh` | 一行搞定 |
| 手动也能 `bash deploy.sh` | 同一套逻辑 |
| 可以在服务器上直接改和测试 | 调试方便 |

## 9.2 脚本内容

**文件**：`deploy/server-deploy.sh` → 部署到 `/srv/light-memo/deploy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${SRC_DIR:-/srv/light-memo/src}"
IMAGE_BASE="${IMAGE_BASE:?IMAGE_BASE 未设置}"
TAG="${TAG:-latest}"

echo "==> 开始部署"
echo "    目录: $SRC_DIR"
echo "    镜像: $IMAGE_BASE"
echo "    标签: $TAG"

cd "$SRC_DIR"

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

## 9.3 ⭐ 逐行详解

### `#!/usr/bin/env bash`

**Shebang（释伴行）** —— 告诉系统用哪个解释器执行这个文件。

**为什么用 `env bash` 而不是 `/bin/bash`**：

| 写法 | 问题 |
|---|---|
| `#!/bin/bash` | 硬编码路径，如果 bash 不在 `/bin` 就失败 |
| `#!/usr/bin/env bash` | 让 `env` 去 PATH 里找 bash，**兼容性更好** |

### `set -euo pipefail` ⭐⭐⭐

**这一行是整个脚本的生命线。拆开看是三个设置：**

| 设置 | 全称 | 作用 |
|---|---|---|
| `-e` | errexit | **任何命令失败（返回非零）就立即退出脚本** |
| `-u` | nounset | **使用未定义的变量就报错退出** |
| `-o pipefail` | pipefail | **管道中任一环节失败，整个管道就算失败** |

#### `-e` 为什么重要

**没有 `-e` 会发生什么**：

```bash
docker compose pull        # 失败！但没有 -e，继续往下走
docker compose up -d       # 用【旧镜像】重建了容器
echo "部署成功"            # 报告成功（假的！）
exit 0                     # 退出码 0，CI 显示绿色 ✅
```

**后果**：
1. 服务被**旧镜像**重启了一遍（可能短暂中断）
2. 你以为上线了，**其实没有**
3. **CI 显示成功，没人知道出了问题**

**有 `-e` 时**：

```bash
docker compose pull        # 失败 → 脚本立即在这里停止
                           # 后面的命令根本不执行
                           # 容器保持原样，服务不受影响
```

> **这就是为什么说「部署脚本最重要的品质不是能成功，而是失败时不出事」。**

**实测验证**（我们专门做过这个演练）：

```bash
IMAGE_BASE=ghcr.io/xxx TAG=不存在的标签 bash /srv/light-memo/deploy.sh
```

结果：脚本在「拉取镜像」这一步**立即停止**，容器显示 `Up 44 hours` —— **时间戳没变，说明从未被重启**。

#### `-u` 为什么重要

**没有 `-u`**：

```bash
rm -rf "$UNSET_VAR/"        # 变量为空 → 实际执行 rm -rf /  ⚠️ 灾难！
```

**有 `-u`**：变量未定义时立即报错退出，**不会执行危险的命令**。

#### `-o pipefail` 为什么重要

**默认行为**：管道的退出码是**最后一个命令**的退出码。

```bash
curl https://坏的地址 | grep "ok"     # curl 失败了，但 grep 可能返回 0
                                      # 整个管道被判定为「成功」！
```

**加 `-o pipefail` 后**：管道中任何一个失败，整个管道就算失败。

### `${IMAGE_BASE:?IMAGE_BASE 未设置}` ⭐

这个语法是**强制要求变量必须存在**：

| 语法 | 行为 |
|---|---|
| `${VAR:-默认值}` | 变量为空时用默认值 |
| `${VAR:?错误信息}` | **变量为空时，打印错误信息并退出** |

**为什么这样写**：`IMAGE_BASE` 是必须的（决定从哪拉镜像）。如果忘传，脚本会**明确报错**，而不是用一个空值去拼出一个错误的镜像地址。

**对比**：

```bash
# 用 :- 的话，忘了传 IMAGE_BASE
docker compose pull    # 会尝试拉 "/memo-api:latest" → 报一个看不懂的错
```

```bash
# 用 :? 的话
# 直接报：IMAGE_BASE 未设置
# 一目了然
```

### `cd "$SRC_DIR"`

**为什么要 cd**：`docker compose` 会读取**当前目录**的 `docker-compose.yml`。

**为什么要加引号**：如果变量值含空格，不加引号会被拆成多个参数：

```bash
cd $DIR      # DIR="/srv/my dir" → cd /srv/my dir  ❌ 报错
cd "$DIR"    # DIR="/srv/my dir" → cd "/srv/my dir"  ✅ 正确
```

> **Shell 脚本铁律**：**永远给变量加双引号**。

### `if [ -n "${GHCR_TOKEN:-}" ]`

| 部分 | 含义 |
|---|---|
| `[ ... ]` | 测试条件（等同于 `test` 命令） |
| `-n` | non-zero，字符串**非空**时为真 |
| `-z` | zero，字符串**为空**时为真 |
| `${GHCR_TOKEN:-}` | 取变量，为空时用空字符串（**配合 `-u` 防止报错**） |

**为什么需要 `${VAR:-}`**：因为我们设了 `set -u`，直接用 `$GHCR_TOKEN` 在变量未定义时会报错退出。加 `:-` 提供默认空值，就能安全地判断。

**这段的作用**：如果提供了 Token 就登录（**私有镜像需要**）；公开镜像不需要，跳过。

### `echo "$GHCR_TOKEN" | docker login --password-stdin`

| 部分 | 含义 |
|---|---|
| `echo "$GHCR_TOKEN"` | 输出 Token |
| `\|` | 管道传给下一个命令 |
| `docker login --password-stdin` | 从**标准输入**读取密码 |

**为什么不用 `--password`**：

```bash
docker login -p "我的密码"     # ❌ 密码出现在命令历史里
                              # ❌ 出现在 ps 进程列表里，其他用户能看到
```

**`--password-stdin` 更安全** —— 密码不经过命令行参数。

### `docker compose up -d --remove-orphans`

| 部分 | 含义 |
|---|---|
| `up -d` | 创建并启动容器（后台） |
| `--remove-orphans` | 删除**孤儿容器** |

**什么是孤儿容器**：之前在这个 compose 项目里创建，但现在 `docker-compose.yml` 里已经没有定义的容器。

**举例**：你删掉了 compose 里的 `cache` 服务，但容器还在。下次 `up` 时加 `--remove-orphans` 就会把它清理掉。

**⚠️ 安全吗**：**安全**。它只清理**属于当前 compose 项目**的容器，**不会碰其他项目的**。

**实测证据**：我们部署了 4 次，1Panel 的 `mysql` 和 `zabbix` 容器始终是 `Up 38 hours`，**时间戳完全没变**。

### 健康检查循环

```bash
for i in $(seq 1 30); do
  code=$(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1/healthz || true)
  if [ "$code" = "200" ]; then
    echo "==> 部署成功"
    exit 0
  fi
  sleep 2
done
```

**逐部分解释**：

| 部分 | 含义 |
|---|---|
| `for i in $(seq 1 30)` | 循环 30 次（`seq 1 30` 生成 1 到 30 的序列） |
| `code=$(...)` | **命令替换**：把命令的输出赋值给变量 |
| `curl ... \|\| true` | **即使失败也返回成功**，防止 `set -e` 让脚本退出 |
| `[ "$code" = "200" ]` | 比较字符串（注意 `=` 两边要有空格） |
| `exit 0` | 成功退出，**跳出脚本** |
| `sleep 2` | 等 2 秒再试 |

**总等待时间**：30 次 × 2 秒 = **60 秒**。

**为什么要 `|| true`**：服务刚启动时 `curl` 会失败（连接被拒绝）。如果没有 `|| true`，`set -e` 会让脚本**立即退出**，我们就等不到服务启动完成了。

**为什么用 HTTPS 而不是 HTTP**：**第 6.3 节讲过的坑** —— 80 端口只返回 301，检查会失败。

### 失败时输出日志

```bash
echo "!! 健康检查超时，输出日志："
docker compose -p light-memo logs --tail=50 api
docker compose -p light-memo logs --tail=50 web
exit 1
```

| 部分 | 含义 |
|---|---|
| `logs --tail=50` | 只看最后 50 行 |
| `exit 1` | **非零退出码**，让 CI 标记为失败 |

**为什么要输出日志**：CI 环境你进不去。**把日志打出来，出问题时能直接在 CI 页面看到原因**。

**`exit 1` 必须写**：如果脚本最后一条命令成功，退出码会是 0，**CI 会显示绿色**，但实际上部署失败了。

## 9.4 部署脚本到服务器

```bash
# 服务器上
install -m 755 /srv/light-memo/src/deploy/server-deploy.sh /srv/light-memo/deploy.sh
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `install` | 复制文件**并设置属性**（比 `cp` + `chmod` 更简洁） |
| `-m 755` | mode，设置权限 |
| 源文件 | 仓库里的脚本 |
| 目标 | `/srv/light-memo/deploy.sh` |

**`755` 权限含义**：

| 数字 | 拥有者 | 组 | 其他人 |
|---|---|---|---|
| 7 | 读+写+执行 | | |
| 5 | | 读+执行 | |
| 5 | | | 读+执行 |

**必须有执行位（`x`）**，否则脚本无法运行。

## 9.5 ⭐ 故障演练（部署前必做）

> **部署脚本最重要的品质不是「能成功」，而是「失败时不出事」。**

### 演练方法

**故意用一个不存在的镜像标签**：

```bash
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=test-notexist bash /srv/light-memo/deploy.sh
```

### 预期输出

```
==> 开始部署
    目录: /srv/light-memo/src
    镜像: ghcr.io/moyongdian/light-memo-deploy
    标签: test-notexist
==> 拉取镜像
[+] Pulling 2/2
 ! api Warning Head "https://ghcr.io/v2/...": denied
2 errors occurred:
	* Error response from daemon: ... denied
（脚本在这里停止，没有执行 up -d）
```

### ⭐ 验证失败没有影响线上

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

**关键**：

```
memo-web   Up 44 hours      ← 时间戳没变！
memo-api   Up 44 hours      ← 说明容器从未被重启
```

**如果时间变成 `Up 30 seconds`**，说明脚本**错误地重启了服务** —— 那就是 bug。

### 这次演练的价值

**如果脚本没有 `set -e`**，会发生：

| 步骤 | 行为 |
|---|---|
| 1 | `docker compose pull` 失败 |
| 2 | 但脚本继续执行 `docker compose up -d` |
| 3 | **用旧镜像重建了容器** → 服务短暂中断 |
| 4 | 脚本返回退出码 0 |
| 5 | **CI 显示绿色 ✅，你以为部署成功了** |

**这比直接报错危险得多** —— 报错至少你知道出了问题。

### 关于 `denied` 错误

```
Error response from daemon: Head "https://ghcr.io/v2/...": denied
```

**`denied` 而不是 `not found`**：

| 响应 | 含义 |
|---|---|
| `denied` | 镜像**不存在** 或 **没有访问权限** |
| `not found` | Docker Hub 常见，GitHub 通常用 `denied` |

**GHCR 故意用 `denied` 混淆这两种情况** —— 这是安全设计，避免攻击者通过报错信息探测私有镜像是否存在。

**如果确认镜像存在却报 `denied`**，那是**权限问题**：

| 原因 | 解决 |
|---|---|
| 镜像是私有包 | 到 GitHub → Packages → 改成 Public |
| 需要登录 | 配置带 `read:packages` 权限的 Token |

**包可见性和仓库可见性是独立设置的** —— 公开仓库的包**默认也是公开的**（我们的情况），但私有仓库的包默认私有。

---

# 第十章 配置 SSH 密钥

> **目标**：让 GitHub Actions 能免密登录服务器。

## 10.1 为什么用密钥而不是密码

| 方式 | 安全性 | CI 中的可行性 |
|---|---|---|
| 密码 | 弱，可被暴力破解 | 需要把密码存在 Secrets 里，泄露风险高 |
| **SSH 密钥** | 强，几乎无法破解 | ✅ 标准做法 |

## 10.2 生成密钥对

**在你的电脑上（PowerShell）**：

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\light_memo_ci" -N '""' -C "github-actions-deploy"
```

### 逐参数解释

| 参数 | 含义 |
|---|---|
| `-t ed25519` | 密钥类型 |
| `-f 路径` | 输出文件路径 |
| `-N '""'` | 空密码短语（**CI 用必须为空**，否则要交互输入） |
| `-C "注释"` | 注释，用来标识这把密钥的用途 |

### ⭐ 为什么用 ed25519 而不是 RSA

| 算法 | 密钥长度 | 安全性 | 速度 |
|---|---|---|---|
| RSA 2048 | 2048 位 | 良好 | 较慢 |
| RSA 4096 | 4096 位 | 很好 | 慢 |
| **ED25519** | **256 位** | **更好** | **最快** |

**ed25519 用更短的密钥达到更高的安全性**，而且签名验证速度快得多。**现代首选**。

### 生成的文件

| 文件 | 内容 | 能否公开 |
|---|---|---|
| `light_memo_ci` | **私钥** | ❌ **绝对不能泄露** |
| `light_memo_ci.pub` | 公钥 | ✅ 可以公开 |

> **类比**：公钥是锁，私钥是钥匙。锁可以随便给人，钥匙必须自己保管。

## 10.3 把公钥安装到服务器

**在服务器上执行**：

```bash
# 确保目录存在且权限正确
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# 追加公钥（把下面的内容替换成你实际的公钥）
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... github-actions-deploy" >> /root/.ssh/authorized_keys

# 设置权限
chmod 600 /root/.ssh/authorized_keys
```

### ⚠️ 权限为什么必须严格

**SSH 会检查权限，不符合要求就拒绝使用**：

| 文件 | 必须的权限 | 如果太开放 |
|---|---|---|
| `~/.ssh` | `700` | SSH 拒绝使用该目录 |
| `authorized_keys` | `600` | SSH 拒绝使用该文件 |

**报错信息**：

```
Authentication refused: bad ownership or modes for directory /root/.ssh
```

**为什么这样设计**：如果 `authorized_keys` 是所有人可写的，**任何用户都能给自己加一把钥匙**，那密钥认证就失去意义了。

### 查看公钥内容

**在本地 PowerShell**：

```powershell
Get-Content "$env:USERPROFILE\.ssh\light_memo_ci.pub"
```

**输出格式**：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... github-actions-deploy
     ↑                ↑                          ↑
   算法类型        公钥内容（这行要复制）        注释
```

## 10.4 验证密钥可用 ⭐

```powershell
ssh -i "$env:USERPROFILE\.ssh\light_memo_ci" root@111.230.141.73 'echo 连接成功'
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `-i 文件` | identity file，指定用哪个私钥 |
| `'echo 连接成功'` | 登录后执行的命令 |

### 预期输出

```
连接成功
```

### 出错了怎么查

**加 `-v` 看详细握手过程**：

```powershell
ssh -v -i "$env:USERPROFILE\.ssh\light_memo_ci" root@111.230.141.73
```

**关注这几行**：

| 输出 | 含义 |
|---|---|
| `Offering public key: ...` | 本地密钥已提供 |
| `Server accepts key: ...` | ✅ 服务器接受了 |
| `Permission denied (publickey)` | ❌ 密钥不匹配 |
| `Connection timed out` | ❌ 网络/防火墙问题 |

**如果是 `Permission denied`**，检查：

```bash
# 服务器上：确认公钥在列表里
cat /root/.ssh/authorized_keys | awk '{print $NF}'    # 只看注释

# 确认权限
ls -ld /root/.ssh && ls -l /root/.ssh/authorized_keys
# 应该是 drwx------ 和 -rw-------
```

## 10.5 ⭐ 密钥轮换的正确顺序

**如果你要撤销旧密钥，必须按这个顺序**：

```
1. 生成新密钥
      ↓
2. 安装新公钥到服务器
      ↓
3. 验证新密钥可用          ← ⚠️ 关键，不能跳过
      ↓
4. 撤销旧密钥
      ↓
5. 验证旧密钥确实失效
```

### 为什么这个顺序

**如果先撤销旧的**：
- 新密钥还没装好或有问题
- **你就完全连不上服务器了**
- 只能通过云厂商控制台的 VNC 救援

> **这条原则适用于所有凭据轮换**：**先建立替代通道，再撤销旧通道。**
>
> 永远不要「先断后接」。

### 撤销密钥的命令

```bash
# 删除包含指定注释的行
sed -i '/workbuddy-deploy/d' /root/.ssh/authorized_keys

# 验证
cat /root/.ssh/authorized_keys | awk '{print $NF}'
```

### `sed` 命令解释

| 部分 | 含义 |
|---|---|
| `sed` | stream editor，流编辑器 |
| `-i` | in-place，直接修改文件（不加则只输出到屏幕） |
| `'/模式/d'` | `/模式/` 是地址，`d` 是 delete 动作 |
| `workbuddy-deploy` | 要匹配的文本 |
| 文件名 | 操作的文件 |

**`awk '{print $NF}'`**：`$NF` 表示**最后一个字段**（NF = Number of Fields）。公钥行的最后一段是注释，所以这样只显示注释，**不暴露密钥内容**。

---

# 第十一章 编写 GitHub Actions 工作流

## 11.1 workflow 文件的位置和结构

**位置**：项目的 `.github/workflows/` 目录

**为什么是这个位置**：GitHub 只扫描这个目录下的 `.yml` 文件，其他地方的不认。

## 11.2 完整内容

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
      packages: write
    outputs:
      image-base: ${{ steps.vars.outputs.image-base }}
      tag: ${{ steps.vars.outputs.tag }}
    steps:
      - uses: actions/checkout@v4

      - name: 计算镜像名和标签
        id: vars
        run: |
          echo "image-base=ghcr.io/$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_OUTPUT"
          echo "tag=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"

      - name: 开启 BuildKit 缓存
        uses: docker/setup-buildx-action@v3

      - name: 登录 GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: 构建并推送 memo-api
        uses: docker/build-push-action@v6
        with:
          context: ./backend
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
    if: ${{ vars.DEPLOY_ENABLED == 'true' }}
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

## 11.3 ⭐ 逐部分详解

### 触发条件

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
```

| 部分 | 含义 |
|---|---|
| `on:` | 定义触发条件 |
| `push:` | 推送代码时触发 |
| `branches: [main]` | **只在 main 分支**触发 |
| `workflow_dispatch:` | 允许在网页上**手动点击运行** |

**为什么要限定 main**：如果所有分支都触发，开发分支的每次推送都会**部署到生产环境**。

#### ⚠️ 一个常见的坑

```yaml
on:
  push:          # 没有 branches 限制
```

**这会匹配所有分支的推送。** 我们的项目里就有一个这样的旧 workflow（部署到 EdgeOne Pages），导致**每次推送都失败一次**，制造大量噪音。

**修复**：改成只有 `workflow_dispatch`（只手动触发），或者加上 `branches` 限制。

### 并发控制

```yaml
concurrency:
  group: deploy-docker
  cancel-in-progress: false
```

| 参数 | 含义 |
|---|---|
| `group` | 并发组的名字 |
| `cancel-in-progress: false` | **不取消**正在运行的，等它跑完 |

**如果两个部署同时跑会怎样**：两个流程都执行 `docker compose up -d`，可能：
- 互相覆盖对方的容器
- 服务器资源争抢
- 最终状态不确定

**为什么用 `false` 而不是 `true`**：部署不能中断。如果取消了正在进行的部署，服务可能处于**半完成状态**（比如镜像拉了但容器没起）。**宁可排队，不要中断**。

### Job 1：build

```yaml
build:
  runs-on: ubuntu-latest
  permissions:
    contents: read
    packages: write
```

| 参数 | 含义 |
|---|---|
| `runs-on: ubuntu-latest` | 在 GitHub 提供的 Ubuntu 机器上运行 |
| `contents: read` | 可以读仓库代码 |
| `packages: write` | **可以推送包到 GHCR**（必须，否则无权推送） |

**GitHub Actions 的权限模型**：默认权限是**只读**的。要推送镜像，必须**显式声明** `packages: write`。

**`outputs`（向其他 job 传递数据）**：

```yaml
outputs:
  image-base: ${{ steps.vars.outputs.image-base }}
  tag: ${{ steps.vars.outputs.tag }}
```

**为什么要传递**：`build` job 算出了镜像地址和标签，`deploy` job 需要**用同样的值**去拉镜像。

**job 之间默认不共享变量**，必须通过 `outputs` 显式传递。

### Step：计算镜像名和标签

```yaml
- name: 计算镜像名和标签
  id: vars
  run: |
    echo "image-base=ghcr.io/$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_OUTPUT"
    echo "tag=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
```

| 部分 | 含义 |
|---|---|
| `id: vars` | 给这个步骤起 ID，**后面用 `steps.vars.outputs.xxx` 引用** |
| `${{ github.repository }}` | GitHub 内置变量，格式 `用户名/仓库名` |
| `tr '[:upper:]' '[:lower:]'` | **转小写** |
| `${GITHUB_SHA::7}` | 取 commit SHA 的**前 7 位** |
| `>> "$GITHUB_OUTPUT"` | 写入 GitHub 的输出文件 |

#### ⭐ 为什么要转小写

**GHCR 要求镜像名必须全小写。**

如果 GitHub 用户名是 `MoyongDian`（含大写），直接拼接会得到 `ghcr.io/MoyongDian/...`，推送时报错：

```
invalid reference format: repository name must be lowercase
```

`tr` 命令是 translate，把大写字符集映射到小写字符集。

#### ⭐ `${GITHUB_SHA::7}` 的双冒号语法

这是 Bash 的**字符串切片**：

```bash
${变量::7}     # 从开头取 7 个字符
```

**为什么用 SHA 前 7 位做标签**：这是 **Git 的惯例**。`git log --oneline` 显示的就是 7 位短 SHA，便于对照。

**完整 SHA** 是 40 位（如 `36f8cf7a1b2c3d4e5f6...`），前 7 位通常已足够唯一。

#### `>> "$GITHUB_OUTPUT"` 的作用

**这是 GitHub Actions 传递数据的机制**：

```
写入格式：变量名=值
写入位置：$GITHUB_OUTPUT 指向的文件
```

**旧写法已废弃**：

```bash
echo "::set-output name=tag::abc"     # ❌ 已弃用（有安全问题）
```

**新写法**：

```bash
echo "tag=abc" >> "$GITHUB_OUTPUT"    # ✅ 推荐
```

### Step：登录 GHCR

```yaml
- name: 登录 GHCR
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
```

| 参数 | 含义 |
|---|---|
| `registry: ghcr.io` | 目标镜像仓库地址 |
| `username: ${{ github.actor }}` | 触发这次运行的用户名 |
| `password: ${{ secrets.GITHUB_TOKEN }}` | **GitHub 自动提供的临时 Token** |

#### ⭐ `GITHUB_TOKEN` 和 `GHCR_TOKEN` 的区别

| Token | 来源 | 用途 |
|---|---|---|
| `secrets.GITHUB_TOKEN` | **GitHub 自动发放**，每次运行都是新的 | 在 **Actions 环境内**认证 |
| 自己创建的 PAT | 你手动创建 | 在 **Actions 环境外**认证（比如服务器上） |

**关键点**：`secrets.GITHUB_TOKEN` **只在 Actions 运行期间有效**，**不能拿到服务器上用**。

#### ⚠️ 这里踩过一个坑

我们最初写的是 `password: ${{ secrets.GHCR_TOKEN }}`，但**这个 Secret 根本没配置**。

**GitHub 的行为**：引用不存在的 Secret **不会报错**，而是变成**空字符串**。

**后果**：`docker login` 收到空密码，**静默失败或跳过登录**，后面的推送才报错，**错误信息离真正的原因很远**。

**修复**：改用自动发放的 `secrets.GITHUB_TOKEN`。

> **教训**：Secret 名字写错不会报错，只会得到一个空值。**配置完要核对名字的拼写。**

### ⭐ 双镜像标签（回滚的基础）

```yaml
tags: |
  ${{ steps.vars.outputs.image-base }}/memo-api:latest
  ${{ steps.vars.outputs.image-base }}/memo-api:${{ steps.vars.outputs.tag }}
```

**同一个镜像打两个标签**：

| 标签 | 值示例 | 用途 |
|---|---|---|
| `latest` | `latest` | 日常部署（始终指向最新） |
| SHA 标签 | `36f8cf7` | **精确回滚**（永久指向那个版本） |

**为什么两个都要**：

| 场景 | 只用 latest | 有 SHA 标签 |
|---|---|---|
| 日常部署 | ✅ | ✅ |
| 回滚到上一版 | ❌ 不可能（latest 已经指向新版） | ✅ `TAG=<旧sha>` |

**这是生产环境的标配设计。**

### ⭐ `cache-from` / `cache-to`（构建缓存）

```yaml
cache-from: type=gha,scope=memo-api
cache-to: type=gha,mode=max,scope=memo-api
```

| 参数 | 含义 |
|---|---|
| `type=gha` | 缓存在 **GitHub Actions 的缓存服务**里 |
| `mode=max` | 缓存**所有层**（不只是最终镜像） |
| `scope=memo-api` | 缓存**命名空间**，区分不同镜像 |

**为什么要 `scope`**：两个镜像都用 gha 缓存，如果不区分 scope，**它们会互相覆盖**，缓存失效。

**效果**：第二次构建时，没变的层直接复用缓存。实测把构建时间从几分钟降到几十秒。

### `build-args`（构建参数）

```yaml
build-args: |
  VITE_API_BASE_URL=${{ vars.SITE_URL }}
```

**含义**：把 `SITE_URL` 作为构建参数传给 Dockerfile。

#### ⭐ 为什么前端需要构建参数

**Vite 的工作方式**：构建时把 `import.meta.env.VITE_*` **静态替换**成字面值，打包进 JS 文件。

```javascript
// 源码
const apiUrl = import.meta.env.VITE_API_BASE_URL;

// 构建后变成（直接替换成字面值）
const apiUrl = "https://111.230.141.73";
```

**所以**：**前端代码编译后就不能改 API 地址了**，必须**在构建时**就确定。

**这就是为什么它是 `build-args` 而不是运行时环境变量。**

#### `vars` vs `secrets`

| 类型 | 用途 | 加密 | 日志中 |
|---|---|---|---|
| `vars.XXX` | 普通变量（如网站地址） | ❌ 不加密 | 正常显示 |
| `secrets.XXX` | 敏感信息（如密钥） | ✅ 加密 | **自动打码成 `***`** |

**`SITE_URL` 用 `vars`** —— 它不是秘密（用户浏览器里就能看到），而且**需要明文**才能正确编译进代码。

### Job 2：deploy

```yaml
deploy:
  needs: build
  runs-on: ubuntu-latest
  if: ${{ vars.DEPLOY_ENABLED == 'true' }}
```

| 参数 | 含义 |
|---|---|
| `needs: build` | **等 build 成功后才运行** |
| `if: ...` | **条件执行** |

#### `needs` 的作用

**形成依赖关系**：

```
build 失败 → deploy 自动跳过（不执行）
build 成功 → deploy 才开始
```

**如果不加 `needs`**：两个 job **并行**运行。deploy 会在镜像还没构建好时就去拉取，**必然失败**。

#### `if` 条件开关的作用

`vars.DEPLOY_ENABLED == 'true'` —— **只有这个变量等于 `true` 才部署**。

**用途**：
1. **第一次跑**：先设 `false`，只验证构建部分，确认镜像能推上去
2. **服务器还没准备好**：不会因为部署失败而让整个流程变红
3. **紧急停止**：线上出问题时，改成 `false` 就能阻止自动部署

> **注意**：变量值必须**恰好**是 `'true'`。`True`、`TRUE`、`yes` 都**不匹配**（字符串比较区分大小写）。

#### `envs` 参数（很关键）

```yaml
      - name: 拉取新镜像并重启
        uses: appleboy/ssh-action@v1.0.3
        env:
          IMAGE_BASE: ${{ needs.build.outputs.image-base }}
          TAG: ${{ needs.build.outputs.tag }}
        with:
          ...
          envs: IMAGE_BASE,TAG
```

**⚠️ 这里必须写两次**：

| 位置 | 作用 |
|---|---|
| `env:` | **在 SSH action 内部**设置环境变量 |
| `with: envs: IMAGE_BASE,TAG` | **告诉 action 把这些变量传送到远程服务器** |

**只写 `env:` 不写 `envs:`**：变量只在 actions 运行的机器上存在，**远程服务器上拿不到**，脚本会报 `IMAGE_BASE 未设置`。

**这是 `appleboy/ssh-action` 特有的设计** —— 需要显式声明要传哪些变量。

#### `command_timeout: 10m`

**默认超时是 10 分钟**，但部署可能更久（拉镜像慢）。显式设置更安全。

#### `script` 部分

```yaml
          script: |
            set -e
            export IMAGE_BASE TAG
            bash /srv/light-memo/deploy.sh
```

| 行 | 作用 |
|---|---|
| `set -e` | 任一命令失败就退出 |
| `export IMAGE_BASE TAG` | **把变量导出为环境变量**，让子进程（deploy.sh）能读到 |
| `bash /srv/light-memo/deploy.sh` | 执行部署脚本 |

**为什么需要 `export`**：`appleboy/ssh-action` 设置的变量默认是**shell 变量**，不是**环境变量**。**子进程只能继承环境变量**，所以必须 `export`。

### Step：同步文件（scp-action）

```yaml
      - name: 同步编排文件与 Nginx 配置
        uses: appleboy/scp-action@v0.1.7
        with:
          source: "docker-compose.yml,deploy/nginx/,deploy/docker-compose.override.yml,deploy/server-deploy.sh"
          target: ${{ secrets.SERVER_DIR }}
```

| 参数 | 含义 |
|---|---|
| `source` | 要传输的文件/目录（**逗号分隔**） |
| `target` | 服务器上的目标目录 |

#### ⚠️ 这里踩过一个大坑

**最初的 source 是**：

```yaml
source: "docker-compose.yml,deploy/nginx/"
```

**漏掉了 `deploy/docker-compose.override.yml`。**

**后果**：
- CI 用新的 `docker-compose.yml` 覆盖服务器上的（**只有 80 端口**）
- 但服务器上的 override 文件**还在**（我们手动放上去的）
- **短期不出问题** —— compose 仍然会读取旧的 override

**但当以下情况发生时，443 端口会静默消失**：
- 有人重新 clone 项目
- 有人清理了服务器目录
- 新服务器首次部署

**而且没有任何报错** —— HTTPS 直接不可用。

**修复**：把 override 加进 source 列表。

> **教训**：CI 同步的文件列表**必须和实际依赖的文件一致**。少传一个文件可能短期不报错，但埋下隐患。

#### 关于 `strip_components`

```yaml
strip_components: 0    # 保持目录结构
```

**含义**：传输时**剥掉路径的层数**。

| 值 | 效果 |
|---|---|
| `0` | 保持原样，`deploy/nginx/x.conf` → `<target>/deploy/nginx/x.conf` |
| `1` | 剥掉一层，`deploy/nginx/x.conf` → `<target>/nginx/x.conf` |

**用 `0`** 是为了保持目录结构，避免文件散落。

---

# 第十二章 配置 GitHub Secrets

## 12.1 打开配置页面

```
https://github.com/<用户名>/<仓库名>/settings/secrets/actions
```

本教程是：

```
https://github.com/moyongdian/light-memo-deploy/settings/secrets/actions
```

## 12.2 配置 Secrets（5 个）

点 **New repository secret**，逐个添加：

| Name | Value | 说明 |
|---|---|---|
| `SERVER_HOST` | `111.230.141.73` | 服务器 IP |
| `SERVER_USER` | `root` | 登录用户名 |
| `SERVER_PORT` | `22` | SSH 端口 |
| `SERVER_DIR` | `/srv/light-memo/src` | 文件同步目标目录 |
| `SERVER_SSH_KEY` | 私钥全文 | **见下** |

### `SERVER_SSH_KEY` 怎么填

**复制私钥文件的完整内容**：

```powershell
Get-Content "$env:USERPROFILE\.ssh\light_memo_ci" -Raw
```

**格式必须是**：

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDBiHhvxZQ4gl9PAGEuQtmBOPb+frNd4wUq4QRXPAlLQAAAAJhRQqfrUUKn
...（中间省略）...
9v5+s13jBSrhBFc8CUtAAAAAFWdpdGh1Yi1hY3Rpb25zLWRlcGxveQ==
-----END OPENSSH PRIVATE KEY-----
```

**⚠️ 三个必须注意的点**：

| 注意 | 后果 |
|---|---|
| **必须包含首尾的 `BEGIN` / `END` 行** | 缺失 → `error in libcrypto` |
| **必须完整，不能截断** | 截断 → `ssh: handshake failed` |
| **换行符必须是 LF** | CRLF → 认证失败 |

**验证方法**：粘贴后检查开头和结尾。

## 12.3 配置 Variables（2 个）

点 **Variables** 标签页，然后 **New repository variable**：

| Name | Value | ⚠️ 注意 |
|---|---|---|
| `SITE_URL` | `https://111.230.141.73` | **不带结尾斜杠** |
| `DEPLOY_ENABLED` | `true` | **必须恰好是 `true`** |

### `SITE_URL` 填错的后果

**这个值会被编译进前端代码**，填错会导致浏览器请求打到错误的地址。

| 写法 | 结果 |
|---|---|
| `https://111.230.141.73` | ✅ 正确 |
| `https://111.230.141.73/` | ❌ 多斜杠，拼出 `https://111.230.141.73//api/...` |
| `http://111.230.141.73` | ❌ **协议错**，浏览器会因混合内容被阻止，或 Cookie 丢失 |
| `111.230.141.73` | ❌ 缺协议，被当成相对路径 |

## 12.4 验证配置正确

**配置完先别急着 push**。检查清单：

| 检查项 | 怎么确认 |
|---|---|
| 5 个 Secrets 名字拼写正确 | 对照 12.2 的表格 |
| 私钥含 BEGIN/END | 打开看看首尾 |
| Variables 有 2 个 | 切到 Variables 标签看 |
| `DEPLOY_ENABLED` 是 `true` | 注意大小写 |

> **记住那个坑**：**Secret 名字写错不会报错，只会得到空值。**

---

# 第十三章 触发自动部署

## 13.1 推送代码

```bash
git add .
git commit -m "你的提交说明"
git push
```

## 13.2 观察运行状态

**打开**：

```
https://github.com/<用户名>/<仓库名>/actions
```

### 会看到什么

```
● Build & Deploy (Docker)
  #4  36f8cf7  main  已完成
```

**点进去**能看到两个 job 的实时状态：

```
✓ build        (2 分 10 秒)
✓ deploy       (1 分 57 秒)
```

**点开每个 job** 能看到**每一步**的状态和**实时日志**。

## 13.3 预期结果

**21 个步骤全绿**，总耗时约 **250 秒**（4 分钟）。

### build job 的步骤

| 步骤 | 做什么 |
|---|---|
| Set up job | 准备运行环境 |
| Run actions/checkout@v4 | 检出代码 |
| 计算镜像名和标签 | 算出镜像地址和 SHA 标签 |
| 开启 BuildKit 缓存 | 启用构建缓存 |
| 登录 GHCR | 认证到镜像仓库 |
| 构建并推送 memo-api | 构建后端镜像 |
| 构建并推送 memo-web | 构建前端镜像 |
| Post ...（若干） | 清理步骤 |

### deploy job 的步骤

| 步骤 | 做什么 |
|---|---|
| Build appleboy/scp-action | 准备 scp 工具 |
| Build appleboy/ssh-action | 准备 ssh 工具 |
| 同步编排文件与 Nginx 配置 | **传输文件到服务器** |
| 拉取新镜像并重启 | **执行部署脚本** |

## 13.4 ⭐ 验证服务器真的更新了

**CI 显示成功，不代表服务器真的更新了。必须实际验证。**

**在服务器上执行**：

```bash
docker inspect memo-web --format '{{.Config.Image}}'
```

### 预期输出

```
ghcr.io/moyongdian/light-memo-deploy/memo-web:36f8cf7
```

### ⭐ 关键验证点

**标签必须是你的 commit SHA**（这里是 `36f8cf7`）。

**怎么核对**：

```bash
git log --oneline -1
```

```
36f8cf7 docs: 交付完整的部署指南
```

**两个 SHA 一致** → 证明 CI 构建的镜像**真的部署到了服务器**。

### 更多验证

```bash
# 查看所有可用版本（应该有多个 SHA 标签）
docker images | grep light-memo-deploy

# 查看前端产物里编译进去的 API 地址
docker exec memo-web sh -c 'grep -rho "https://111.230.141.73" /usr/share/nginx/html/assets/*.js | head -1'
```

## 13.5 验证其他服务没被影响

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

**预期的关键点**：

```
memo-web                         Up 30 seconds     ← 我们的，刚重启
memo-api                         Up 35 seconds     ← 我们的，刚重启
1Panel-zabbix-server-hJqx-nginx  Up 38 hours       ← 别人的，时间没变 ✅
1Panel-mysql-YGhm                Up 38 hours       ← 别人的，时间没变 ✅
```

**如果 1Panel 的容器时间变了**，说明 `--remove-orphans` 出问题了 —— 但实际测试证明它**只影响当前项目**。

---

# 第十四章 回滚

## 14.1 什么是回滚

**回滚** = 把线上服务切回**之前的版本**。

**什么时候需要**：
- 新版本有 bug
- 新版本性能变差
- 需要时间排查，但线上不能一直坏着

## 14.2 为什么我们能快速回滚

**因为镜像标签用了 commit SHA**（第 11.3 节）：

```
ghcr.io/moyongdian/light-memo-deploy/memo-web:36f8cf7    ← 当前
ghcr.io/moyongdian/light-memo-deploy/memo-web:b0467fb    ← 上一个版本
ghcr.io/moyongdian/light-memo-deploy/memo-web:372feb8    ← 更早
```

**每个版本都还在服务器上，随时可以切回去。**

## 14.3 执行回滚

```bash
# 第 1 步：查看有哪些版本
docker images | grep light-memo-deploy

# 第 2 步：切换到指定版本
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=372feb8 bash /srv/light-memo/deploy.sh
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `IMAGE_BASE=...` | **临时**环境变量（只对这一条命令有效） |
| `TAG=372feb8` | **指定要部署的版本**（这里是旧版本的 SHA） |
| `bash /srv/light-memo/deploy.sh` | 同一个部署脚本 |

### ⭐ 回滚的本质

**回滚不需要特殊的机制** —— 它就是**用同一个部署脚本，换一个镜像标签**。

因为部署脚本用 `${TAG}` 变量决定拉哪个镜像：

```yaml
image: ${IMAGE_BASE}/memo-api:${TAG:-latest}
```

- `TAG=latest` → 部署最新版
- `TAG=372feb8` → **部署那个特定版本**

**这就是用 SHA 做标签的价值** —— 标签是**不可变的标识符**，永远指向那一次构建。

## 14.4 验证回滚成功

```bash
docker inspect memo-web --format '{{.Config.Image}}'
docker inspect memo-web --format '{{.Image}}'
```

### 预期输出

```
ghcr.io/moyongdian/light-memo-deploy/memo-web:372feb8       ← 标签变回旧版
sha256:ee2e3a648ff9462d97803eb196e290fbecb31128e9340b7a6d9f01cc3f26b607   ← 镜像 ID
```

### ⭐ 关键验证：镜像 ID 变了

**对比回滚前后**：

| 版本 | 镜像 ID |
|---|---|
| `b0467fb` | `sha256:ec539bb86aa86adfe2f5656191d5204673c5cb2025541211369578d51714a1dd` |
| `372feb8` | `sha256:ee2e3a648ff9462d97803eb196e290fbecb31128e9340b7a6d9f01cc3f26b607` |

**两个 ID 不同** → 证明**容器真的换了一个镜像在运行**，而不是只改了标签文字。

> **为什么要验证这个**：如果只是改了 compose 里的 `image:` 文本，但容器没重建，`docker inspect` 的标签会变但 ID 不变。**ID 变化才是真的换了版本。**

## 14.5 更直观的验证

**如果你的改动是可见的**（比如改了一行文案），可以直接看效果：

```bash
# 在新版本镜像里找这行文案
docker exec memo-web sh -c 'grep -l "你的新文案" /usr/share/nginx/html/assets/*.js'
```

- 有输出 → 是新版本
- 无输出（`未找到`）→ 是旧版本

**然后刷新浏览器**，界面上应该能看到差异。

---

# 第十五章 日常运维

## 15.1 状态总览脚本

**创建 `/tmp/memo-status.sh`**：

```bash
#!/bin/bash
echo "########## 容器状态 ##########"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "########## compose 项目 ##########"
docker compose ls -a

echo
echo "########## 端口监听 ##########"
ss -tlnp | grep -E ':(80|443|22)\s' || echo "(无)"

echo
echo "########## 冒烟测试 ##########"
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
```

**用法**：

```bash
bash /tmp/memo-status.sh
```

**一条命令看全貌。**

## 15.2 常用命令速查

### 查看状态

```bash
docker ps -a                                       # 所有容器
docker compose -p light-memo ps                     # 项目容器
docker compose -p light-memo top                    # 容器内进程
docker stats --no-stream                            # 资源占用快照
```

### 查看日志

```bash
cd /srv/light-memo/src

docker compose -p light-memo logs -f api            # 实时跟踪
docker compose -p light-memo logs --tail=100 web    # 最后 100 行
docker compose -p light-memo logs --since 1h api    # 最近 1 小时
```

| 参数 | 含义 |
|---|---|
| `-f` | follow，实时跟踪（`Ctrl+C` 退出） |
| `--tail=100` | 只显示最后 100 行 |
| `--since 1h` | 只显示最近 1 小时 |

### 重启服务

```bash
docker compose -p light-memo restart          # 重启全部
docker compose -p light-memo restart web      # 只重启 web
docker compose -p light-memo up -d            # 重新创建（配置改动后用）
```

**`restart` vs `up -d`**：

| 命令 | 行为 | 何时用 |
|---|---|---|
| `restart` | 重启现有容器 | 只改了应用逻辑 |
| `up -d` | 检查配置，必要时**重建**容器 | 改了 compose 或镜像 |

### 进入容器调试

```bash
docker exec -it memo-web sh                    # 进入容器
docker exec -it memo-api sh

# 容器内常用命令
ls /usr/share/nginx/html/                      # 看前端文件
cat /etc/nginx/conf.d/default.conf             # 看 nginx 配置
nginx -t                                       # 测试 nginx 配置语法
```

| 参数 | 含义 |
|---|---|
| `-i` | interactive，保持标准输入 |
| `-t` | tty，分配终端 |
| `sh` | 执行的命令（Alpine 用 sh，不用 bash） |

## 15.3 备份与恢复

### 查看现有备份

```bash
ls -lh /srv/backups/memo/
crontab -l | grep memo
```

### 手动备份

```bash
docker run --rm \
  -v light-memo_memo-data:/data:ro \
  -v /srv/backups/memo:/backup \
  alpine tar czf /backup/manual-$(date +%F-%H%M).tar.gz -C /data .
```

### ⭐ 恢复备份

**⚠️ 恢复会覆盖现有数据，操作前先备份当前数据。**

```bash
cd /srv/light-memo/src

# 第 1 步：停止服务
docker compose -p light-memo down

# 第 2 步：清空并解压备份
docker run --rm \
  -v light-memo_memo-data:/data \
  -v /srv/backups/memo:/backup \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/你的备份文件.tar.gz -C /data"

# 第 3 步：重新启动
docker compose -p light-memo up -d

# 第 4 步：验证
bash /tmp/memo-status.sh
```

## 15.4 清理磁盘空间

```bash
docker system df                    # 查看占用情况
docker system df -v                 # 详细（每个镜像/卷/容器）
```

### 清理命令

| 命令 | 清理什么 | 有风险吗 |
|---|---|---|
| `docker container prune` | 已停止的容器 | 低 |
| `docker image prune` | **悬空**镜像（无标签的） | 低 |
| `docker image prune -a` | **所有**未使用的镜像 | ⚠️ **会删掉回滚用的旧版本** |
| `docker volume prune` | 未使用的数据卷 | ⚠️ **可能删掉数据** |
| `docker builder prune` | 构建缓存 | 低 |

### ⚠️ 关于 `docker image prune -a`

**它会删除所有没有被容器使用的镜像**，包括你**用来回滚的旧版本**。

**推荐做法**：手动删除，保留最近 3～5 个版本：

```bash
# 查看所有版本（按时间倒序）
docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}' | grep light-memo-deploy

# 手动删除指定的旧版本
docker rmi ghcr.io/moyongdian/light-memo-deploy/memo-web:很旧的sha
```

---

# 第十六章 排错手册

## 16.1 四条核心排查原则

### 原则 1：不要用 `2>/dev/null` 掩盖错误 ⭐

**真实教训**：

```bash
# ❌ 这样写
docker --version 2>/dev/null || echo "Docker 未安装"
```

**输出**：

```
Docker 未安装        ← 完全错误！实际是权限问题
```

**如果去掉 `2>/dev/null`**：

```bash
docker --version
```

**真实输出**：

```
permission denied while trying to connect to the Docker daemon socket
at unix:///var/run/docker.sock
```

**真相大白** —— 是权限问题，不是没装。

**`2>/dev/null` 把「权限错误」伪装成了「未安装」**，导致排查方向完全错误（你会去重装 Docker，浪费大量时间）。

> **原则**：**让错误原样显示出来。**

### 原则 2：读原始数据，不要信中间层 ⭐

**真实教训**：

配置文件里的中文显示为乱码：

```
# ���ܵ�֤��
```

**看起来像是文件被写坏了。**

**用十六进制查看真实字节**：

```powershell
Format-Hex .gitignore | Select-Object -First 3
```

**结果**：

```
00000000  64 6F 63 73 2F 53 53 48  2D 4C 4F 47 49 4E 2D 58  docs/SSH-LOGIN-X
```

**文件完全正常**（UTF-8 编码）。

**真正的问题**：终端用 GBK 编码显示 UTF-8 内容。

> **原则**：**显示层的问题不等于文件层的问题。用 `Format-Hex`（Windows）或 `xxd`（Linux）看真实字节。**

### 原则 3：用退出码判断，不要用输出文本 ⭐

```bash
# ❌ 脆弱：依赖文本匹配，改一个字就失效
output=$(some_command)
if [[ "$output" == *"OK"* ]]; then
  echo "成功"
fi

# ✅ 可靠：基于退出码（0 = 成功，非 0 = 失败）
if some_command; then
  echo "成功"
fi
```

**为什么**：程序的**退出码**是标准契约，**输出文本**不是。

### 原则 4：加 `-v` 看细节

| 命令 | 作用 |
|---|---|
| `ssh -v ...` | 逐行看认证过程 |
| `curl -v ...` | 看完整的请求和响应头 |
| `docker compose --dry-run up` | 只显示会做什么，不实际执行 |
| `nginx -t` | 测试配置语法 |
| `bash -x script.sh` | 逐行跟踪脚本执行 |

## 16.2 按症状查找

### 症状：无法登录服务器

| 检查 | 命令 |
|---|---|
| 网络通不通 | `ping 111.230.141.73` |
| 22 端口通不通 | `telnet 111.230.141.73 22` |
| SSH 详情 | `ssh -v -i 密钥 root@IP` |
| 是否被封禁 | 云控制台 VNC 登录后 `fail2ban-client status sshd` |

**如果被 fail2ban 封了**：

```bash
fail2ban-client set sshd unbanip 你的IP
```

### 症状：网站打不开

**按顺序排查**：

```bash
# 1. 容器在跑吗
docker ps | grep memo

# 2. 服务在监听吗
ss -tlnp | grep -E ':(80|443)\s'
# 必须是 0.0.0.0:80，如果是 127.0.0.1:80 则外部访问不到

# 3. 服务器自己能访问吗
curl -kfsS https://127.0.0.1/healthz

# 4. 如果 3 正常但外部不行 → 防火墙问题
ufw status
```

**再看云厂商安全组**：控制台 → 防火墙 → 确认 80/443 对 `0.0.0.0/0` 开放。

### 症状：502 Bad Gateway

**含义**：Nginx 正常，但**连不上后端**。

```bash
# 看后端日志
docker compose -p light-memo logs --tail=50 api

# 看两者是否在同一网络
docker inspect memo-web --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'
docker inspect memo-api --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'
# 应该都是 light-memo_memo-net

# 测试 Nginx 能否解析 api 主机名
docker exec memo-web sh -c 'ping -c 1 api'
```

### 症状：部署脚本报「IMAGE_BASE 未设置」

**原因**：环境变量没传进来。

**检查 workflow 里的两处**：

```yaml
env:
  IMAGE_BASE: ...        # ← 这里
with:
  envs: IMAGE_BASE,TAG   # ← 和这里，两个都要有
```

### 症状：CI 报 `permission denied (publickey)`

| 原因 | 检查 |
|---|---|
| 私钥不完整 | 确认含 BEGIN/END 行 |
| 公钥没装 | 服务器上 `cat /root/.ssh/authorized_keys \| awk '{print $NF}'` |
| 权限不对 | `ls -ld /root/.ssh` 应为 `drwx------` |
| 换行符问题 | 私钥必须是 LF 换行 |

**本地先验证私钥可用**：

```powershell
ssh -i "$env:USERPROFILE\.ssh\light_memo_ci" root@111.230.141.73 'echo OK'
```

**本地能连但 CI 不能** → 说明复制到 Secrets 时**丢失或篡改了内容**（通常是没有 END 行）。

### 症状：拉取镜像报 `denied`

| 原因 | 解决 |
|---|---|
| 镜像是私有包 | GitHub → Packages → 改成 Public |
| 名字大小写问题 | GHCR 要求全小写 |
| 确实不存在 | 检查 CI 是否成功推送了 |

**验证镜像是否存在**：

```bash
docker manifest inspect ghcr.io/用户名/仓库/memo-api:标签
```

### 症状：CI 成功但服务器没更新

```bash
# 1. 检查 DEPLOY_ENABLED
#    GitHub → Settings → Variables，必须是 'true'

# 2. 看 deploy job 是否被跳过
#    Actions 页面里，跳过的 job 显示为灰色

# 3. 看容器用的镜像标签
docker inspect memo-web --format '{{.Config.Image}}'
```

### 症状：PowerShell 传文件报 `not in gzip format`

**原因**：用了管道传二进制（第 5.2 节）。

**修复**：分两步，先打包成文件再 `scp`。

### 症状：脚本报 `$'\r': command not found`

**原因**：文件是 Windows 换行（CRLF）。

**修复**：

```bash
sed -i 's/\r$//' 脚本.sh
```

**或预防**：在 `.gitattributes` 里加：

```
*.sh text eol=lf
```

---

# 附录

## A. 完整命令速查

### Docker

```bash
docker ps -a                                          # 所有容器
docker ps --format 'table {{.Names}}\t{{.Status}}'    # 格式化输出
docker images                                         # 镜像列表
docker volume ls                                      # 数据卷
docker network ls                                     # 网络

docker compose -p <项目> ps                            # 项目容器
docker compose -p <项目> logs -f <服务>                # 实时日志
docker compose -p <项目> up -d                         # 启动
docker compose -p <项目> down                          # 停止并删除
docker compose -p <项目> restart <服务>                # 重启

docker inspect <容器> --format '{{.Config.Image}}'     # 容器用的镜像
docker exec -it <容器> sh                              # 进入容器
docker system df                                      # 空间占用
```

### 系统

```bash
ss -tlnp | grep -E ':(80|443)\s'      # 端口占用
df -h /                               # 磁盘
free -m                               # 内存
systemctl status docker               # 服务状态
journalctl -u docker --since "1h ago" # 服务日志
```

### 网络测试

```bash
curl -kfsS https://127.0.0.1/healthz                    # 健康检查
curl -k -I https://127.0.0.1/                           # 只看响应头
curl -k -s -o /dev/null -w '%{http_code}' https://...   # 只看状态码
curl -s -o /dev/null -w '%{redirect_url}' http://...    # 看跳转目标
```

### Git

```bash
git log --oneline -5                                    # 最近 5 次提交
git filter-repo --path <文件> --invert-paths --force    # 从历史删除文件
git rev-list --all --objects | grep -i "<敏感词>"       # 检查历史残留
```

## B. 本次部署实测数据

| 指标 | 数值 |
|---|---|
| CI 总耗时 | 247 秒（约 4 分钟） |
| 后端镜像大小 | 20.3 MB |
| 前端镜像大小 | 49.3 MB |
| 服务器资源 | 2 核 2G，磁盘 40G（用 12G，30%） |
| 清理构建缓存回收 | 约 1.3 GB |
| 回滚耗时 | 约 30 秒 |
| 健康检查等待上限 | 60 秒 |
| CI 步骤总数 | 21 个 |

## C. 十条关键教训

| # | 教训 | 具体场景 |
|---|---|---|
| 1 | **`set -euo pipefail` 是脚本生命线** | 镜像拉取失败时立即停止，容器时间戳 44 小时未变 |
| 2 | **`git rm` 删不掉历史里的密钥** | 删除提交的 diff 里同样含密码，泄露点从 4 处变 12 处 |
| 3 | **不要用 `2>/dev/null` 掩盖错误** | 把 `permission denied` 误报成「未安装」 |
| 4 | **读原始数据，不信中间层** | 终端 GBK 乱码让人误判文件损坏，`Format-Hex` 一看便知 |
| 5 | **跨平台管道不能传二进制** | PowerShell `\|` 传对象，导致 `not in gzip format` |
| 6 | **先建立替代通道，再撤销旧通道** | 凭据轮换铁律，否则把自己锁在门外 |
| 7 | **部署脚本要演练失败路径** | 「失败时不出事」比「能成功」更重要 |
| 8 | **`expose` 不占宿主机端口** | 用它避开了与 Zabbix 的 8080 冲突 |
| 9 | **同一 commit 打两个镜像标签** | `sha` 用于精确回滚，`latest` 用于日常部署 |
| 10 | **改造前先确认无关服务不受影响** | 1Panel 的 mysql/zabbix 全程时间戳未变 |

## D. 文件清单

| 文件 | 作用 |
|---|---|
| `docker-compose.yml` | 容器编排基础配置 |
| `deploy/docker-compose.override.yml` | 服务器特有配置（443、证书） |
| `deploy/nginx/nginx.conf` | Nginx 配置（跳转、TLS、代理） |
| `deploy/server-deploy.sh` | 服务器端部署脚本 |
| `deploy/memo-status.sh` | 状态总览脚本 |
| `.github/workflows/deploy.yml` | GitHub Actions 工作流 |
| `/srv/light-memo/certs/` | HTTPS 证书 |
| `/srv/backups/memo/` | 数据备份 |

## E. 访问地址

| 项目 | 地址 |
|---|---|
| 网站 | https://111.230.141.73 |
| GitHub 仓库 | https://github.com/moyongdian/light-memo-deploy |
| Actions 运行记录 | https://github.com/moyongdian/light-memo-deploy/actions |
| Secret 配置 | https://github.com/moyongdian/light-memo-deploy/settings/secrets/actions |
| 镜像仓库 | https://github.com/moyongdian?tab=packages |
