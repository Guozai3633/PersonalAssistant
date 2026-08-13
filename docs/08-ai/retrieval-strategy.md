# 个人 AI 助手 (Personal AI Assistant) - 混合检索与重排策略

为了在日程和知识问答中兼顾“语义理解”与“强硬时间/标签过滤”，系统设计了一套不需要依赖云端复杂重排模型（如 Cohere Rerank）的本地混合检索方案。

---

## 1. 检索通道设计

### 1.1 精准 SQL 检索通道 (SQLite Track)
* **目的**：获取有强属性约束（时间、分类标签）的事实。
* **输入**：由大模型在第一步解析出来的 SQL 过滤参数（如：`start_time`, `end_time`, `tags`）。
* **匹配机制**：
  * **时间匹配**：使用 `extracted_time BETWEEN :start_time AND :end_time`。
  * **标签匹配**：通过多表 JOIN，筛选 `tags.name IN (:tags)` 的记忆条目。
  * **软删除过滤**：必须追加 `deleted_at IS NULL`。
* **排序权重**：SQL 轨内部按 `priority` 降序和 `created_at` 降序进行初步排序。

### 1.2 语义向量检索通道 (Vector Track)
* **目的**：召回不含具体时间词、但语义高度关联的背景知识（如“学委发过的关于课件的通知”或“某学科的考试重点范围说明”）。
* **输入**：意图解析重写后的核心语义查询字符串 `semantic_query`。
* **过滤条件**：
  * 使用 Qdrant 的 Payload 过滤器做前置硬性过滤（如排除标记为已删除 `deleted_at` 的向量，限制相同 Collection 内搜索）。
* **计算逻辑**：使用 Cosine 余弦相似度计算，截取 Top-10 结果。
* **相似度阈值**：相似度得分（Score）必须大于 **0.35**，低于该阈值的向量结果直接被舍弃，防止召回无关噪声。

---

## 2. 本地重排与融合算法 (Reciprocal Rank Fusion)

双通道结果召回后，系统在 Go 后端执行 **RRF (Reciprocal Rank Fusion)** 进行多轨结果合并与打分。

### 2.1 RRF 排名计算逻辑
对于召回出来的所有候选文档 $d \in D$（每个文档为一个 unique `memory_id`），其综合 RRF 得分计算为：
$$Score(d) = w_{sql} \cdot \sum_{m \in M_{sql}} \frac{1}{60 + r_{sql}(d)} + w_{vec} \cdot \sum_{m \in M_{vec}} \frac{1}{60 + r_{vec}(d)}$$

* **参数定义**：
  * $r_{sql}(d)$：文档 $d$ 在 SQL 检索结果集中的排名（索引从 0 开始计数，排名第一则 $r = 0$；如果文档未在 SQL 轨召回，则倒数倒数分数贡献为 0）。
  * $r_{vec}(d)$：文档 $d$ 在向量检索结果集中的排名。
  * $60$：平滑常数，缓和排名非常靠后文档的极小倒数分，使其不至于完全归零。
  * $w_{sql}$：SQL 轨权重，设定为 **1.5**（赋予精准事实更高的优先级）。
  * $w_{vec}$：向量轨权重，设定为 **1.0**。

### 2.2 融合步骤实现 (Go 伪代码)
```go
type DocumentScore struct {
    MemoryID string
    Score    float64
}

func ReciprocalRankFusion(sqlResults []string, vectorResults []string) []DocumentScore {
    scores := make(map[string]float64)
    k := 60.0
    wSQL := 1.5
    wVec := 1.0

    // 统计 SQL 轨排名得分
    for rank, id := range sqlResults {
        scores[id] += wSQL * (1.0 / (k + float64(rank)))
    }

    // 统计向量轨排名得分
    for rank, id := range vectorResults {
        scores[id] += wVec * (1.0 / (k + float64(rank)))
    }

    // 转换为切片并按得分从高到低排序
    var sorted []DocumentScore
    for id, score := range scores {
        sorted = append(sorted, DocumentScore{MemoryID: id, Score: score})
    }
    
    sort.Slice(sorted, func(i, j int) bool {
        return sorted[i].Score > sorted[j].Score
    })

    return sorted
}
```

---

## 3. 动态截断策略
重排合并后，系统采用**分值与数量双重截断**：
1. **最高数量限制**：最终喂给大模型做 QA 生成的上下文最大项数设定为 **Top-5**，防止超出 Context Window 且降低云端模型 Token 开销。
2. **最低分值筛选**：得分必须高于阈值（例如 $RRF\_Score > 0.01$），对于过低的边缘数据予以剔除，确保提供给大模型的上下文纯净、高相关。
