# ---------- 阶段 1：构建前端 ----------
FROM node:24-alpine AS builder

# 启用 corepack，它会按 package.json 里的 packageManager 字段
# 自动使用正确版本的 pnpm（本项目是 pnpm@10.32.1）
RUN corepack enable && corepack prepare pnpm@10.32.1 --activate

WORKDIR /app

# 同样先只复制依赖文件，锁文件没变就走缓存
COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY frontend/ ./

# VITE_API_BASE_URL 必须在【构建时】写死进产物：
# Vite 会把 import.meta.env.VITE_* 在打包时替换成常量字符串，
# 运行容器时再改环境变量是无效的 —— 这是前端部署最常见的坑。
# 同时 vite.config.ts 会用它生成 CSP 的 connect-src。
ARG VITE_API_BASE_URL=http://localhost
RUN printf 'VITE_API_BASE_URL=%s\n' "$VITE_API_BASE_URL" > .env \
    && pnpm build

# ---------- 阶段 2：用 Nginx 托管静态文件 ----------
FROM nginx:1.27-alpine

# 把构建产物 dist 放到 Nginx 默认站点根目录
COPY --from=builder /app/dist /usr/share/nginx/html
# 站点配置 + 安全响应头片段（memo.conf 里用 include 引入后者）
COPY deploy/nginx/ /etc/nginx/memo/
COPY deploy/nginx/memo.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
