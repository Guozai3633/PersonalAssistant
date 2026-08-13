package ai

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"assistant/config"
	"assistant/models"
	"assistant/repositories"

	einoembed "github.com/cloudwego/eino-ext/components/embedding/openai"
	einomodel "github.com/cloudwego/eino-ext/components/model/openai"
	"github.com/cloudwego/eino/components/embedding"
	"github.com/cloudwego/eino/components/model"
	"github.com/cloudwego/eino/schema"
)

type EinoEngine struct {
	sqliteRepo *repositories.SQLiteRepository
	qdrantRepo *repositories.QdrantRepository

	chatModelCache  sync.Map // key: sha256 of config, value: model.ChatModel
	embedderCache   sync.Map // key: sha256 of config, value: embedding.Embedder
	inFlightIngests sync.Map // key: sha256 of rawContent, value: bool
}

func NewEinoEngine(sqliteRepo *repositories.SQLiteRepository, qdrantRepo *repositories.QdrantRepository) *EinoEngine {
	return &EinoEngine{
		sqliteRepo: sqliteRepo,
		qdrantRepo: qdrantRepo,
	}
}

// getCacheKey 计算 API 配置的唯一哈希，用于连接复用，防范内存泄露
func (e *EinoEngine) getCacheKey(provider, model, apiKey, baseURL string, isEmbed bool) string {
	var keyStr string
	if isEmbed {
		keyStr = fmt.Sprintf("embed-%s-%s-%s-%s", provider, model, apiKey, baseURL)
	} else {
		keyStr = fmt.Sprintf("chat-%s-%s-%s-%s", provider, model, apiKey, baseURL)
	}
	h := sha256.New()
	h.Write([]byte(keyStr))
	return fmt.Sprintf("%x", h.Sum(nil))
}

// GetChatModel 动态获取或创建 ChatModel 客户端
func (e *EinoEngine) GetChatModel(ctx context.Context, cfg *models.AIConfig) (model.ChatModel, error) {
	provider := cfg.ChatProvider
	modelName := cfg.ChatModel
	apiKey := cfg.ChatAPIKey

	// 若系统配置了离线 LOCAL_MODE，强制本地推理
	if config.GlobalConfig != nil && config.GlobalConfig.LocalMode {
		provider = "local"
		if modelName == "" || provider != cfg.ChatProvider {
			modelName = "llama3"
		}
		apiKey = "local"
	}

	if apiKey == "" && provider == "local" {
		apiKey = "local"
	}
	baseURLVal := cfg.ChatBaseURL

	cacheKey := e.getCacheKey(provider, modelName, apiKey, baseURLVal, false)
	if val, ok := e.chatModelCache.Load(cacheKey); ok {
		return val.(model.ChatModel), nil
	}

	// 统一映射 OpenAI 兼容协议
	var baseURL string
	if baseURLVal != "" {
		baseURL = baseURLVal
	} else {
		if provider == "openai" {
			baseURL = "https://api.openai.com/v1"
		} else if provider == "local" {
			if config.GlobalConfig != nil && config.GlobalConfig.OllamaAPIBase != "" {
				baseURL = formatLocalBaseURL(config.GlobalConfig.OllamaAPIBase)
			} else {
				baseURL = "http://localhost:11434/v1" // Ollama 默认兼容接口
			}
		}
	}

	chatModel, err := einomodel.NewChatModel(ctx, &einomodel.ChatModelConfig{
		APIKey:  apiKey,
		BaseURL: baseURL,
		Model:   modelName,
	})
	if err != nil {
		// 自愈降级：如果不是本地模式，且本地服务可用，自动转入本地 Ollama
		if provider != "local" && config.GlobalConfig != nil && config.GlobalConfig.OllamaAPIBase != "" {
			fmt.Printf("[WARN] Failed to create remote chat model (%v), falling back to local Ollama.\n", err)
			cfg.ChatProvider = "local"
			cfg.ChatModel = "llama3"
			cfg.ChatAPIKey = "local"
			cfg.ChatBaseURL = formatLocalBaseURL(config.GlobalConfig.OllamaAPIBase)
			return e.GetChatModel(ctx, cfg)
		}
		return nil, fmt.Errorf("failed to create OpenAI ChatModel: %w", err)
	}

	e.chatModelCache.Store(cacheKey, chatModel)
	return chatModel, nil
}

// GetEmbedder 动态获取或创建 Embedder 客户端
func (e *EinoEngine) GetEmbedder(ctx context.Context, cfg *models.AIConfig) (embedding.Embedder, error) {
	provider := cfg.EmbedProvider
	modelName := cfg.EmbedModel
	apiKey := cfg.EmbedAPIKey

	// 若系统配置了离线 LOCAL_MODE，强制本地推理
	if config.GlobalConfig != nil && config.GlobalConfig.LocalMode {
		provider = "local"
		if modelName == "" || provider != cfg.EmbedProvider {
			modelName = "nomic-embed-text"
		}
		apiKey = "local"
	}

	if apiKey == "" && provider == "local" {
		apiKey = "local"
	}
	baseURLVal := cfg.EmbedBaseURL

	cacheKey := e.getCacheKey(provider, modelName, apiKey, baseURLVal, true)
	if val, ok := e.embedderCache.Load(cacheKey); ok {
		return val.(embedding.Embedder), nil
	}

	var baseURL string
	if baseURLVal != "" {
		baseURL = baseURLVal
	} else {
		if provider == "openai" {
			baseURL = "https://api.openai.com/v1"
		} else if provider == "local" {
			if config.GlobalConfig != nil && config.GlobalConfig.OllamaAPIBase != "" {
				baseURL = formatLocalBaseURL(config.GlobalConfig.OllamaAPIBase)
			} else {
				baseURL = "http://localhost:11434/v1"
			}
		}
	}

	embedder, err := einoembed.NewEmbedder(ctx, &einoembed.EmbeddingConfig{
		APIKey:  apiKey,
		BaseURL: baseURL,
		Model:   modelName,
	})
	if err != nil {
		// 自愈降级：自动转入本地 Ollama embedding
		if provider != "local" && config.GlobalConfig != nil && config.GlobalConfig.OllamaAPIBase != "" {
			fmt.Printf("[WARN] Failed to create remote embedder (%v), falling back to local Ollama.\n", err)
			cfg.EmbedProvider = "local"
			cfg.EmbedModel = "nomic-embed-text"
			cfg.EmbedAPIKey = "local"
			cfg.EmbedBaseURL = formatLocalBaseURL(config.GlobalConfig.OllamaAPIBase)
			return e.GetEmbedder(ctx, cfg)
		}
		return nil, fmt.Errorf("failed to create OpenAI Embedder: %w", err)
	}

	e.embedderCache.Store(cacheKey, embedder)
	return embedder, nil
}

// formatLocalBaseURL 格式化本地 Ollama API 路径为 OpenAI 兼容子端点
func formatLocalBaseURL(apiBase string) string {
	if apiBase == "" {
		return "http://localhost:11434/v1"
	}
	if !strings.HasSuffix(apiBase, "/v1") && !strings.HasSuffix(apiBase, "/v1/") {
		if strings.HasSuffix(apiBase, "/") {
			return apiBase + "v1"
		}
		return apiBase + "/v1"
	}
	return apiBase
}

type ExtractedTask struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	ActionType  string `json:"action_type"` // e.g. "reminder", "alarm", "api_call"
	DueTime     string `json:"due_time"`    // ISO 8601 格式时间，如 "2026-06-17T09:00:00+08:00"
}

type ExtractedMetadata struct {
	Content       string          `json:"content"`
	Title         string          `json:"title"`
	ExtractedTime string          `json:"extracted_time"` // ISO 8601
	Priority      int             `json:"priority"`
	Tags          []string        `json:"tags"`
	Tasks         []ExtractedTask `json:"tasks,omitempty"` // 提取出的主动任务
}

// ExtractMetadata 从非结构化文本中利用大模型强行提取元数据 (NER)
// 增强版：支持更多数据类型和格式化的日常数据，优化元数据提取，以及意图与任务提取

// ExtractMetadata 从非结构化文本中利用大模型强行提取元数据 (NER)
// 增强版：支持更多数据类型和格式化的日常数据，优化元数据提取，以及意图与任务提取
func (e *EinoEngine) ExtractMetadata(ctx context.Context, text string, sourceType string, cfg *models.AIConfig) (*ExtractedMetadata, error) {
	chat, err := e.GetChatModel(ctx, cfg)
	if err != nil {
		return nil, err
	}

	sourceTypeHint := ""
	switch sourceType {
	case "image":
		sourceTypeHint = "（图片OCR内容）"
	case "link":
		sourceTypeHint = "（网页/链接内容）"
	case "audio":
		sourceTypeHint = "（语音转录文本）"
	case "file":
		sourceTypeHint = "（文件内容）"
	case "note":
		sourceTypeHint = "（笔记/便签）"
	case "contact":
		sourceTypeHint = "（联系人信息）"
	case "location":
		sourceTypeHint = "（位置信息）"
	default:
		sourceTypeHint = ""
	}

	weekdayCn := map[time.Weekday]string{
		time.Sunday:    "日",
		time.Monday:    "一",
		time.Tuesday:   "二",
		time.Wednesday: "三",
		time.Thursday:  "四",
		time.Friday:    "五",
		time.Saturday:  "六",
	}[time.Now().Weekday()]
	nowTimeStr := time.Now().Format("2006-01-02 15:04:05") + " 星期" + weekdayCn

	systemPrompt := fmt.Sprintf("# 任务目标\n"+
		"你是一个高精度的个人日程与事务元数据提取器。你的职责是将用户输入的碎片化信息%s，整理为结构化的 JSON 元数据。\n\n"+
		"# 当前时间参考\n"+
		"当前系统时间为: %s (Unix timestamp: %d) (请根据此绝对时间换算用户口中的 明天、下周五、大后天 等相对时间)\n\n"+
		"# 提取字段规范\n"+
		"请提取以下字段，并必须以严格 JSON 格式输出，不要包含任何 Markdown 格式包裹（如 ```json 等）：\n"+
		"{\n"+
		"  \"content\": \"提取并精简后的事件摘要文本，保留核心意图和关键信息\",\n"+
		"  \"title\": \"简短标题，10字以内，极具写实风格地概括核心内容。如果用户没有提供或强调标题，你必须根据内容数据智能拟定提炼出一个10字以内最能反映本质的标题。此字段在任何情况下都不能返回空字符串或无标题\",\n"+
		"  \"extracted_time\": \"事件的发生或截止时间，格式必须为 ISO 8601 (YYYY-MM-DDTHH:mm:SSZ)。如果事件没有明确对应的时间，返回空字符串\",\n"+
		"  \"priority\": 1,\n"+
		"  \"tags\": [\"标签A\", \"标签B\"],\n"+
		"  \"tasks\": [\n"+
		"    {\n"+
		"      \"id\": \"唯一任务ID(如 task_12345)\",\n"+
		"      \"title\": \"任务简短标题\",\n"+
		"      \"description\": \"任务详细描述\",\n"+
		"      \"action_type\": \"reminder 或 alarm 或 api_call\",\n"+
		"      \"due_time\": \"2026-06-17T09:00:00+08:00\" // 必须是一个精确 of 8601 格式的本地时间字符串 (带有时区)，代表何时触发该任务\n"+
		"    }\n"+
		"  ]\n"+
		"}\n\n"+
		"# 提取规则\n"+
		"1. 如果提到 取消考试、改期 等词，请将 取消、变更 标签加入 tags。\n"+
		"2. 标签分类尽量精炼：上课、考试、账单、日常事务、工作、生活、健康、财务、社交等。\n"+
		"3. 请进行日期换算。例如当前时间是周三，用户说 下周一早八点上机房课，extracted_time 应对应日期。\n"+
		"4. 对于链接类信息，提取域名和核心内容概要；对于联系人信息，提取姓名、电话、邮箱等关键信息。\n"+
		"5. 如果内容包含明显的【系统提醒】、【闹钟】、【代办任务】意图（如“提醒我明早9点开会”），请在 `tasks` 数组中添加对应的结构，并生成具体的 `due_time`（ISO 8601 字符串）。如果没有任何需要主动执行的任务，`tasks` 保持空数组 []。\n"+
		"6. 标题拟定原则：任何情况下，你必须根据内容智能提炼出 10 字以内的写实标题。如果用户没有明确提到标题，不得留空或返回'（暂无标题）'，必须提炼；如果内容完全无法提炼，以其主要标签或行为命名。\n"+
		"7. 保证 JSON 结构合法，提取不出任何字段时对应字段返回默认值。", sourceTypeHint, nowTimeStr, time.Now().Unix())

	messages := []*schema.Message{
		schema.SystemMessage(systemPrompt),
		schema.UserMessage(text),
	}

	fmt.Printf("[DEBUG] ExtractMetadata -> Starting metadata extraction. Provider: %s | Model: %s | InputLength: %d\n", cfg.ChatProvider, cfg.ChatModel, len(text))

	resp, err := chat.Generate(ctx, messages)
	if err != nil {
		fmt.Printf("[ERROR] ExtractMetadata -> LLM generation failed: %v\n", err)
		return nil, fmt.Errorf("failed to generate metadata: %w", err)
	}

	// 清理 Markdown JSON 包装
	jsonStr := resp.Content
	re := regexp.MustCompile("(?s)```(?:json)?(.*?)```")
	if matches := re.FindStringSubmatch(jsonStr); len(matches) > 1 {
		jsonStr = matches[1]
	}

	var meta ExtractedMetadata
	if err := json.Unmarshal([]byte(jsonStr), &meta); err != nil {
		fmt.Printf("[ERROR] ExtractMetadata -> JSON Unmarshal failed: %v\n[ERROR] ExtractMetadata -> LLM Raw Output was: %q\n", err, resp.Content)
		// 回退容错：填充基础数据
		meta.Content = text
		meta.Title = ""
		meta.Tags = []string{"未分类"}
		meta.Priority = 1
	} else {
		fmt.Printf("[DEBUG] ExtractMetadata -> Successfully extracted. Title: %q | Time: %q | Tags: %v | Tasks Count: %d\n", meta.Title, meta.ExtractedTime, meta.Tags, len(meta.Tasks))
	}

	return &meta, nil
}

type ExtractedQuery struct {
	StartTime     string   `json:"start_time"`
	EndTime       string   `json:"end_time"`
	Tags          []string `json:"tags"`
	SemanticQuery string   `json:"semantic_query"`
}

// ParseQueryIntent 解析用户的检索意图
func (e *EinoEngine) ParseQueryIntent(ctx context.Context, query string, cfg *models.AIConfig) (*ExtractedQuery, error) {
	chat, err := e.GetChatModel(ctx, cfg)
	if err != nil {
		return nil, err
	}

	systemPrompt := fmt.Sprintf(`# 任务目标
你是一个精准的查询意图解析器。你需要将用户的自然语言问题，转换为结构化的数据库检索条件。

# 当前时间参考
当前系统时间为: %s

# 解析字段规范
必须只返回以下严格的 JSON 结构，不要包含任何 Markdown 格式包裹（如 `+"```json"+` 等）：
{
  "start_time": "事件检索的起始时间，ISO 8601 格式，无明确时间则返回空字符串",
  "end_time": "事件检索的截止时间，ISO 8601 格式，无明确时间则返回空字符串",
  "tags": ["用于精确过滤的标签数组，如果没有明显的标签词则返回空数组"],
  "semantic_query": "慢/快 核心语义查询句，用于向量检索"
}`, time.Now().Format(time.RFC3339))

	messages := []*schema.Message{
		schema.SystemMessage(systemPrompt),
		schema.UserMessage(query),
	}

	resp, err := chat.Generate(ctx, messages)
	if err != nil {
		return nil, fmt.Errorf("failed to parse query: %w", err)
	}

	jsonStr := resp.Content
	re := regexp.MustCompile("(?s)```(?:json)?(.*?)```")
	if matches := re.FindStringSubmatch(jsonStr); len(matches) > 1 {
		jsonStr = matches[1]
	}

	var intent ExtractedQuery
	if err := json.Unmarshal([]byte(jsonStr), &intent); err != nil {
		// 降级策略
		intent.SemanticQuery = query
		intent.Tags = []string{}
	}

	return &intent, nil
}

// PerformOCR 通过多模态 Vision 模型对 base64 图片数据进行 OCR 文字提取
func (e *EinoEngine) PerformOCR(ctx context.Context, base64Data string, cfg *models.AIConfig) (string, error) {
	provider := cfg.VisionProvider
	modelName := cfg.VisionModel
	apiKey := cfg.VisionAPIKey
	baseURLVal := cfg.VisionBaseURL

	// 降级机制：如果未配置 VisionModel，则完全降级使用 ChatModel 对应的配置
	if modelName == "" {
		provider = cfg.ChatProvider
		modelName = cfg.ChatModel
		apiKey = cfg.ChatAPIKey
		baseURLVal = cfg.ChatBaseURL
	}

	// 1. 确定 BaseURL
	var baseURL string
	if baseURLVal != "" {
		baseURL = baseURLVal
	} else {
		if provider == "openai" {
			baseURL = "https://api.openai.com/v1"
		} else if provider == "local" {
			baseURL = "http://localhost:11434/v1"
		}
	}
	baseURL = strings.TrimSuffix(baseURL, "/")

	fmt.Printf("[DEBUG] PerformOCR -> Dispatching Vision Request. Provider: %s | Model: %s | BaseURL: %s | base64Len: %d\n", provider, modelName, baseURL, len(base64Data))

	// 构造 OpenAI 兼容的多模态请求 Payload
	type ImageURLInfo struct {
		URL string `json:"url"`
	}
	type ContentItem struct {
		Type     string        `json:"type"`
		Text     string        `json:"text,omitempty"`
		ImageURL *ImageURLInfo `json:"image_url,omitempty"`
	}
	type VisionMessage struct {
		Role    string        `json:"role"`
		Content []ContentItem `json:"content"`
	}
	type VisionRequest struct {
		Model    string          `json:"model"`
		Messages []VisionMessage `json:"messages"`
	}

	textPrompt := `你是一个顶级的多模态 AI 视觉分析助手。请对这张图片进行全面深度理解和分析：

1. **场景识别**：描述图片中展示的场景、物体、人物、环境信息。
2. **文字提取**：如果图片中包含任何文字（包括屏幕截图、文档、通知、聊天记录等），请完整提取并保持原文排版。如果是微信聊天截图，请清晰整理出发送者、时间和内容。
3. **意图推断**：根据图片内容推测用户拍这张照片最可能的目的（例如：记录待办事项、保存收据信息、备忘会议纪要、保存地址、记录菜单价格等）。
4. **关键信息**：提炼图片中最核心的信息要素（如金额、日期、地点、联系方式、任务事项等）。
5. **可操作建议**：如果图片内容隐含行动项，给出简洁的操作建议。

请用中文回答，结构化输出，简洁精炼。不要输出任何 Markdown 标记包裹。`

	imgURL := base64Data
	if !strings.HasPrefix(imgURL, "data:image/") {
		imgURL = "data:image/png;base64," + base64Data
	}

	reqBody := VisionRequest{
		Model: modelName,
		Messages: []VisionMessage{
			{
				Role: "user",
				Content: []ContentItem{
					{
						Type: "text",
						Text: textPrompt,
					},
					{
						Type: "image_url",
						ImageURL: &ImageURLInfo{
							URL: imgURL,
						},
					},
				},
			},
		},
	}

	payloadBytes, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("failed to marshal vision request: %w", err)
	}

	apiURL := fmt.Sprintf("%s/chat/completions", baseURL)
	req, err := http.NewRequestWithContext(ctx, "POST", apiURL, bytes.NewBuffer(payloadBytes))
	if err != nil {
		return "", fmt.Errorf("failed to create http request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if apiKey != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", apiKey))
	}

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("[ERROR] PerformOCR -> Network request failed: %v\n", err)
		return "", fmt.Errorf("failed to send vision request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var errResp struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&errResp)
		errMsg := fmt.Sprintf("API returned non-200 status: %d", resp.StatusCode)
		if errResp.Error.Message != "" {
			errMsg = fmt.Sprintf("API error (status %d): %s", resp.StatusCode, errResp.Error.Message)
		}
		fmt.Printf("[ERROR] PerformOCR -> Vision LLM API Request Failed: %s\n", errMsg)
		return "", fmt.Errorf("%s", errMsg)
	}

	type Choice struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	}
	type VisionResponse struct {
		Choices []Choice `json:"choices"`
	}

	var visionResp VisionResponse
	if err := json.NewDecoder(resp.Body).Decode(&visionResp); err != nil {
		return "", fmt.Errorf("failed to decode vision response: %w", err)
	}

	if len(visionResp.Choices) == 0 {
		return "", fmt.Errorf("API returned empty choices")
	}

	ocrText := strings.TrimSpace(visionResp.Choices[0].Message.Content)
	if ocrText == "" {
		fmt.Printf("[ERROR] PerformOCR -> Vision LLM returned empty content string.\n")
		return "", fmt.Errorf("OCR result is empty text")
	}

	fmt.Printf("[DEBUG] PerformOCR -> Successfully extracted image info. Length: %d characters.\n", len(ocrText))
	return ocrText, nil
}

func (e *EinoEngine) IngestMemory(ctx context.Context, id string, rawContent string, sourceType string, sourceMeta string, isEncrypted bool, title string, tags []string, cfg *models.AIConfig) (*models.Memory, error) {
	fmt.Printf("[DEBUG] IngestMemory -> Ingestion Initiated. ID: %s | SourceType: %s | SourceMeta: %s | IsEncrypted: %t | RawContentLen: %d | InputTitle: %q | InputTags: %v\n",
		id, sourceType, sourceMeta, isEncrypted, len(rawContent), title, tags)

	// E2EE 加密数据直通存储通道
	if isEncrypted {
		fmt.Printf("[DEBUG] IngestMemory -> E2EE Encrypted mode is active for ID %s. Bypassing OCR image analysis and LLM Metadata extraction completely.\n", id)
		now := time.Now().Unix()
		mem := &models.Memory{
			ID:               id,
			RawContent:       rawContent,
			OriginalContent:  rawContent,
			ExtractedTime:    "",
			Priority:         1,
			SourceType:       sourceType,
			SourceMeta:       sourceMeta,
			Title:            title,
			ProcessingStatus: models.MemoryStatusCompleted,
			CreatedAt:        now,
			UpdatedAt:        now,
			Tags:             tags,
		}
		if err := e.sqliteRepo.SaveMemory(ctx, mem); err != nil {
			fmt.Printf("[ERROR] IngestMemory -> Failed to save encrypted memory: %v\n", err)
			return nil, fmt.Errorf("failed to save encrypted memory to SQLite: %w", err)
		}
		fmt.Printf("[DEBUG] IngestMemory -> Encrypted memory saved successfully.\n")
		return mem, nil
	}

	// 0.2 在途并发去重锁（基于 SHA256，阻止 1 秒内完全相同的并发录入导致并发穿透）
	trimmedContent := strings.TrimSpace(rawContent)
	if trimmedContent != "" {
		h := sha256.Sum256([]byte(trimmedContent))
		lockKey := fmt.Sprintf("%x", h)
		if _, loaded := e.inFlightIngests.LoadOrStore(lockKey, true); loaded {
			return nil, fmt.Errorf("duplicate memory ingestion in flight")
		}
		defer e.inFlightIngests.Delete(lockKey)
	}

	// 0.3 5分钟内容防重复校验（幂等去重防手抖，保障底层质量）
	recentMem, err := e.sqliteRepo.FindRecentMemoryByContent(ctx, rawContent, 5*time.Minute)
	if err != nil {
		fmt.Printf("[WARN] Failed to query recent duplicate memory: %v\n", err)
	} else if recentMem != nil {
		fmt.Printf("[DEBUG] IngestMemory -> Found recent duplicate memory for ID %s. Reusing ID: %s\n", id, recentMem.ID)
		return recentMem, nil
	}

	// 构造初始 Memory 记录，先存入 SQLite，秒级返回
	now := time.Now().Unix()
	mem := &models.Memory{
		ID:               id,
		RawContent:       rawContent,
		OriginalContent:  rawContent,
		ExtractedTime:    "",
		Priority:         1,
		SourceType:       sourceType,
		SourceMeta:       sourceMeta,
		Title:            title,
		ProcessingStatus: models.MemoryStatusPending,
		CreatedAt:        now,
		UpdatedAt:        now,
		Tags:             tags,
	}

	if err := e.sqliteRepo.SaveMemory(ctx, mem); err != nil {
		fmt.Printf("[ERROR] SQLite initial save failed for %s: %v\n", id, err)
		return nil, fmt.Errorf("sqlite initial save step failed: %w", err)
	}

	fmt.Printf("[INFO] Initial Memory %s created successfully and saved to SQLite\n", id)
	return mem, nil
}

// SearchSimilarInQdrant 辅助向量查询封装
func (e *EinoEngine) SearchSimilarInQdrant(ctx context.Context, queryText string, cfg *models.AIConfig) ([]repositories.SearchResult, error) {
	embedder, err := e.GetEmbedder(ctx, cfg)
	if err != nil {
		return nil, err
	}

	vectors, err := embedder.EmbedStrings(ctx, []string{queryText})
	if err != nil || len(vectors) == 0 {
		return nil, fmt.Errorf("embedding failed for search: %w", err)
	}
	vector := vectors[0]

	// 转换精度 []float64 -> []float32
	vector32 := make([]float32, len(vector))
	for i, v := range vector {
		vector32[i] = float32(v)
	}

	collectionName := fmt.Sprintf("memories_%s_%d", cfg.EmbedProvider, len(vector32))
	has, err := e.qdrantRepo.HasCollection(ctx, collectionName)
	if err != nil || !has {
		// 集合不存在表示无历史向量
		return nil, nil
	}

	return e.qdrantRepo.SearchSimilar(ctx, collectionName, vector32, 15)
}

// RRFScore 存储重排打分项
type RRFItem struct {
	ID    string
	Score float64
}

// ExecuteRRF 本地 RRF (Reciprocal Rank Fusion) 重排融合算法
func (e *EinoEngine) ExecuteRRF(sqlIDs []string, vecIDs []string) []string {
	scores := make(map[string]float64)
	k := 60.0
	wSQL := 1.5
	wVec := 1.0

	// 显式复制以防修改原切片或数据覆写
	sqlCopy := make([]string, len(sqlIDs))
	copy(sqlCopy, sqlIDs)
	vecCopy := make([]string, len(vecIDs))
	copy(vecCopy, vecIDs)

	for rank, id := range sqlCopy {
		scores[id] += wSQL * (1.0 / (k + float64(rank)))
	}

	for rank, id := range vecCopy {
		scores[id] += wVec * (1.0 / (k + float64(rank)))
	}

	var items []RRFItem
	for id, score := range scores {
		items = append(items, RRFItem{ID: id, Score: score})
	}

	// 按得分降序排序
	for i := 0; i < len(items); i++ {
		for j := i + 1; j < len(items); j++ {
			if items[j].Score > items[i].Score {
				items[i], items[j] = items[j], items[i]
			}
		}
	}

	var finalIDs []string
	for _, item := range items {
		finalIDs = append(finalIDs, item.ID)
		if len(finalIDs) >= 5 { // 限制最终喂给大模型上下文为 Top-5
			break
		}
	}

	return finalIDs
}

// HandleTaskCommands 匹配并处理指令，同时净化文字回复内容
func (e *EinoEngine) HandleTaskCommands(ctx context.Context, answer string) string {
	re := regexp.MustCompile(`\[TASK_COMMAND:\s*DELETE:\s*([a-zA-Z0-9_\-]+)\]`)
	matches := re.FindAllStringSubmatch(answer, -1)
	for _, m := range matches {
		if len(m) > 1 {
			taskID := m[1]
			fmt.Printf("[INFO] Intercepted TASK_COMMAND. Deleting scheduled task: %s\n", taskID)
			if err := e.sqliteRepo.DeleteScheduledTask(ctx, taskID); err != nil {
				fmt.Printf("[ERROR] Failed to execute TASK_COMMAND delete task %s: %v\n", taskID, err)
			}
		}
	}
	clean := re.ReplaceAllString(answer, "")
	return strings.TrimSpace(clean)
}

// RetrieveAndAnswer 双轨混合检索与生成流程 (Retrieval Graph)
func (e *EinoEngine) RetrieveAndAnswer(ctx context.Context, query string, sessionID string, cfg *models.AIConfig) (*models.ChatResult, error) {
	// 1. 意图提取与重写
	intent, err := e.ParseQueryIntent(ctx, query, cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to parse user query intent: %w", err)
	}

	// 2. 双通道并行召回
	// 轨道 A: SQL 精准检索
	sqlMemories, err := e.sqliteRepo.SearchMemoriesByTimeRange(ctx, intent.StartTime, intent.EndTime, intent.Tags)
	if err != nil {
		return nil, fmt.Errorf("sqlite retrieve step failed: %w", err)
	}
	var sqlIDs []string
	for _, m := range sqlMemories {
		sqlIDs = append(sqlIDs, m.ID)
	}

	// 轨道 B: Qdrant 向量检索
	vecResults, err := e.SearchSimilarInQdrant(ctx, intent.SemanticQuery, cfg)
	if err != nil {
		return nil, fmt.Errorf("qdrant retrieve step failed: %w", err)
	}
	var vecIDs []string
	for _, r := range vecResults {
		if r.Score > 0.35 { // 只保留相似度大于 0.35 的相关向量
			vecIDs = append(vecIDs, r.MemoryID)
		}
	}

	// 3. RRF 本地排序融合
	mergedIDs := e.ExecuteRRF(sqlIDs, vecIDs)

	// 4. 提取完整事实并拼接上下文
	var contextChunks []string
	var sources []*models.MemoryCitation
	seenContent := make(map[string]bool)
	for _, id := range mergedIDs {
		mem, err := e.sqliteRepo.GetMemory(ctx, id)
		if err != nil || mem == nil {
			continue
		}

		// 规范化内容去重，防范历史脏数据造成大模型“复读机”幻觉与上下文膨胀
		normContent := strings.TrimSpace(mem.RawContent)
		if seenContent[normContent] {
			continue
		}
		seenContent[normContent] = true

		tagsStr := ""
		if len(mem.Tags) > 0 {
			tagsStr = "[" + fmt.Sprintf("%v", mem.Tags) + "]"
		}
		citationNumber := len(sources) + 1
		chunk := fmt.Sprintf("引用编号: [%d]\nID: %s\n创建时间: %s\n事件关联时间: %s\n标签: %s\n内容: %s",
			citationNumber,
			mem.ID,
			time.Unix(mem.CreatedAt, 0).Format(time.RFC3339),
			mem.ExtractedTime,
			tagsStr,
			mem.RawContent,
		)
		contextChunks = append(contextChunks, chunk)

		title := strings.TrimSpace(mem.Title)
		if title == "" {
			title = "未命名记忆"
		}
		excerptRunes := []rune(strings.TrimSpace(mem.RawContent))
		if len(excerptRunes) > 160 {
			excerptRunes = append(excerptRunes[:160], []rune("...")...)
		}
		sources = append(sources, &models.MemoryCitation{
			MemoryID:      mem.ID,
			Title:         title,
			Excerpt:       string(excerptRunes),
			SourceType:    mem.SourceType,
			SourceMeta:    mem.SourceMeta,
			ExtractedTime: mem.ExtractedTime,
			CreatedAt:     mem.CreatedAt,
		})
	}

	var contextPayload string
	if len(contextChunks) == 0 {
		contextPayload = "未检索到任何本地事实记录。"
	} else {
		for _, chunk := range contextChunks {
			contextPayload += chunk + "\n--------------------\n"
		}
	}

	// 5. 组装对话历史
	historyMsgs, err := e.sqliteRepo.GetChatMessages(ctx, sessionID)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch chat history: %w", err)
	}

	userProfile, _ := e.sqliteRepo.GetUserProfile(ctx)
	if userProfile == "" {
		userProfile = "{}"
	}

	upcomingTasks, _ := e.sqliteRepo.GetUpcomingTasks(ctx, 10)
	tasksPayload := "当前无待执行的提醒或日程任务。"
	if len(upcomingTasks) > 0 {
		var sb strings.Builder
		for _, t := range upcomingTasks {
			sb.WriteString(fmt.Sprintf("- ID: %s, 标题: %s, 描述: %s, 触发时间: %s\n",
				t.ID, t.Title, t.Description, time.Unix(t.DueTime, 0).Format("2006-01-02 15:04:05")))
		}
		tasksPayload = sb.String()
	}

	systemPrompt := fmt.Sprintf(`# 角色定义
你是一个极度靠谱的个人智能助理。你的主要任务是结合 [全局用户画像] 和本地检索到的 [关联事实上下文]，忠实且贴心地回答用户的问题。

# 防幻觉黄金守则
1. 你的回答必须完全基于下方 [本地事实上下文] 区域提供的信息，不能凭空编造事实。
2. 如果上下文中没有提及对应的时间、地点或事件，你必须诚实地回答 "我的记忆库中没有找到相关记录"，严禁依靠大模型自身的常识进行猜测或虚构任何考试、作业截止期。
3. 结合 [全局用户画像]，如果能推断用户的偏好，语气可以更自然、个性化。但事实层面仍然以 [本地事实上下文] 为准。
4. 引用某条本地事实时，在对应句末标注它的引用编号，例如 [1]。不要引用上下文中不存在的编号。

# 待办日程管理指令
当前待执行的日程与待办任务列表如下：
--------------------
%s
--------------------
如果用户当前的提问明确表达了想要 **取消、删除、完成、做完了、不需要了、勾掉** 上述列表中某项任务的意图：
1. 你必须在输出的最开始或最末尾（建议最末尾新起一行），附带严格的指令格式：`+"`[TASK_COMMAND: DELETE: <task_id>]`"+`。例如，用户要取消 ID 为 task_abc 的会面，请附带 `+"`[TASK_COMMAND: DELETE: task_abc]`"+`。
2. 依然用极其自然的口吻礼貌地回复用户，例如：“好的，我已经为您取消了明天上午的会面提醒。”。

# 全局用户画像 (JSON)
--------------------
%s
--------------------

# 本地事实上下文
--------------------
%s
--------------------

# 物理参考时间
当前系统时间: %s (用户提及的 "今天", "明天", "昨天" 等时间均以此为基准)`, tasksPayload, userProfile, contextPayload, time.Now().Format(time.RFC3339))

	var messages []*schema.Message
	messages = append(messages, schema.SystemMessage(systemPrompt))

	// 添加历史消息
	for _, h := range historyMsgs {
		trimmed := strings.TrimSpace(h.Content)
		if trimmed == "" {
			continue // 过滤空历史，避免 LLM 接口 400 报错
		}
		if h.Role == "user" {
			messages = append(messages, schema.UserMessage(trimmed))
		} else if h.Role == "assistant" {
			messages = append(messages, schema.AssistantMessage(trimmed, nil))
		}
	}

	// 添加当前提问
	messages = append(messages, schema.UserMessage(query))

	// 6. 调用大模型生成回答
	chat, err := e.GetChatModel(ctx, cfg)
	if err != nil {
		return nil, err
	}

	resp, err := chat.Generate(ctx, messages)
	if err != nil {
		return nil, fmt.Errorf("llm generate step failed: %w", err)
	}

	cleanAnswer := e.HandleTaskCommands(ctx, resp.Content)

	// 7. 持久化当前轮次聊天记录
	userMsg := &models.ChatMessage{
		ID:        fmt.Sprintf("msg_%d_user", time.Now().UnixNano()),
		SessionID: sessionID,
		Role:      "user",
		Content:   query,
		CreatedAt: time.Now().Unix(),
	}
	_ = e.sqliteRepo.SaveChatMessage(ctx, userMsg)

	assistantMsg := &models.ChatMessage{
		ID:        fmt.Sprintf("msg_%d_assistant", time.Now().UnixNano()),
		SessionID: sessionID,
		Role:      "assistant",
		Content:   cleanAnswer,
		CreatedAt: time.Now().Unix(),
	}
	_ = e.sqliteRepo.SaveChatMessage(ctx, assistantMsg)

	return &models.ChatResult{
		Answer:  cleanAnswer,
		Sources: sources,
	}, nil
}

// RetrieveAndStreamAnswer 双轨混合检索与流式生成流程 (Streaming Retrieval Graph)
func (e *EinoEngine) RetrieveAndStreamAnswer(ctx context.Context, query string, sessionID string, cfg *models.AIConfig) (*schema.StreamReader[*schema.Message], error) {
	// 1. 意图提取与重写
	intent, err := e.ParseQueryIntent(ctx, query, cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to parse user query intent: %w", err)
	}

	// 2. 双通道并行召回
	// 轨道 A: SQL 精准检索
	sqlMemories, err := e.sqliteRepo.SearchMemoriesByTimeRange(ctx, intent.StartTime, intent.EndTime, intent.Tags)
	if err != nil {
		return nil, fmt.Errorf("sqlite retrieve step failed: %w", err)
	}
	var sqlIDs []string
	for _, m := range sqlMemories {
		sqlIDs = append(sqlIDs, m.ID)
	}

	// 轨道 B: Qdrant 向量检索
	vecResults, err := e.SearchSimilarInQdrant(ctx, intent.SemanticQuery, cfg)
	if err != nil {
		return nil, fmt.Errorf("qdrant retrieve step failed: %w", err)
	}
	var vecIDs []string
	for _, r := range vecResults {
		if r.Score > 0.35 { // 只保留相似度大于 0.35 的相关向量
			vecIDs = append(vecIDs, r.MemoryID)
		}
	}

	// 3. RRF 本地排序融合
	mergedIDs := e.ExecuteRRF(sqlIDs, vecIDs)

	// 4. 提取完整事实并拼接上下文
	var contextChunks []string
	seenContent := make(map[string]bool)
	for _, id := range mergedIDs {
		mem, err := e.sqliteRepo.GetMemory(ctx, id)
		if err != nil || mem == nil {
			continue
		}

		// 规范化内容去重，防范历史脏数据造成大模型“复读机”幻觉与上下文膨胀
		normContent := strings.TrimSpace(mem.RawContent)
		if seenContent[normContent] {
			continue
		}
		seenContent[normContent] = true

		tagsStr := ""
		if len(mem.Tags) > 0 {
			tagsStr = "[" + fmt.Sprintf("%v", mem.Tags) + "]"
		}
		chunk := fmt.Sprintf("ID: %s\n创建时间: %s\n事件关联时间: %s\n标签: %s\n内容: %s",
			mem.ID,
			time.Unix(mem.CreatedAt, 0).Format(time.RFC3339),
			mem.ExtractedTime,
			tagsStr,
			mem.RawContent,
		)
		contextChunks = append(contextChunks, chunk)
	}

	var contextPayload string
	if len(contextChunks) == 0 {
		contextPayload = "未检索到任何本地事实记录。"
	} else {
		for _, chunk := range contextChunks {
			contextPayload += chunk + "\n--------------------\n"
		}
	}

	// 5. 组装对话历史
	historyMsgs, err := e.sqliteRepo.GetChatMessages(ctx, sessionID)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch chat history: %w", err)
	}

	userProfile, _ := e.sqliteRepo.GetUserProfile(ctx)
	if userProfile == "" {
		userProfile = "{}"
	}

	upcomingTasks, _ := e.sqliteRepo.GetUpcomingTasks(ctx, 10)
	tasksPayload := "当前无待执行的提醒或日程任务。"
	if len(upcomingTasks) > 0 {
		var sb strings.Builder
		for _, t := range upcomingTasks {
			sb.WriteString(fmt.Sprintf("- ID: %s, 标题: %s, 描述: %s, 触发时间: %s\n",
				t.ID, t.Title, t.Description, time.Unix(t.DueTime, 0).Format("2006-01-02 15:04:05")))
		}
		tasksPayload = sb.String()
	}

	systemPrompt := fmt.Sprintf(`# 角色定义
你是一个极度靠谱的个人智能助理。你的主要任务是结合 [全局用户画像] 和本地检索到的 [关联事实上下文]，忠实且贴心地回答用户的问题。

# 防幻觉黄金守则
1. 你的回答必须完全基于下方 [本地事实上下文] 区域提供的信息，不能凭空编造事实。
2. 如果上下文中没有提及对应的时间、地点或事件，你必须诚实地回答 "我的记忆库中没有找到相关记录"，严禁依靠大模型自身的常识进行猜测或虚构任何考试、作业截止期。
3. 结合 [全局用户画像]，如果能推断用户的偏好，语气可以更自然、个性化。但事实层面仍然以 [本地事实上下文] 为准。

# 待办日程管理指令
当前待执行的日程与待办任务列表如下：
--------------------
%s
--------------------
如果用户当前的提问明确表达了想要 **取消、删除、完成、做完了、不需要了、勾掉** 上述列表中某项任务的意图：
1. 你必须在输出的最开始或最末尾（建议最末尾新起一行），附带严格的指令格式：`+"`[TASK_COMMAND: DELETE: <task_id>]`"+`。例如，用户要取消 ID 为 task_abc 的会面，请附带 `+"`[TASK_COMMAND: DELETE: task_abc]`"+`。
2. 依然用极其自然的口吻礼貌地回复用户，例如：“好的，我已经为您取消了明天上午的会面提醒。”。

# 全局用户画像 (JSON)
--------------------
%s
--------------------

# 本地事实上下文
--------------------
%s
--------------------

# 物理参考时间
当前系统时间: %s (用户提及的 "今天", "明天", "昨天" 等时间均以此为基准)`, tasksPayload, userProfile, contextPayload, time.Now().Format(time.RFC3339))

	var messages []*schema.Message
	messages = append(messages, schema.SystemMessage(systemPrompt))

	// 添加历史消息
	for _, h := range historyMsgs {
		trimmed := strings.TrimSpace(h.Content)
		if trimmed == "" {
			continue // 过滤空历史，避免 LLM 接口 400 报错
		}
		if h.Role == "user" {
			messages = append(messages, schema.UserMessage(trimmed))
		} else if h.Role == "assistant" {
			messages = append(messages, schema.AssistantMessage(trimmed, nil))
		}
	}

	// 添加当前提问
	messages = append(messages, schema.UserMessage(query))

	// 持久化当前轮次用户的聊天记录
	userMsg := &models.ChatMessage{
		ID:        fmt.Sprintf("msg_%d_user", time.Now().UnixNano()),
		SessionID: sessionID,
		Role:      "user",
		Content:   query,
		CreatedAt: time.Now().Unix(),
	}
	_ = e.sqliteRepo.SaveChatMessage(ctx, userMsg)

	// 6. 获取 ChatModel 实例并开启 Stream
	chat, err := e.GetChatModel(ctx, cfg)
	if err != nil {
		return nil, err
	}

	return chat.Stream(ctx, messages)
}

// TranscribeAudio 动态转译音频文件为文本 (STT - Speech to Text)
func (e *EinoEngine) TranscribeAudio(ctx context.Context, audioBytes []byte, fileName string, cfg *models.AIConfig) (string, error) {
	provider := cfg.STTProvider
	modelName := cfg.STTModel
	apiKey := cfg.STTAPIKey
	baseURLVal := cfg.STTBaseURL

	// 降级机制：如果未配置 STTModel，则完全降级使用 ChatModel 对应的配置
	if modelName == "" {
		provider = cfg.ChatProvider
		modelName = "whisper-1" // 默认 OpenAI 语音转文字模型
		apiKey = cfg.ChatAPIKey
		baseURLVal = cfg.ChatBaseURL
	}

	// 1. 确定 BaseURL
	var baseURL string
	if baseURLVal != "" {
		baseURL = baseURLVal
	} else {
		if provider == "openai" {
			baseURL = "https://api.openai.com/v1"
		} else if provider == "local" {
			baseURL = "http://localhost:11434/v1"
		}
	}
	baseURL = strings.TrimSuffix(baseURL, "/")
	// 自愈机制：如果 BaseURL 缺失版本前缀 /v1，且非本地 Ollama 默认端口，自动补齐 /v1 规避 404 错误
	if baseURL != "" && !strings.HasSuffix(baseURL, "/v1") && !strings.Contains(baseURL, "/v1/") && !strings.Contains(baseURL, ":11434") {
		baseURL = baseURL + "/v1"
	}

	// 2. 构造 Multipart 表单数据
	bodyBuf := &bytes.Buffer{}
	bodyWriter := multipart.NewWriter(bodyBuf)

	// 写入 file 字段
	fileWriter, err := bodyWriter.CreateFormFile("file", fileName)
	if err != nil {
		return "", fmt.Errorf("failed to create form file field: %w", err)
	}
	if _, err := fileWriter.Write(audioBytes); err != nil {
		return "", fmt.Errorf("failed to write audio bytes: %w", err)
	}

	// 写入 model 字段
	if err := bodyWriter.WriteField("model", modelName); err != nil {
		return "", fmt.Errorf("failed to write model field: %w", err)
	}

	// 关闭 bodyWriter 写入 Boundary 结束标记
	if err := bodyWriter.Close(); err != nil {
		return "", fmt.Errorf("failed to close body writer: %w", err)
	}

	// 3. 构建 HTTP 请求
	apiURL := fmt.Sprintf("%s/audio/transcriptions", baseURL)
	req, err := http.NewRequestWithContext(ctx, "POST", apiURL, bodyBuf)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", bodyWriter.FormDataContentType())
	if apiKey != "" && provider != "local" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", apiKey))
	} else if apiKey == "" && provider == "local" {
		// 防护：如果本地没有 key，自动设置占位，以防有些 local 代理敏感
		req.Header.Set("Authorization", "Bearer local")
	} else if apiKey != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", apiKey))
	}

	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to execute request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var errResp struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&errResp)
		if errResp.Error.Message != "" {
			return "", fmt.Errorf("API response error (status %d): %s", resp.StatusCode, errResp.Error.Message)
		}
		return "", fmt.Errorf("API returned status %d", resp.StatusCode)
	}

	var successResp struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&successResp); err != nil {
		return "", fmt.Errorf("failed to decode success response: %w", err)
	}

	return successResp.Text, nil
}

// TextToSpeech 将文本转译为语音 (TTS - Text to Speech)
func (e *EinoEngine) TextToSpeech(ctx context.Context, text string, cfg *models.AIConfig) ([]byte, error) {
	provider := cfg.TTSProvider
	modelName := cfg.TTSModel
	apiKey := cfg.TTSAPIKey
	baseURLVal := cfg.TTSBaseURL

	// 降级机制：如果未配置 TTSModel，则完全降级使用 ChatModel 对应的配置
	if modelName == "" {
		provider = cfg.ChatProvider
		modelName = "tts-1" // 默认 OpenAI TTS 模型
		apiKey = cfg.ChatAPIKey
		baseURLVal = cfg.ChatBaseURL
	}

	// 1. 确定 BaseURL
	var baseURL string
	if baseURLVal != "" {
		baseURL = baseURLVal
	} else {
		if provider == "openai" {
			baseURL = "https://api.openai.com/v1"
		} else if provider == "local" {
			baseURL = "http://localhost:11434/v1"
		}
	}
	baseURL = strings.TrimSuffix(baseURL, "/")
	// 防止双重 /v1 拼接：如果用户配置的 baseURL 已经以 /v1 结尾（如 xiaomimimo.com/v1），不应再追加
	if baseURL != "" && !strings.HasSuffix(baseURL, "/v1") && !strings.Contains(baseURL, "/v1/") && !strings.Contains(baseURL, ":11434") {
		baseURL = baseURL + "/v1"
	}

	// 2. 根据模型协议路由生成 Payload
	isMimo := strings.Contains(modelName, "mimo-")

	var payloadBytes []byte
	var err error
	var apiURL string

	if isMimo {
		type MimoMessage struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		}
		type MimoAudio struct {
			Format string `json:"format"`
			Voice  string `json:"voice"`
		}
		type MimoRequest struct {
			Model    string        `json:"model"`
			Messages []MimoMessage `json:"messages"`
			Audio    MimoAudio     `json:"audio"`
		}

		// mimo TTS 官方支持的音色: 冰糖、茉莉、苏打、白桦、Mia、Chloe、Milo、Dean
		voice := "Mia" // 默认使用 Mia（自然中性英文音色）
		if cfg.TTSVoice != "" {
			voice = cfg.TTSVoice
		}
		// 将 OpenAI 标准音色名自动映射为 mimo 官方支持的对应音色
		switch voice {
		case "alloy":
			voice = "Mia"
		case "echo":
			voice = "Milo"
		case "fable":
			voice = "冰糖"
		case "onyx":
			voice = "Dean"
		case "nova":
			voice = "茉莉"
		case "shimmer":
			voice = "Chloe"
		case "mimo_default":
			voice = "Mia" // 修复历史遗留的无效音色名
		}

		mimoReq := MimoRequest{
			Model: modelName,
			Messages: []MimoMessage{
				{
					Role:    "assistant",
					Content: text,
				},
			},
			Audio: MimoAudio{
				Format: "mp3", // 改回 mp3，匹配客户端播放器后缀名
				Voice:  voice,
			},
		}

		payloadBytes, err = json.Marshal(mimoReq)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal mimo tts request: %w", err)
		}
		apiURL = fmt.Sprintf("%s/chat/completions", baseURL)
	} else {
		type TTSRequest struct {
			Model string `json:"model"`
			Input string `json:"input"`
			Voice string `json:"voice"`
		}

		voice := "alloy"
		if cfg.TTSVoice != "" {
			voice = cfg.TTSVoice
		}
		reqBody := TTSRequest{
			Model: modelName,
			Input: text,
			Voice: voice,
		}

		payloadBytes, err = json.Marshal(reqBody)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal tts request: %w", err)
		}
		apiURL = fmt.Sprintf("%s/audio/speech", baseURL)
	}

	// 3. 构建 HTTP 请求
	req, err := http.NewRequestWithContext(ctx, "POST", apiURL, bytes.NewBuffer(payloadBytes))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if apiKey != "" && provider != "local" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", apiKey))
	} else if apiKey == "" && provider == "local" {
		req.Header.Set("Authorization", "Bearer local")
	} else if apiKey != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", apiKey))
	}

	fmt.Printf("[DEBUG] TTS Request -> URL: %s | Model: %s | Provider: %s | PayloadLen: %d | Voice: %s\n", apiURL, modelName, provider, len(payloadBytes), cfg.TTSVoice)

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("[ERROR] TTS HTTP request failed: %v\n", err)
		return nil, fmt.Errorf("failed to execute request: %w", err)
	}
	defer resp.Body.Close()

	fmt.Printf("[DEBUG] TTS Response -> StatusCode: %d | ContentType: %s | ContentLen: %d\n", resp.StatusCode, resp.Header.Get("Content-Type"), resp.ContentLength)

	if resp.StatusCode != http.StatusOK {
		var errResp struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&errResp)
		if errResp.Error.Message != "" {
			return nil, fmt.Errorf("API response error (status %d): %s", resp.StatusCode, errResp.Error.Message)
		}
		return nil, fmt.Errorf("API returned status %d", resp.StatusCode)
	}

	if isMimo {
		type MimoResponse struct {
			Choices []struct {
				Message struct {
					Audio struct {
						Data string `json:"data"`
					} `json:"audio"`
				} `json:"message"`
			} `json:"choices"`
		}

		var mimoResp MimoResponse
		if err := json.NewDecoder(resp.Body).Decode(&mimoResp); err != nil {
			return nil, fmt.Errorf("failed to decode mimo response: %w", err)
		}

		if len(mimoResp.Choices) == 0 || mimoResp.Choices[0].Message.Audio.Data == "" {
			return nil, fmt.Errorf("mimo returned empty audio choices")
		}

		decodedBytes, err := base64.StdEncoding.DecodeString(mimoResp.Choices[0].Message.Audio.Data)
		if err != nil {
			return nil, fmt.Errorf("failed to decode base64 audio data: %w", err)
		}

		return decodedBytes, nil
	}

	audioBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read audio response: %w", err)
	}

	return audioBytes, nil
}

// GenerateUserProfile 基于过去的画像和新的记忆卡片，生成/更新结构化用户画像
func (e *EinoEngine) GenerateUserProfile(ctx context.Context, oldProfile string, recentMemories []*models.Memory, cfg *models.AIConfig) (string, error) {
	chat, err := e.GetChatModel(ctx, cfg)
	if err != nil {
		return "", err
	}

	var memoriesText string
	for _, m := range recentMemories {
		memoriesText += fmt.Sprintf("- [%s] %s (Tags: %v)\n", time.Unix(m.CreatedAt, 0).Format(time.RFC3339), m.RawContent, m.Tags)
	}

	if oldProfile == "" {
		oldProfile = "{}"
	}

	systemPrompt := `# 任务目标
你是一个顶级的心理学与习惯分析专家。你需要根据用户过去已经存在的 JSON 格式 [历史画像]，以及下面提供的最近发生的一批 [新记忆卡片]，推断并更新该用户的全局画像，并以严格的 JSON 格式输出。

# JSON 画像结构要求
请严格按以下字段输出，不要包含任何 Markdown 包裹（如 ` + "```json" + `）：
{
  "basic_info": "推测的用户的基本信息（如姓名、职业、年龄段、居住地等，如无法推测则保留原样或为空）",
  "relationships": ["推测的用户的人际关系，例如：老婆、同事、朋友的名字"],
  "preferences": ["用户的偏好或习惯，例如：喜欢喝咖啡、常去XX地、作息规律"],
  "current_focus": ["用户近期关注的核心事项或焦虑点，例如：近期准备XX考试、计划去旅游"]
}

# 历史画像
` + oldProfile

	userPrompt := `# 新记忆卡片\n` + memoriesText

	messages := []*schema.Message{
		schema.SystemMessage(systemPrompt),
		schema.UserMessage(userPrompt),
	}

	resp, err := chat.Generate(ctx, messages)
	if err != nil {
		return "", fmt.Errorf("failed to generate user profile: %w", err)
	}

	jsonStr := resp.Content
	re := regexp.MustCompile("(?s)```(?:json)?(.*?)```")
	if matches := re.FindStringSubmatch(jsonStr); len(matches) > 1 {
		jsonStr = strings.TrimSpace(matches[1])
	}

	return jsonStr, nil
}

// GenerateSummary 批量聚合并生成知识总结 (Markdown 长文)
func (e *EinoEngine) GenerateSummary(ctx context.Context, memories []*models.Memory, cfg *models.AIConfig) (string, error) {
	chat, err := e.GetChatModel(ctx, cfg)
	if err != nil {
		return "", err
	}

	var memoriesText string
	for _, m := range memories {
		tagsStr := strings.Join(m.Tags, ", ")
		memoriesText += fmt.Sprintf("标题: %s\n创建时间: %s\n事件关联时间: %s\n标签: [%s]\n内容: %s\n--------------------\n",
			m.Title,
			time.Unix(m.CreatedAt, 0).Format(time.RFC3339),
			m.ExtractedTime,
			tagsStr,
			m.RawContent,
		)
	}

	systemPrompt := `# 任务目标
你是一个专业的知识整理与写作助手。你需要将用户提供的多条碎片化记忆卡片（包含笔记、待办、想法、会议记录等），进行深度的逻辑融合与归纳整理，生成一篇结构清晰、内容通顺、排版美观的 Markdown 格式长文。

# 写作要求
1. **结构化排版**：使用合适的 Markdown 标题（#、##、###）、无序/有序列表、引用块等，使内容条理清晰。
2. **逻辑融合**：不要只是简单地把每条记忆罗列出来。要把主题相同或相关的内容合并归类，并根据时间线或事件的逻辑联系，整理成通顺的文章。
3. **补充和扩展**：对于逻辑上有明显断层或不够连贯的地方，可以进行合理的文学性过渡与逻辑润色，使整篇文章更具可读性。
4. **输出格式**：只输出最终的 Markdown 文本内容，不要包含任何包裹用的 ` + "```markdown" + ` 标记或前言、后缀。`

	messages := []*schema.Message{
		schema.SystemMessage(systemPrompt),
		schema.UserMessage(memoriesText),
	}

	resp, err := chat.Generate(ctx, messages)
	if err != nil {
		return "", fmt.Errorf("failed to generate summary: %w", err)
	}

	return resp.Content, nil
}

type ExtractedEntityRelation struct {
	Source     string `json:"source"`
	SourceType string `json:"source_type"`
	Target     string `json:"target"`
	TargetType string `json:"target_type"`
	Relation   string `json:"relation"`
}

func (e *EinoEngine) ExtractEntityRelations(ctx context.Context, text string, cfg *models.AIConfig) ([]*ExtractedEntityRelation, error) {
	chat, err := e.GetChatModel(ctx, cfg)
	if err != nil {
		return nil, err
	}

	systemPrompt := `
# 任务目标
你是一个高精度的三元组关系抽取器（GraphRAG 实体抽取节点）。你的任务是从用户提供的一段个人备忘或事实信息中，提取出核心实体（Entity）以及它们之间的明确指向关系。

# 提取字段规范
请输出一个严格的 JSON 数组，包含三元组关系对象。不要包含任何 Markdown 格式包裹（如 ` + "```json" + ` 等）：
[
  {
    "source": "实体A名称（例如：郭丰硕，北京大学，JARVIS，等等）",
    "source_type": "实体A类型（例如：person, project, location, event, organization 等）",
    "target": "实体B名称",
    "target_type": "实体B类型",
    "relation": "实体A与实体B的关系描述，规范限制在8字以内（例如：开发了，就读于，包含，开始于，等等）"
  }
]

# 提取规则
1. 如果没有明确的实体关系可提取，必须输出空数组 []。
2. 保持实体名称的规范和一致（如 “郭丰硕”、“郭同学” 统一用 “郭丰硕”；“北京”、“北京市” 统一用 “北京”）。
3. 关系不要包含修饰词，直接表述关系核心。
4. 尽量将提取出的 relation 关系描述语规范或映射为以下常用类型之一以保证图谱归类展示效果：
   - '属于' (belongs_to), '触发' (triggers), '参考' (refers), '矛盾' (contradicts), '协同' (collaborates), '开发/创造' (creates), '包含' (contains), '工作于' (works_at), '就读于' (studies_at), '关于' (about)。
   - 若确实无法归入，请使用最简练的 8 字以内精准动词或介词表达。
`

	messages := []*schema.Message{
		schema.SystemMessage(systemPrompt),
		schema.UserMessage(text),
	}

	resp, err := chat.Generate(ctx, messages)
	if err != nil {
		return nil, fmt.Errorf("failed to generate entity relations: %w", err)
	}

	jsonStr := cleanJSONArray(resp.Content)

	var list []*ExtractedEntityRelation
	if err := json.Unmarshal([]byte(jsonStr), &list); err != nil {
		fmt.Printf("[WARN] ExtractEntityRelations -> failed to unmarshal: %v, raw response: %q\n", err, resp.Content)
		return []*ExtractedEntityRelation{}, nil
	}

	return list, nil
}

func cleanJSONArray(content string) string {
	jsonStr := content
	re := regexp.MustCompile("(?s)```(?:json)?(.*?)```")
	if matches := re.FindStringSubmatch(jsonStr); len(matches) > 1 {
		jsonStr = matches[1]
	}
	jsonStr = strings.TrimSpace(jsonStr)
	// 寻找第一个 '[' 和最后一个 ']'
	start := strings.Index(jsonStr, "[")
	end := strings.LastIndex(jsonStr, "]")
	if start != -1 && end != -1 && end > start {
		jsonStr = jsonStr[start : end+1]
	}
	return jsonStr
}
