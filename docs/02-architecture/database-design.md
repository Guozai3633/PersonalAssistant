# 个人 AI 助手 (Personal AI Assistant) - 数据库结构设计

为了实现“双轨防幻觉检索”，系统采用 SQLite (结构化事实库) + Qdrant (语义向量库) 的联合存储方案。本设计保障在百万级非结构化碎片数据下的事务一致性与极速过滤检索。

---

## 1. SQLite 数据库设计 (sqlite.db)

### 1.1 全局优化参数 (WAL Mode)
SQLite 默认在 `DELETE` 日志模式下工作，写操作会独占并锁定整个数据库。我们在后端初始化 SQLite 连接池时，强行执行以下配置，榨干其性能：
```sql
PRAGMA journal_mode = WAL;          -- 开启写前日志模式，实现并发读写。
PRAGMA synchronous = NORMAL;         -- 降低同步级别，提升写性能，但在极端断电下可能丢失几毫秒数据（对个人助手完全可容忍）。
PRAGMA foreign_keys = ON;            -- 强制开启外键约束。
PRAGMA busy_timeout = 5000;          -- 设置忙等待超时为 5 秒，防止多协程写冲突时直接报错。
```

### 1.2 数据表设计 (DDL)

#### 1.2.1 `memories` (碎片记忆事实表)
存储清洗过滤后的核心记忆片断。
```sql
CREATE TABLE IF NOT EXISTS memories (
    id TEXT PRIMARY KEY,                       -- UUID 字符串
    raw_content TEXT NOT NULL,                -- AI/OCR 处理后用于检索的内容
    original_content TEXT NOT NULL DEFAULT '', -- 不可变的用户原始输入，用于来源追溯
    extracted_time TEXT,                      -- AI 提取出的具体事件关联时间 (ISO 8601 格式，如 "2026-06-15T08:00:00Z")
    priority INTEGER DEFAULT 1,                -- 优先级 (0: 低, 1: 普通, 2: 高, 3: 紧急)
    source_type TEXT DEFAULT 'text',          -- 来源类型: 'text', 'image', 'audio', 'file'
    source_meta TEXT,                         -- JSON 字符串，存储额外信息（如图片原始绝对路径、原文件名）
    title TEXT DEFAULT '',                    -- AI 提取或用户修正的标题
    processing_status TEXT NOT NULL DEFAULT 'completed', -- pending/processing/completed/failed/needs_confirmation
    processing_error TEXT NOT NULL DEFAULT '', -- 最近一次后台解析失败原因
    created_at INTEGER NOT NULL,              -- 创建时间戳 (秒级 Unix Timestamp)
    updated_at INTEGER NOT NULL,              -- 更新时间戳 (秒级 Unix Timestamp)
    deleted_at INTEGER                        -- 软删除标记 (秒级 Unix Timestamp，NULL 表示未删除)
);

-- 索引：针对防幻觉的高频时间范围过滤，建立联合索引
CREATE INDEX IF NOT EXISTS idx_memories_time_deleted ON memories (extracted_time, deleted_at);
-- 索引：针对时间流展示，按创建时间降序排序
CREATE INDEX IF NOT EXISTS idx_memories_created ON memories (created_at DESC);
```

#### 1.2.2 `tags` (标签表)
```sql
CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,                -- 标签名称 (如 '考试', '机房课', '账单')
    created_at INTEGER NOT NULL
);
```

#### 1.2.3 `memory_tags` (记忆标签关联表 - 多对多)
```sql
CREATE TABLE IF NOT EXISTS memory_tags (
    memory_id TEXT NOT NULL,
    tag_id TEXT NOT NULL,
    PRIMARY KEY (memory_id, tag_id),
    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE,
    FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
);

-- 索引：加速根据标签进行筛选
CREATE INDEX IF NOT EXISTS idx_mem_tags_tag ON memory_tags (tag_id);
```

#### 1.2.4 `chat_sessions` (对话会话表)
```sql
CREATE TABLE IF NOT EXISTS chat_sessions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,                      -- 会话标题 (AI 自动生成或默认首条提问)
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

#### 1.2.5 `chat_messages` (对话消息表)
```sql
CREATE TABLE IF NOT EXISTS chat_messages (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,                       -- 'system', 'user', 'assistant'
    content TEXT NOT NULL,                    -- 消息内容
    token_count INTEGER DEFAULT 0,            -- 消耗的 Token 统计
    created_at INTEGER NOT NULL,
    FOREIGN KEY (session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
);

-- 索引：加速会话历史消息的升序拉取
CREATE INDEX IF NOT EXISTS idx_chat_msg_session ON chat_messages (session_id, created_at ASC);
```

#### 1.2.6 `scheduled_tasks`（提醒与任务表）

AI 提取出的任务默认保存为 `pending_confirmation`。调度器只读取 `pending`，因此未经用户确认的提醒不会触发。

```sql
CREATE TABLE IF NOT EXISTS scheduled_tasks (
    id TEXT PRIMARY KEY,
    memory_id TEXT DEFAULT '',                -- 关联来源 memories.id
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    action_type TEXT NOT NULL,                -- reminder/alarm/api_call
    due_time INTEGER NOT NULL,
    original_due_text TEXT DEFAULT '',        -- 模型解析前的时间表达
    status TEXT DEFAULT 'pending',             -- pending_confirmation/pending/processing/done/failed
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tasks_due_time
ON scheduled_tasks (status, due_time);
```

---

## 2. Qdrant 向量数据库设计

### 2.1 动态 Collection 命名规约 (BYOK 维度隔离)
在 BYOK 模式下，系统在配置新模型时，从后端动态向 Qdrant 创建 Collection。命名格式如下：
* **命名公式**：`memories_{provider}_{dimension}_{hash}`
* **例如**：
  * OpenAI 默认 `text-embedding-3-small` (1536维) -> `memories_openai_1536_default`
  * Ollama 本地 `mxbai-embed-large` (1024维) -> `memories_ollama_1024_default`
* **向量距离计算度量**：一律采用 **Cosine (余弦相似度)**。

### 2.2 Point Payload (负荷数据) 结构
Qdrant 存储的每个向量节点 (Point) 都必须附带以下元数据载荷，便于在语义搜索前/后进行联合条件过滤：
```json
{
  "memory_id": "uuid-string",            // 映射到 SQLite 中的 memories.id
  "source_type": "text",                 // 来源类型
  "extracted_time": "2026-06-15T08:00:00Z", // 关联时间，支持范围过滤
  "priority": 1,                         // 优先级
  "tags": ["考试", "算法课"],             // 标签数组，支持精确匹配
  "created_at": 1774849200               // 向量创建时间戳
}
```

### 2.3 Payload 过滤索引策略
为了在百万级向量数据下快速执行 Payload 联合过滤（防止暴力扫描非结构化数据），必须在 Qdrant 集合创建时，向以下字段创建 **Payload Index**：
1. **Keyword 索引**：对 `memory_id` 和 `tags` 进行索引，提高精确匹配性能。
2. **Integer 索引**：对 `created_at` 和 `priority` 建立数值索引。
3. **Datetime/Float 索引**：对 `extracted_time` 进行索引，以支持 Qdrant 内部的时间段范围筛选（Range Filter）。
