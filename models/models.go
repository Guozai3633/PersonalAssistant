package models

const (
	MemoryStatusPending           = "pending"
	MemoryStatusProcessing        = "processing"
	MemoryStatusCompleted         = "completed"
	MemoryStatusFailed            = "failed"
	MemoryStatusNeedsConfirmation = "needs_confirmation"
)

const (
	TaskStatusPendingConfirmation = "pending_confirmation"
	TaskStatusPending             = "pending"
	TaskStatusProcessing          = "processing"
	TaskStatusDone                = "done"
	TaskStatusFailed              = "failed"
)

type Memory struct {
	ID               string   `json:"id"`
	RawContent       string   `json:"raw_content"`
	OriginalContent  string   `json:"original_content"`
	ExtractedTime    string   `json:"extracted_time"` // ISO 8601
	Priority         int      `json:"priority"`       // 0-3
	SourceType       string   `json:"source_type"`    // text, image, audio, file, link, note, contact, location
	SourceMeta       string   `json:"source_meta"`    // JSON string for image path, url, etc.
	Title            string   `json:"title,omitempty"`
	ProcessingStatus string   `json:"processing_status"`
	ProcessingError  string   `json:"processing_error,omitempty"`
	CreatedAt        int64    `json:"created_at"` // Unix Timestamp
	UpdatedAt        int64    `json:"updated_at"` // Unix Timestamp
	DeletedAt        *int64   `json:"deleted_at,omitempty"`
	Tags             []string `json:"tags,omitempty"`
}

type MemoryCitation struct {
	MemoryID      string `json:"memory_id"`
	Title         string `json:"title"`
	Excerpt       string `json:"excerpt"`
	SourceType    string `json:"source_type"`
	SourceMeta    string `json:"source_meta"`
	ExtractedTime string `json:"extracted_time"`
	CreatedAt     int64  `json:"created_at"`
}

type ChatResult struct {
	Answer  string            `json:"answer"`
	Sources []*MemoryCitation `json:"sources"`
}

type Tag struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"created_at"`
}

type ChatSession struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	CreatedAt int64  `json:"created_at"`
	UpdatedAt int64  `json:"updated_at"`
}

type ChatMessage struct {
	ID         string `json:"id"`
	SessionID  string `json:"session_id"`
	Role       string `json:"role"` // system, user, assistant
	Content    string `json:"content"`
	TokenCount int    `json:"token_count"`
	CreatedAt  int64  `json:"created_at"`
}

// AIConfig 存储用户从前端请求时动态传递的模型配置
type AIConfig struct {
	ChatProvider string `json:"chat_provider"`
	ChatModel    string `json:"chat_model"`
	ChatAPIKey   string `json:"chat_api_key"`
	ChatBaseURL  string `json:"chat_base_url"`

	VisionProvider string `json:"vision_provider"`
	VisionModel    string `json:"vision_model"`
	VisionAPIKey   string `json:"vision_api_key"`
	VisionBaseURL  string `json:"vision_base_url"`

	EmbedProvider string `json:"embed_provider"`
	EmbedModel    string `json:"embed_model"`
	EmbedAPIKey   string `json:"embed_api_key"`
	EmbedBaseURL  string `json:"embed_base_url"`

	STTProvider string `json:"stt_provider"`
	STTModel    string `json:"stt_model"`
	STTAPIKey   string `json:"stt_api_key"`
	STTBaseURL  string `json:"stt_base_url"`

	TTSProvider string `json:"tts_provider"`
	TTSModel    string `json:"tts_model"`
	TTSAPIKey   string `json:"tts_api_key"`
	TTSBaseURL  string `json:"tts_base_url"`

	RerankModel string `json:"rerank_model"` // 预留
	TTSVoice    string `json:"tts_voice"`
	BarkKey     string `json:"bark_key"`
}

// ScheduledTask 代表提取出的需要系统主动执行的任务（日程、提醒等）
type ScheduledTask struct {
	ID              string `json:"id"`
	MemoryID        string `json:"memory_id,omitempty"`
	Title           string `json:"title"`
	Description     string `json:"description"`
	ActionType      string `json:"action_type"` // e.g. "reminder", "alarm", "api_call"
	DueTime         int64  `json:"due_time"`    // Unix Timestamp when it should be executed
	OriginalDueText string `json:"original_due_text,omitempty"`
	Status          string `json:"status"` // pending_confirmation, pending, processing, done, failed
	CreatedAt       int64  `json:"created_at"`
	SourceContent   string `json:"source_content,omitempty"`
}
