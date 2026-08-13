# 个人 AI 助手 (Personal AI Assistant) - Eino AI 工作流图设计

本系统利用字节开源的 Go 语言 AI 编排框架 **Eino** 编排工作流。将 AI 推理拆分为清晰的“图 (Graph)”节点，保障运行时各环节的可控性与易调试性。

---

## 1. 记忆录入工作流图 (Ingestion Graph)

此 Graph 用于接收非结构化内容并实现自动清洗打标入库。

### 1.1 节点与数据流定义
```
[StartInput] 
     | (Text / Image Path)
     v
[Node_OCR] (OCR / Vision 模型解析，可选分支，若是图片则执行 OCR，输出纯文本)
     |
     v
[Node_MetadataExtractor] (NER 节点：大模型抽取元数据，输出结构化 JSON)
     |
     +---> [Node_SQLSaver] (SQLite 写入节点：持久化事实、标签、实体关系)
     |
     v
[Node_Embedder] (向量化节点：调用 Embedding 模型，输出 Float32 向量)
     |
     v
[Node_VectorSaver] (Qdrant 写入节点：将向量与 Payload 写入 Collection)
     |
     v
[EndIngestion] (输出成功信号及提取的元数据 JSON 给前端展示)
```

### 1.2 Eino 编排控制逻辑
* **条件分支 (Branching)**：使用 Eino 的 `Router` 节点检测输入类型。若输入包含图片路径，路由到 `OCR` 节点；若为纯文本，直接路由到 `MetadataExtractor`。
* **双向并行 (Fork-Join)**：在 `MetadataExtractor` 提取完 JSON 后，生成的数据并行发送至 `SQLSaver` 与 `Embedder` 节点，提高处理效率并减少等待时间。

---

## 2. 混合问答检索工作流图 (Query & QA Graph)

此 Graph 用于响应用户的全局指令舱查询，提取意图并召回背景生成无幻觉的回答。

### 2.1 节点与数据流定义
```
[StartQuery] 
     | (User Query String & Current Time)
     v
[Node_QueryParser] (意图解析：提取时间、标签和核心语义)
     |
     +--------------------------+--------------------------+
     | (Time & Tags)                                       | (Semantic Query)
     v                                                     v
[Node_SQLRetriever] (SQL 查询)                        [Node_VectorRetriever] (向量召回)
     | (Facts)                                             | (Context Points)
     +--------------------------+--------------------------+
                                |
                                v
                     [Node_RRF_Reranker] (本地 RRF 算法排序融合)
                                | (Top-K Sorted Contexts)
                                v
                     [Node_ContextFormatter] (格式化 Prompt 上下文)
                                |
                                v
                     [Node_QA_LLM] (最终生成回答，流式 Steam 输出)
                                |
                                v
                            [EndQA]
```

### 2.2 Eino 编排控制逻辑
* **并行检索 (Fork-Join)**：`QueryParser` 解析意图后，数据流被拆分成两路：
  1. SQL 条件参数被发送至 `SQLRetriever` 执行 SQLite 关系查询。
  2. 语义参数被向量化后发送至 `VectorRetriever` 执行 Qdrant 范围检索。
* **数据汇聚 (Join)**：`RRF_Reranker` 节点合并并重排两个通道的数据，作为后续节点的统一输入。
* **流式响应支持**：`QA_LLM` 节点在 Eino 中配置为 `Streamable`，允许 Go 后端以 Server-Sent Events (SSE) 格式将大模型生成的回答实时流式推送至 Flutter 客户端，提升用户体验。
