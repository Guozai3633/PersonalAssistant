package services

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"time"

	"assistant/config"
	"assistant/models"
)

type TelegramService struct {
	service  *AssistantService
	token    string
	chatID   int64
	client   *http.Client
	stopChan chan struct{}
}

func NewTelegramService(service *AssistantService) *TelegramService {
	return &TelegramService{
		service:  service,
		token:    config.GlobalConfig.TelegramBotToken,
		chatID:   config.GlobalConfig.TelegramChatID,
		client:   &http.Client{Timeout: 35 * time.Second}, // 稍微大于 Long-polling 的 30 秒超时
		stopChan: make(chan struct{}),
	}
}

// Start 在独立协程中启动 Telegram 机器人的 Long-polling 轮询监听
func (t *TelegramService) Start(ctx context.Context) {
	if t.token == "" || t.chatID == 0 {
		fmt.Println("[INFO] Telegram Bot is not configured (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty). Skipping Telegram Bot service.")
		return
	}

	fmt.Printf("[INFO] Telegram Bot is starting. Listening to chat ID: %d...\n", t.chatID)

	go func() {
		offset := 0
		for {
			select {
			case <-t.stopChan:
				fmt.Println("[INFO] Telegram Bot service stopped.")
				return
			case <-ctx.Done():
				fmt.Println("[INFO] Telegram Bot service stopped via context.")
				return
			default:
				// 执行长轮询
				updates, err := t.getUpdates(ctx, offset)
				if err != nil {
					fmt.Printf("[ERROR] Telegram Bot: failed to get updates: %v. Retrying in 10 seconds...\n", err)
					select {
					case <-t.stopChan:
						return
					case <-ctx.Done():
						return
					case <-time.After(10 * time.Second):
					}
					continue
				}

				for _, update := range updates {
					offset = update.UpdateID + 1

					if update.Message == nil {
						continue
					}

					// 强安全机制：校验 Chat ID 白名单
					if update.Message.Chat.ID != t.chatID {
						fmt.Printf("[WARN] Telegram Bot: unauthorized message from Chat ID %d. Ignored.\n", update.Message.Chat.ID)
						continue
					}

					// 异步处理当前消息，避免阻塞轮询主协程
					go t.handleMessage(context.Background(), update.Message)
				}

				// 轮询缓冲
				time.Sleep(500 * time.Millisecond)
			}
		}
	}()
}

// Stop 停止服务
func (t *TelegramService) Stop() {
	close(t.stopChan)
}

// getUpdates 调用 Telegram getUpdates 获取增量消息列表
func (t *TelegramService) getUpdates(ctx context.Context, offset int) ([]tgUpdate, error) {
	url := fmt.Sprintf("https://api.telegram.org/bot%s/getUpdates", t.token)
	reqBody := map[string]interface{}{
		"offset":  offset,
		"timeout": 30,
	}
	jsonBytes, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(jsonBytes))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := t.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var tgResp tgResponse
	if err := json.NewDecoder(resp.Body).Decode(&tgResp); err != nil {
		return nil, err
	}

	if !tgResp.Ok {
		return nil, fmt.Errorf("telegram api error response")
	}

	return tgResp.Result, nil
}

// handleMessage 执行具体的分类多模态入库
func (t *TelegramService) handleMessage(ctx context.Context, msg *tgMessage) {
	// 1. 从 SQLite 加载当前可用的大模型 API 凭证
	aiConfig, err := t.service.GetAIConfig(ctx)
	if err != nil || aiConfig == nil || aiConfig.ChatAPIKey == "" {
		t.SendNotification("⚠️ J.A.R.V.I.S 机器人无法处理您的请求：本地数据库未检测到可用的大模型凭证密钥。请先在手机 App 设置页中保存或触发一次 API 请求以同步密钥！")
		return
	}

	// 2. 判断消息类型
	if msg.Text != "" {
		t.processText(ctx, msg.Text, aiConfig)
	} else if len(msg.Photo) > 0 {
		// 选取分辨率最大的一张照片（一般在列表最后）
		photo := msg.Photo[len(msg.Photo)-1]
		t.processPhoto(ctx, photo.FileID, aiConfig)
	} else if msg.Voice != nil {
		t.processVoice(ctx, msg.Voice.FileID, "voice.ogg", aiConfig)
	} else if msg.Audio != nil {
		t.processVoice(ctx, msg.Audio.FileID, msg.Audio.FileName, aiConfig)
	} else {
		t.SendNotification("💡 J.A.R.V.I.S 目前仅支持处理您发送的 文字、照片或语音速记 消息。")
	}
}

func (t *TelegramService) processText(ctx context.Context, text string, cfg *models.AIConfig) {
	fmt.Printf("[INFO] Telegram Bot: Ingesting text memory: %q\n", text)
	mem, err := t.service.IngestMemory(ctx, text, "text", "Telegram Bot", false, "", nil, cfg)
	if err != nil {
		t.SendNotification(fmt.Sprintf("❌ 文本入库失败: %v", err))
		return
	}

	tagsStr := ""
	if len(mem.Tags) > 0 {
		tagsStr = "\n🏷️ 标签: #" + stringJoin(mem.Tags, " #")
	}
	titleStr := mem.Title
	if titleStr == "" {
		titleStr = "新事实记录"
	}
	t.SendNotification(fmt.Sprintf("✅ 记住了！\n📌 标题: %s\n📝 内容: %s%s", titleStr, mem.RawContent, tagsStr))
}

func (t *TelegramService) processPhoto(ctx context.Context, fileID string, cfg *models.AIConfig) {
	t.SendNotification("📸 收到图片，正在下载并执行 OCR 文字识别提取...")

	fileBytes, fileName, err := t.downloadFile(ctx, fileID)
	if err != nil {
		t.SendNotification(fmt.Sprintf("❌ 图片下载失败: %v", err))
		return
	}

	// 转换 Base64
	base64Data := base64.StdEncoding.EncodeToString(fileBytes)
	mimeType := "image/png"
	ext := filepath.Ext(fileName)
	if ext == ".jpg" || ext == ".jpeg" {
		mimeType = "image/jpeg"
	}
	dataURL := fmt.Sprintf("data:%s;base64,%s", mimeType, base64Data)

	// 调用 IngestMemory 自动通过大模型执行 OCR 并关联入库
	mem, err := t.service.IngestMemory(ctx, dataURL, "image", "Telegram: "+fileName, false, "", nil, cfg)
	if err != nil {
		t.SendNotification(fmt.Sprintf("❌ 图片 OCR 处理失败: %v", err))
		return
	}

	tagsStr := ""
	if len(mem.Tags) > 0 {
		tagsStr = "\n🏷️ 标签: #" + stringJoin(mem.Tags, " #")
	}
	t.SendNotification(fmt.Sprintf("✅ 图片 OCR 识别并提取成功！\n📌 标题: %s\n📝 提取内容: %s%s", mem.Title, mem.RawContent, tagsStr))
}

func (t *TelegramService) processVoice(ctx context.Context, fileID string, fallbackName string, cfg *models.AIConfig) {
	t.SendNotification("🎙️ 收到语音速记，正在下载并转译为文字事实...")

	fileBytes, fileName, err := t.downloadFile(ctx, fileID)
	if err != nil {
		t.SendNotification(fmt.Sprintf("❌ 语音下载失败: %v", err))
		return
	}
	if fileName == "" {
		fileName = fallbackName
	}

	// 转译并入库
	mem, err := t.service.IngestAudio(ctx, fileBytes, fileName, cfg)
	if err != nil {
		t.SendNotification(fmt.Sprintf("❌ 语音转译失败: %v", err))
		return
	}

	tagsStr := ""
	if len(mem.Tags) > 0 {
		tagsStr = "\n🏷️ 标签: #" + stringJoin(mem.Tags, " #")
	}
	t.SendNotification(fmt.Sprintf("✅ 语音转译入库成功！\n📌 标题: %s\n📝 识别内容: %s%s", mem.Title, mem.RawContent, tagsStr))
}

// downloadFile 通过 fileID 下载 Telegram 文件内容与原文件名
func (t *TelegramService) downloadFile(ctx context.Context, fileID string) ([]byte, string, error) {
	// 1. 获取 FilePath
	url := fmt.Sprintf("https://api.telegram.org/bot%s/getFile?file_id=%s", t.token, fileID)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, "", err
	}

	resp, err := t.client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()

	var fileResp tgFileResponse
	if err := json.NewDecoder(resp.Body).Decode(&fileResp); err != nil {
		return nil, "", err
	}

	if !fileResp.Ok || fileResp.Result.FilePath == "" {
		return nil, "", fmt.Errorf("failed to locate file on telegram servers")
	}

	filePath := fileResp.Result.FilePath
	originalName := filepath.Base(filePath)

	// 2. 下载文件字节
	downloadURL := fmt.Sprintf("https://api.telegram.org/file/bot%s/%s", t.token, filePath)
	reqDL, err := http.NewRequestWithContext(ctx, "GET", downloadURL, nil)
	if err != nil {
		return nil, "", err
	}

	respDL, err := t.client.Do(reqDL)
	if err != nil {
		return nil, "", err
	}
	defer respDL.Body.Close()

	fileBytes, err := io.ReadAll(respDL.Body)
	if err != nil {
		return nil, "", err
	}

	return fileBytes, originalName, nil
}

// SendNotification 主动推送提醒消息给指定 Chat ID 用户
func (t *TelegramService) SendNotification(message string) {
	if t.token == "" || t.chatID == 0 {
		return
	}

	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", t.token)
	reqBody := map[string]interface{}{
		"chat_id": t.chatID,
		"text":    message,
	}

	jsonBytes, err := json.Marshal(reqBody)
	if err != nil {
		fmt.Printf("[ERROR] SendNotification: json marshal failed: %v\n", err)
		return
	}

	// 主动推送由于是旁路提醒，设置独立较短超时，防止堵塞业务主线程
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(jsonBytes))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := t.client.Do(req)
	if err != nil {
		fmt.Printf("[ERROR] SendNotification request failed: %v\n", err)
		return
	}
	defer resp.Body.Close()

	var res struct {
		Ok bool `json:"ok"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&res)
	if !res.Ok {
		fmt.Println("[ERROR] SendNotification: Telegram API returned failed status")
	}
}

// Helper: 拼接字符串数组
func stringJoin(elems []string, sep string) string {
	if len(elems) == 0 {
		return ""
	}
	if len(elems) == 1 {
		return elems[0]
	}
	n := len(sep) * (len(elems) - 1)
	for i := 0; i < len(elems); i++ {
		n += len(elems[i])
	}

	var b bytes.Buffer
	b.Grow(n)
	b.WriteString(elems[0])
	for _, s := range elems[1:] {
		b.WriteString(sep)
		b.WriteString(s)
	}
	return b.String()
}

// JSON 结构体映射
type tgResponse struct {
	Ok     bool       `json:"ok"`
	Result []tgUpdate `json:"result"`
}

type tgUpdate struct {
	UpdateID int        `json:"update_id"`
	Message  *tgMessage `json:"message"`
}

type tgMessage struct {
	MessageID int           `json:"message_id"`
	Chat      tgChat        `json:"chat"`
	Text      string        `json:"text"`
	Photo     []tgPhotoSize `json:"photo"`
	Voice     *tgVoice      `json:"voice"`
	Audio     *tgAudio      `json:"audio"`
}

type tgChat struct {
	ID int64 `json:"id"`
}

type tgPhotoSize struct {
	FileID   string `json:"file_id"`
	FileSize int    `json:"file_size"`
}

type tgVoice struct {
	FileID   string `json:"file_id"`
	Duration int    `json:"duration"`
	MimeType string `json:"mime_type"`
}

type tgAudio struct {
	FileID   string `json:"file_id"`
	FileName string `json:"file_name"`
	MimeType string `json:"mime_type"`
}

type tgFileResponse struct {
	Ok     bool   `json:"ok"`
	Result tgFile `json:"result"`
}

type tgFile struct {
	FileID   string `json:"file_id"`
	FilePath string `json:"file_path"`
}
