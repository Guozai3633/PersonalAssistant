# 个人 AI 助手 (Personal AI Assistant) - 系统架构设计

## 1. 架构总览
本系统采用典型分层架构设计，各层职责高内聚，低耦合。为了适配单用户本地自部署 (Self-Host) 场景，架构在设计上砍去了所有不必要的分布式中间件，确保轻量级与极速启动。

```
+-----------------------------------------------------------+
|                        Flutter Client                     |
+-----------------------------+-----------------------------+
                              | HTTP (RESTful JSON)
                              v
+-----------------------------------------------------------+
|                          Go API Gateway                   |
|  - Middleware (Key Injector, CORS, Logging, Recovery)     |
+-----------------------------+-----------------------------+
                              |
                              v
+-----------------------------------------------------------+
|                       Business Services                   |
|  - MemoryService (Capture, Ingest, Retrieval Coordinator) |
|  - SessionService (Chat Logic, Context Cache)             |
|  - MetricService (Dashboard Stats Compiler)               |
+-----------------------------+-----------------------------+
                              |
            +-----------------+-----------------+
            |                                   |
            v                                   v
+-----------------------+           +-----------------------+
|    SQLite Repository  |           |      AI Engine        |
| - Read/Write SQLite   |           | - Eino Graph Manager  |
| - Transactions        |           | - Dynamic Clients     |
+-----------------------+           +-----------------------+
```

---

## 2. 核心设计细节

### 2.1 分层职责与边界
1. **Handler (控制层)**：
   * 负责解析 HTTP 请求（绑定 JSON，检查必要参数）。
   * 抽取请求头中的 API 密钥配置 (`X-API-Key` 等) 并将其注入到 `context.Context` 中，传递给下层。
   * 捕获下层返回的 `error` 并翻译成标准的 HTTP 状态码。
2. **Service (业务层)**：
   * 负责业务逻辑编排。例如：接收到文本后，调用 AI 提取元数据，同时调用 Repository 写入 SQLite，并触发向量存储。
   * 单个 Service 必须遵循单一职责原则。
3. **Repository (仓储层)**：
   * 屏蔽数据库的具体实现。所有对 SQLite 的操作必须通过接口完成，严禁 Service 直接操作 `sql.DB`。
4. **AI Engine (AI 引擎)**：
   * 封装 Eino 框架的图编排（Graph）、节点定义（Nodes）和模型客户端（Model Adapters）。
   * 仅暴露统一的推理/检索接口，外部业务层无需关心 Eino 的底层流向。

### 2.2 BYOK (Bring Your Own Key) 动态客户端实例化与缓存
为了防止用户每次请求都创建新的 HTTP 客户端导致内存泄露或连接耗尽，我们引入**算力连接池**：
* **动态解析**：Go 后端从 `context.Context` 中读取当前请求对应的 Provider, Model, API Key 和 Base URL。
* **LRU 客户端缓存 (Client Cache)**：
  * 后端维护一个全局并发安全的哈希映射 `sync.Map`，Key 为密钥配置信息的 SHA256 签名，Value 为 Eino 的模型客户端实例 (`ChatModel` / `Embedding`)。
  * 每次请求时，若缓存命中则复用，否则新建并缓存。
  * 引入淘汰机制，当缓存容量达到限制或长时间未被使用时，调用底层客户端的销毁方法释放资源，防止内存暴涨。

### 2.3 基于 context.Context 的优雅停机与协程防泄漏 (Graceful Shutdown)
在本地运行且高频操作时，必须保证后端进程正常退出的安全性：
* **信号监听**：监听操作系统的 `SIGINT` 和 `SIGTERM` 信号。
* **超时撤销**：使用 `context.WithTimeout` 创建一个生命周期为 10 秒的 Root Context。
* **链路取消**：所有的 Eino Graph 推理节点、HTTP Handler 请求以及 SQLite 事务，在执行时都必须接收这个 `context.Context`。
* 当系统接收到停机信号时：
  1. 停止接收新的 HTTP 请求。
  2. 调用正在执行的 context 的 `CancelFunc`，迫使所有阻塞在网络调用（如请求 OpenAI API 或 Qdrant 写入）的协程立即退出并释放连接。
  3. 等待所有存活的协程退出，或超时强制退出。

### 2.4 极轻量内存缓存 (Replacing Redis)
由于移除了 Redis，短期会话记忆（Session Memory，如最近 10 条对话上下文）的存储方案设计如下：
* 采用进程内带有 TTL (Time-To-Live) 和容量限制的**内存缓存库**。
* 定义 `SessionCache` 结构体，内部使用 `sync.RWMutex` 保护 `map[string]*ChatSession`。
* 启动一个轻量级的后台定时协程，每分钟扫描并清理已过期的 Session 缓存。
* 当会话结束或用户切走时，业务层触发异步归档，将完整的 Session 记录以 JSONB 格式持久化到 SQLite 中。

---

## 3. 可观测性 (Observability) 设计
* **结构化日志**：使用标准库 `log/slog`（Go 1.21+ 引入），统一输出 JSON 格式日志。包含 `trace_id`（从 HTTP 请求生成并沿 context 传递）、级别、模块、耗时及错误详情。
* **Eino 图指标监控**：在 Eino 的运行时 Graph 中注册 Callback 钩子，自动打印每个节点（Node）的输入、输出、耗时和 Token 消耗。
* **健康度度量**：对外提供 `/health` 及 `/metrics` 接口，暴露 SQLite 数据库连接状态、Qdrant 的网络延迟以及进程内存占用指标。
