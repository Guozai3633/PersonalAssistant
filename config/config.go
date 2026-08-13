package config

import (
	"os"
	"strconv"
)

type Config struct {
	Port               string
	DBPath             string
	QdrantHost         string
	QdrantPort         string
	QdrantgRPCPort     string
	TelegramBotToken   string
	TelegramChatID     int64
	APIToken           string
	LocalMode          bool
	OllamaAPIBase      string
	EncryptionMode     bool
}

var GlobalConfig *Config

func LoadConfig() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "./assistant.db"
	}

	qdrantHost := os.Getenv("QDRANT_HOST")
	if qdrantHost == "" {
		qdrantHost = "localhost"
	}

	qdrantPort := os.Getenv("QDRANT_PORT")
	if qdrantPort == "" {
		qdrantPort = "6333" // REST API 端口
	}

	qdrantgRPCPort := os.Getenv("QDRANT_GRPC_PORT")
	if qdrantgRPCPort == "" {
		qdrantgRPCPort = "6334" // gRPC API 端口
	}

	telegramBotToken := os.Getenv("TELEGRAM_BOT_TOKEN")
	telegramChatIDStr := os.Getenv("TELEGRAM_CHAT_ID")
	var telegramChatID int64
	if telegramChatIDStr != "" {
		if id, err := strconv.ParseInt(telegramChatIDStr, 10, 64); err == nil {
			telegramChatID = id
		}
	}

	apiToken := os.Getenv("APP_API_TOKEN")

	localMode := os.Getenv("LOCAL_MODE") == "true"
	ollamaAPIBase := os.Getenv("OLLAMA_API_BASE")
	if ollamaAPIBase == "" {
		ollamaAPIBase = "http://localhost:11434"
	}
	encryptionMode := os.Getenv("ENCRYPTION_MODE") == "true"

	GlobalConfig = &Config{
		Port:             port,
		DBPath:           dbPath,
		QdrantHost:       qdrantHost,
		QdrantPort:       qdrantPort,
		QdrantgRPCPort:   qdrantgRPCPort,
		TelegramBotToken: telegramBotToken,
		TelegramChatID:   telegramChatID,
		APIToken:         apiToken,
		LocalMode:        localMode,
		OllamaAPIBase:    ollamaAPIBase,
		EncryptionMode:   encryptionMode,
	}
}
