# light-memo 部署实战：Docker + Nginx 部分

> **本文件从 [DEPLOY-GUIDE.md](DEPLOY-GUIDE.md) 中抽出，只讲 Docker 与 Nginx 的部署步骤。**
> 不含 GitHub Actions 自动部署（那部分见原文档第十至十四章）。
>
> 服务器：腾讯云 Ubuntu 22.04（2 核 2G / 40G 磁盘）
> 公网 IP：`111.230.141.73`
>
> 每一步都包含：**做什么 → 命令逐行解释 → 预期输出 → 如何验证 → 出错了怎么查**

---

# 目录

- [第一章 基础概念](#第一章-基础概念)
- [第二章 检查服务器现状](#第二章-检查服务器现状)
- [第三章 备份数据（不可跳过）](#第三章-备份数据不可跳过)
- [第四章 拆除旧环境](#第四章-拆除旧环境)
- [第五章 准备服务器环境](#第五章-准备服务器环境)
- [第六章 编写 docker-compose.yml](#第六章-编写-docker-composeyml)
- [第七章 编写 override 配置](#第七章-编写-override-配置)
- [第八章 编写 nginx.conf](#第八章-编写-nginxconf)
- [第九章 生成 HTTPS 证书](#第九章-生成-https-证书)
- [第十章 首次部署与验证](#第十章-首次部署与验证)
- [第十一章 部署脚本](#第十一章-部署脚本)
- [第十二章 日常运维](#第十二章-日常运维)
- [第十三章 排错手册](#第十三章-排错手册)
- [附录](#附录)

---

# 第一章 基础概念

> 这一章不执行命令，但**必须看懂**，否则后面的命令只是照抄。

## 1.1 Docker：把程序和运行环境打包在一起

**问题**：你的程序在本地能跑，传到服务器上却报错 —— 因为服务器上没装 Go、或者 Node 版本不对、或者缺某个系统库。

**Docker 的解法**：把「程序 + 它需要的一切依赖」打包成一个**镜像**（image），在任何装了 Docker 的机器上都能直接运行。

| 概念 | 类比 | 说明 |
|---|---|---|
| **镜像 image** | 光盘 | 只读的模板，包含程序和环境 |
| **容器 container** | 正在播放的光盘 | 镜像运行起来的实例 |
| **Dockerfile** | 制作光盘的说明书 | 描述怎么构建镜像 |
| **数据卷 volume** | 移动硬盘 | 容器删了数据还在，用于存数据库 |

**为什么容器删了数据会丢**：容器是临时的。要持久保存的数据必须放在**数据卷**里。

### Compose 是干什么的

一个项目通常有多个容器（我们的有两个：前端 Nginx + 后端 Go）。逐个 `docker run` 启动很麻烦，参数一多就乱。

**Docker Compose 用一份 YAML 描述所有服务**，一条命令全部启动：

```bash
docker compose up -d      # 启动所有服务
docker compose down       # 停止并删除所有服务
```

**关键概念：项目名（project name）**

Compose 会给资源加项目名前缀，避免不同项目的资源互相干扰：

| 资源 | 实际名字 |
|---|---|
| 容器 | `memo-web`（用 `container_name` 可自定义） |
| 数据卷 | `light-memo_memo-data` |
| 网络 | `light-memo_memo-net` |

用 `-p light-memo` 显式指定项目名，比依赖目录名更可靠。

## 1.2 Nginx：负责接收用户请求

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

### 反向代理 vs 正向代理

| 类型 | 谁在用 | 例子 |
|---|---|---|
| 正向代理 | **客户端**配置，代替客户端发请求 | 科学上网工具 |
| **反向代理** | **服务端**配置，客户端不知道 | Nginx 转发到后端 |

**我们用的是反向代理** —— 用户以为在跟 Nginx 说话，其实 Nginx 偷偷把请求转给了后端。

## 1.3 最终架构

```
                     ┌──────────── 服务器 111.230.141.73 ────────────┐
                     │                                               │
  浏览器              │   Docker 网络 light-memo_memo-net（内部）      │
 ┌────────┐ 80/443   │   ┌──────────────┐      ┌──────────────┐     │
 │ 用户   │ ────────►│   │   memo-web   │      │   memo-api   │     │
 └────────┘          │   │   (Nginx)    │─────►│   (Go 后端)   │     │
                     │   │  静态页面     │ :8080│  SQLite 数据  │     │
                     │   └──────────────┘      └───────┬──────┘     │
                     │          ▲                      │            │
                     │          │ /api/* 反代           ▼            │
                     │          │              light-memo_memo-data │
                     │          │              （数据卷，持久化）      │
                     └──────────┼───────────────────────────────────┘
                                │
                          宿主机 80 / 443
```

**三个要点**：

| 要点 | 说明 |
|---|---|
| `memo-web` 用 `ports` 映射到宿主机 80/443 | 对外提供服务的唯一入口 |
| `memo-api` 用 `expose` 只在容器网络内暴露 8080 | **不占用宿主机端口**，避免冲突 |
| 数据放独立的数据卷 | 容器重建不影响数据 |

## 1.4 为什么要拆成两个容器

| 方案 | 优点 | 缺点 |
|---|---|---|
| 一个容器装前后端 | 简单 | 前端和后端耦合，改一个要重建整个镜像 |
| **两个容器** | 各自独立构建、独立更新；Nginx 可以做静态文件缓存 | 稍复杂，需要理解容器网络 |

**我们选两个容器**，因为：

1. **前端改动不用重建后端镜像**（构建更快）
2. **职责清晰** —— Nginx 只管静态文件和转发，后端只管业务
3. **可以单独重启** —— 改 Nginx 配置只需重启 web

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

| 观察 | 结论 |
|---|---|
| 内存只有 2G | ⚠️ **不要在服务器上构建前端**（Vite 构建很容易 OOM） |
| 磁盘剩 27G | 够用，但要注意清理旧镜像 |
| CPU 2 核 | 够用，构建时会慢 |

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

**`\s` 的作用**：匹配空白字符，确保匹配的是 `:80 ` 而不是 `:8080`。

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
| **80 / 443** | **没出现** | **空闲，我们可用** | ✅ |

### ⭐ 这一步救了我们

`0.0.0.0:8080` 被 Zabbix 占用了。**如果我们的后端也映射 8080 到宿主机，服务会启动失败**：

```
Error response from daemon: driver failed programming external connectivity
on endpoint memo-api: Bind for 0.0.0.0:8080 failed: port is already allocated
```

**解决方案**：后端用 `expose` 而不是 `ports`（见第六章），让它只在容器内部可见。

### 出错了怎么查

**如果 80/443 被占用**：

```bash
# 查具体是谁占用（注意 \s 避免匹配到 8080）
ss -tlnp | grep ':80\s'
# 或用 lsof
lsof -i :80
```

看到 `pid=xxxx` 后：

```bash
ps -p xxxx -o pid,comm,args    # 查看这个进程是什么
```

**处理方式**：

| 情况 | 做法 |
|---|---|
| 是你自己之前部署的服务 | `docker compose -p <项目名> down` |
| 是系统服务（apache2、nginx） | `systemctl stop nginx && systemctl disable nginx` |
| 不认识的进程 | ⚠️ **先查清楚再动**，可能是系统关键服务 |

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
permission denied while trying to connect to the Docker daemon socket at
unix:///var/run/docker.sock: Post "http://%2Fvar%2Frun%2Fdocker.sock/v1.24/containers/json":
dial unix /var/run/docker.sock: connect: permission denied
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

> **常见错误**：在 `docker run -v` 里写 `memo-data`，会创建一个**新的空卷**，而不是挂载原有的。**必须写完整的 `light-memo_memo-data`。**

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

**`date` 格式串**：

| 占位符 | 含义 | 示例 |
|---|---|---|
| `%F` | 完整日期 | 2026-10-15 |
| `%H` | 小时（24 小时制） | 14 |
| `%M` | 分钟 | 30 |

**为什么要用容器来打包**：因为备份的是一个**数据卷**，而数据卷不属于任何容器。用一个临时容器把它挂载进来，是最干净的做法。

## 3.3 ⭐ 验证备份有效

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
| 只有 `./` 没有文件 | 程序还没写入数据 | 检查 API 是否正常运行过 |

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

**如果顺序反了会怎样**：比如先删镜像，容器还在运行，Docker 会报：

```
Error response from daemon: conflict: unable to delete xxx (must be forced)
- image is being used by running container
```

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

**为什么要 `grep` 过滤**：如果直接 `docker rmi $(docker images -q)`，会删除**所有**镜像，包括 1Panel 用的。**必须只删我们自己的。**

**`docker builder prune -af`**

| 部分 | 含义 |
|---|---|
| `docker builder prune` | 清理构建缓存 |
| `-a` | all，删除**所有**缓存（不只是悬空的） |
| `-f` | force，不询问确认 |

**这一步回收的空间通常最多** —— 实测约 1.3GB。

## 4.3 验证拆除干净

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
| 网络删不掉 | 有容器连接着 | 先删容器，网络会自动删 |

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

### 为什么不会误伤

因为我们是按 **compose 项目**操作的：

| 命令 | 作用范围 |
|---|---|
| `docker compose -p light-memo down` | **只有 light-memo 项目** |
| `docker volume rm light-memo_memo-data` | **只有这个指定的卷** |
| `grep light-memo \| xargs docker rmi` | **只有名字含 light-memo 的镜像** |

**每一条都限定了范围**，加上第四章 4.3 的验证，就能确保安全。

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
│   │   ├── docker-compose.yml
│   │   ├── docker-compose.override.yml
│   │   ├── deploy/
│   │   │   └── nginx/nginx.conf
│   │   ├── backend/
│   │   └── frontend/
│   ├── certs/            # HTTPS 证书
│   │   ├── server.crt
│   │   └── server.key
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
tar: Error is not recoverable: exiting now
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

# 第六章 编写 docker-compose.yml

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

## 6.1 逐项解释

### `image: ${IMAGE_BASE}/memo-api:${TAG:-latest}`

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

**为什么要用变量**：这样切换版本时只要改 `TAG` 就能生效：

```bash
IMAGE_BASE=ghcr.io/... TAG=abc1234 docker compose up -d
# 会用 ghcr.io/.../memo-api:abc1234
```

> **本地开发时**也可以直接用 `build:` 代替 `image:`，让 compose 从本地 Dockerfile 构建。

### ⭐ `expose` vs `ports`（关键区别）

| 写法 | 效果 | 宿主机能否访问 |
|---|---|---|
| `ports: - "8080:8080"` | 把容器 8080 映射到宿主机 8080 | ✅ 能 |
| `expose: - "8080"` | 只在**容器网络内部**暴露 | ❌ 不能 |

**我们用 `expose` 的原因**：宿主机 8080 被 Zabbix 占用了（第二章发现的）。用 `expose` 就**不占用宿主机端口**，完全避免冲突。

**`ports` 的冒号语法**：

```yaml
ports:
  - "8080:8080"
#    ↑     ↑
#  宿主机  容器
```

**那 Nginx 怎么访问后端**：因为它们在同一容器网络 `memo-net` 里，Nginx 可以直接用**服务名**访问：

```nginx
proxy_pass http://api:8080;    # api 就是 compose 里的服务名
```

Docker 内置的 DNS 会把服务名 `api` 解析成容器 IP。

### `volumes`（数据卷）

```yaml
volumes:
  - memo-data:/data
```

| 部分 | 含义 |
|---|---|
| `memo-data` | **命名卷**的名字（在文件底部 `volumes:` 声明） |
| `/data` | 容器内的挂载点 |

**命名卷 vs 绑定挂载**：

| 类型 | 写法 | 存在哪 | 适合 |
|---|---|---|---|
| **命名卷** | `memo-data:/data` | Docker 管理（`/var/lib/docker/volumes/`） | **数据库数据** ✅ |
| 绑定挂载 | `./local:/data` | 你指定的宿主机路径 | 配置文件 |

**数据用命名卷的原因**：
1. 由 Docker 管理，备份和迁移有标准做法
2. 性能更好（不受宿主机文件系统影响）
3. 不会因为误删宿主机目录而丢失

### `environment`（环境变量）

```yaml
environment:
  MEMO_DATA_DIR: /data
```

**传给容器内程序的环境变量**。后端读到这个值，就知道数据存哪。

**两种写法**：

```yaml
# 写法 1：映射
environment:
  KEY: value

# 写法 2：列表
environment:
  - KEY=value
```

### `healthcheck`（健康检查）

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

**`test` 的两种写法**：

| 写法 | 含义 |
|---|---|
| `["CMD", "命令", "参数"]` | **直接执行**（推荐，不经过 shell） |
| `["CMD-SHELL", "命令 参数"]` | 通过 shell 执行（可以用管道等） |

**为什么要健康检查**：后端启动需要时间（要加载数据库、初始化）。如果 Nginx 在数据库还没初始化好时就启动，用户会看到 502 错误。

### `depends_on` + `condition: service_healthy`

```yaml
depends_on:
  api:
    condition: service_healthy
```

**不加 `condition` 的 `depends_on` 只保证「容器启动了」，不保证「服务能用了」。**

| 写法 | 效果 |
|---|---|
| `depends_on: [api]` | 等 api 容器**启动**（可能程序还没就绪） |
| `condition: service_started` | 同上，明确写出来 |
| `condition: service_healthy` | **等 api 健康检查通过**（真正可用）✅ |

**这就是启动顺序的控制**：

```
api 容器启动 → 健康检查通过 → web 容器才启动
```

### `restart: unless-stopped`

| 值 | 含义 |
|---|---|
| `no` | 不自动重启（默认） |
| `always` | 总是重启（包括你手动停掉后） |
| `unless-stopped` | 自动重启，**但如果你手动 stop 了就不重启** |
| `on-failure` | 只在非正常退出时重启 |

**用 `unless-stopped` 的原因**：
- 服务器重启后容器会自动起来（高可用）✅
- 但你手动停止维护时不会自己又起来（可控）✅

### `networks`（网络）

```yaml
networks: [memo-net]
```

**自定义 bridge 网络的好处**：

| 好处 | 说明 |
|---|---|
| **服务名 DNS 解析** | 容器间可以用名字互相访问（`http://api:8080`） |
| **服务隔离** | 不同 compose 项目的网络默认隔离 |
| **安全性** | 不在同一网络的容器无法互相访问 |

**默认的 `bridge` 网络不支持服务名解析** —— 这是必须自定义网络的原因。

## 6.2 验证配置语法

```bash
cd /srv/light-memo/src
docker compose config
```

### 命令解释

`docker compose config` 会**解析并打印最终配置**（包括合并 override、替换变量之后的结果）。

**这一步能提前发现**：
- YAML 语法错误
- 变量未定义
- 缩进问题

### 出错了怎么查

| 报错 | 原因 |
|---|---|
| `yaml: line X: ...` | YAML 语法错误（通常是缩进） |
| `Invalid interpolation format` | 变量语法写错 |
| `service "x" has neither an image nor a build context` | 既没有 `image` 也没有 `build` |

> ⚠️ **YAML 对缩进极其敏感** —— 必须用**空格**，不能用 Tab。

---

# 第七章 编写 override 配置

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

## 7.1 ⭐ 什么是 override 文件

Docker Compose 会**自动**读取这两个文件并**合并**：

| 顺序 | 文件 | 作用 |
|---|---|---|
| 1 | `docker-compose.yml` | 基础配置 |
| 2 | `docker-compose.override.yml` | **自动覆盖/补充**基础配置 |

**这是自动的** —— 不需要任何命令参数，只要文件名是 `docker-compose.override.yml` 就会被读取。

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

## 7.2 为什么要拆成两个文件

| 场景 | 好处 |
|---|---|
| 本地开发 | 只有基础文件，不需要证书和 443 |
| 换服务器 | 只改 override，基础文件不动 |
| 代码仓库 | 基础文件通用，override 按环境定制 |

**判断标准**：**这个配置是「所有环境都需要」还是「只有当前服务器需要」？**

| 配置 | 归属 |
|---|---|
| 镜像、数据卷、健康检查 | 基础文件（所有环境都需要） |
| 证书、443 端口、绝对路径 | override（服务器特有） |

## 7.3 ⚠️ 一个真实的坑

**自动部署时必须把 override 文件也传上去。**

我们的 CI workflow 一开始只传了 `docker-compose.yml`，**没传 override**。短期不出问题（服务器上旧的 override 还在），但如果有人重新 clone 或者清了目录：

**443 端口会消失，HTTPS 直接挂掉，而且没有任何报错。**

修复方法是在传输列表里加上 override 文件。

> **教训**：**配置文件之间的依赖关系要明确。**少传一个文件可能短期不报错，但埋下隐患。

## 7.4 冒号语法解释（卷挂载）

```yaml
- ./deploy/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
```

| 部分 | 含义 |
|---|---|
| `./deploy/nginx/nginx.conf` | **宿主机**上的路径（`.` 是 compose 文件所在目录） |
| `:` | 分隔符 |
| `/etc/nginx/conf.d/default.conf` | **容器内**的路径 |
| `:ro` | read-only，容器只能读，不能改（**更安全**） |

**原理**：把宿主机的文件「映射」到容器里。容器里改了，宿主机也变（除非 `:ro`）—— 这叫**绑定挂载（bind mount）**。

**为什么证书用绝对路径**：证书在 `/srv/light-memo/certs/`，而不在项目目录里。用绝对路径更清晰。

**为什么要 `:ro`**：
- 防止容器内的程序误改配置
- 明确表达「这个文件是只读的」意图

---

# 第八章 编写 nginx.conf

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

## 8.1 逐段解释

### `listen 80` + `return 301`

```nginx
server {
    listen 80;
    server_name _;

    location / {
        return 301 https://$host$request_uri;
    }
}
```

| 部分 | 含义 |
|---|---|
| `listen 80` | 监听 80 端口（HTTP） |
| `server_name _` | 匹配所有域名（`_` 是「无所谓」的约定写法） |
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

### ⚠️ `return 301` 带来的坑

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

> **这个坑在部署脚本里真实踩到过** —— 健康检查用了 `http://`，导致部署「成功」了但脚本报失败。

### `listen 443 ssl` + `http2 on`

```nginx
listen 443 ssl;
http2 on;
```

| 部分 | 含义 |
|---|---|
| `443 ssl` | 监听 443 并启用 SSL/TLS |
| `http2 on` | 启用 HTTP/2 协议 |

**`http2` vs `http2 on` 的版本差异**：

| Nginx 版本 | 写法 |
|---|---|
| < 1.25.1 | `listen 443 ssl http2;`（写在 listen 里） |
| ≥ 1.25.1 | `http2 on;`（独立指令）✅ |

**HTTP/2 的好处**：多路复用（一个连接并发传多个请求）、头部压缩。**比 HTTP/1.1 明显更快**。

### `ssl_certificate` / `ssl_certificate_key`

```nginx
ssl_certificate     /etc/nginx/certs/server.crt;
ssl_certificate_key /etc/nginx/certs/server.key;
```

| 指令 | 含义 |
|---|---|
| `ssl_certificate` | 证书文件（**可以公开**） |
| `ssl_certificate_key` | 私钥文件（⚠️ **绝对不能泄露**） |

**路径是容器内的路径** —— 因为 override 里把宿主机的 `/srv/light-memo/certs/` 挂载到了 `/etc/nginx/certs/`。

### `ssl_protocols TLSv1.2 TLSv1.3`

**只允许这两个版本**。

| 版本 | 状态 |
|---|---|
| SSLv3 | ⛔ 已废弃，有严重漏洞 |
| TLSv1.0 / 1.1 | ⛔ 已废弃，多个漏洞 |
| **TLSv1.2** | ✅ 安全 |
| **TLSv1.3** | ✅ 最新最安全 |

**不写这一行会怎样**：Nginx 默认可能启用旧的协议版本，**存在安全隐患**。

### `root` / `index`

```nginx
root /usr/share/nginx/html;
index index.html;
```

| 指令 | 含义 |
|---|---|
| `root` | 静态文件的根目录 |
| `index` | 默认首页文件名 |

**`/usr/share/nginx/html` 是 Nginx 官方镜像的默认目录** —— 前端构建产物被 Dockerfile 复制到这里。

### ⭐ `try_files`（单页应用路由）

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

**举例说明**：

| 用户访问 | 磁盘上有这个文件吗 | 没有 `try_files` | 有 `try_files` |
|---|---|---|---|
| `/` | ✅ index.html | 返回首页 | 返回首页 |
| `/assets/x.js` | ✅ 存在 | 返回文件 | 返回文件 |
| `/notes/123` | ❌ 不存在 | **404 错误** | 返回 index.html，React 解析路由 ✅ |

**这就是「路由回退」** —— 找不到的路径统一回退到 `index.html`，交给前端路由处理。

### ⭐ `proxy_pass`（反向代理）

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

> ⚠️ **`proxy_pass` 末尾斜杠的坑**：
> - `proxy_pass http://api:8080;`（无斜杠）→ 保留完整路径 `/api/xxx`
> - `proxy_pass http://api:8080/;`（有斜杠）→ **去掉 `/api` 前缀**，转发 `/xxx`
>
> **我们的后端路由带 `/api` 前缀，所以不能加斜杠。**

### `proxy_set_header` 四个头

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

**`X-Forwarded-Proto` 的具体影响**：如果后端根据协议生成 Cookie 的 `Secure` 属性或重定向地址，缺少这个头会导致**生成 http 地址**，用户被降级到不安全连接。

## 8.2 验证 nginx 配置语法

**在容器内测试**：

```bash
docker exec memo-web nginx -t
```

### 预期输出

```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

**`nginx -t` 的作用**：只检查语法，**不重新加载**。安全，可以随时跑。

### 出错了怎么查

| 报错 | 原因 |
|---|---|
| `unexpected "}"` | 括号不匹配 |
| `unknown directive "xxx"` | 指令拼写错误 |
| `directive is not allowed here` | 指令放错了层级 |
| `cannot load certificate` | 证书文件不存在或路径错 |
| `host not found in upstream "api"` | api 服务不在同一网络 |

> **改完配置记得重启**：`docker compose -p light-memo restart web`
> Nginx 的配置是**启动时读取**的，改文件不会自动生效。

---

# 第九章 生成 HTTPS 证书

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

## 9.1 逐参数解释

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

> **为什么 `-nodes` 重要**：如果私钥有密码保护，Nginx 每次启动都需要**手动输入密码**。而容器是自动启动的，**没人能输入**，服务就起不来。

## 9.2 ⭐ 为什么必须加 `subjectAltName`

**现代浏览器和程序不再认可 CN 字段**，只认 SAN（Subject Alternative Name）。

不加 `-addext "subjectAltName=IP:..."` 的话，访问时会报：

```
SSL: certificate subject name '111.230.141.73' does not match target host name
```

**注意是 `IP:` 而不是 `DNS:`** —— 因为我们的地址是 IP 不是域名。

| 地址类型 | 正确写法 |
|---|---|
| 域名 | `subjectAltName=DNS:example.com` |
| **IP 地址** | `subjectAltName=IP:1.2.3.4` ✅ |

## 9.3 `chmod 600 server.key`

```bash
chmod 600 server.key
```

| 数字 | 权限 |
|---|---|
| 6 | 拥有者：读 + 写 |
| 0 | 组：无权限 |
| 0 | 其他人：无权限 |

**权限数字含义**：

| 数字 | 二进制 | 权限 |
|---|---|---|
| 0 | 000 | 无 |
| 4 | 100 | 读 |
| 5 | 101 | 读 + 执行 |
| 6 | 110 | 读 + 写 |
| 7 | 111 | 读 + 写 + 执行 |

**私钥泄露 = 别人可以冒充你的网站**，所以必须只有 root 能读。

## 9.4 验证证书

```bash
openssl x509 -in server.crt -noout -subject -dates -ext subjectAltName
```

### 命令解释

| 部分 | 含义 |
|---|---|
| `x509` | 处理 x509 格式的证书 |
| `-in server.crt` | 输入文件 |
| `-noout` | 不输出证书本身（只输出我们要看的字段） |
| `-subject` | 显示主体信息 |
| `-dates` | 显示有效期 |
| `-ext subjectAltName` | 显示 SAN 扩展 |

### 预期输出

```
subject=C = CN, ST = Guangdong, L = Shenzhen, O = LightMemo, CN = 111.230.141.73
notBefore=Oct 15 12:00:00 2026 GMT
notAfter=Oct 12 12:00:00 2036 GMT
X509v3 Subject Alternative Name:
    IP Address:111.230.141.73          ← 确认有这个
```

**必须确认 `IP Address:111.230.141.73` 存在**。

## 9.5 为什么用自签证书

| 方案 | 适用 |
|---|---|
| Let's Encrypt | **需要域名**，不签 IP 地址 |
| 云厂商免费证书 | 同样需要域名 |
| **自签证书** | ✅ 适用于 IP 访问 |

**自签的代价**：浏览器会显示「不安全」警告（因为证书不是受信任的机构签发的）。

**但加密是真实有效的** —— 数据传输仍然加密，只是无法验证服务器身份。

**进入网站时会看到警告，点「高级」→「继续前往」即可。**

| 对比项 | 自签证书 | 正式证书 |
|---|---|---|
| 加密强度 | ✅ 相同 | ✅ 相同 |
| 浏览器警告 | ⚠️ 有 | ✅ 无 |
| 需要域名 | ❌ 不需要 | ✅ 需要 |
| 费用 | 免费 | 免费（Let's Encrypt） |
| 自动续期 | 不需要（10 年） | 需要（90 天） |

---

# 第十章 首次部署与验证

## 10.1 构建并启动

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
dmesg | tail -20    # 看是否 OOM
```

**2G 内存构建前端很可能 OOM（内存不足）**。解决办法：

| 方案 | 做法 |
|---|---|
| 加 swap | `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` |
| **不在服务器构建** | 改用 CI 构建后推送到镜像仓库（推荐）✅ |

## 10.2 获取初始密码

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

## 10.3 ⭐ 冒烟测试

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
| 健康检查非 200 | 后端启动失败 | `docker compose -p light-memo logs api` |
| 首页 502 | Nginx 连不上后端 | `docker compose -p light-memo logs web` |
| 首页 404 | 前端文件没打进镜像 | `docker exec memo-web ls /usr/share/nginx/html/` |
| SSL 错误 | 证书路径或权限问题 | `docker exec memo-web ls -l /etc/nginx/certs/` |
| `502 Bad Gateway` + 日志报 `host not found` | 服务和 Nginx 不在同一网络 | `docker inspect memo-api --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'` |

## 10.4 从外部访问测试

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

### 如果服务器上一切正常，问题就在云厂商的安全组

腾讯云控制台 → 轻量应用服务器 → 你的实例 → **防火墙** → 添加规则：

| 协议 | 端口 | 来源 |
|---|---|---|
| TCP | 80 | 0.0.0.0/0 |
| TCP | 443 | 0.0.0.0/0 |

## 10.5 验证 HTTPS 生效

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

**看到 `HTTP/2`** 说明 HTTP/2 启用成功。

### 检查证书信息

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername 111.230.141.73 2>/dev/null | openssl x509 -noout -subject -dates -ext subjectAltName 2>/dev/null
```

| 部分 | 含义 |
|---|---|
| `echo \|` | 输入一个空行（`openssl s_client` 会等待输入） |
| `openssl s_client -connect host:port` | 作为客户端连接，建立 TLS 握手 |
| `-servername` | SNI 字段，告诉服务器我们想访问哪个主机 |
| `2>/dev/null` | 丢弃握手过程的大量输出 |
| `\| openssl x509 -noout ...` | 把证书拿出来解析 |

**确认 `IP Address:111.230.141.73` 存在** —— 没有它浏览器会报证书不匹配。

---

# 第十一章 部署脚本

> **目标**：把部署步骤固化成一个脚本，避免每次手敲。

## 11.1 脚本内容

**文件**：`/srv/light-memo/deploy.sh`

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

## 11.2 ⭐ 逐行详解

### `#!/usr/bin/env bash`

**Shebang（释伴行）** —— 告诉系统用哪个解释器执行这个文件。

**为什么用 `env bash` 而不是 `/bin/bash`**：

| 写法 | 问题 |
|---|---|
| `#!/bin/bash` | 硬编码路径，如果 bash 不在 `/bin` 就失败 |
| `#!/usr/bin/env bash` | 让 `env` 去 PATH 里找 bash，**兼容性更好** |

### ⭐⭐⭐ `set -euo pipefail`

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
exit 0                     # 退出码 0
```

**后果**：
1. 服务被**旧镜像**重启了一遍（可能短暂中断）
2. 你以为上线了，**其实没有**
3. **脚本显示成功，没人知道出了问题**

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

### `cd "$SRC_DIR"`

**为什么要 cd**：`docker compose` 会读取**当前目录**的 `docker-compose.yml`。

**为什么要加引号**：如果变量值含空格，不加引号会被拆成多个参数：

```bash
cd $DIR      # DIR="/srv/my dir" → cd /srv/my dir  ❌ 报错
cd "$DIR"    # DIR="/srv/my dir" → cd "/srv/my dir"  ✅ 正确
```

> **Shell 脚本铁律**：**永远给变量加双引号**。

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

**为什么用 HTTPS 而不是 HTTP**：**第八章讲过的坑** —— 80 端口只返回 301，检查会失败。

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
| `exit 1` | **非零退出码**，标记为失败 |

**为什么要输出日志**：你在 CI 页面进不去服务器。**把日志打出来，出问题时能直接看到原因**。

**`exit 1` 必须写**：如果脚本最后一条命令成功，退出码会是 0，**会被判定为成功**，但实际上部署失败了。

## 11.3 部署脚本

```bash
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

## 11.4 手动执行部署

```bash
IMAGE_BASE=ghcr.io/moyongdian/light-memo-deploy TAG=latest bash /srv/light-memo/deploy.sh
```

**这就是日常部署命令** —— 指定镜像地址和标签，剩下的交给脚本。

---

# 第十二章 日常运维

## 12.1 状态总览脚本

**创建 `/srv/light-memo/memo-status.sh`**：

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
bash /srv/light-memo/memo-status.sh
```

**一条命令看全貌。**

> **`printf` vs `echo -n`**：`printf` 是**可移植性更好**的写法，且行为一致（`echo -n` 在不同 shell 表现不同）。

## 12.2 常用命令速查

### 查看状态

```bash
docker ps -a                                       # 所有容器
docker compose -p light-memo ps                     # 项目容器
docker compose -p light-memo top                    # 容器内进程
docker stats --no-stream                            # 资源占用快照
```

| 命令 | 作用 |
|---|---|
| `ps` | 容器列表 |
| `top` | 容器内**进程**列表 |
| `stats --no-stream` | 一次性资源快照（不加 `--no-stream` 会持续刷新） |

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

**为什么要 `--tail`**：不加的话会打印**从容器启动以来的所有日志**，可能刷屏几分钟。

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

> **改了 nginx.conf 用哪个**：用 `restart web` 就够（配置是挂载进去的，重启会重新读取）。

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

## 12.3 备份与恢复

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
bash /srv/light-memo/memo-status.sh
```

**为什么第 2 步要先 `rm -rf /data/*`**：如果只解压不清理，旧文件和备份文件会**混在一起**，可能导致数据状态不一致。

### 定时备份（cron）

```bash
# 编辑定时任务
crontab -e

# 添加这一行（每天凌晨 4 点备份）
0 4 * * * /usr/local/bin/memo-backup.sh >> /var/log/memo-backup.log 2>&1
```

**cron 时间格式**：

```
0    4    *    *    *   命令
↑    ↑    ↑    ↑    ↑
分   时   日   月   周
```

| 字段 | 取值 | 含义 |
|---|---|---|
| 分 | 0-59 | 0 = 第 0 分钟 |
| 时 | 0-23 | 4 = 凌晨 4 点 |
| 日 | 1-31 | `*` = 每天 |
| 月 | 1-12 | `*` = 每月 |
| 周 | 0-7 | `*` = 每周 |

**`>> /var/log/memo-backup.log 2>&1` 的作用**：

| 部分 | 含义 |
|---|---|
| `>>` | 追加输出到文件 |
| `2>&1` | 把**错误输出**（2）也重定向到**标准输出**（1）的位置 |

**为什么重要**：cron 任务的输出**默认会发邮件**（通常没人看）。重定向到日志文件，出问题时能查。

## 12.4 清理磁盘空间

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

### ⚠️ 关于 `docker volume prune`

**这是最危险的命令** —— 如果数据卷当前没有被容器使用（比如容器停了），它**会被删掉**。

**建议**：**永远不要在生产环境跑 `docker volume prune`**。要清理就明确指定卷名。

---

# 第十三章 排错手册

## 13.1 四条核心排查原则

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

**`2>/dev/null` 是什么意思**：

| 部分 | 含义 |
|---|---|
| `2` | 文件描述符 2 = 标准错误 |
| `>` | 重定向 |
| `/dev/null` | 黑洞设备，写入的内容被丢弃 |

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

**Linux 上的对应命令**：

```bash
xxd 文件 | head -3          # 十六进制
file 文件                    # 探测编码
```

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

**查看上一条命令的退出码**：

```bash
some_command
echo $?      # 0 = 成功，非 0 = 失败
```

### 原则 4：加 `-v` 看细节

| 命令 | 作用 |
|---|---|
| `ssh -v ...` | 逐行看认证过程 |
| `curl -v ...` | 看完整的请求和响应头 |
| `docker compose --dry-run up` | 只显示会做什么，不实际执行 |
| `nginx -t` | 测试配置语法 |
| `bash -x script.sh` | 逐行跟踪脚本执行 |
| `docker inspect <容器>` | 看容器的完整配置 |

## 13.2 按症状查找

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

**常见原因**：

| 原因 | 解决 |
|---|---|
| 后端容器没启动 | `docker compose up -d` |
| 网络不一致 | 检查两个服务的 `networks` 配置 |
| 后端启动慢 | 加健康检查 + `depends_on: condition` |
| `proxy_pass` 写错 | 确认是 `http://api:8080` 而不是 `localhost:8080` |

> ⚠️ **不要在 Nginx 配置里写 `localhost:8080`** —— 在容器里 `localhost` 指的是**容器自己**，不是宿主机，也不是后端容器。

### 症状：首页 404

```bash
# 看容器里有没有前端文件
docker exec memo-web ls /usr/share/nginx/html/

# 看 nginx 配置的 root 指向哪
docker exec memo-web grep root /etc/nginx/conf.d/default.conf
```

**可能原因**：
1. 前端构建产物没复制进镜像（Dockerfile 的 `COPY` 写错）
2. `root` 路径和实际文件位置不一致
3. 缺少 `try_files`，SPA 路由无法回退

### 症状：SSL 证书错误

```bash
# 看证书是否挂载进容器了
docker exec memo-web ls -l /etc/nginx/certs/

# 看 nginx 能否读取（权限问题）
docker exec memo-web cat /etc/nginx/certs/server.key > /dev/null && echo "可读" || echo "不可读"
```

**常见原因**：

| 报错 | 原因 |
|---|---|
| `cannot load certificate` | 文件路径错或没挂载 |
| `Permission denied` | 私钥权限太开放（Nginx 拒绝读） |
| `does not match target host name` | 证书缺少 `subjectAltName` |

### 症状：端口被占用

```
Error response from daemon: Bind for 0.0.0.0:80 failed: port is already allocated
```

```bash
# 查是谁占用
ss -tlnp | grep ':80\s'
lsof -i :80
```

**如果是 docker 容器占用**：

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep ':80'
```

### 症状：数据丢失

**先别慌，按顺序检查**：

```bash
# 1. 数据卷还在吗
docker volume ls | grep memo

# 2. 容器挂载的是哪个卷
docker inspect memo-api --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}'

# 3. 卷里有数据吗
docker run --rm -v light-memo_memo-data:/data alpine ls -la /data
```

**如果卷空了，从备份恢复**（见 12.3）。

**数据丢失的常见原因**：

| 原因 | 预防 |
|---|---|
| 卷名写错，创建了新卷 | 用完整的 `light-memo_memo-data` |
| 跑了 `docker volume prune` | **永远不要在生产跑** |
| `docker compose down -v` | `-v` 会删卷！**不要加** |

> ⚠️ **`down -v` 是危险命令**：`-v` 表示同时删除数据卷。**日常维护用 `down`（不加 -v）。**

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

### 症状：镜像拉取报 `denied`

| 原因 | 解决 |
|---|---|
| 镜像是私有包 | 改成 Public 或登录 |
| 名字大小写问题 | 镜像仓库要求全小写 |
| 确实不存在 | 检查标签拼写 |

**验证镜像是否存在**：

```bash
docker manifest inspect ghcr.io/用户名/仓库/memo-api:标签
```

---

# 附录

## A. Docker 命令速查

```bash
# 查看
docker ps -a                                          # 所有容器
docker ps --format 'table {{.Names}}\t{{.Status}}'    # 格式化输出
docker images                                         # 镜像列表
docker volume ls                                      # 数据卷
docker network ls                                     # 网络
docker system df                                      # 空间占用
docker stats --no-stream                              # 资源快照

# Compose
docker compose -p <项目> ps                            # 项目容器
docker compose -p <项目> top                           # 容器内进程
docker compose -p <项目> logs -f <服务>                # 实时日志
docker compose -p <项目> up -d                         # 启动/重建
docker compose -p <项目> down                          # 停止并删除
docker compose -p <项目> restart <服务>                # 重启
docker compose config                                 # 查看合并后的配置
docker compose --dry-run up                           # 预演

# 检查
docker inspect <容器> --format '{{.Config.Image}}'     # 容器用的镜像
docker inspect <容器> --format '{{.Image}}'            # 镜像 ID
docker inspect <容器> --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}'   # 挂载
docker exec -it <容器> sh                              # 进入容器

# 清理
docker container prune                                # 已停止的容器
docker image prune                                    # 悬空镜像
docker builder prune                                  # 构建缓存
```

## B. Nginx 相关速查

```bash
# 测试配置语法
docker exec memo-web nginx -t

# 重新加载配置（不中断服务）
docker exec memo-web nginx -s reload

# 查看配置
docker exec memo-web cat /etc/nginx/conf.d/default.conf

# 查看 nginx 版本
docker exec memo-web nginx -v

# 查看访问日志
docker exec memo-web tail -f /var/log/nginx/access.log

# 查看错误日志
docker exec memo-web tail -f /var/log/nginx/error.log
```

## C. 网络测试

```bash
curl -kfsS https://127.0.0.1/healthz                    # 健康检查
curl -k -I https://127.0.0.1/                           # 只看响应头
curl -k -s -o /dev/null -w '%{http_code}' https://...   # 只看状态码
curl -s -o /dev/null -w '%{redirect_url}' http://...    # 看跳转目标
curl -v https://127.0.0.1/                              # 详细过程
```

## D. 本次部署实测数据

| 指标 | 数值 |
|---|---|
| 后端镜像大小 | 20.3 MB |
| 前端镜像大小 | 49.3 MB |
| 服务器资源 | 2 核 2G，磁盘 40G（用 12G，30%） |
| 清理构建缓存回收 | 约 1.3 GB |
| 健康检查等待上限 | 60 秒 |
| 数据卷名 | `light-memo_memo-data` |
| 网络名 | `light-memo_memo-net` |

## E. 关键教训

| # | 教训 | 具体场景 |
|---|---|---|
| 1 | **`expose` 不占宿主机端口** | 用它避开了与 Zabbix 的 8080 冲突 |
| 2 | **`set -euo pipefail` 是脚本生命线** | 镜像拉取失败时立即停止，容器时间戳 44 小时未变 |
| 3 | **`return 301` 会让 http 健康检查失败** | 健康检查必须用 `https://` |
| 4 | **不要用 `2>/dev/null` 掩盖错误** | 把 `permission denied` 误报成「未安装」 |
| 5 | **跨平台管道不能传二进制** | PowerShell `\|` 传对象，导致 `not in gzip format` |
| 6 | **`down -v` 会删数据卷** | 日常维护用 `down`，不要加 `-v` |
| 7 | **服务名只在自定义网络里能解析** | 所以必须声明 `networks` |
| 8 | **不要在 Nginx 里写 `localhost:端口`** | 容器内的 localhost 是容器自己 |
| 9 | **改造前先确认无关服务不受影响** | 1Panel 的 mysql/zabbix 全程时间戳未变 |
| 10 | **改 nginx.conf 后必须重启容器** | 配置是启动时读取的 |

## F. 文件清单

| 文件 | 作用 |
|---|---|
| `/srv/light-memo/src/docker-compose.yml` | 容器编排基础配置 |
| `/srv/light-memo/src/docker-compose.override.yml` | 服务器特有配置（443、证书挂载） |
| `/srv/light-memo/src/deploy/nginx/nginx.conf` | Nginx 配置（跳转、TLS、代理） |
| `/srv/light-memo/deploy.sh` | 部署脚本 |
| `/srv/light-memo/certs/server.crt` | HTTPS 证书 |
| `/srv/light-memo/certs/server.key` | HTTPS 私钥（⚠️ 保密） |
| `/srv/backups/memo/` | 数据备份目录 |

## G. 相关文档

| 文档 | 内容 |
|---|---|
| [DEPLOY-GUIDE.md](DEPLOY-GUIDE.md) | 完整教程（含 GitHub Actions 自动部署） |
| [SSH-LOGIN-XSHELL.md](SSH-LOGIN-XSHELL.md) | 服务器连接与排查 |
| [GUIDE.md](GUIDE.md) | 项目使用说明 |
