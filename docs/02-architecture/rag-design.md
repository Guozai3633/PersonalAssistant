# 个人 AI 助手 (Personal AI Assistant) - RAG 双轨混合检索设计

本系统的 RAG (检索增强生成) 引擎以**高精确度**和**零幻觉日程管理**为核心指标。系统抛弃了纯向量库的局限性，实现了结构化 SQL 事实匹配与语义距离检索的融合（RRF）。

---

## 1. 数据入库工作流 (Data Ingestion)

```
[原始输入: 文本/图片 Markdown] 
        |
        v
[文本智能切块 Chunking] (段落拆分，最大 500 tokens，保持段落完整)
        |
        v
[大模型元数据抽取 NER Node] (并行执行)
        +---> 提取事件时间 -> 写入 SQLite memories 表 (获取 uuid)
        +---> 提取标签 (例如: '考试') -> 写入 SQLite tags / memory_tags 表
        |
        v
[Qdrant 负荷封装 Payload Packaging] (拼装 uuid, tags, 时间戳)
        |
        v
[Eino Embedding 向量化] (根据前端传入的模型动态生成向量)
        |
        v
[Qdrant Vector DB 写入] (存储向量与 Payload)
```

### 1.1 切片策略 (Chunking)
* **规则**：单条碎片记录（通常小于 2000 字）默认不进行过碎切割，以保持上下文的绝对完整性。
* **对于长文本**：若用户上传了长课件（Markdown格式，大于 1000 tokens），系统使用带有重叠区间（Overlap = 10%）的滑动窗口分割。
* **元数据向下继承**：每个 Chunk 均会被打上父级 Memory 的 `uuid`、原始文件名、来源类型、以及统一的创建时间戳。

---

## 2. 混合检索工作流 (Hybrid Retrieval)

混合检索采用双通道并行捞取，然后在本地进行重排融合 (Rerank / Fusion)：

```
                         [用户查询: 下周三有什么考试?]
                                     |
                                     +--------------------+
                                     |                    |
                                     v                    v
                             [结构化意图抽取]      [语义向量查询]
                                     |                    |
                                     v                    v
                             [SQLite SQL 精准]     [Qdrant 向量]
                             [Time & Tags 过滤]    [余弦相似度]
                                     |                    |
                                     v                    v
                                [SQL 结果集]       [Qdrant 向量集]
                                     |                    |
                                     +---------+----------+
                                               |
                                               v
                                    [RRF 本地融合与重排]
                                               |
                                               v
                                      [重排后前 Top-K 个]
                                               |
                                               v
                                      [构造 Prompt 上下文]
                                               |
                                               v
                                        [LLM 推理回答]
```

### 2.1 双通道检索细节
1. **通道一：SQLite 结构化精准匹配**：
   * Eino 图解析用户查询的意图（如“下周三”、“考试”）。
   * 构造 SQL 语句：
     ```sql
     SELECT m.*, GROUP_CONCAT(t.name) as tag_names 
     FROM memories m
     JOIN memory_tags mt ON m.id = mt.memory_id
     JOIN tags t ON mt.tag_id = t.id
     WHERE m.deleted_at IS NULL
       AND m.extracted_time BETWEEN '下周三零点' AND '下周三23:59:59'
       AND t.name = '考试';
     ```
   * 这一步可以拦截 100% 具备强时间特征和实体特征的日程数据，返回结果权重极大。
2. **通道二：Qdrant 向量检索**：
   * 使用当前配置的 Embedding 模型将用户查询（如“下周三有什么考试？”）向量化。
   * 向 Qdrant 查询 top-10 最相似的 Point，返回 `Cosine Score`。
   * 支持通过 Payload 属性进行前置预过滤（例如，如果识别到有具体类型，前置过滤只在特定 tags 范围内寻找向量）。

### 2.2 本地 RRF (Reciprocal Rank Fusion) 重排算法
为避免调用高成本的第三方 Rerank API，我们利用 Go 后端本地实现倒数排序融合 (RRF) 算法。
* **算法公式**：
  $$RRF\_Score(d) = \sum_{m \in M} \frac{1}{k + r_m(d)}$$
  * 其中 $r_m(d)$ 是文档 $d$ 在检索通道 $m$ 中的排名位置。
  * 常数 $k$ 设为 60（业界标准参数，防止排名靠后的项分数衰减过快）。
* **融合逻辑**：
  * 对 SQL 捞出来的数据，默认按关联时间的临近程度和优先级在 SQL 轨排序。
  * 对 Qdrant 捞出的向量数据，按 `Cosine Score` 降序排列。
  * 运行 RRF 函数计算每个 `memory_id` 的综合得分，重新从高到低排序，截取 Top-5 数据。

---

## 3. 生成 Prompt 拼接规约
重排得到 Top-5 片段后，Go 后端拼装出供大模型消费的 System Prompt 上下文，格式如下：
```markdown
你是一个贴心、严谨的个人 AI 助手。以下是从用户的本地结构化事实库以及向量知识库中检索出的真实上下文。
请必须基于此上下文回答用户的问题，严禁编造任何时间、地点或事件。

[检索出的本地事实上下文]
--------------------
<% for item in Top-5 %>
ID: <%= item.id %>
记录时间: <%= item.created_at %>
事件关联时间: <%= item.extracted_time %>
标签: <%= item.tags %>
内容: <%= item.content %>
--------------------
<% end %>

当前系统时间: 2026-06-10T15:43:01+08:00 (星期三)
用户问题: <%= user_query %>

请回答：
```
* **强调当前系统时间**：将当前绝对物理时间传给模型，避免模型无法锚定“明天”、“下周”对应的具体日期。
