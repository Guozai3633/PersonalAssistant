package handlers

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"assistant/config"
	"assistant/models"
	"assistant/services"
)

type Handler struct {
	service *services.AssistantService
}

func NewHandler(service *services.AssistantService) *Handler {
	return &Handler{service: service}
}

// escapeJSON 转义 JSON 字符串中的特殊字符，防止前端解析出错
func escapeJSON(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\"", "\\\"")
	s = strings.ReplaceAll(s, "\n", "\\n")
	s = strings.ReplaceAll(s, "\r", "\\r")
	s = strings.ReplaceAll(s, "\t", "\\t")
	return s
}

// parseAIConfig 从 HTTP 请求头中动态抽取用户配置的 AI API 连接凭证
func (h *Handler) parseAIConfig(r *http.Request) *models.AIConfig {
	// 动态检测并覆盖本地离线模式参数
	localModeHeader := r.Header.Get("X-Local-Mode")
	if localModeHeader != "" && config.GlobalConfig != nil {
		config.GlobalConfig.LocalMode = (localModeHeader == "true")
		ollamaBaseHeader := r.Header.Get("X-Ollama-API-Base")
		if ollamaBaseHeader != "" {
			config.GlobalConfig.OllamaAPIBase = ollamaBaseHeader
		}
	}

	chatProvider := r.Header.Get("X-Chat-Provider")
	if chatProvider == "" {
		chatProvider = "openai" // 默认走 OpenAI 协议
	}

	visionProvider := r.Header.Get("X-Vision-Provider")
	if visionProvider == "" {
		visionProvider = chatProvider // 视觉默认同对话
	}

	embedProvider := r.Header.Get("X-Embed-Provider")
	if embedProvider == "" {
		embedProvider = chatProvider // 向量默认同对话
	}

	sttProvider := r.Header.Get("X-STT-Provider")
	if sttProvider == "" {
		sttProvider = chatProvider // 语音默认同对话
	}

	cfg := &models.AIConfig{
		ChatProvider: chatProvider,
		ChatModel:    r.Header.Get("X-Chat-Model"),
		ChatAPIKey:   r.Header.Get("X-Chat-API-Key"),
		ChatBaseURL:  r.Header.Get("X-Chat-Base-URL"),

		VisionProvider: visionProvider,
		VisionModel:    r.Header.Get("X-Vision-Model"),
		VisionAPIKey:   r.Header.Get("X-Vision-API-Key"),
		VisionBaseURL:  r.Header.Get("X-Vision-Base-URL"),

		EmbedProvider: embedProvider,
		EmbedModel:    r.Header.Get("X-Embed-Model"),
		EmbedAPIKey:   r.Header.Get("X-Embed-API-Key"),
		EmbedBaseURL:  r.Header.Get("X-Embed-Base-URL"),

		STTProvider: sttProvider,
		STTModel:    r.Header.Get("X-STT-Model"),
		STTAPIKey:   r.Header.Get("X-STT-API-Key"),
		STTBaseURL:  r.Header.Get("X-STT-Base-URL"),

		TTSProvider: r.Header.Get("X-TTS-Provider"),
		TTSModel:    r.Header.Get("X-TTS-Model"),
		TTSAPIKey:   r.Header.Get("X-TTS-API-Key"),
		TTSBaseURL:  r.Header.Get("X-TTS-Base-URL"),
		TTSVoice:    r.Header.Get("X-TTS-Voice"),
		BarkKey:     r.Header.Get("X-Bark-Key"),
	}

	// 异步持久化凭证到 SQLite 数据库，供 Telegram Bot 等后台任务使用
	if cfg.ChatAPIKey != "" {
		go func(c *models.AIConfig) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = h.service.SaveAIConfig(ctx, c)
		}(cfg)
	}

	return cfg
}

// RegisterRoutes 注册所有的 API 路由端点
func (h *Handler) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/memories/ingest", h.corsMiddleware(h.authMiddleware(h.HandleIngest)))
	mux.HandleFunc("/api/memories/ingest-audio", h.corsMiddleware(h.authMiddleware(h.HandleIngestAudio)))
	mux.HandleFunc("/api/memories/retry", h.corsMiddleware(h.authMiddleware(h.HandleRetryMemory)))
	mux.HandleFunc("/api/memories", h.corsMiddleware(h.authMiddleware(h.HandleMemories)))
	mux.HandleFunc("/api/chat", h.corsMiddleware(h.authMiddleware(h.HandleChat)))
	mux.HandleFunc("/api/chat/messages", h.corsMiddleware(h.authMiddleware(h.HandleChatHistory)))
	mux.HandleFunc("/api/dashboard/stats", h.corsMiddleware(h.authMiddleware(h.HandleDashboardStats)))
	mux.HandleFunc("/api/audio/transcribe", h.corsMiddleware(h.authMiddleware(h.HandleTranscribeAudio)))
	mux.HandleFunc("/api/audio/tts", h.corsMiddleware(h.authMiddleware(h.HandleTTS)))
	mux.HandleFunc("/api/ocr", h.corsMiddleware(h.authMiddleware(h.HandleOCR)))
	mux.HandleFunc("/api/memories/summarize", h.corsMiddleware(h.authMiddleware(h.HandleMemoriesSummarize)))
	mux.HandleFunc("/api/dashboard/mind-graph", h.corsMiddleware(h.authMiddleware(h.HandleMindGraph)))
	mux.HandleFunc("/api/chat/voice-stream", h.corsMiddleware(h.HandleVoiceStream))
	mux.HandleFunc("/api/tasks/delete", h.corsMiddleware(h.authMiddleware(h.HandleDeleteTask)))
	mux.HandleFunc("/api/tasks/confirm", h.corsMiddleware(h.authMiddleware(h.HandleConfirmTask)))
	mux.HandleFunc("/api/e2ee/sync", h.corsMiddleware(h.authMiddleware(h.HandleE2EESync)))
}

// authMiddleware API 访问令牌认证中间件
func (h *Handler) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := config.GlobalConfig.APIToken
		if token == "" {
			// 未设置令牌，向下兼容，直接通过
			next(w, r)
			return
		}

		// 支持从 X-App-Token 或 Authorization: Bearer 获取
		reqToken := r.Header.Get("X-App-Token")
		if reqToken == "" {
			authHeader := r.Header.Get("Authorization")
			if strings.HasPrefix(authHeader, "Bearer ") {
				reqToken = strings.TrimPrefix(authHeader, "Bearer ")
			}
		}

		if reqToken != token {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error": "Unauthorized: Invalid or missing API Token"}`))
			return
		}

		next(w, r)
	}
}

// corsMiddleware 跨域访问控制中间件
func (h *Handler) corsMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS, DELETE, PUT")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-App-Token, X-Chat-Provider, X-Chat-Model, X-Chat-API-Key, X-Chat-Base-URL, X-Vision-Provider, X-Vision-Model, X-Vision-API-Key, X-Vision-Base-URL, X-Embed-Provider, X-Embed-Model, X-Embed-API-Key, X-Embed-Base-URL, X-STT-Provider, X-STT-Model, X-STT-API-Key, X-STT-Base-URL, X-TTS-Provider, X-TTS-Model, X-TTS-API-Key, X-TTS-Base-URL, X-TTS-Voice, X-Bark-Key")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		next(w, r)
	}
}

type IngestRequest struct {
	Content     string   `json:"content"`
	SourceType  string   `json:"source_type"`
	SourceMeta  string   `json:"source_meta"`
	IsEncrypted bool     `json:"is_encrypted"`
	Title       string   `json:"title"`
	Tags        []string `json:"tags"`
}

// HandleIngest 处理非结构化信息上传入库
func (h *Handler) HandleIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	// 设置请求超时，防止 LLM API 挂起导致后端长时间无响应
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	r = r.WithContext(ctx)

	var req IngestRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
		return
	}

	if strings.TrimSpace(req.Content) == "" {
		http.Error(w, "Content cannot be empty", http.StatusBadRequest)
		return
	}

	aiConfig := h.parseAIConfig(r)
	fmt.Printf("[DEBUG] HandleIngest -> Ingesting record. IsEncrypted: %t | SourceType: %s | SourceMeta: %s | ContentLen: %d | Title: %q | Tags: %v\n",
		req.IsEncrypted, req.SourceType, req.SourceMeta, len(req.Content), req.Title, req.Tags)
	mem, err := h.service.IngestMemory(r.Context(), req.Content, req.SourceType, req.SourceMeta, req.IsEncrypted, req.Title, req.Tags, aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleIngest -> Ingestion failed: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+escapeJSON(err.Error())+"\"}", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(mem)
}

// HandleRetryMemory 重新提交失败或因服务重启而中断的记忆解析任务。
func (h *Handler) HandleRetryMemory(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		http.Error(w, "Missing id parameter", http.StatusBadRequest)
		return
	}

	mem, err := h.service.RetryMemoryProcessing(r.Context(), id, h.parseAIConfig(r))
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		status := http.StatusConflict
		if strings.Contains(err.Error(), "not found") {
			status = http.StatusNotFound
		}
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(mem)
}

// HandleMemories 处理记忆列表拉取或删除
func (h *Handler) HandleMemories(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		if id := strings.TrimSpace(r.URL.Query().Get("id")); id != "" {
			mem, err := h.service.GetMemory(r.Context(), id)
			if err != nil {
				http.Error(w, "Internal Error: "+err.Error(), http.StatusInternalServerError)
				return
			}
			if mem == nil {
				http.Error(w, "Memory not found", http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(mem)
			return
		}

		// 分页拉取
		pageStr := r.URL.Query().Get("page")
		pageSizeStr := r.URL.Query().Get("pageSize")

		page, err := strconv.Atoi(pageStr)
		if err != nil || page < 1 {
			page = 1
		}
		pageSize, err := strconv.Atoi(pageSizeStr)
		if err != nil || pageSize < 1 {
			pageSize = 10
		}

		list, err := h.service.ListMemories(r.Context(), page, pageSize)
		if err != nil {
			fmt.Printf("[ERROR] HandleMemories list error: %v\n", err)
			http.Error(w, "Internal Error: "+err.Error(), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(list)

	case http.MethodDelete:
		// 删除单个记忆
		id := r.URL.Query().Get("id")
		if id == "" {
			http.Error(w, "Missing id parameter", http.StatusBadRequest)
			return
		}

		aiConfig := h.parseAIConfig(r)
		err := h.service.DeleteMemory(r.Context(), id, aiConfig)
		if err != nil {
			http.Error(w, "Failed to delete: "+err.Error(), http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusNoContent)

	case http.MethodPut:
		// 更新单个记忆
		var mem models.Memory
		if err := json.NewDecoder(r.Body).Decode(&mem); err != nil {
			http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
			return
		}

		if mem.ID == "" {
			http.Error(w, "Missing memory id", http.StatusBadRequest)
			return
		}

		aiConfig := h.parseAIConfig(r)
		err := h.service.UpdateMemory(r.Context(), &mem, aiConfig)
		if err != nil {
			fmt.Printf("[ERROR] HandleMemories update error: %v\n", err)
			http.Error(w, "Failed to update: "+err.Error(), http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
	}
}

type ChatRequest struct {
	Query     string `json:"query"`
	SessionID string `json:"session_id"`
}

// HandleChat 处理混合双轨检索问答
func (h *Handler) HandleChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req ChatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
		return
	}

	if strings.TrimSpace(req.Query) == "" {
		http.Error(w, "Query cannot be empty", http.StatusBadRequest)
		return
	}

	aiConfig := h.parseAIConfig(r)
	result, err := h.service.Ask(r.Context(), req.Query, req.SessionID, aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleChat error: %v\n", err)
		http.Error(w, "AI generate error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

// HandleChatHistory 拉取对话消息历史记录
func (h *Handler) HandleChatHistory(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	sessionID := r.URL.Query().Get("session_id")
	messages, err := h.service.GetChatMessages(r.Context(), sessionID)
	if err != nil {
		fmt.Printf("[ERROR] HandleChatHistory error: %v\n", err)
		http.Error(w, "Failed to get chat messages: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(messages)
}

// HandleDashboardStats 获取仪表盘所需的实时系统健康度指标
func (h *Handler) HandleDashboardStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	aiConfig := h.parseAIConfig(r)
	stats, err := h.service.GetDashboardStats(r.Context(), aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleDashboardStats error: %v\n", err)
		http.Error(w, "Failed to fetch stats: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

// HandleIngestAudio 处理音频文件上传并转译 NER 入库
func (h *Handler) HandleIngestAudio(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	// 限制文件大小在 15MB 以内
	if err := r.ParseMultipartForm(15 << 20); err != nil {
		http.Error(w, "Parse Multipart Form error: "+err.Error(), http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("audio")
	if err != nil {
		http.Error(w, "Get audio file error: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()

	// 读取音频字节
	var buf bytes.Buffer
	if _, err := io.Copy(&buf, file); err != nil {
		http.Error(w, "Read file error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	aiConfig := h.parseAIConfig(r)

	// 调用服务执行语音识别与元数据解析入库
	mem, err := h.service.IngestAudio(r.Context(), buf.Bytes(), header.Filename, aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleIngestAudio error: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+escapeJSON(err.Error())+"\"}", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(mem)
}

// HandleTranscribeAudio 仅对上传的语音文件执行识别返回文本，不录入数据库
func (h *Handler) HandleTranscribeAudio(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	if err := r.ParseMultipartForm(15 << 20); err != nil {
		http.Error(w, "Parse Multipart Form error: "+err.Error(), http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("audio")
	if err != nil {
		http.Error(w, "Get audio file error: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()

	var buf bytes.Buffer
	if _, err := io.Copy(&buf, file); err != nil {
		http.Error(w, "Read file error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	aiConfig := h.parseAIConfig(r)
	text, err := h.service.TranscribeAudio(r.Context(), buf.Bytes(), header.Filename, aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleTranscribeAudio error: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+escapeJSON(err.Error())+"\"}", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"text": text})
}

// HandleOCR 对图片执行 OCR 识别返回文本，不录入数据库
func (h *Handler) HandleOCR(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var base64Data string

	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
		if err := r.ParseMultipartForm(15 << 20); err != nil {
			http.Error(w, "Parse Multipart Form error: "+err.Error(), http.StatusBadRequest)
			return
		}
		file, _, err := r.FormFile("image")
		if err != nil {
			http.Error(w, "Get image file error: "+err.Error(), http.StatusBadRequest)
			return
		}
		defer file.Close()
		var buf bytes.Buffer
		if _, err := io.Copy(&buf, file); err != nil {
			http.Error(w, "Read file error: "+err.Error(), http.StatusInternalServerError)
			return
		}
		base64Data = base64.StdEncoding.EncodeToString(buf.Bytes())
	} else {
		var req struct {
			Base64Data string `json:"base64_data"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
			return
		}
		base64Data = req.Base64Data
	}

	if base64Data == "" {
		http.Error(w, "Missing image data", http.StatusBadRequest)
		return
	}

	aiConfig := h.parseAIConfig(r)
	text, err := h.service.PerformOCR(r.Context(), base64Data, aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleOCR error: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+escapeJSON(err.Error())+"\"}", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"text": text})
}

// HandleTTS 将传入的文本转为语音音频流并返回
func (h *Handler) HandleTTS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Text == "" {
		http.Error(w, "Text is required", http.StatusBadRequest)
		return
	}

	aiConfig := h.parseAIConfig(r)
	audioData, err := h.service.GenerateTTS(r.Context(), req.Text, aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleTTS error: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+escapeJSON(err.Error())+"\"}", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "audio/mpeg") // 默认设定为 MP3 流，这取决于底层 TTS API 返回格式
	w.Header().Set("Content-Length", strconv.Itoa(len(audioData)))
	w.WriteHeader(http.StatusOK)
	w.Write(audioData)
}

// HandleMemoriesSummarize 处理批量事实记忆融合总结请求
func (h *Handler) HandleMemoriesSummarize(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	// 提取并设置超时时间，防止 LLM 请求挂起
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()
	r = r.WithContext(ctx)

	var req struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
		return
	}

	if len(req.IDs) == 0 {
		http.Error(w, "IDs list cannot be empty", http.StatusBadRequest)
		return
	}

	aiConfig := h.parseAIConfig(r)
	summary, err := h.service.GenerateSummary(r.Context(), req.IDs, aiConfig)
	if err != nil {
		fmt.Printf("[ERROR] HandleMemoriesSummarize error: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+escapeJSON(err.Error())+"\"}", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"summary": summary})
}

type GraphNode struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	Type       string `json:"type"`        // "memory", "tag", "entity"
	EntityType string `json:"entity_type"` // e.g. "person", "location" (optional)
}

type GraphLink struct {
	Source string `json:"source"`
	Target string `json:"target"`
	Type   string `json:"type"`  // "tag", "similar", "graph_rag", "memory_entity"
	Label  string `json:"label"` // 关系描述，如 "开发了"
}

type MindGraphResponse struct {
	Nodes []GraphNode `json:"nodes"`
	Links []GraphLink `json:"links"`
}

// HandleMindGraph 计算并获取用户长短期记忆与标签编织的神经图谱数据
func (h *Handler) HandleMindGraph(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	// 加载最近的 100 条未删除记忆卡片
	ctx := r.Context()
	memories, err := h.service.ListMemories(ctx, 1, 100)
	if err != nil {
		fmt.Printf("[ERROR] HandleMindGraph error: %v\n", err)
		http.Error(w, "Failed to load memories: "+err.Error(), http.StatusInternalServerError)
		return
	}

	if len(memories) == 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(MindGraphResponse{
			Nodes: []GraphNode{},
			Links: []GraphLink{},
		})
		return
	}

	var memoryIDs []string
	for _, mem := range memories {
		memoryIDs = append(memoryIDs, mem.ID)
	}

	// 获取 GraphRAG 三元组实体关系
	relations, err := h.service.GetGraphRAGRelations(ctx, memoryIDs)
	if err != nil {
		fmt.Printf("[ERROR] HandleMindGraph GetGraphRAGRelations error: %v\n", err)
		// 允许降级不返回三元组关系，不中断整个接口
		relations = nil
	}

	// 获取 Memory 到 Entity 的关联
	memoryEntities, err := h.service.GetMemoryEntities(ctx, memoryIDs)
	if err != nil {
		fmt.Printf("[ERROR] HandleMindGraph GetMemoryEntities error: %v\n", err)
		memoryEntities = nil
	}

	nodesMap := make(map[string]bool)
	var nodes []GraphNode
	var links []GraphLink

	// 1. 提取所有 Memory 节点及 Tag 节点与连线
	for _, mem := range memories {
		// 添加 Memory 节点
		label := mem.Title
		if label == "" {
			runes := []rune(mem.RawContent)
			if len(runes) > 12 {
				label = string(runes[:12]) + "..."
			} else {
				label = string(runes)
			}
		}
		if !nodesMap[mem.ID] {
			nodesMap[mem.ID] = true
			nodes = append(nodes, GraphNode{
				ID:    mem.ID,
				Label: label,
				Type:  "memory",
			})
		}

		// 2. 添加 Tag 节点及连接线
		for _, tag := range mem.Tags {
			tagID := "tag_" + tag
			if !nodesMap[tagID] {
				nodesMap[tagID] = true
				nodes = append(nodes, GraphNode{
					ID:    tagID,
					Label: tag,
					Type:  "tag",
				})
			}

			// 建立 Memory -> Tag 的结构连线
			links = append(links, GraphLink{
				Source: mem.ID,
				Target: tagID,
				Type:   "tag",
			})
		}
	}

	// 4. 插入 GraphRAG 实体节点与三元组连边
	for _, rel := range relations {
		// 插入 Source 实体节点
		if !nodesMap[rel.SourceID] {
			nodesMap[rel.SourceID] = true
			nodes = append(nodes, GraphNode{
				ID:         rel.SourceID,
				Label:      rel.SourceName,
				Type:       "entity",
				EntityType: rel.SourceType,
			})
		}
		// 插入 Target 实体节点
		if !nodesMap[rel.TargetID] {
			nodesMap[rel.TargetID] = true
			nodes = append(nodes, GraphNode{
				ID:         rel.TargetID,
				Label:      rel.TargetName,
				Type:       "entity",
				EntityType: rel.TargetType,
			})
		}
		// 插入 Entity -> Entity 的三元组定向语义边
		links = append(links, GraphLink{
			Source: rel.SourceID,
			Target: rel.TargetID,
			Type:   "graph_rag",
			Label:  rel.RelationType,
		})
	}

	// 5. 插入 Memory 到 Entity 的关联边
	for _, me := range memoryEntities {
		// 容灾：以防 Entity 节点在 schema 遍历中没有被插入
		if !nodesMap[me.EntityID] {
			nodesMap[me.EntityID] = true
			nodes = append(nodes, GraphNode{
				ID:         me.EntityID,
				Label:      me.EntityName,
				Type:       "entity",
				EntityType: me.EntityType,
			})
		}
		// 插入 Memory -> Entity 关联边
		links = append(links, GraphLink{
			Source: me.MemoryID,
			Target: me.EntityID,
			Type:   "memory_entity",
		})
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(MindGraphResponse{
		Nodes: nodes,
		Links: links,
	})
}

// HandleDeleteTask 处理物理删除待办提醒任务的请求
func (h *Handler) HandleDeleteTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodDelete && r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	id := r.URL.Query().Get("id")
	if id == "" {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err == nil {
			id = req.ID
		}
	}

	if id == "" {
		http.Error(w, "Missing task id", http.StatusBadRequest)
		return
	}

	if err := h.service.DeleteScheduledTask(r.Context(), id); err != nil {
		fmt.Printf("[ERROR] HandleDeleteTask error: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+err.Error()+`"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"success"}`))
}

// HandleConfirmTask 保存用户修正并激活一条 AI 提取的提醒。
func (h *Handler) HandleConfirmTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut && r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var task models.ScheduledTask
	if err := json.NewDecoder(r.Body).Decode(&task); err != nil {
		http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := h.service.ConfirmScheduledTask(r.Context(), &task); err != nil {
		w.Header().Set("Content-Type", "application/json")
		status := http.StatusBadRequest
		if strings.Contains(err.Error(), "not found") {
			status = http.StatusNotFound
		} else if strings.Contains(err.Error(), "not pending confirmation") {
			status = http.StatusConflict
		}
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// E2EESyncRequest E2EE 同步请求体
type E2EESyncRequest struct {
	LastSyncTime int64            `json:"last_sync_time"`
	Changes      []*models.Memory `json:"changes"`
}

// E2EESyncResponse E2EE 同步响应体
type E2EESyncResponse struct {
	SyncTime int64            `json:"sync_time"`
	Changes  []*models.Memory `json:"changes"`
}

// HandleE2EESync 处理端到端加密数据同步请求
func (h *Handler) HandleE2EESync(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req E2EESyncRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad Request: "+err.Error(), http.StatusBadRequest)
		return
	}

	delta, syncTime, err := h.service.SyncE2EEMemories(r.Context(), req.LastSyncTime, req.Changes)
	if err != nil {
		fmt.Printf("[ERROR] HandleE2EESync error: %v\n", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error": "`+escapeJSON(err.Error())+`"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(E2EESyncResponse{
		SyncTime: syncTime,
		Changes:  delta,
	})
}
