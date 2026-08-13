# Personal Assistant

一个本地优先的个人 AI 助手 App，用来把碎片化信息快速收进记忆库，并通过语义检索、任务抽取、待确认提醒和来源引用，帮助用户重新找到可靠上下文。

当前项目包含 Go 后端、Flutter 客户端、本地 SQLite 数据库、Qdrant 向量库，以及可选的语音转写和 Telegram 通知能力。

## 核心能力

- 快速录入：文本、语音、图片/OCR、系统分享入口。
- 记忆收件箱：首页聚合快速录入、最近记忆、待确认任务和即将提醒。
- AI 结构化：自动抽取标题、标签、优先级、时间、任务信息和处理状态。
- 混合检索：结合 SQLite 结构化数据与 Qdrant 语义向量检索。
- 来源引用：问答结果可回到原始记忆内容，降低幻觉风险。
- 本地优先：业务数据默认保存在本地 SQLite 和本地 Qdrant。

## 技术栈

- Backend: Go, net/http, SQLite, Qdrant, Eino, OpenAI-compatible API / Ollama
- Client: Flutter, Riverpod, fl_chart, Google Fonts
- Infra: Docker Compose, Qdrant, faster-whisper-server

## 目录结构

```text
.
├── ai/                 # AI 编排、Embedding 与检索逻辑
├── client/             # Flutter 客户端
├── config/             # 后端环境配置
├── docs/               # 产品、架构、研发和路线图文档
├── handlers/           # HTTP API handlers
├── models/             # 核心领域模型
├── repositories/       # SQLite 与 Qdrant 数据访问
├── services/           # 业务服务、通知、任务处理
├── docker-compose.yml  # 本地依赖与后端编排
├── Dockerfile          # 后端镜像构建
└── main.go             # 后端入口
```

## 快速开始

### 1. 准备环境

- Go 1.25+
- Flutter 3.x
- Docker Desktop
- 可选：Ollama 或 OpenAI-compatible 模型服务

### 2. 配置环境变量

复制 `.env.example` 并按需填写：

```powershell
Copy-Item .env.example .env
```

关键配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8080` | 后端 HTTP 端口 |
| `DB_PATH` | `./assistant.db` | SQLite 数据库路径 |
| `QDRANT_HOST` | `localhost` | Qdrant 地址 |
| `QDRANT_PORT` | `6333` | Qdrant REST 端口 |
| `QDRANT_GRPC_PORT` | `6334` | Qdrant gRPC 端口 |
| `APP_API_TOKEN` | 空 | API 鉴权 token，留空则不强制 |
| `LOCAL_MODE` | `false` | 是否启用本地模型模式 |
| `OLLAMA_API_BASE` | `http://localhost:11434` | Ollama 服务地址 |
| `TELEGRAM_BOT_TOKEN` | 空 | Telegram Bot token，可选 |
| `TELEGRAM_CHAT_ID` | 空 | Telegram 接收方，可选 |

### 3. 启动依赖

```powershell
docker compose up -d qdrant whisper-asr
```

### 4. 启动后端

```powershell
go run .
```

健康检查：

```powershell
Invoke-RestMethod http://localhost:8080/health
```

也可以直接用 Docker Compose 启动完整后端：

```powershell
docker compose up --build
```

Compose 中后端默认映射到宿主机 `8082` 端口。

### 5. 启动客户端

```powershell
cd client
flutter pub get
flutter run
```

## 常用 API

- `POST /api/memories/ingest`：录入文本记忆
- `POST /api/memories/ingest-audio`：录入音频记忆
- `POST /api/memories/retry`：重试失败记忆处理
- `GET /api/memories`：读取记忆列表或详情
- `POST /api/chat`：基于记忆库问答
- `GET /api/chat/messages`：读取聊天历史
- `GET /api/dashboard/stats`：仪表盘统计
- `GET /api/dashboard/mind-graph`：记忆关系图
- `POST /api/tasks/confirm`：确认 AI 抽取的任务

## 测试

后端：

```powershell
go test ./...
```

客户端：

```powershell
cd client
flutter test
```

## GitHub 上传注意事项

仓库根目录已配置 `.gitignore`，默认排除：

- 本地数据库和向量库：`data/`、`*.db`
- 密钥和证书：`.env`、`usercert-*.zip`
- 编译产物：`*.exe`、`build/`、`.dart_tool/`
- 日志与临时文件：`*.log`、`tmpclaude-*`
- 本地 Agent/IDE 状态：`.agent/`、`.agents/`、`.claude/`、`.idea/`

上传前建议先确认：

```powershell
git status --short
git status --ignored --short
```

## 文档

- 产品需求：[docs/01-product/PRD.md](docs/01-product/PRD.md)
- 系统设计：[docs/02-architecture/system-design.md](docs/02-architecture/system-design.md)
- 研发日志：[docs/04-development/changelog.md](docs/04-development/changelog.md)
- 路线图：[docs/07-roadmap/roadmap.md](docs/07-roadmap/roadmap.md)
