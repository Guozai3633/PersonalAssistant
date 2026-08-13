package repositories

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"assistant/config"
	"assistant/models"
)

func TestMemoryProcessingStatusMigrationAndUpdate(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "assistant.db")
	legacyDB, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatalf("open legacy database: %v", err)
	}
	_, err = legacyDB.Exec(`
		CREATE TABLE memories (
			id TEXT PRIMARY KEY,
			raw_content TEXT NOT NULL,
			extracted_time TEXT,
			priority INTEGER DEFAULT 1,
			source_type TEXT DEFAULT 'text',
			source_meta TEXT,
			title TEXT DEFAULT '',
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			deleted_at INTEGER
		);
		INSERT INTO memories (
			id, raw_content, source_type, created_at, updated_at
		) VALUES ('legacy', 'old memory', 'text', 1, 1);
		CREATE TABLE scheduled_tasks (
			id TEXT PRIMARY KEY,
			title TEXT NOT NULL,
			description TEXT NOT NULL,
			action_type TEXT NOT NULL,
			due_time INTEGER NOT NULL,
			status TEXT DEFAULT 'pending',
			created_at INTEGER NOT NULL
		);
		INSERT INTO scheduled_tasks (
			id, title, description, action_type, due_time, status, created_at
		) VALUES (
			'legacy_task', 'old task', '', 'reminder', 4102444800, 'pending', 1
		);
	`)
	if err != nil {
		legacyDB.Close()
		t.Fatalf("create legacy schema: %v", err)
	}
	if err := legacyDB.Close(); err != nil {
		t.Fatalf("close legacy database: %v", err)
	}

	previousConfig := config.GlobalConfig
	config.GlobalConfig = &config.Config{DBPath: dbPath}
	t.Cleanup(func() {
		config.GlobalConfig = previousConfig
	})

	repo, err := NewSQLiteRepository()
	if err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	t.Cleanup(func() {
		_ = repo.Close()
	})

	ctx := context.Background()
	legacy, err := repo.GetMemory(ctx, "legacy")
	if err != nil {
		t.Fatalf("get migrated memory: %v", err)
	}
	if legacy.ProcessingStatus != models.MemoryStatusCompleted {
		t.Fatalf("legacy status = %q, want %q", legacy.ProcessingStatus, models.MemoryStatusCompleted)
	}
	if legacy.OriginalContent != "old memory" {
		t.Fatalf("legacy original content = %q", legacy.OriginalContent)
	}
	legacyTasks, err := repo.GetUpcomingTasks(ctx, 10)
	if err != nil {
		t.Fatalf("get migrated tasks: %v", err)
	}
	if len(legacyTasks) != 1 || legacyTasks[0].MemoryID != "" {
		t.Fatalf("migrated tasks = %#v", legacyTasks)
	}

	pending := &models.Memory{
		ID:               "new",
		RawContent:       "new memory",
		SourceType:       "text",
		ProcessingStatus: models.MemoryStatusPending,
	}
	if err := repo.SaveMemory(ctx, pending); err != nil {
		t.Fatalf("save pending memory: %v", err)
	}
	if err := repo.UpdateMemoryProcessingStatus(
		ctx,
		pending.ID,
		models.MemoryStatusFailed,
		"model unavailable",
	); err != nil {
		t.Fatalf("update processing status: %v", err)
	}

	failed, err := repo.GetMemory(ctx, pending.ID)
	if err != nil {
		t.Fatalf("get failed memory: %v", err)
	}
	if failed.ProcessingStatus != models.MemoryStatusFailed {
		t.Fatalf("status = %q, want %q", failed.ProcessingStatus, models.MemoryStatusFailed)
	}
	if failed.ProcessingError != "model unavailable" {
		t.Fatalf("processing error = %q", failed.ProcessingError)
	}
}

func TestTaskConfirmationActivatesSchedulingAndCompletesMemory(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "assistant.db")
	previousConfig := config.GlobalConfig
	config.GlobalConfig = &config.Config{DBPath: dbPath}
	t.Cleanup(func() {
		config.GlobalConfig = previousConfig
	})

	repo, err := NewSQLiteRepository()
	if err != nil {
		t.Fatalf("create repository: %v", err)
	}
	t.Cleanup(func() {
		_ = repo.Close()
	})

	ctx := context.Background()
	memory := &models.Memory{
		ID:               "memory_with_tasks",
		RawContent:       "明天下午三点交报告，并提醒我给老师发邮件",
		SourceType:       "text",
		ProcessingStatus: models.MemoryStatusNeedsConfirmation,
	}
	if err := repo.SaveMemory(ctx, memory); err != nil {
		t.Fatalf("save memory: %v", err)
	}

	dueTime := time.Now().Add(24 * time.Hour).Unix()
	for _, task := range []*models.ScheduledTask{
		{
			ID:              "task_report",
			MemoryID:        memory.ID,
			Title:           "提交报告",
			Description:     "提交课程报告",
			ActionType:      "reminder",
			DueTime:         dueTime,
			OriginalDueText: "明天下午三点",
			Status:          models.TaskStatusPendingConfirmation,
			CreatedAt:       time.Now().Unix(),
		},
		{
			ID:         "task_email",
			MemoryID:   memory.ID,
			Title:      "给老师发邮件",
			ActionType: "reminder",
			DueTime:    dueTime,
			Status:     models.TaskStatusPendingConfirmation,
			CreatedAt:  time.Now().Unix(),
		},
	} {
		if err := repo.SaveScheduledTask(ctx, task); err != nil {
			t.Fatalf("save task %s: %v", task.ID, err)
		}
	}

	confirmations, err := repo.GetPendingConfirmationTasks(ctx, 10)
	if err != nil {
		t.Fatalf("get confirmations: %v", err)
	}
	if len(confirmations) != 2 {
		t.Fatalf("confirmation count = %d, want 2", len(confirmations))
	}
	if confirmations[0].SourceContent == "" {
		t.Fatal("confirmation task is missing source content")
	}

	if err := repo.ConfirmScheduledTask(ctx, &models.ScheduledTask{
		ID:          "task_report",
		Title:       "提交最终报告",
		Description: "确认后的描述",
		ActionType:  "alarm",
		DueTime:     dueTime,
	}); err != nil {
		t.Fatalf("confirm task: %v", err)
	}

	upcoming, err := repo.GetUpcomingTasks(ctx, 10)
	if err != nil {
		t.Fatalf("get upcoming tasks: %v", err)
	}
	if len(upcoming) != 1 || upcoming[0].ID != "task_report" {
		t.Fatalf("upcoming tasks = %#v, want only confirmed task", upcoming)
	}
	stillWaiting, err := repo.GetMemory(ctx, memory.ID)
	if err != nil {
		t.Fatalf("get memory before final decision: %v", err)
	}
	if stillWaiting.ProcessingStatus != models.MemoryStatusNeedsConfirmation {
		t.Fatalf("memory status = %q before final decision", stillWaiting.ProcessingStatus)
	}

	if err := repo.DeleteScheduledTask(ctx, "task_email"); err != nil {
		t.Fatalf("reject remaining task: %v", err)
	}
	completed, err := repo.GetMemory(ctx, memory.ID)
	if err != nil {
		t.Fatalf("get completed memory: %v", err)
	}
	if completed.ProcessingStatus != models.MemoryStatusCompleted {
		t.Fatalf("memory status = %q, want completed", completed.ProcessingStatus)
	}
}
