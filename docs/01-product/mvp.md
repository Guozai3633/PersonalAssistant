# 个人 AI 助手 (Personal AI Assistant) - MVP 边界定义

## 1. 核心目标
本阶段 MVP (Minimum Viable Product) 的核心目标是**跑通最基本的数据流闭环**：
> 用户主动输入非结构化数据 -> Go 后端利用 Eino 提取并清洗 -> 分别写入 SQLite 与 Qdrant -> 用户通过 Flutter 仪表盘发出自然语言查询 -> 系统执行双轨混合检索并输出精准回答。

---

## 2. 必须实现的功能 (In-Scope)

### 2.1 录入端 (Input)
* **极简手动录入**：
  * Flutter App 主页顶部提供万能输入框，支持输入一段非结构化文字。
  * 支持上传单张图片，调用大模型 OCR 接口（或 Vision 模型）将其转化为 Markdown 文本。
* **快捷剪贴板保存**：
  * 每次切回 App 前台时，自动提示是否保存当前剪贴板的文字内容。

### 2.2 仪表盘端 (Dashboard UI)
* **度量卡片**：
  * 记忆囊总数（通过 Qdrant Collection Count 获取）。
  * Qdrant 数据存储空间大小统计（模拟或通过 Qdrant Telemetry API 读取）。
  * 大模型 API key 运行状态（健康检查，检测配置的 Key 是否可用）。
* **潜意识流时间线**：
  * 展示最近处理的 10 条记忆卡片。
  * 每张卡片上展示提取到的标签、日期和优先级。支持点击卡片查看 AI 处理后的结构化 JSON 详情。

### 2.3 后端 RAG 引擎 & Eino (AI Engine)
* **BYOK 动态 Adapter**：
  * Go 后端基于 HTTP 请求头（Header）中传入的 `X-API-Key`、`X-Base-URL`、`X-Model-Provider` 和 `X-Model-Name` 动态实例化 Eino 编排中的 `ChatModel` 与 `Embedding` 客户端。不持久化密钥在后端。
* **实体提取图 (Ingest Graph)**：
  * 使用 Eino Graph：接收原文 -> LLM 提取 JSON 元数据 -> 写入 SQLite -> 调用 Embedding 向量化 -> 写入 Qdrant。
* **双轨检索图 (Query Graph)**：
  * 使用 Eino Graph：接收查询 -> LLM 提取时间与事件条件 -> SQLite 过滤 SQL -> Qdrant 向量检索 -> Rerank/Fusion（根据文本重叠和向量分数组合重排） -> 构造 System Prompt 并发送至大模型生成回答。

### 2.4 数据存储 (Storage)
* **SQLite**：单文件关系数据库。主要存储 `memories` 事实表（包含实体字段、时间戳、优先级、软删除标记）、`tags` 标签表、`chat_sessions` 会话表及 `chat_messages` 对话消息。
* **Qdrant**：本地单机 Docker 镜像。根据用户配置的 Embedding 模型名称，动态创建 Collection 存储向量及关联文本。

---

## 3. 禁止实现的功能 (Out-of-Scope)
为了保证项目的敏捷迭代与高内聚，以下功能在 MVP 阶段**严禁开发**：
* **多用户与 SaaS**：不支持注册、登录、找回密码、多租户数据隔离。默认本地单用户模式。
* **多租户权限校验**：无复杂的角色权限（RBAC），默认前端控制一切。
* **Agent 自动执行与主动提醒**：不需要 AI 自动去调本地日历应用或定时发送手机通知（以防复杂的跨平台后台常驻机制和轮询开销）。
* **知识图谱 (Knowledge Graph)**：暂不建立节点与节点之间复杂的图数据库关系。
* **多云同步**：暂不支持本地 SQLite 数据与 Notion/Obsidian 等第三方云服务自动同步。
* **插件生态**：禁止设计外部动态加载的插件市场。
