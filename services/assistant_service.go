package services

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"assistant/ai"
	"assistant/models"
	"assistant/repositories"

	"github.com/cloudwego/eino/schema"
)

type AssistantService struct {
	sqliteRepo         *repositories.SQLiteRepository
	qdrantRepo         *repositories.QdrantRepository
	einoEngine         *ai.EinoEngine
	processingMemories sync.Map             // memory ID -> active background parser
	isReconciling      int32                // 状态自愈锁，防止多个对账协程并发竞态运行
	isProfiling        int32                // 画像更新锁，防抖
	notifyListener     func(message string) // 消息推送监听器（如 Telegram 推送）
}

func NewAssistantService(sqliteRepo *repositories.SQLiteRepository, qdrantRepo *repositories.QdrantRepository, einoEngine *ai.EinoEngine) *AssistantService {
	s := &AssistantService{
		sqliteRepo: sqliteRepo,
		qdrantRepo: qdrantRepo,
		einoEngine: einoEngine,
	}
	s.StartTaskScheduler()
	return s
}

// RegisterNotifyListener 注册消息推送监听器
func (s *AssistantService) RegisterNotifyListener(listener func(string)) {
	s.notifyListener = listener
}

// IngestMemory 提取非结构化信息并双向持久化 (异步重型解析版本)
func (s *AssistantService) IngestMemory(ctx context.Context, rawContent string, sourceType string, sourceMeta string, isEncrypted bool, title string, tags []string, cfg *models.AIConfig) (*models.Memory, error) {
	id := fmt.Sprintf("mem_%d", time.Now().UnixNano())

	// 1. 同步进行极速的初始落库（查重校验与写入只涉及本地 DB，延迟极其微小）
	mem, err := s.einoEngine.IngestMemory(ctx, id, rawContent, sourceType, sourceMeta, isEncrypted, title, tags, cfg)
	if err != nil {
		return nil, err
	}

	// 2. 如果是明文，且确实新建了该记忆 (非复用 5 分钟内已有相同数据)
	if err == nil && mem != nil && mem.ID == id && !isEncrypted {
		s.startMemoryProcessing(mem, cfg)
	}

	return mem, nil
}

// startMemoryProcessing 启动单条记忆的后台解析，同一记忆同时只允许一个任务运行。
func (s *AssistantService) startMemoryProcessing(mem *models.Memory, cfg *models.AIConfig) bool {
	if mem == nil || cfg == nil {
		return false
	}
	if _, loaded := s.processingMemories.LoadOrStore(mem.ID, struct{}{}); loaded {
		return false
	}

	cfgCopy := *cfg
	memCopy := *mem
	memCopy.Tags = append([]string(nil), mem.Tags...)
	go func(m *models.Memory, aiCfg *models.AIConfig) {
		defer s.processingMemories.Delete(m.ID)
		ctxBg := context.Background()

		if err := s.sqliteRepo.UpdateMemoryProcessingStatus(ctxBg, m.ID, models.MemoryStatusProcessing, ""); err != nil {
			fmt.Printf("[ASYNC ERROR] Failed to mark memory %s as processing: %v\n", m.ID, err)
			return
		}
		m.ProcessingStatus = models.MemoryStatusProcessing
		m.ProcessingError = ""

		fmt.Printf("\n🚀 [ASYNC PARSE START] Memory ID: %s | SourceType: %s\n", m.ID, m.SourceType)

		contentToProcess := m.RawContent

		// A. OCR / 多模态图像描述降级过滤
		if m.SourceType == "image" {
			fmt.Printf("[ASYNC] Performing Vision OCR/Analysis for %s...\n", m.ID)
			ocrText, err := s.einoEngine.PerformOCR(ctxBg, m.RawContent, aiCfg)
			if err != nil {
				s.failMemoryProcessing(ctxBg, m, fmt.Errorf("图片识别失败: %w", err))
				return
			} else {
				fmt.Printf("[ASYNC INFO] PerformOCR succeeded for %s. Text length: %d\n", m.ID, len(ocrText))
				contentToProcess = ocrText
			}
		}

		// B. LLM Metadata 结构化提取
		fmt.Printf("[ASYNC] Extracting Metadata for %s...\n", m.ID)
		meta, err := s.einoEngine.ExtractMetadata(ctxBg, contentToProcess, m.SourceType, aiCfg)
		if err != nil {
			s.failMemoryProcessing(ctxBg, m, fmt.Errorf("结构化解析失败: %w", err))
			return
		}

		// C. 更新 Memory 数据字段
		m.RawContent = contentToProcess
		m.ExtractedTime = meta.ExtractedTime
		m.Priority = meta.Priority
		m.Title = meta.Title
		m.Tags = meta.Tags
		m.UpdatedAt = time.Now().Unix()

		// D. 提取并保存主动执行的 Task (待办/闹钟)
		confirmationTaskCount := 0
		if err := s.sqliteRepo.DeletePendingConfirmationTasksForMemory(ctxBg, m.ID); err != nil {
			s.failMemoryProcessing(ctxBg, m, fmt.Errorf("清理旧待确认任务失败: %w", err))
			return
		}
		if len(meta.Tasks) > 0 {
			fmt.Printf("[ASYNC INFO] Extracted %d tasks/alarms from Memory %s\n", len(meta.Tasks), m.ID)
			for _, rawTask := range meta.Tasks {
				taskID := fmt.Sprintf("task_%d_%d", time.Now().UnixNano(), rand.Intn(100000))
				var dueTimestamp int64
				dueStr := strings.TrimSpace(rawTask.DueTime)
				if dueStr != "" {
					t, err := time.Parse(time.RFC3339, dueStr)
					if err != nil {
						loc, locErr := time.LoadLocation("Asia/Shanghai")
						if locErr != nil {
							loc = time.FixedZone("CST", 8*3600)
						}
						formats := []string{
							"2006-01-02T15:04:05",
							"2006-01-02 15:04:05",
							"2006-01-02T15:04:00",
							"2006-01-02 15:04:00",
						}
						parsed := false
						for _, f := range formats {
							if tVal, parseErr := time.ParseInLocation(f, dueStr, loc); parseErr == nil {
								t = tVal
								parsed = true
								break
							}
						}
						if !parsed {
							t = time.Now().Add(24 * time.Hour)
							fmt.Printf("[ASYNC WARN] Failed to parse task due_time %q, fallback to tomorrow: %v\n", dueStr, err)
						}
					}
					dueTimestamp = t.Unix()
				} else {
					dueTimestamp = time.Now().Add(24 * time.Hour).Unix()
				}

				actionType := strings.TrimSpace(rawTask.ActionType)
				switch actionType {
				case "reminder", "alarm", "api_call":
				default:
					actionType = "reminder"
				}
				taskTitle := strings.TrimSpace(rawTask.Title)
				if taskTitle == "" {
					taskTitle = strings.TrimSpace(m.Title)
				}
				if taskTitle == "" {
					taskTitle = "待办提醒"
				}

				task := models.ScheduledTask{
					ID:              taskID,
					MemoryID:        m.ID,
					Title:           taskTitle,
					Description:     rawTask.Description,
					ActionType:      actionType,
					DueTime:         dueTimestamp,
					OriginalDueText: dueStr,
					Status:          models.TaskStatusPendingConfirmation,
					CreatedAt:       m.UpdatedAt,
				}

				if err := s.sqliteRepo.SaveScheduledTask(ctxBg, &task); err != nil {
					fmt.Printf("[ASYNC ERROR] Failed to save scheduled task %s: %v\n", task.ID, err)
				} else {
					confirmationTaskCount++
					fmt.Printf("[ASYNC INFO] Created task confirmation %s: %s (due: %d, raw: %s)\n", task.ID, task.Title, task.DueTime, dueStr)
				}
			}
		}

		// E. 向量生成与 Qdrant 写入 (RAG)
		var embedFailed bool
		var vector32 []float32
		var collectionName string

		embedder, err := s.einoEngine.GetEmbedder(ctxBg, aiCfg)
		if err != nil {
			fmt.Printf("[ASYNC WARN] GetEmbedder failed for %s: %v. Vector RAG index skipped.\n", m.ID, err)
			embedFailed = true
		}

		if !embedFailed {
			fmt.Printf("[ASYNC] Computing Embedding vector for %s...\n", m.ID)
			vectors, err := embedder.EmbedStrings(ctxBg, []string{contentToProcess})
			if err != nil || len(vectors) == 0 {
				fmt.Printf("[ASYNC WARN] EmbedStrings failed: %v. Vector RAG index skipped.\n", err)
				embedFailed = true
			} else {
				vector := vectors[0]
				vector32 = make([]float32, len(vector))
				for i, v := range vector {
					vector32[i] = float32(v)
				}
				collectionName = fmt.Sprintf("memories_%s_%d", aiCfg.EmbedProvider, len(vector32))
				if err := s.qdrantRepo.InitCollection(ctxBg, collectionName, uint64(len(vector32))); err != nil {
					fmt.Printf("[ASYNC WARN] Init Qdrant Collection failed: %v\n", err)
					embedFailed = true
				}
			}
		}

		if !embedFailed {
			payload := map[string]interface{}{
				"memory_id":      m.ID,
				"source_type":    m.SourceType,
				"extracted_time": m.ExtractedTime,
				"priority":       int64(m.Priority),
				"created_at":     m.CreatedAt,
			}
			if len(m.Tags) > 0 {
				payload["tags"] = m.Tags
			}
			if m.Title != "" {
				payload["title"] = m.Title
			}

			if err := s.qdrantRepo.SaveVector(ctxBg, collectionName, m.ID, vector32, payload); err != nil {
				fmt.Printf("[ASYNC WARN] Qdrant save vector failed for %s: %v\n", m.ID, err)
			} else {
				fmt.Printf("[ASYNC INFO] Vector saved successfully in Qdrant for Memory %s\n", m.ID)
			}
		}

		// F. SQLite 最终合并覆盖（将包含提取标题、标签等字段的 memory 重新写入 SQLite）
		fmt.Printf("[ASYNC] Updating Memory record in SQLite for %s...\n", m.ID)
		if confirmationTaskCount > 0 {
			m.ProcessingStatus = models.MemoryStatusNeedsConfirmation
		} else {
			m.ProcessingStatus = models.MemoryStatusCompleted
		}
		m.ProcessingError = ""
		if err := s.sqliteRepo.SaveMemory(ctxBg, m); err != nil {
			fmt.Printf("[ASYNC ERROR] SaveMemory update failed for %s: %v\n", m.ID, err)
			s.failMemoryProcessing(ctxBg, m, fmt.Errorf("保存解析结果失败: %w", err))
			return
		} else {
			fmt.Printf("[ASYNC INFO] Memory %s metadata successfully updated in SQLite\n", m.ID)
		}

		// G. 异步触发用户画像分析
		go s.TriggerUserProfileUpdate(aiCfg)

		// H. 异步提取 GraphRAG 实体关系
		fmt.Printf("[ASYNC] Extracting GraphRAG entity relations for %s...\n", m.ID)
		relations, err := s.einoEngine.ExtractEntityRelations(ctxBg, contentToProcess, aiCfg)
		if err != nil {
			fmt.Printf("[ASYNC ERROR] GraphRAG extract relations API error for %s: %v\n", m.ID, err)
		} else {
			fmt.Printf("[ASYNC INFO] GraphRAG successfully extracted %d relations for %s\n", len(relations), m.ID)
			for _, r := range relations {
				err = s.sqliteRepo.SaveEntityRelation(ctxBg, r.Source, r.SourceType, r.Target, r.TargetType, r.Relation, m.ID)
				if err != nil {
					fmt.Printf("[ASYNC WARN] GraphRAG save relation error for %s: %v\n", m.ID, err)
				}
			}
		}

		fmt.Printf("🏁 [ASYNC PARSE COMPLETED] Memory ID: %s\n\n", m.ID)
	}(&memCopy, &cfgCopy)
	return true
}

func (s *AssistantService) failMemoryProcessing(ctx context.Context, mem *models.Memory, processingErr error) {
	errorMessage := processingErr.Error()
	mem.ProcessingStatus = models.MemoryStatusFailed
	mem.ProcessingError = errorMessage
	if err := s.sqliteRepo.UpdateMemoryProcessingStatus(ctx, mem.ID, models.MemoryStatusFailed, errorMessage); err != nil {
		fmt.Printf("[ASYNC ERROR] Failed to persist processing error for %s: %v\n", mem.ID, err)
	}
	fmt.Printf("[ASYNC ERROR] Memory %s processing failed: %v\n", mem.ID, processingErr)
}

// RetryMemoryProcessing 重新启动失败或中断的解析任务。
func (s *AssistantService) RetryMemoryProcessing(ctx context.Context, id string, cfg *models.AIConfig) (*models.Memory, error) {
	mem, err := s.sqliteRepo.GetMemory(ctx, id)
	if err != nil {
		return nil, err
	}
	if mem == nil {
		return nil, fmt.Errorf("memory not found: %s", id)
	}
	if mem.ProcessingStatus == models.MemoryStatusCompleted {
		return nil, fmt.Errorf("memory is already processed")
	}
	if !s.startMemoryProcessing(mem, cfg) {
		return nil, fmt.Errorf("memory processing is already running")
	}
	mem.ProcessingStatus = models.MemoryStatusPending
	mem.ProcessingError = ""
	return mem, nil
}

// IngestAudio 语音一键上传：转译音频并录入双轨持久化
func (s *AssistantService) IngestAudio(ctx context.Context, audioBytes []byte, fileName string, cfg *models.AIConfig) (*models.Memory, error) {
	// 1. 调用 EinoEngine 执行语音转文字
	transcribedText, err := s.einoEngine.TranscribeAudio(ctx, audioBytes, fileName, cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to transcribe audio: %w", err)
	}

	trimmedText := strings.TrimSpace(transcribedText)
	if trimmedText == "" {
		return nil, fmt.Errorf("transcribed text is empty")
	}

	fmt.Printf("[INFO] Audio transcribed successfully: %q\n", trimmedText)

	// 2. 将识别出的文本作为 rawContent 走正常的 ingest 逻辑，类型标记为 "audio"
	return s.IngestMemory(ctx, trimmedText, "audio", fileName, false, "", nil, cfg)
}

// DeleteMemory 软删除记忆并删除向量库数据
func (s *AssistantService) DeleteMemory(ctx context.Context, id string, cfg *models.AIConfig) error {
	// 1. 删除 SQLite 记录 (软删除)
	if err := s.sqliteRepo.DeleteMemory(ctx, id); err != nil {
		return err
	}

	// 2. 物理删除 Qdrant 中的向量
	// 这里通过计算一次虚拟 Embedding 长度确定 Collection 名称
	embedder, err := s.einoEngine.GetEmbedder(ctx, cfg)
	if err != nil {
		return fmt.Errorf("failed to get embedder for deletion: %w", err)
	}
	vectors, err := embedder.EmbedStrings(ctx, []string{"test"})
	if err != nil || len(vectors) == 0 {
		return fmt.Errorf("failed to get dimension size for deletion: %w", err)
	}
	collectionName := fmt.Sprintf("memories_%s_%d", cfg.EmbedProvider, len(vectors[0]))

	return s.qdrantRepo.DeleteVector(ctx, collectionName, id)
}

// ListMemories 分页拉取记忆事实列表
func (s *AssistantService) ListMemories(ctx context.Context, page, pageSize int) ([]*models.Memory, error) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 10
	}
	offset := (page - 1) * pageSize
	return s.sqliteRepo.ListMemories(ctx, pageSize, offset)
}

func (s *AssistantService) GetMemory(ctx context.Context, id string) (*models.Memory, error) {
	return s.sqliteRepo.GetMemory(ctx, id)
}

// Ask 混合双轨检索问答
func (s *AssistantService) Ask(ctx context.Context, query string, sessionID string, cfg *models.AIConfig) (*models.ChatResult, error) {
	if sessionID == "" {
		sessionID = "session_default"
	}

	// 确保 SQLite 中会话存在
	sess := &models.ChatSession{
		ID:    sessionID,
		Title: "默认会话",
	}
	_ = s.sqliteRepo.SaveChatSession(ctx, sess)

	return s.einoEngine.RetrieveAndAnswer(ctx, query, sessionID, cfg)
}

type DashboardStats struct {
	TotalMemories         int                       `json:"total_memories"`
	ActiveNeurons         uint64                    `json:"active_neurons"`
	TodayCount            int                       `json:"today_count"`
	StreakDays            int                       `json:"streak_days"`
	PendingTaskCount      int                       `json:"pending_task_count"`
	ConfirmationTaskCount int                       `json:"confirmation_task_count"`
	DailyCounts           []repositories.DailyCount `json:"daily_counts"`
	UpcomingTasks         []*models.ScheduledTask   `json:"upcoming_tasks"`
	ConfirmationTasks     []*models.ScheduledTask   `json:"confirmation_tasks"`
	TopTags               []repositories.TagCount   `json:"top_tags"`
	UserProfile           string                    `json:"user_profile"`
	Status                string                    `json:"status"`
}

// GetDashboardStats 编译并获取仪表盘的核心统计指标 (Vitals)
func (s *AssistantService) GetDashboardStats(ctx context.Context, cfg *models.AIConfig) (*DashboardStats, error) {
	// 0. 自动执行 SQLite 历史重复数据大清洗，净化数据库以彻底杜绝重复记录
	if cleaned, err := s.sqliteRepo.DeduplicateMemories(ctx); err == nil && cleaned > 0 {
		fmt.Printf("[INFO] Automatically cleaned and soft-deleted %d duplicate history memories\n", cleaned)
	}

	// 1. 获取 SQLite 记忆条数
	totalMemories, err := s.sqliteRepo.GetTotalMemoryCount(ctx)
	if err != nil {
		totalMemories = 0
	}

	// 2. 获取当前模型对应的 Qdrant 向量数
	var activeNeurons uint64
	cols, err := s.qdrantRepo.ListCollections(ctx)
	if err == nil {
		for _, col := range cols {
			if strings.HasPrefix(col, "memories_") {
				count, err := s.qdrantRepo.GetCollectionCount(ctx, col)
				if err == nil {
					activeNeurons += count
				}
			}
		}
	}

	// 3. 触发缺失向量的后台静默对账与自愈补偿协程
	if totalMemories > 0 && activeNeurons == 0 && cfg.EmbedModel != "" {
		go s.reconcileMissingVectors(context.Background(), cfg)
	}

	// 4. 获取今日录入数
	todayCount, _ := s.sqliteRepo.GetTodayMemoryCount(ctx)

	// 5. 获取连续记录天数
	streakDays, _ := s.sqliteRepo.GetStreakDays(ctx)

	// 6. 获取最近 7 日每日录入数量
	dailyCounts, _ := s.sqliteRepo.GetDailyMemoryCounts(ctx, 7)

	// 7. 获取即将到来的待办任务 (最多 5 条)
	upcomingTasks, _ := s.sqliteRepo.GetUpcomingTasks(ctx, 5)
	pendingTaskCount := len(upcomingTasks)

	// 8. 获取等待用户确认的 AI 提取任务
	confirmationTasks, _ := s.sqliteRepo.GetPendingConfirmationTasks(ctx, 10)

	// 9. 获取热门标签 TOP 8
	topTags, _ := s.sqliteRepo.GetTopTags(ctx, 8)

	// 10. 获取用户画像
	userProfile, _ := s.sqliteRepo.GetUserProfile(ctx)

	return &DashboardStats{
		TotalMemories:         totalMemories,
		ActiveNeurons:         activeNeurons,
		TodayCount:            todayCount,
		StreakDays:            streakDays,
		PendingTaskCount:      pendingTaskCount + len(confirmationTasks),
		ConfirmationTaskCount: len(confirmationTasks),
		DailyCounts:           dailyCounts,
		UpcomingTasks:         upcomingTasks,
		ConfirmationTasks:     confirmationTasks,
		TopTags:               topTags,
		UserProfile:           userProfile,
		Status:                "Healthy",
	}, nil
}

// GetChatMessages 获取指定会话的历史记录
func (s *AssistantService) GetChatMessages(ctx context.Context, sessionID string) ([]*models.ChatMessage, error) {
	if sessionID == "" {
		sessionID = "session_default"
	}
	return s.sqliteRepo.GetChatMessages(ctx, sessionID)
}

// reconcileMissingVectors 静默自愈对账协程，自动为 Qdrant 中缺失向量的历史数据补偿跑一遍 Embedding 提取并写入
func (s *AssistantService) reconcileMissingVectors(ctx context.Context, cfg *models.AIConfig) {
	// 1. 原子比较交换抢自愈锁，防止多个 reconciles 并发执行造成冲突与内存雪崩
	if !atomic.CompareAndSwapInt32(&s.isReconciling, 0, 1) {
		return
	}
	defer atomic.StoreInt32(&s.isReconciling, 0)

	// 使用独立带长超时的 Background Context 声明周期运行，防范外层连接关闭
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	fmt.Printf("[INFO] Reconciliation: Start auto-reconciliation of missing vectors for embed provider %s\n", cfg.EmbedProvider)

	// 2. 从 SQLite 批量拉取所有已存储的事实记录 (限制最多 1000 条，保护内存)
	memories, err := s.sqliteRepo.ListMemories(ctx, 1000, 0)
	if err != nil {
		fmt.Printf("[ERROR] Reconciliation: Failed to list memories from sqlite: %v\n", err)
		return
	}

	if len(memories) == 0 {
		return
	}

	// 3. 动态实例化 Embedder
	embedder, err := s.einoEngine.GetEmbedder(ctx, cfg)
	if err != nil {
		fmt.Printf("[ERROR] Reconciliation: Failed to get embedder: %v\n", err)
		return
	}

	// 4. 跑一个虚拟样本计算 Embedding 维度
	testVectors, err := embedder.EmbedStrings(ctx, []string{"test"})
	if err != nil || len(testVectors) == 0 {
		fmt.Printf("[ERROR] Reconciliation: Failed to get vector dimensions: %v\n", err)
		return
	}
	vectorDim := uint64(len(testVectors[0]))

	collectionName := fmt.Sprintf("memories_%s_%d", cfg.EmbedProvider, vectorDim)
	err = s.qdrantRepo.InitCollection(ctx, collectionName, vectorDim)
	if err != nil {
		fmt.Printf("[ERROR] Reconciliation: Failed to init collection %s: %v\n", collectionName, err)
		return
	}

	// 5. 循环补偿更新。使用局部局部变量副本，防止切片及循环指针在并发中发生复用和交叉覆盖惨剧
	for _, memoryItem := range memories {
		// 每次分配独立的内存单元存储局部临时变量，避让 Go 循环变量复用陷阱
		mem := memoryItem

		// 频率控制：每条对账间隔 100ms，防范过快并发请求将 LLM API 熔断或 CPU 跑满
		select {
		case <-ctx.Done():
			fmt.Println("[WARN] Reconciliation: Time limit exceeded or context cancelled")
			return
		case <-time.After(100 * time.Millisecond):
		}

		// 重新向量化
		singleVectors, err := embedder.EmbedStrings(ctx, []string{mem.RawContent})
		if err != nil || len(singleVectors) == 0 {
			fmt.Printf("[WARN] Reconciliation: Failed to extract embedding for memory %s: %v\n", mem.ID, err)
			continue
		}

		vector64 := singleVectors[0]
		vector32 := make([]float32, len(vector64))
		for i, val := range vector64 {
			vector32[i] = float32(val)
		}

		payload := map[string]interface{}{
			"memory_id":      mem.ID,
			"source_type":    mem.SourceType,
			"extracted_time": mem.ExtractedTime,
			"priority":       int64(mem.Priority),
			"created_at":     mem.CreatedAt,
		}
		if len(mem.Tags) > 0 {
			payload["tags"] = mem.Tags
		}

		// 批量 Upsert 进 Qdrant：Qdrant 会根据 UUID ID 自动覆盖相同的数据，保持幂等性
		err = s.qdrantRepo.SaveVector(ctx, collectionName, mem.ID, vector32, payload)
		if err != nil {
			fmt.Printf("[WARN] Reconciliation: Failed to save vector to Qdrant for memory %s: %v\n", mem.ID, err)
		} else {
			fmt.Printf("[INFO] Reconciliation: Reconciled vector for memory %s successfully\n", mem.ID)
		}
	}

	fmt.Println("[INFO] Reconciliation: Completed successfully")
}

// TranscribeAudio 仅语音转译文本，不自动入库
func (s *AssistantService) TranscribeAudio(ctx context.Context, audioBytes []byte, fileName string, cfg *models.AIConfig) (string, error) {
	transcribedText, err := s.einoEngine.TranscribeAudio(ctx, audioBytes, fileName, cfg)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(transcribedText), nil
}

// PerformOCR 图片一键 OCR 提取文本
func (s *AssistantService) PerformOCR(ctx context.Context, base64Data string, cfg *models.AIConfig) (string, error) {
	return s.einoEngine.PerformOCR(ctx, base64Data, cfg)
}

// UpdateMemory 更改或更新记忆，并在 Qdrant 重新 Upsert 向量
func (s *AssistantService) UpdateMemory(ctx context.Context, mem *models.Memory, cfg *models.AIConfig) error {
	// 1. 获取现有记忆检查是否存在
	existing, err := s.sqliteRepo.GetMemory(ctx, mem.ID)
	if err != nil || existing == nil {
		return fmt.Errorf("memory not found: %s", mem.ID)
	}

	// 保持原有的不可变属性
	mem.CreatedAt = existing.CreatedAt
	mem.SourceType = existing.SourceType
	mem.OriginalContent = existing.OriginalContent
	mem.ProcessingStatus = existing.ProcessingStatus
	mem.ProcessingError = existing.ProcessingError
	mem.UpdatedAt = time.Now().Unix()

	// 2. 写入/更新 SQLite
	if err := s.sqliteRepo.SaveMemory(ctx, mem); err != nil {
		return fmt.Errorf("failed to save memory update to sqlite: %w", err)
	}

	// 触发画像更新
	go s.TriggerUserProfileUpdate(cfg)

	// 3. 非阻断容灾更新向量库 Qdrant
	embedder, err := s.einoEngine.GetEmbedder(ctx, cfg)
	if err != nil {
		fmt.Printf("[WARN] UpdateMemory: failed to get embedder: %v. Falling back to SQLite only.\n", err)
		return nil
	}

	vectors, err := embedder.EmbedStrings(ctx, []string{mem.RawContent})
	if err != nil || len(vectors) == 0 {
		fmt.Printf("[WARN] UpdateMemory: embedding extraction failed: %v. Falling back to SQLite only.\n", err)
		return nil
	}

	vector := vectors[0]
	vector32 := make([]float32, len(vector))
	for i, v := range vector {
		vector32[i] = float32(v)
	}

	collectionName := fmt.Sprintf("memories_%s_%d", cfg.EmbedProvider, len(vector32))
	if err := s.qdrantRepo.InitCollection(ctx, collectionName, uint64(len(vector32))); err != nil {
		fmt.Printf("[WARN] UpdateMemory: init qdrant collection failed: %v. Falling back to SQLite only.\n", err)
		return nil
	}

	payload := map[string]interface{}{
		"memory_id":      mem.ID,
		"source_type":    mem.SourceType,
		"extracted_time": mem.ExtractedTime,
		"priority":       int64(mem.Priority),
		"created_at":     mem.CreatedAt,
	}
	if len(mem.Tags) > 0 {
		payload["tags"] = mem.Tags
	}
	if mem.Title != "" {
		payload["title"] = mem.Title
	}

	if err := s.qdrantRepo.SaveVector(ctx, collectionName, mem.ID, vector32, payload); err != nil {
		fmt.Printf("[WARN] UpdateMemory: failed to save vector to qdrant: %v. Falling back to SQLite only.\n", err)
	} else {
		fmt.Printf("[INFO] Vector updated for memory %s successfully (collection: %s)\n", mem.ID, collectionName)
	}

	return nil
}

// GenerateTTS 通过 einoEngine 将文本转化为语音数据
func (s *AssistantService) GenerateTTS(ctx context.Context, text string, cfg *models.AIConfig) ([]byte, error) {
	if text == "" {
		return nil, fmt.Errorf("text cannot be empty")
	}

	audioData, err := s.einoEngine.TextToSpeech(ctx, text, cfg)
	if err != nil {
		return nil, fmt.Errorf("engine failed to generate tts: %w", err)
	}

	return audioData, nil
}

// TriggerUserProfileUpdate 异步更新用户画像（带防抖）
func (s *AssistantService) TriggerUserProfileUpdate(cfg *models.AIConfig) {
	if !atomic.CompareAndSwapInt32(&s.isProfiling, 0, 1) {
		return // 已经在执行中，放弃
	}
	defer atomic.StoreInt32(&s.isProfiling, 0)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	// 1. 获取最近的10条卡片
	recentMemories, err := s.sqliteRepo.ListMemories(ctx, 10, 0)
	if err != nil || len(recentMemories) == 0 {
		return
	}

	// 2. 获取当前的画像
	oldProfile, _ := s.sqliteRepo.GetUserProfile(ctx)

	// 3. 调用 LLM 生成新的画像
	newProfile, err := s.einoEngine.GenerateUserProfile(ctx, oldProfile, recentMemories, cfg)
	if err != nil || newProfile == "" {
		fmt.Printf("[WARN] TriggerUserProfileUpdate failed to generate: %v\n", err)
		return
	}

	// 4. 保存新画像
	if err := s.sqliteRepo.SaveUserProfile(ctx, newProfile); err != nil {
		fmt.Printf("[ERROR] TriggerUserProfileUpdate failed to save: %v\n", err)
		return
	}

	fmt.Println("[INFO] User profile updated in background successfully.")
}

// StartTaskScheduler 启动一个简单的后台任务调度器
func (s *AssistantService) StartTaskScheduler() {
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()

		for range ticker.C {
			ctx, cancel := context.WithTimeout(context.Background(), 1*time.Minute)
			now := time.Now().Unix()

			tasks, err := s.sqliteRepo.GetDueTasks(ctx, now)
			if err != nil {
				fmt.Printf("[ERROR] TaskScheduler: failed to get due tasks: %v\n", err)
				cancel()
				continue
			}

			cfg, _ := s.sqliteRepo.GetAIConfig(ctx)

			for _, task := range tasks {
				fmt.Printf("[INFO] TaskScheduler: Executing task %s: %s (%s)\n", task.ID, task.Title, task.ActionType)

				// 标记为处理中
				s.sqliteRepo.UpdateTaskStatus(ctx, task.ID, "processing")

				// 1. 如果配置了 Bark 推送且是提醒或闹钟，触发网络推送
				if cfg != nil && strings.TrimSpace(cfg.BarkKey) != "" && (task.ActionType == "reminder" || task.ActionType == "alarm") {
					barkKey := strings.TrimSpace(cfg.BarkKey)
					titleEscaped := url.PathEscape(task.Title)
					descEscaped := url.PathEscape(task.Description)
					if descEscaped == "" {
						descEscaped = url.PathEscape("待办提醒时间已到")
					}
					barkURL := fmt.Sprintf("https://api.day.app/%s/%s/%s?group=JARVIS&sound=glass", barkKey, titleEscaped, descEscaped)

					go func(urlStr string, tid string) {
						client := &http.Client{Timeout: 5 * time.Second}
						resp, httpErr := client.Get(urlStr)
						if httpErr == nil {
							resp.Body.Close()
							fmt.Printf("[INFO] TaskScheduler: Bark push notification sent successfully for task %s\n", tid)
						} else {
							fmt.Printf("[WARN] TaskScheduler: Failed to send Bark push for task %s: %v\n", tid, httpErr)
						}
					}(barkURL, task.ID)
				}

				// 2. 打印日志并在 Telegram 等渠道发布通知
				if task.ActionType == "reminder" || task.ActionType == "alarm" {
					fmt.Printf("\n🔔 [REMINDER/ALARM TRIGGERED]: %s - %s\n\n", task.Title, task.Description)
					if s.notifyListener != nil {
						s.notifyListener(fmt.Sprintf("🔔 [提醒我]: %s\n%s", task.Title, task.Description))
					}
				} else {
					fmt.Printf("\n🚀 [ACTION EXECUTED]: %s - %s\n\n", task.Title, task.Description)
					if s.notifyListener != nil {
						s.notifyListener(fmt.Sprintf("🚀 [任务执行]: %s\n%s", task.Title, task.Description))
					}
				}

				// 标记为已完成
				s.sqliteRepo.UpdateTaskStatus(ctx, task.ID, "done")
			}
			cancel()
		}
	}()
}

// GenerateSummary 批量读取记忆卡片并调用大模型融合成长文
func (s *AssistantService) GenerateSummary(ctx context.Context, ids []string, cfg *models.AIConfig) (string, error) {
	if len(ids) == 0 {
		return "", fmt.Errorf("ids cannot be empty")
	}

	var memories []*models.Memory
	for _, id := range ids {
		mem, err := s.sqliteRepo.GetMemory(ctx, id)
		if err != nil {
			fmt.Printf("[WARN] GenerateSummary: failed to fetch memory %s: %v\n", id, err)
			continue
		}
		if mem != nil {
			memories = append(memories, mem)
		}
	}

	if len(memories) == 0 {
		return "", fmt.Errorf("no valid memories found for the given ids")
	}

	return s.einoEngine.GenerateSummary(ctx, memories, cfg)
}

// SaveAIConfig 保存用户大模型配置到本地
func (s *AssistantService) SaveAIConfig(ctx context.Context, cfg *models.AIConfig) error {
	return s.sqliteRepo.SaveAIConfig(ctx, cfg)
}

// GetAIConfig 获取本地保存的用户大模型配置
func (s *AssistantService) GetAIConfig(ctx context.Context) (*models.AIConfig, error) {
	return s.sqliteRepo.GetAIConfig(ctx)
}

// DeleteScheduledTask 删除指定的待办提醒任务
func (s *AssistantService) DeleteScheduledTask(ctx context.Context, taskID string) error {
	return s.sqliteRepo.DeleteScheduledTask(ctx, taskID)
}

// ConfirmScheduledTask 保存用户修正，并将待确认任务激活为可调度任务。
func (s *AssistantService) ConfirmScheduledTask(ctx context.Context, task *models.ScheduledTask) error {
	task.ID = strings.TrimSpace(task.ID)
	task.Title = strings.TrimSpace(task.Title)
	task.Description = strings.TrimSpace(task.Description)
	task.ActionType = strings.TrimSpace(task.ActionType)
	if task.ID == "" {
		return fmt.Errorf("task id is required")
	}
	if task.Title == "" {
		return fmt.Errorf("task title is required")
	}
	if task.DueTime <= 0 {
		return fmt.Errorf("task due time is required")
	}
	switch task.ActionType {
	case "reminder", "alarm", "api_call":
	default:
		return fmt.Errorf("unsupported action type: %s", task.ActionType)
	}
	return s.sqliteRepo.ConfirmScheduledTask(ctx, task)
}

// UpdateTaskStatus 更新待办任务的执行状态
func (s *AssistantService) UpdateTaskStatus(ctx context.Context, taskID string, status string) error {
	return s.sqliteRepo.UpdateTaskStatus(ctx, taskID, status)
}

func (s *AssistantService) GetGraphRAGRelations(ctx context.Context, memoryIDs []string) ([]*repositories.EntityRelation, error) {
	return s.sqliteRepo.GetGraphRAGRelations(ctx, memoryIDs)
}

func (s *AssistantService) GetMemoryEntities(ctx context.Context, memoryIDs []string) ([]*repositories.MemoryEntityRelation, error) {
	return s.sqliteRepo.GetMemoryEntities(ctx, memoryIDs)
}

func (s *AssistantService) RetrieveAndStreamAnswer(ctx context.Context, query string, sessionID string, cfg *models.AIConfig) (*schema.StreamReader[*schema.Message], error) {
	return s.einoEngine.RetrieveAndStreamAnswer(ctx, query, sessionID, cfg)
}

func (s *AssistantService) SaveChatMessage(ctx context.Context, msg *models.ChatMessage) error {
	return s.sqliteRepo.SaveChatMessage(ctx, msg)
}

// HandleTaskCommands 处理并净化文本中的任务指令
func (s *AssistantService) HandleTaskCommands(ctx context.Context, answer string) string {
	return s.einoEngine.HandleTaskCommands(ctx, answer)
}

// SyncE2EEMemories 执行 E2EE 双向增量同步与冲突处理 (时间戳较新者覆盖较旧者)
func (s *AssistantService) SyncE2EEMemories(ctx context.Context, lastSyncTime int64, clientChanges []*models.Memory) ([]*models.Memory, int64, error) {
	// 1. 处理客户端推送的数据变更
	for _, clientMem := range clientChanges {
		existingMem, err := s.sqliteRepo.GetMemory(ctx, clientMem.ID)
		if err != nil {
			fmt.Printf("[WARN] E2EE Sync failed to query memory %s: %v\n", clientMem.ID, err)
			continue
		}

		if existingMem == nil {
			// 记录不存在，直接入库
			if saveErr := s.sqliteRepo.SaveMemory(ctx, clientMem); saveErr != nil {
				fmt.Printf("[ERROR] E2EE Sync failed to save new memory %s: %v\n", clientMem.ID, saveErr)
			}
			continue
		}

		// 冲突判定：时间戳新者覆盖旧者
		if clientMem.UpdatedAt > existingMem.UpdatedAt {
			if saveErr := s.sqliteRepo.SaveMemory(ctx, clientMem); saveErr != nil {
				fmt.Printf("[ERROR] E2EE Sync failed to update memory %s: %v\n", clientMem.ID, saveErr)
			}
		}
	}

	// 2. 拉取云端最近的增量更新（比 lastSyncTime 更新的所有数据）
	serverChanges, err := s.sqliteRepo.GetMemoriesUpdatedAfter(ctx, lastSyncTime)
	if err != nil {
		return nil, 0, err
	}

	// 过滤掉客户端刚才刚刚推送上去的记录，避免下发造成冗余
	uploadedMap := make(map[string]bool)
	for _, m := range clientChanges {
		uploadedMap[m.ID] = true
	}

	var delta []*models.Memory
	for _, sm := range serverChanges {
		if !uploadedMap[sm.ID] {
			delta = append(delta, sm)
		}
	}

	return delta, time.Now().Unix(), nil
}
