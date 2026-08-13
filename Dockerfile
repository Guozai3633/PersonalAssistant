# 第一阶段：编译构建 Go 二进制文件
FROM golang:1.25 AS builder

WORKDIR /app

# go-sqlite3 驱动依赖 CGO，必须开启
ENV CGO_ENABLED=1

# 复制依赖定义并缓存下载
COPY go.mod go.sum ./
RUN go mod download

# 复制全部源码
COPY . .

# 编译生成可执行文件
RUN go build -o assistant-backend main.go

# 第二阶段：运行阶段轻量级镜像
FROM debian:bookworm-slim

# 安装 SQLite3 运行库、CA 安全证书、健康检查用的 curl，以及 CGO 必需的 gcc 编译器
RUN apt-get update && apt-get install -y --no-install-recommends \
    sqlite3 \
    ca-certificates \
    curl \
    gcc \
    libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 从构建阶段拷贝编译好的二进制
COPY --from=builder /app/assistant-backend .

# 暴露服务端口
EXPOSE 8080

# 启动可执行程序
CMD ["./assistant-backend"]
