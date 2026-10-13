# ---------- 阶段 1：编译（builder） ----------
# 用官方 Go 镜像只做一件事：把源码编译成二进制。
# 这个阶段镜像很大（含完整 Go 工具链），但不会进入最终镜像。
FROM golang:1.27-alpine AS builder

WORKDIR /src

# 国内服务器访问 proxy.golang.org 会超时，改用国内模块代理。
# 在境外构建时可覆盖：docker build --build-arg GOPROXY=https://proxy.golang.org,direct
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY} GOSUMDB=sum.golang.google.cn

# 先只复制依赖清单，利用 Docker 层缓存：
# 只要 go.mod / go.sum 没变，下面这条 go mod download 就会命中缓存，秒过。
COPY go.mod go.sum ./
RUN go mod download

# 再复制源码
COPY . .

# CGO_ENABLED=0 → 纯静态编译，不依赖 glibc/musl 版本，
# 这样最终镜像可以用 alpine 甚至 scratch/distroless。
# 本项目用的是 modernc.org/sqlite（纯 Go 实现的 SQLite），不需要 cgo。
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -trimpath -ldflags='-s -w' -o /out/memo-api ./cmd/memo-api

# ---------- 阶段 2：运行（runtime） ----------
# 只带一个二进制的极简镜像，体积小、攻击面小。
FROM alpine:3.22

# 创建非 root 用户运行服务（安全最佳实践：容器里绝不用 root 跑应用）
RUN addgroup -S memo && adduser -S -G memo memo \
    && mkdir -p /var/lib/memo && chown -R memo:memo /var/lib/memo

COPY --from=builder /out/memo-api /usr/local/bin/memo-api

# 默认环境变量（可在 docker-compose.yml / docker run 里覆盖）
# 注意：容器里必须监听 0.0.0.0，不能是 127.0.0.1，
# 否则只有容器内部能访问，Nginx 容器连不上它。
ENV MEMO_LISTEN_ADDR=0.0.0.0:8080 \
    MEMO_DATABASE_PATH=/var/lib/memo/memo.db

USER memo
WORKDIR /var/lib/memo
EXPOSE 8080

# ENTRYPOINT 固定为程序，CMD 是默认参数 → 方便执行 init：
# docker compose run --rm api init    （覆盖 CMD）
# docker compose up -d api            （用默认 CMD: serve）
ENTRYPOINT ["/usr/local/bin/memo-api"]
CMD ["serve"]
