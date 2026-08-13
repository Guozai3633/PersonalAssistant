package repositories

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"assistant/config"
	"assistant/models"

	"github.com/google/uuid"
	_ "github.com/mattn/go-sqlite3"
)

type SQLiteRepository struct {
	db *sql.DB
}

func NewSQLiteRepository() (*SQLiteRepository, error) {
	dbPath := config.GlobalConfig.DBPath
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open sqlite db: %w", err)
	}

	// 开启 WAL 模式及优化参数，保障并发读写稳定性与高性能
	queries := []string{
		"PRAGMA journal_mode = WAL;",
		"PRAGMA synchronous = NORMAL;",
		"PRAGMA foreign_keys = ON;",
		"PRAGMA busy_timeout = 5000;",
	}
	for _, q := range queries {
		if _, err := db.Exec(q); err != nil {
			db.Close()
			return nil, fmt.Errorf("failed to execute pragma config %q: %w", q, err)
		}
	}

	repo := &SQLiteRepository{db: db}
	if err := repo.InitDB(); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to init database tables: %w", err)
	}

	return repo, nil
}

func (r *SQLiteRepository) Close() error {
	if r.db != nil {
		return r.db.Close()
	}
	return nil
}

func (r *SQLiteRepository) InitDB() error {
	tableDDLs := []string{
		`CREATE TABLE IF NOT EXISTS memories (
			id TEXT PRIMARY KEY,
			raw_content TEXT NOT NULL,
			original_content TEXT NOT NULL DEFAULT '',
			extracted_time TEXT,
			priority INTEGER DEFAULT 1,
			source_type TEXT DEFAULT 'text',
			source_meta TEXT,
			title TEXT DEFAULT '',
			processing_status TEXT NOT NULL DEFAULT 'completed',
			processing_error TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			deleted_at INTEGER
		);`,
		`CREATE INDEX IF NOT EXISTS idx_memories_time_deleted ON memories (extracted_time, deleted_at);`,
		`CREATE INDEX IF NOT EXISTS idx_memories_created ON memories (created_at DESC);`,

		`CREATE TABLE IF NOT EXISTS tags (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL UNIQUE,
			created_at INTEGER NOT NULL
		);`,

		`CREATE TABLE IF NOT EXISTS memory_tags (
			memory_id TEXT NOT NULL,
			tag_id TEXT NOT NULL,
			PRIMARY KEY (memory_id, tag_id),
			FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE,
			FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
		);`,
		`CREATE INDEX IF NOT EXISTS idx_mem_tags_tag ON memory_tags (tag_id);`,

		`CREATE TABLE IF NOT EXISTS chat_sessions (
			id TEXT PRIMARY KEY,
			title TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);`,

		`CREATE TABLE IF NOT EXISTS chat_messages (
			id TEXT PRIMARY KEY,
			session_id TEXT NOT NULL,
			role TEXT NOT NULL,
			content TEXT NOT NULL,
			token_count INTEGER DEFAULT 0,
			created_at INTEGER NOT NULL,
			FOREIGN KEY (session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
		);`,
		`CREATE INDEX IF NOT EXISTS idx_chat_msg_session ON chat_messages (session_id, created_at ASC);`,

		`CREATE TABLE IF NOT EXISTS user_profile (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			profile_data TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		);`,

		`CREATE TABLE IF NOT EXISTS scheduled_tasks (
			id TEXT PRIMARY KEY,
			memory_id TEXT DEFAULT '',
			title TEXT NOT NULL,
			description TEXT NOT NULL,
			action_type TEXT NOT NULL,
			due_time INTEGER NOT NULL,
			original_due_text TEXT DEFAULT '',
			status TEXT DEFAULT 'pending',
			created_at INTEGER NOT NULL
		);`,
		`CREATE INDEX IF NOT EXISTS idx_tasks_due_time ON scheduled_tasks (status, due_time);`,
		`CREATE TABLE IF NOT EXISTS ai_config (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			chat_provider TEXT,
			chat_model TEXT,
			chat_api_key TEXT,
			chat_base_url TEXT,
			vision_provider TEXT,
			vision_model TEXT,
			vision_api_key TEXT,
			vision_base_url TEXT,
			embed_provider TEXT,
			embed_model TEXT,
			embed_api_key TEXT,
			embed_base_url TEXT,
			stt_provider TEXT,
			stt_model TEXT,
			stt_api_key TEXT,
			stt_base_url TEXT,
			tts_provider TEXT,
			tts_model TEXT,
			tts_api_key TEXT,
			tts_base_url TEXT,
			tts_voice TEXT,
			bark_key TEXT,
			updated_at INTEGER NOT NULL
		);`,
		`CREATE TABLE IF NOT EXISTS entities (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL UNIQUE,
			type TEXT DEFAULT 'generic',
			created_at INTEGER NOT NULL
		);`,
		`CREATE TABLE IF NOT EXISTS entity_relations (
			id TEXT PRIMARY KEY,
			source_id TEXT NOT NULL,
			target_id TEXT NOT NULL,
			relation_type TEXT NOT NULL,
			weight REAL DEFAULT 1.0,
			created_at INTEGER NOT NULL,
			FOREIGN KEY(source_id) REFERENCES entities(id) ON DELETE CASCADE,
			FOREIGN KEY(target_id) REFERENCES entities(id) ON DELETE CASCADE,
			UNIQUE(source_id, target_id, relation_type)
		);`,
		`CREATE TABLE IF NOT EXISTS memory_entities (
			memory_id TEXT NOT NULL,
			entity_id TEXT NOT NULL,
			PRIMARY KEY(memory_id, entity_id),
			FOREIGN KEY(memory_id) REFERENCES memories(id) ON DELETE CASCADE,
			FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
		);`,
		`CREATE INDEX IF NOT EXISTS idx_entity_relations_source ON entity_relations (source_id);`,
		`CREATE INDEX IF NOT EXISTS idx_entity_relations_target ON entity_relations (target_id);`,
	}

	for _, ddl := range tableDDLs {
		if _, err := r.db.Exec(ddl); err != nil {
			return fmt.Errorf("failed to execute DDL: %w", err)
		}
	}
	// 热升级：如果旧表中没有 tts_voice 和 bark_key 列，进行动态添加，忽略“列已存在”等报错
	_, _ = r.db.Exec("ALTER TABLE ai_config ADD COLUMN tts_voice TEXT;")
	_, _ = r.db.Exec("ALTER TABLE ai_config ADD COLUMN bark_key TEXT;")
	// 热升级 memories 补上缺少的 title 字段
	_, _ = r.db.Exec("ALTER TABLE memories ADD COLUMN title TEXT DEFAULT '';")
	// 已有记忆在升级前已经完成处理，新录入记录会显式写入 pending。
	_, _ = r.db.Exec("ALTER TABLE memories ADD COLUMN processing_status TEXT NOT NULL DEFAULT 'completed';")
	_, _ = r.db.Exec("ALTER TABLE memories ADD COLUMN processing_error TEXT NOT NULL DEFAULT '';")
	_, _ = r.db.Exec("ALTER TABLE memories ADD COLUMN original_content TEXT NOT NULL DEFAULT '';")
	_, _ = r.db.Exec(`
		UPDATE memories
		SET original_content = CASE
				WHEN original_content IS NULL OR original_content = '' THEN raw_content
				ELSE original_content
			END,
			extracted_time = COALESCE(extracted_time, ''),
			source_meta = COALESCE(source_meta, ''),
			title = COALESCE(title, ''),
			processing_status = COALESCE(NULLIF(processing_status, ''), 'completed'),
			processing_error = COALESCE(processing_error, '')
	`)
	_, _ = r.db.Exec("ALTER TABLE scheduled_tasks ADD COLUMN memory_id TEXT DEFAULT '';")
	_, _ = r.db.Exec("ALTER TABLE scheduled_tasks ADD COLUMN original_due_text TEXT DEFAULT '';")
	_, _ = r.db.Exec(`
		UPDATE scheduled_tasks
		SET memory_id = COALESCE(memory_id, ''),
			original_due_text = COALESCE(original_due_text, '')
	`)
	return nil
}

// SaveMemory 保存记忆，并处理其关联标签
func (r *SQLiteRepository) SaveMemory(ctx context.Context, mem *models.Memory) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback()

	now := time.Now().Unix()
	if mem.UpdatedAt == 0 {
		mem.UpdatedAt = now
	}
	if mem.CreatedAt == 0 {
		mem.CreatedAt = now
	}
	if mem.OriginalContent == "" {
		mem.OriginalContent = mem.RawContent
	}
	if mem.ProcessingStatus == "" {
		mem.ProcessingStatus = models.MemoryStatusCompleted
	}

	upsertQuery := `
		INSERT INTO memories (id, raw_content, original_content, extracted_time, priority, source_type, source_meta, title, processing_status, processing_error, created_at, updated_at, deleted_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			raw_content = excluded.raw_content,
			original_content = excluded.original_content,
			extracted_time = excluded.extracted_time,
			priority = excluded.priority,
			source_type = excluded.source_type,
			source_meta = excluded.source_meta,
			title = excluded.title,
			processing_status = excluded.processing_status,
			processing_error = excluded.processing_error,
			updated_at = excluded.updated_at,
			deleted_at = excluded.deleted_at;
	`
	_, err = tx.ExecContext(ctx, upsertQuery,
		mem.ID, mem.RawContent, mem.OriginalContent, mem.ExtractedTime, mem.Priority, mem.SourceType, mem.SourceMeta, mem.Title,
		mem.ProcessingStatus, mem.ProcessingError, mem.CreatedAt, mem.UpdatedAt, mem.DeletedAt,
	)
	if err != nil {
		return fmt.Errorf("failed to upsert memory: %w", err)
	}

	// 先删除旧有的标签关联
	_, err = tx.ExecContext(ctx, "DELETE FROM memory_tags WHERE memory_id = ?", mem.ID)
	if err != nil {
		return fmt.Errorf("failed to clear old memory tags: %w", err)
	}

	// 插入标签并建立关联
	for _, tagName := range mem.Tags {
		tagName = strings.TrimSpace(tagName)
		if tagName == "" {
			continue
		}

		// 检查标签是否存在，不存在则新建
		var tagID string
		err := tx.QueryRowContext(ctx, "SELECT id FROM tags WHERE name = ?", tagName).Scan(&tagID)
		if err == sql.ErrNoRows {
			tagID = fmt.Sprintf("tag_%d_%s", time.Now().UnixNano(), tagName)
			_, err = tx.ExecContext(ctx, "INSERT INTO tags (id, name, created_at) VALUES (?, ?, ?)", tagID, tagName, now)
			if err != nil {
				return fmt.Errorf("failed to create tag %s: %w", tagName, err)
			}
		} else if err != nil {
			return fmt.Errorf("failed to query tag %s: %w", tagName, err)
		}

		// 建立关联
		_, err = tx.ExecContext(ctx, "INSERT OR IGNORE INTO memory_tags (memory_id, tag_id) VALUES (?, ?)", mem.ID, tagID)
		if err != nil {
			return fmt.Errorf("failed to associate memory with tag %s: %w", tagName, err)
		}
	}

	return tx.Commit()
}

// GetMemory 根据 ID 获取记忆
func (r *SQLiteRepository) GetMemory(ctx context.Context, id string) (*models.Memory, error) {
	query := `
		SELECT id, raw_content, original_content, extracted_time, priority, source_type, source_meta, title, processing_status, processing_error, created_at, updated_at, deleted_at
		FROM memories
		WHERE id = ? AND deleted_at IS NULL
	`
	var mem models.Memory
	err := r.db.QueryRowContext(ctx, query, id).Scan(
		&mem.ID, &mem.RawContent, &mem.OriginalContent, &mem.ExtractedTime, &mem.Priority, &mem.SourceType, &mem.SourceMeta, &mem.Title,
		&mem.ProcessingStatus, &mem.ProcessingError, &mem.CreatedAt, &mem.UpdatedAt, &mem.DeletedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("failed to query memory: %w", err)
	}

	// 获取标签
	tags, err := r.getMemoryTags(ctx, id)
	if err != nil {
		return nil, err
	}
	mem.Tags = tags

	return &mem, nil
}

// FindRecentMemoryByContent 查找指定时间内是否存在内容完全相同的未删除记忆（用于防重幂等性）
func (r *SQLiteRepository) FindRecentMemoryByContent(ctx context.Context, content string, duration time.Duration) (*models.Memory, error) {
	threshold := time.Now().Add(-duration).Unix()
	query := `
		SELECT id, raw_content, original_content, extracted_time, priority, source_type, source_meta, title, processing_status, processing_error, created_at, updated_at, deleted_at
		FROM memories
		WHERE (raw_content = ? OR original_content = ?)
			AND deleted_at IS NULL AND created_at >= ?
		LIMIT 1
	`
	var mem models.Memory
	err := r.db.QueryRowContext(ctx, query, content, content, threshold).Scan(
		&mem.ID, &mem.RawContent, &mem.OriginalContent, &mem.ExtractedTime, &mem.Priority, &mem.SourceType, &mem.SourceMeta, &mem.Title,
		&mem.ProcessingStatus, &mem.ProcessingError, &mem.CreatedAt, &mem.UpdatedAt, &mem.DeletedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("failed to query recent memory: %w", err)
	}

	// 获取标签
	memTags, err := r.getMemoryTags(ctx, mem.ID)
	if err != nil {
		return nil, err
	}
	mem.Tags = memTags

	return &mem, nil
}

// DeleteMemory 软删除记忆
func (r *SQLiteRepository) DeleteMemory(ctx context.Context, id string) error {
	now := time.Now().Unix()
	_, err := r.db.ExecContext(ctx, "UPDATE memories SET deleted_at = ?, updated_at = ? WHERE id = ?", now, now, id)
	if err != nil {
		return fmt.Errorf("failed to soft delete memory: %w", err)
	}
	return nil
}

// UpdateMemoryProcessingStatus 独立更新后台解析状态，避免覆盖用户内容。
func (r *SQLiteRepository) UpdateMemoryProcessingStatus(ctx context.Context, id, status, processingError string) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE memories
		SET processing_status = ?, processing_error = ?, updated_at = ?
		WHERE id = ? AND deleted_at IS NULL
	`, status, processingError, time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("failed to update memory processing status: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("failed to read processing status update result: %w", err)
	}
	if affected == 0 {
		return fmt.Errorf("memory not found: %s", id)
	}
	return nil
}

// ListMemories 分页拉取记忆
func (r *SQLiteRepository) ListMemories(ctx context.Context, limit, offset int) ([]*models.Memory, error) {
	query := `
		SELECT id, raw_content, original_content, extracted_time, priority, source_type, source_meta, title, processing_status, processing_error, created_at, updated_at, deleted_at
		FROM memories
		WHERE deleted_at IS NULL
		ORDER BY created_at DESC
		LIMIT ? OFFSET ?
	`
	rows, err := r.db.QueryContext(ctx, query, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory list: %w", err)
	}
	defer rows.Close()

	var list []*models.Memory
	for rows.Next() {
		var mem models.Memory
		err := rows.Scan(
			&mem.ID, &mem.RawContent, &mem.OriginalContent, &mem.ExtractedTime, &mem.Priority, &mem.SourceType, &mem.SourceMeta, &mem.Title,
			&mem.ProcessingStatus, &mem.ProcessingError, &mem.CreatedAt, &mem.UpdatedAt, &mem.DeletedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan memory: %w", err)
		}
		list = append(list, &mem)
	}

	// 填充标签
	for _, mem := range list {
		tags, err := r.getMemoryTags(ctx, mem.ID)
		if err != nil {
			return nil, err
		}
		mem.Tags = tags
	}

	return list, nil
}

// SearchMemoriesByTimeRange 混合检索的第一轨：结构化条件精确过滤
func (r *SQLiteRepository) SearchMemoriesByTimeRange(ctx context.Context, startTime, endTime string, tags []string) ([]*models.Memory, error) {
	var queryBuilder strings.Builder
	var args []interface{}

	queryBuilder.WriteString(`
		SELECT DISTINCT m.id, m.raw_content, m.original_content, m.extracted_time, m.priority, m.source_type, m.source_meta, m.title, m.processing_status, m.processing_error, m.created_at, m.updated_at, m.deleted_at
		FROM memories m
	`)

	if len(tags) > 0 {
		queryBuilder.WriteString(`
			JOIN memory_tags mt ON m.id = mt.memory_id
			JOIN tags t ON mt.tag_id = t.id
		`)
	}

	queryBuilder.WriteString(" WHERE m.deleted_at IS NULL ")

	if startTime != "" {
		queryBuilder.WriteString(" AND m.extracted_time >= ? ")
		args = append(args, startTime)
	}
	if endTime != "" {
		queryBuilder.WriteString(" AND m.extracted_time <= ? ")
		args = append(args, endTime)
	}

	if len(tags) > 0 {
		placeholders := make([]string, len(tags))
		for i, tag := range tags {
			placeholders[i] = "?"
			args = append(args, tag)
		}
		queryBuilder.WriteString(fmt.Sprintf(" AND t.name IN (%s) ", strings.Join(placeholders, ",")))
	}

	queryBuilder.WriteString(" ORDER BY m.priority DESC, m.extracted_time ASC LIMIT 50")

	rows, err := r.db.QueryContext(ctx, queryBuilder.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("failed to execute range query: %w", err)
	}
	defer rows.Close()

	var list []*models.Memory
	for rows.Next() {
		var mem models.Memory
		err := rows.Scan(
			&mem.ID, &mem.RawContent, &mem.OriginalContent, &mem.ExtractedTime, &mem.Priority, &mem.SourceType, &mem.SourceMeta, &mem.Title,
			&mem.ProcessingStatus, &mem.ProcessingError, &mem.CreatedAt, &mem.UpdatedAt, &mem.DeletedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan range memory: %w", err)
		}
		list = append(list, &mem)
	}

	// 填充标签
	for _, mem := range list {
		memTags, err := r.getMemoryTags(ctx, mem.ID)
		if err != nil {
			return nil, err
		}
		mem.Tags = memTags
	}

	return list, nil
}

func (r *SQLiteRepository) GetTotalMemoryCount(ctx context.Context) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM memories WHERE deleted_at IS NULL").Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("failed to get total memory count: %w", err)
	}
	return count, nil
}

func (r *SQLiteRepository) getMemoryTags(ctx context.Context, memoryID string) ([]string, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT t.name 
		FROM tags t
		JOIN memory_tags mt ON t.id = mt.tag_id
		WHERE mt.memory_id = ?
	`, memoryID)
	if err != nil {
		return nil, fmt.Errorf("failed to get memory tags: %w", err)
	}
	defer rows.Close()

	var tags []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("failed to scan tag name: %w", err)
		}
		tags = append(tags, name)
	}
	return tags, nil
}

// SaveChatSession 保存或更新会话
func (r *SQLiteRepository) SaveChatSession(ctx context.Context, session *models.ChatSession) error {
	now := time.Now().Unix()
	session.UpdatedAt = now
	if session.CreatedAt == 0 {
		session.CreatedAt = now
	}

	query := `
		INSERT INTO chat_sessions (id, title, created_at, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			title = excluded.title,
			updated_at = excluded.updated_at;
	`
	_, err := r.db.ExecContext(ctx, query, session.ID, session.Title, session.CreatedAt, session.UpdatedAt)
	if err != nil {
		return fmt.Errorf("failed to save chat session: %w", err)
	}
	return nil
}

// GetChatMessages 拉取会话消息历史
func (r *SQLiteRepository) GetChatMessages(ctx context.Context, sessionID string) ([]*models.ChatMessage, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, session_id, role, content, token_count, created_at
		FROM chat_messages
		WHERE session_id = ?
		ORDER BY created_at ASC
	`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("failed to get chat messages: %w", err)
	}
	defer rows.Close()

	var messages []*models.ChatMessage
	for rows.Next() {
		var msg models.ChatMessage
		err := rows.Scan(&msg.ID, &msg.SessionID, &msg.Role, &msg.Content, &msg.TokenCount, &msg.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("failed to scan chat message: %w", err)
		}
		messages = append(messages, &msg)
	}
	return messages, nil
}

// SaveChatMessage 保存单条对话消息
func (r *SQLiteRepository) SaveChatMessage(ctx context.Context, msg *models.ChatMessage) error {
	// 防御性安全校验：拒绝空内容的历史消息落库，从源头杜绝 400 Param Incorrect 报错
	if strings.TrimSpace(msg.Content) == "" {
		fmt.Printf("[WARN] SQLiteRepository -> Bypassing save of empty chat message for session %s (role: %s).\n", msg.SessionID, msg.Role)
		return nil
	}

	if msg.CreatedAt == 0 {
		msg.CreatedAt = time.Now().Unix()
	}
	query := `
		INSERT INTO chat_messages (id, session_id, role, content, token_count, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`
	_, err := r.db.ExecContext(ctx, query, msg.ID, msg.SessionID, msg.Role, msg.Content, msg.TokenCount, msg.CreatedAt)
	if err != nil {
		return fmt.Errorf("failed to save chat message: %w", err)
	}
	return nil
}

// DeduplicateMemories 自动清洗完全相同的历史未删除记录，只保留最早创建的一条以净化记忆库（防范历史脏数据）
func (r *SQLiteRepository) DeduplicateMemories(ctx context.Context) (int64, error) {
	now := time.Now().Unix()
	query := `
		UPDATE memories 
		SET deleted_at = ?, updated_at = ?
		WHERE id NOT IN (
			SELECT MIN(id) 
			FROM memories 
			WHERE deleted_at IS NULL 
			GROUP BY raw_content
		) AND deleted_at IS NULL;
	`
	res, err := r.db.ExecContext(ctx, query, now, now)
	if err != nil {
		return 0, fmt.Errorf("failed to deduplicate sqlite memories: %w", err)
	}
	rowsAffected, _ := res.RowsAffected()
	return rowsAffected, nil
}

// GetUserProfile 获取全局单用户画像
func (r *SQLiteRepository) GetUserProfile(ctx context.Context) (string, error) {
	var profileData string
	err := r.db.QueryRowContext(ctx, "SELECT profile_data FROM user_profile WHERE id = 1").Scan(&profileData)
	if err != nil {
		if err == sql.ErrNoRows {
			return "", nil
		}
		return "", fmt.Errorf("failed to get user profile: %w", err)
	}
	return profileData, nil
}

// SaveUserProfile 写入/更新全局单用户画像
func (r *SQLiteRepository) SaveUserProfile(ctx context.Context, profileData string) error {
	now := time.Now().Unix()
	query := `
		INSERT INTO user_profile (id, profile_data, updated_at)
		VALUES (1, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			profile_data = excluded.profile_data,
			updated_at = excluded.updated_at;
	`
	_, err := r.db.ExecContext(ctx, query, profileData, now)
	if err != nil {
		return fmt.Errorf("failed to save user profile: %w", err)
	}
	return nil
}

// GetAIConfig 获取全局单用户 AI 密钥配置
func (r *SQLiteRepository) GetAIConfig(ctx context.Context) (*models.AIConfig, error) {
	query := `
		SELECT 
			chat_provider, chat_model, chat_api_key, chat_base_url,
			vision_provider, vision_model, vision_api_key, vision_base_url,
			embed_provider, embed_model, embed_api_key, embed_base_url,
			stt_provider, stt_model, stt_api_key, stt_base_url,
			tts_provider, tts_model, tts_api_key, tts_base_url,
			tts_voice, bark_key
		FROM ai_config 
		WHERE id = 1
	`
	var cfg models.AIConfig
	err := r.db.QueryRowContext(ctx, query).Scan(
		&cfg.ChatProvider, &cfg.ChatModel, &cfg.ChatAPIKey, &cfg.ChatBaseURL,
		&cfg.VisionProvider, &cfg.VisionModel, &cfg.VisionAPIKey, &cfg.VisionBaseURL,
		&cfg.EmbedProvider, &cfg.EmbedModel, &cfg.EmbedAPIKey, &cfg.EmbedBaseURL,
		&cfg.STTProvider, &cfg.STTModel, &cfg.STTAPIKey, &cfg.STTBaseURL,
		&cfg.TTSProvider, &cfg.TTSModel, &cfg.TTSAPIKey, &cfg.TTSBaseURL,
		&cfg.TTSVoice, &cfg.BarkKey,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("failed to get AI config: %w", err)
	}
	return &cfg, nil
}

// SaveAIConfig 保存/更新全局单用户 AI 密钥配置
func (r *SQLiteRepository) SaveAIConfig(ctx context.Context, cfg *models.AIConfig) error {
	now := time.Now().Unix()
	query := `
		INSERT INTO ai_config (
			id, 
			chat_provider, chat_model, chat_api_key, chat_base_url,
			vision_provider, vision_model, vision_api_key, vision_base_url,
			embed_provider, embed_model, embed_api_key, embed_base_url,
			stt_provider, stt_model, stt_api_key, stt_base_url,
			tts_provider, tts_model, tts_api_key, tts_base_url,
			tts_voice, bark_key,
			updated_at
		) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			chat_provider = excluded.chat_provider,
			chat_model = excluded.chat_model,
			chat_api_key = excluded.chat_api_key,
			chat_base_url = excluded.chat_base_url,
			vision_provider = excluded.vision_provider,
			vision_model = excluded.vision_model,
			vision_api_key = excluded.vision_api_key,
			vision_base_url = excluded.vision_base_url,
			embed_provider = excluded.embed_provider,
			embed_model = excluded.embed_model,
			embed_api_key = excluded.embed_api_key,
			embed_base_url = excluded.embed_base_url,
			stt_provider = excluded.stt_provider,
			stt_model = excluded.stt_model,
			stt_api_key = excluded.stt_api_key,
			stt_base_url = excluded.stt_base_url,
			tts_provider = excluded.tts_provider,
			tts_model = excluded.tts_model,
			tts_api_key = excluded.tts_api_key,
			tts_base_url = excluded.tts_base_url,
			tts_voice = excluded.tts_voice,
			bark_key = excluded.bark_key,
			updated_at = excluded.updated_at;
	`
	_, err := r.db.ExecContext(ctx, query,
		cfg.ChatProvider, cfg.ChatModel, cfg.ChatAPIKey, cfg.ChatBaseURL,
		cfg.VisionProvider, cfg.VisionModel, cfg.VisionAPIKey, cfg.VisionBaseURL,
		cfg.EmbedProvider, cfg.EmbedModel, cfg.EmbedAPIKey, cfg.EmbedBaseURL,
		cfg.STTProvider, cfg.STTModel, cfg.STTAPIKey, cfg.STTBaseURL,
		cfg.TTSProvider, cfg.TTSModel, cfg.TTSAPIKey, cfg.TTSBaseURL,
		cfg.TTSVoice, cfg.BarkKey,
		now,
	)
	if err != nil {
		return fmt.Errorf("failed to save AI config: %w", err)
	}
	return nil
}

// SaveScheduledTask 保存一条待执行的任务
func (r *SQLiteRepository) SaveScheduledTask(ctx context.Context, task *models.ScheduledTask) error {
	query := `
		INSERT INTO scheduled_tasks (
			id, memory_id, title, description, action_type, due_time,
			original_due_text, status, created_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`
	_, err := r.db.ExecContext(
		ctx,
		query,
		task.ID,
		task.MemoryID,
		task.Title,
		task.Description,
		task.ActionType,
		task.DueTime,
		task.OriginalDueText,
		task.Status,
		task.CreatedAt,
	)
	if err != nil {
		return fmt.Errorf("failed to save scheduled task: %w", err)
	}
	return nil
}

// DeleteScheduledTask 物理删除一条任务
func (r *SQLiteRepository) DeleteScheduledTask(ctx context.Context, taskID string) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin task deletion: %w", err)
	}
	defer tx.Rollback()

	var memoryID, status string
	err = tx.QueryRowContext(ctx, `
		SELECT memory_id, status FROM scheduled_tasks WHERE id = ?
	`, taskID).Scan(&memoryID, &status)
	if err == sql.ErrNoRows {
		return fmt.Errorf("task not found: %s", taskID)
	}
	if err != nil {
		return fmt.Errorf("failed to query task before deletion: %w", err)
	}

	if _, err := tx.ExecContext(ctx, "DELETE FROM scheduled_tasks WHERE id = ?", taskID); err != nil {
		return fmt.Errorf("failed to delete task: %w", err)
	}
	if status == models.TaskStatusPendingConfirmation {
		if err := completeMemoryConfirmationIfDone(ctx, tx, memoryID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// GetDueTasks 获取所有已到期且尚未执行的待办任务
func (r *SQLiteRepository) GetDueTasks(ctx context.Context, currentTime int64) ([]*models.ScheduledTask, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, memory_id, title, description, action_type, due_time, original_due_text, status, created_at
		FROM scheduled_tasks
		WHERE status = 'pending' AND due_time <= ?
	`, currentTime)
	if err != nil {
		return nil, fmt.Errorf("failed to get due tasks: %w", err)
	}
	defer rows.Close()

	var tasks []*models.ScheduledTask
	for rows.Next() {
		var t models.ScheduledTask
		if err := rows.Scan(
			&t.ID, &t.MemoryID, &t.Title, &t.Description, &t.ActionType,
			&t.DueTime, &t.OriginalDueText, &t.Status, &t.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("failed to scan task: %w", err)
		}
		tasks = append(tasks, &t)
	}
	return tasks, nil
}

// UpdateTaskStatus 更新任务状态（防重复执行）
func (r *SQLiteRepository) UpdateTaskStatus(ctx context.Context, taskID string, status string) error {
	_, err := r.db.ExecContext(ctx, "UPDATE scheduled_tasks SET status = ? WHERE id = ?", status, taskID)
	return err
}

// DeletePendingConfirmationTasksForMemory 清理同一记忆未确认的旧提取结果，保证重试幂等。
func (r *SQLiteRepository) DeletePendingConfirmationTasksForMemory(ctx context.Context, memoryID string) error {
	_, err := r.db.ExecContext(ctx, `
		DELETE FROM scheduled_tasks
		WHERE memory_id = ? AND status = ?
	`, memoryID, models.TaskStatusPendingConfirmation)
	if err != nil {
		return fmt.Errorf("failed to clear pending confirmation tasks: %w", err)
	}
	return nil
}

// GetPendingConfirmationTasks 返回待用户核对的 AI 提取任务，并附带原始记忆内容。
func (r *SQLiteRepository) GetPendingConfirmationTasks(ctx context.Context, limit int) ([]*models.ScheduledTask, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT
			t.id, t.memory_id, t.title, t.description, t.action_type,
			t.due_time, t.original_due_text, t.status, t.created_at,
			COALESCE(m.raw_content, '')
		FROM scheduled_tasks t
		LEFT JOIN memories m ON m.id = t.memory_id
		WHERE t.status = ?
		ORDER BY t.created_at DESC
		LIMIT ?
	`, models.TaskStatusPendingConfirmation, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to query pending confirmation tasks: %w", err)
	}
	defer rows.Close()

	var tasks []*models.ScheduledTask
	for rows.Next() {
		var task models.ScheduledTask
		if err := rows.Scan(
			&task.ID, &task.MemoryID, &task.Title, &task.Description,
			&task.ActionType, &task.DueTime, &task.OriginalDueText,
			&task.Status, &task.CreatedAt, &task.SourceContent,
		); err != nil {
			return nil, fmt.Errorf("failed to scan pending confirmation task: %w", err)
		}
		tasks = append(tasks, &task)
	}
	return tasks, rows.Err()
}

// ConfirmScheduledTask 保存用户修正并激活提醒。
func (r *SQLiteRepository) ConfirmScheduledTask(ctx context.Context, task *models.ScheduledTask) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin task confirmation: %w", err)
	}
	defer tx.Rollback()

	var memoryID, status string
	err = tx.QueryRowContext(ctx, `
		SELECT memory_id, status FROM scheduled_tasks WHERE id = ?
	`, task.ID).Scan(&memoryID, &status)
	if err == sql.ErrNoRows {
		return fmt.Errorf("task not found: %s", task.ID)
	}
	if err != nil {
		return fmt.Errorf("failed to query task before confirmation: %w", err)
	}
	if status != models.TaskStatusPendingConfirmation {
		return fmt.Errorf("task is not pending confirmation")
	}

	_, err = tx.ExecContext(ctx, `
		UPDATE scheduled_tasks
		SET title = ?, description = ?, action_type = ?, due_time = ?, status = ?
		WHERE id = ?
	`, task.Title, task.Description, task.ActionType, task.DueTime, models.TaskStatusPending, task.ID)
	if err != nil {
		return fmt.Errorf("failed to confirm task: %w", err)
	}
	if err := completeMemoryConfirmationIfDone(ctx, tx, memoryID); err != nil {
		return err
	}
	return tx.Commit()
}

func completeMemoryConfirmationIfDone(ctx context.Context, tx *sql.Tx, memoryID string) error {
	if memoryID == "" {
		return nil
	}
	var remaining int
	err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM scheduled_tasks
		WHERE memory_id = ? AND status = ?
	`, memoryID, models.TaskStatusPendingConfirmation).Scan(&remaining)
	if err != nil {
		return fmt.Errorf("failed to count remaining confirmations: %w", err)
	}
	if remaining == 0 {
		_, err = tx.ExecContext(ctx, `
			UPDATE memories
			SET processing_status = ?, processing_error = '', updated_at = ?
			WHERE id = ? AND deleted_at IS NULL
		`, models.MemoryStatusCompleted, time.Now().Unix(), memoryID)
		if err != nil {
			return fmt.Errorf("failed to complete memory confirmation: %w", err)
		}
	}
	return nil
}

// DailyCount 每日录入数量
type DailyCount struct {
	Date  string `json:"date"`
	Count int    `json:"count"`
}

// GetDailyMemoryCounts 返回最近 N 天的每日录入数量（用于活跃趋势柱状图）
func (r *SQLiteRepository) GetDailyMemoryCounts(ctx context.Context, days int) ([]DailyCount, error) {
	query := `
		SELECT DATE(created_at, 'unixepoch', 'localtime') as day, COUNT(*) as cnt
		FROM memories
		WHERE deleted_at IS NULL
		AND created_at >= ?
		GROUP BY day
		ORDER BY day ASC
	`
	cutoff := time.Now().AddDate(0, 0, -days).Unix()
	rows, err := r.db.QueryContext(ctx, query, cutoff)
	if err != nil {
		return nil, fmt.Errorf("failed to get daily memory counts: %w", err)
	}
	defer rows.Close()

	var results []DailyCount
	for rows.Next() {
		var dc DailyCount
		if err := rows.Scan(&dc.Date, &dc.Count); err != nil {
			return nil, fmt.Errorf("failed to scan daily count: %w", err)
		}
		results = append(results, dc)
	}
	return results, nil
}

// GetUpcomingTasks 返回未来即将到来的 pending 状态任务
func (r *SQLiteRepository) GetUpcomingTasks(ctx context.Context, limit int) ([]*models.ScheduledTask, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, memory_id, title, description, action_type, due_time, original_due_text, status, created_at
		FROM scheduled_tasks
		WHERE status = 'pending' AND due_time > ?
		ORDER BY due_time ASC
		LIMIT ?
	`, time.Now().Unix(), limit)
	if err != nil {
		return nil, fmt.Errorf("failed to get upcoming tasks: %w", err)
	}
	defer rows.Close()

	var tasks []*models.ScheduledTask
	for rows.Next() {
		var t models.ScheduledTask
		if err := rows.Scan(
			&t.ID, &t.MemoryID, &t.Title, &t.Description, &t.ActionType,
			&t.DueTime, &t.OriginalDueText, &t.Status, &t.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("failed to scan task: %w", err)
		}
		tasks = append(tasks, &t)
	}
	return tasks, nil
}

// TagCount 标签使用频率统计
type TagCount struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

// GetTopTags 返回使用频率最高的前 N 个标签
func (r *SQLiteRepository) GetTopTags(ctx context.Context, limit int) ([]TagCount, error) {
	query := `
		SELECT t.name, COUNT(mt.tag_id) as cnt
		FROM tags t
		JOIN memory_tags mt ON t.id = mt.tag_id
		JOIN memories m ON mt.memory_id = m.id
		WHERE m.deleted_at IS NULL
		GROUP BY t.id, t.name
		ORDER BY cnt DESC
		LIMIT ?
	`
	rows, err := r.db.QueryContext(ctx, query, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to get top tags: %w", err)
	}
	defer rows.Close()

	var results []TagCount
	for rows.Next() {
		var tc TagCount
		if err := rows.Scan(&tc.Name, &tc.Count); err != nil {
			return nil, fmt.Errorf("failed to scan tag count: %w", err)
		}
		results = append(results, tc)
	}
	return results, nil
}

// GetStreakDays 计算用户连续记录天数（从今天往前推，直到某天没有任何记忆为止）
func (r *SQLiteRepository) GetStreakDays(ctx context.Context) (int, error) {
	query := `
		SELECT DISTINCT DATE(created_at, 'unixepoch', 'localtime') as day
		FROM memories
		WHERE deleted_at IS NULL
		ORDER BY day DESC
		LIMIT 365
	`
	rows, err := r.db.QueryContext(ctx, query)
	if err != nil {
		return 0, fmt.Errorf("failed to get streak days: %w", err)
	}
	defer rows.Close()

	var days []string
	for rows.Next() {
		var day string
		if err := rows.Scan(&day); err != nil {
			return 0, fmt.Errorf("failed to scan day: %w", err)
		}
		days = append(days, day)
	}

	if len(days) == 0 {
		return 0, nil
	}

	streak := 0
	today := time.Now().Format("2006-01-02")
	for i, day := range days {
		expected := time.Now().AddDate(0, 0, -i).Format("2006-01-02")
		if i == 0 && day != today {
			// 今天还没记录，从昨天开始算
			expected = time.Now().AddDate(0, 0, -1).Format("2006-01-02")
			if day != expected {
				return 0, nil
			}
			streak++
			for j := 1; j < len(days); j++ {
				expected = time.Now().AddDate(0, 0, -(j + 1)).Format("2006-01-02")
				if days[j] == expected {
					streak++
				} else {
					break
				}
			}
			return streak, nil
		}
		if day == expected {
			streak++
		} else {
			break
		}
	}
	return streak, nil
}

// GetTodayMemoryCount 返回今天新增的记忆数量
func (r *SQLiteRepository) GetTodayMemoryCount(ctx context.Context) (int, error) {
	// 计算今天零点的 Unix 时间戳
	now := time.Now()
	todayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).Unix()

	var count int
	err := r.db.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM memories WHERE deleted_at IS NULL AND created_at >= ?",
		todayStart,
	).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("failed to get today memory count: %w", err)
	}
	return count, nil
}

func (r *SQLiteRepository) SaveEntityRelation(ctx context.Context, sourceName, sourceType, targetName, targetType, relationType string, memoryID string) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin entity relation tx: %w", err)
	}
	defer tx.Rollback()

	now := time.Now().Unix()

	getOrCreateEntity := func(name, entType string) (string, error) {
		var id string
		err := tx.QueryRowContext(ctx, "SELECT id FROM entities WHERE name = ?", name).Scan(&id)
		if err == sql.ErrNoRows {
			id = "ent_" + strings.ReplaceAll(uuid.New().String(), "-", "")
			_, err = tx.ExecContext(ctx,
				"INSERT INTO entities (id, name, type, created_at) VALUES (?, ?, ?, ?)",
				id, name, entType, now,
			)
			if err != nil {
				return "", fmt.Errorf("failed to insert entity: %w", err)
			}
		} else if err != nil {
			return "", fmt.Errorf("failed to query entity: %w", err)
		}
		return id, nil
	}

	sourceID, err := getOrCreateEntity(sourceName, sourceType)
	if err != nil {
		return err
	}

	targetID, err := getOrCreateEntity(targetName, targetType)
	if err != nil {
		return err
	}

	relationID := "rel_" + strings.ReplaceAll(uuid.New().String(), "-", "")
	_, err = tx.ExecContext(ctx, `
		INSERT INTO entity_relations (id, source_id, target_id, relation_type, weight, created_at)
		VALUES (?, ?, ?, ?, 1.0, ?)
		ON CONFLICT(source_id, target_id, relation_type) DO UPDATE SET
			weight = weight + 0.5,
			created_at = excluded.created_at;
	`, relationID, sourceID, targetID, relationType, now)
	if err != nil {
		return fmt.Errorf("failed to upsert relation: %w", err)
	}

	_, err = tx.ExecContext(ctx, "INSERT OR IGNORE INTO memory_entities (memory_id, entity_id) VALUES (?, ?)", memoryID, sourceID)
	if err != nil {
		return fmt.Errorf("failed to bind source entity to memory: %w", err)
	}
	_, err = tx.ExecContext(ctx, "INSERT OR IGNORE INTO memory_entities (memory_id, entity_id) VALUES (?, ?)", memoryID, targetID)
	if err != nil {
		return fmt.Errorf("failed to bind target entity to memory: %w", err)
	}

	return tx.Commit()
}

type EntityRelation struct {
	SourceID     string  `json:"source_id"`
	SourceName   string  `json:"source_name"`
	SourceType   string  `json:"source_type"`
	TargetID     string  `json:"target_id"`
	TargetName   string  `json:"target_name"`
	TargetType   string  `json:"target_type"`
	RelationType string  `json:"relation_type"`
	Weight       float64 `json:"weight"`
}

func (r *SQLiteRepository) GetGraphRAGRelations(ctx context.Context, memoryIDs []string) ([]*EntityRelation, error) {
	if len(memoryIDs) == 0 {
		return nil, nil
	}

	placeholders := make([]string, len(memoryIDs))
	args := make([]interface{}, len(memoryIDs))
	for i, id := range memoryIDs {
		placeholders[i] = "?"
		args[i] = id
	}

	query := fmt.Sprintf(`
		SELECT DISTINCT 
			r.source_id, e_src.name, e_src.type,
			r.target_id, e_tgt.name, e_tgt.type,
			r.relation_type, r.weight
		FROM entity_relations r
		JOIN entities e_src ON r.source_id = e_src.id
		JOIN entities e_tgt ON r.target_id = e_tgt.id
		WHERE r.source_id IN (
			SELECT entity_id FROM memory_entities WHERE memory_id IN (%s)
		) OR r.target_id IN (
			SELECT entity_id FROM memory_entities WHERE memory_id IN (%s)
		)
	`, strings.Join(placeholders, ","), strings.Join(placeholders, ","))

	queryArgs := append(args, args...)

	rows, err := r.db.QueryContext(ctx, query, queryArgs...)
	if err != nil {
		return nil, fmt.Errorf("failed to query graph relations: %w", err)
	}
	defer rows.Close()

	var relations []*EntityRelation
	for rows.Next() {
		var rel EntityRelation
		err := rows.Scan(
			&rel.SourceID, &rel.SourceName, &rel.SourceType,
			&rel.TargetID, &rel.TargetName, &rel.TargetType,
			&rel.RelationType, &rel.Weight,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan graph relation: %w", err)
		}
		relations = append(relations, &rel)
	}
	return relations, nil
}

type MemoryEntityRelation struct {
	MemoryID   string `json:"memory_id"`
	EntityID   string `json:"entity_id"`
	EntityName string `json:"entity_name"`
	EntityType string `json:"entity_type"`
}

func (r *SQLiteRepository) GetMemoryEntities(ctx context.Context, memoryIDs []string) ([]*MemoryEntityRelation, error) {
	if len(memoryIDs) == 0 {
		return nil, nil
	}

	placeholders := make([]string, len(memoryIDs))
	args := make([]interface{}, len(memoryIDs))
	for i, id := range memoryIDs {
		placeholders[i] = "?"
		args[i] = id
	}

	query := fmt.Sprintf(`
		SELECT me.memory_id, me.entity_id, e.name, e.type
		FROM memory_entities me
		JOIN entities e ON me.entity_id = e.id
		WHERE me.memory_id IN (%s)
	`, strings.Join(placeholders, ","))

	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory entities: %w", err)
	}
	defer rows.Close()

	var list []*MemoryEntityRelation
	for rows.Next() {
		var item MemoryEntityRelation
		err := rows.Scan(&item.MemoryID, &item.EntityID, &item.EntityName, &item.EntityType)
		if err != nil {
			return nil, fmt.Errorf("failed to scan memory entity: %w", err)
		}
		list = append(list, &item)
	}
	return list, nil
}

// GetMemoriesUpdatedAfter 获取指定时间戳之后更新过的所有记忆卡片记录（含标签）
func (r *SQLiteRepository) GetMemoriesUpdatedAfter(ctx context.Context, timestamp int64) ([]*models.Memory, error) {
	query := `
		SELECT id, raw_content, original_content, extracted_time, priority, source_type, source_meta, title, processing_status, processing_error, created_at, updated_at, deleted_at
		FROM memories
		WHERE updated_at > ?
	`
	rows, err := r.db.QueryContext(ctx, query, timestamp)
	if err != nil {
		return nil, fmt.Errorf("failed to query memories updated after %d: %w", timestamp, err)
	}
	defer rows.Close()

	var list []*models.Memory
	for rows.Next() {
		var mem models.Memory
		err := rows.Scan(
			&mem.ID, &mem.RawContent, &mem.OriginalContent, &mem.ExtractedTime, &mem.Priority,
			&mem.SourceType, &mem.SourceMeta, &mem.Title, &mem.ProcessingStatus, &mem.ProcessingError,
			&mem.CreatedAt, &mem.UpdatedAt, &mem.DeletedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan memory: %w", err)
		}

		// 加载当前记忆的所有标签列表
		tagsQuery := `
			SELECT t.name 
			FROM tags t
			JOIN memory_tags mt ON t.id = mt.tag_id
			WHERE mt.memory_id = ?
		`
		tagRows, err := r.db.QueryContext(ctx, tagsQuery, mem.ID)
		if err == nil {
			var tags []string
			for tagRows.Next() {
				var tName string
				if scanErr := tagRows.Scan(&tName); scanErr == nil {
					tags = append(tags, tName)
				}
			}
			tagRows.Close()
			mem.Tags = tags
		}

		list = append(list, &mem)
	}

	return list, nil
}
