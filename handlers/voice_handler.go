package handlers

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"assistant/config"
	"assistant/models"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  8192,
	WriteBufferSize: 8192,
	CheckOrigin: func(r *http.Request) bool {
		return true // 自托管开发环境下，允许跨域
	},
}

// WSMessage 客户端发送控制帧
type WSMessage struct {
	Type   string `json:"type"`   // "start", "end"
	Format string `json:"format"` // "pcm"
}

// HandleVoiceStream 处理语音交互双向流 (WebSocket)
func (h *Handler) HandleVoiceStream(w http.ResponseWriter, r *http.Request) {
	// API Token 鉴权，支持 URL Query, Header 以及 Bearer 头
	expectedToken := config.GlobalConfig.APIToken
	if expectedToken != "" {
		reqToken := r.URL.Query().Get("token")
		if reqToken == "" {
			reqToken = r.Header.Get("X-App-Token")
		}
		if reqToken == "" {
			authHeader := r.Header.Get("Authorization")
			if strings.HasPrefix(authHeader, "Bearer ") {
				reqToken = strings.TrimPrefix(authHeader, "Bearer ")
			}
		}
		if reqToken != expectedToken {
			http.Error(w, "Unauthorized: Invalid or missing API Token", http.StatusUnauthorized)
			return
		}
	}

	ctx := r.Context()
	dbCfg, err := h.service.GetAIConfig(ctx)
	if err != nil {
		fmt.Printf("[WARN] Failed to get AI Config from database: %v\n", err)
	}

	// 升级连接为 WebSocket
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		fmt.Printf("[ERROR] WebSocket upgrade failed: %v\n", err)
		return
	}
	defer conn.Close()

	fmt.Println("[INFO] Voice Loop WebSocket connected.")

	var wsMu sync.Mutex
	writeJSON := func(v interface{}) error {
		wsMu.Lock()
		defer wsMu.Unlock()
		return conn.WriteJSON(v)
	}
	writeBinary := func(data []byte) error {
		wsMu.Lock()
		defer wsMu.Unlock()
		return conn.WriteMessage(websocket.BinaryMessage, data)
	}

	// 整合配置缓存，如果数据库有配置则复用
	var aiConfig *models.AIConfig
	if dbCfg != nil {
		aiConfig = dbCfg
	} else {
		aiConfig = &models.AIConfig{}
	}

	// 允许从请求头或 Query 临时覆写配置
	h.overrideConfigFromQuery(r, aiConfig)

	// 异步固化凭证到 SQLite 数据库，防范局部没有被保存的问题
	if aiConfig.ChatAPIKey != "" {
		go func(c *models.AIConfig) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = h.service.SaveAIConfig(ctx, c)
		}(aiConfig)
	}

	// 语音录入二进制缓冲区
	var audioBuffer bytes.Buffer
	sessionID := "session_voice"

	for {
		messageType, payload, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				fmt.Println("[INFO] WebSocket closed normally.")
			} else {
				fmt.Printf("[WARN] WebSocket read error: %v\n", err)
			}
			break
		}

		if messageType == websocket.BinaryMessage {
			// 音频原始 PCM 数据块
			audioBuffer.Write(payload)
		} else if messageType == websocket.TextMessage {
			// 控制 JSON 命令
			var msg WSMessage
			if err := json.Unmarshal(payload, &msg); err != nil {
				_ = writeJSON(map[string]string{"type": "error", "content": "Invalid control frame"})
				continue
			}

			switch msg.Type {
			case "start":
				audioBuffer.Reset()
				fmt.Println("[INFO] Voice stream ingestion started.")
				_ = writeJSON(map[string]string{"type": "status", "content": "listening"})
			case "end":
				fmt.Printf("[INFO] Voice stream ingestion completed. Ingested size: %d bytes\n", audioBuffer.Len())
				if audioBuffer.Len() == 0 {
					_ = writeJSON(map[string]string{"type": "error", "content": "Empty audio data"})
					continue
				}

				// 开启异步处理链，防止阻塞 WS 接收循环
				go func(audioData []byte) {
					// 1. ASR 语音识别
					// 将 PCM 转化为 WAV 格式（Whisper 兼容）
					wavBytes := addWavHeader(audioData, 16000, 1, 16)
					
					_ = writeJSON(map[string]string{"type": "status", "content": "asr_processing"})
					asrText, err := h.service.TranscribeAudio(context.Background(), wavBytes, "audio.wav", aiConfig)
					if err != nil {
						fmt.Printf("[ERROR] Voice STT failed: %v\n", err)
						_ = writeJSON(map[string]string{"type": "error", "content": "STT failed: " + err.Error()})
						return
					}
					asrText = strings.TrimSpace(asrText)
					if asrText == "" {
						_ = writeJSON(map[string]string{"type": "status", "content": "silent"})
						return
					}

					// 向客户端广播 ASR 结果
					_ = writeJSON(map[string]string{"type": "asr_text", "content": asrText})

					// 将本次用户的 ASR 转译文本持久化到本地 SQLite 数据库中，以维持完整多轮会话
					userMsg := &models.ChatMessage{
						ID:        fmt.Sprintf("msg_%d_user", time.Now().UnixNano()),
						SessionID: sessionID,
						Role:      "user",
						Content:   asrText,
						CreatedAt: time.Now().Unix(),
					}
					_ = h.service.SaveChatMessage(context.Background(), userMsg)

					// 2. 检索并开启流式大语言模型生成回答
					_ = writeJSON(map[string]string{"type": "status", "content": "llm_processing"})
					
					streamReader, err := h.service.RetrieveAndStreamAnswer(context.Background(), asrText, sessionID, aiConfig)
					if err != nil {
						fmt.Printf("[ERROR] Stream LLM generate failed: %v\n", err)
						_ = writeJSON(map[string]string{"type": "error", "content": "LLM query failed: " + err.Error()})
						return
					}

					// 开启句子的 TTS 流式消费协程
					sentenceChan := make(chan string, 10)
					var ttsWg sync.WaitGroup
					ttsWg.Add(1)
					go func() {
						defer ttsWg.Done()
						for sentence := range sentenceChan {
							sentence = strings.TrimSpace(sentence)
							if sentence == "" {
								continue
							}
							
							// 语音流式合成 (TTS)
							audioBytes, err := h.service.GenerateTTS(context.Background(), sentence, aiConfig)
							if err != nil {
								fmt.Printf("[ERROR] TTS failed for sentence %q: %v\n", sentence, err)
								// 向客户端推送 TTS 错误信息，帮助定位声音问题
								_ = writeJSON(map[string]string{"type": "tts_error", "content": "TTS合成失败: " + err.Error()})
								continue
							}
							
							fmt.Printf("[DEBUG] TTS audio chunk generated: %d bytes for sentence: %q\n", len(audioBytes), sentence)
							
							if len(audioBytes) == 0 {
								fmt.Printf("[WARN] TTS returned 0 bytes for sentence %q, skipping\n", sentence)
								_ = writeJSON(map[string]string{"type": "tts_error", "content": "TTS返回空音频数据"})
								continue
							}

							// 将音频二进制流直接写入 WS 发送给客户端进行拼接播放
							if err := writeBinary(audioBytes); err != nil {
								fmt.Printf("[WARN] Failed to write binary TTS audio frame: %v\n", err)
								break
							}
						}
					}()

					// 3. 读取 LLM 流式输出，进行流式打字与按标点断句
					var fullResponse strings.Builder
					var currentSentence strings.Builder

					for {
						chunk, err := streamReader.Recv()
						if err != nil {
							// 读取结束或被取消
							break
						}
						
						content := chunk.Content
						fullResponse.WriteString(content)
						currentSentence.WriteString(content)

						// 实时向客户端返回流式文字（打字机）
						_ = writeJSON(map[string]string{"type": "llm_text", "content": content})

						// 流式断句判断
						currentText := currentSentence.String()
						if containsSentenceEnd(currentText) {
							runes := []rune(currentText)
							// 为了让发音更饱满连贯，句子不少于 5 个字或者包含换行时才断句
							if len(runes) >= 5 || strings.Contains(currentText, "\n") {
								if !strings.Contains(currentText, "[TASK_COMMAND:") {
									sentenceChan <- currentText
								}
								currentSentence.Reset()
							}
						}
					}
					streamReader.Close()

					// 发送最后的余留句子
					if currentSentence.Len() > 0 {
						lastSent := currentSentence.String()
						if !strings.Contains(lastSent, "[TASK_COMMAND:") {
							sentenceChan <- lastSent
						}
					}
					close(sentenceChan)

					// 等待 TTS 发送完毕
					ttsWg.Wait()

					// 4. 处理命令并净化完整回复
					cleanAnswer := h.service.HandleTaskCommands(context.Background(), fullResponse.String())

					// 发送结束标识包
					_ = writeJSON(map[string]string{
						"type":          "llm_end",
						"clean_content": cleanAnswer,
					})

					// 将本次 AI 回复持久化到本地 SQLite 数据库中，保持上下文连贯
					assistantMsg := &models.ChatMessage{
						ID:        fmt.Sprintf("msg_%d_assistant", time.Now().UnixNano()),
						SessionID: sessionID,
						Role:      "assistant",
						Content:   cleanAnswer,
						CreatedAt: time.Now().Unix(),
					}
					_ = h.service.SaveChatMessage(context.Background(), assistantMsg)
					fmt.Println("[INFO] Stream Voice round completed and saved to history.")
				}(audioBuffer.Bytes())
			}
		}
	}
}

// 从请求 Query 中解析覆写配置
func (h *Handler) overrideConfigFromQuery(r *http.Request, cfg *models.AIConfig) {
	q := r.URL.Query()
	if q.Get("chat_provider") != "" {
		cfg.ChatProvider = q.Get("chat_provider")
	}
	if q.Get("chat_model") != "" {
		cfg.ChatModel = q.Get("chat_model")
	}
	if q.Get("chat_api_key") != "" {
		cfg.ChatAPIKey = q.Get("chat_api_key")
	}
	if q.Get("chat_base_url") != "" {
		cfg.ChatBaseURL = q.Get("chat_base_url")
	}

	if q.Get("vision_provider") != "" {
		cfg.VisionProvider = q.Get("vision_provider")
	}
	if q.Get("vision_model") != "" {
		cfg.VisionModel = q.Get("vision_model")
	}
	if q.Get("vision_api_key") != "" {
		cfg.VisionAPIKey = q.Get("vision_api_key")
	}
	if q.Get("vision_base_url") != "" {
		cfg.VisionBaseURL = q.Get("vision_base_url")
	}

	if q.Get("embed_provider") != "" {
		cfg.EmbedProvider = q.Get("embed_provider")
	}
	if q.Get("embed_model") != "" {
		cfg.EmbedModel = q.Get("embed_model")
	}
	if q.Get("embed_api_key") != "" {
		cfg.EmbedAPIKey = q.Get("embed_api_key")
	}
	if q.Get("embed_base_url") != "" {
		cfg.EmbedBaseURL = q.Get("embed_base_url")
	}

	if q.Get("stt_provider") != "" {
		cfg.STTProvider = q.Get("stt_provider")
	}
	if q.Get("stt_model") != "" {
		cfg.STTModel = q.Get("stt_model")
	}
	if q.Get("stt_api_key") != "" {
		cfg.STTAPIKey = q.Get("stt_api_key")
	}
	if q.Get("stt_base_url") != "" {
		cfg.STTBaseURL = q.Get("stt_base_url")
	}

	if q.Get("tts_provider") != "" {
		cfg.TTSProvider = q.Get("tts_provider")
	}
	if q.Get("tts_model") != "" {
		cfg.TTSModel = q.Get("tts_model")
	}
	if q.Get("tts_api_key") != "" {
		cfg.TTSAPIKey = q.Get("tts_api_key")
	}
	if q.Get("tts_base_url") != "" {
		cfg.TTSBaseURL = q.Get("tts_base_url")
	}
	if q.Get("tts_voice") != "" {
		cfg.TTSVoice = q.Get("tts_voice")
	}
	if q.Get("bark_key") != "" {
		cfg.BarkKey = q.Get("bark_key")
	}
}

// 检查是否是一句话的结尾
func containsSentenceEnd(s string) bool {
	if len(s) == 0 {
		return false
	}
	ends := []string{"。", "！", "？", "，", "\n", "；", "；", ".", "!", "?", ","}
	for _, end := range ends {
		if strings.HasSuffix(s, end) {
			return true
		}
	}
	return false
}

// 构造 WAV 头
func addWavHeader(pcmData []byte, sampleRate int, numChannels int, bitsPerSample int) []byte {
	subChunk2Size := len(pcmData)
	chunkSize := 36 + subChunk2Size
	byteRate := sampleRate * numChannels * bitsPerSample / 8
	blockAlign := numChannels * bitsPerSample / 8

	header := make([]byte, 44)
	copy(header[0:4], "RIFF")
	binary.LittleEndian.PutUint32(header[4:8], uint32(chunkSize))
	copy(header[8:12], "WAVE")
	copy(header[12:16], "fmt ")
	binary.LittleEndian.PutUint32(header[16:20], 16) // Subchunk1Size
	binary.LittleEndian.PutUint16(header[20:22], 1)  // AudioFormat (PCM)
	binary.LittleEndian.PutUint16(header[22:24], uint16(numChannels))
	binary.LittleEndian.PutUint32(header[24:28], uint32(sampleRate))
	binary.LittleEndian.PutUint32(header[28:32], uint32(byteRate))
	binary.LittleEndian.PutUint16(header[32:34], uint16(blockAlign))
	binary.LittleEndian.PutUint16(header[34:36], uint16(bitsPerSample))
	copy(header[36:40], "data")
	binary.LittleEndian.PutUint32(header[40:44], uint32(subChunk2Size))

	return append(header, pcmData...)
}
