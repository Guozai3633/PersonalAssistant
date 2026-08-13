package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"assistant/ai"
	"assistant/config"
	"assistant/handlers"
	"assistant/repositories"
	"assistant/services"
)

func main() {
	// 1. 加载系统配置
	config.LoadConfig()
	fmt.Printf("Starting Assistant Backend on port %s...\n", config.GlobalConfig.Port)

	// 2. 初始化 SQLite 关系型事实仓储
	sqliteRepo, err := repositories.NewSQLiteRepository()
	if err != nil {
		fmt.Printf("CRITICAL: Failed to initialize SQLite: %v\n", err)
		os.Exit(1)
	}
	defer sqliteRepo.Close()
	fmt.Println("SQLite database initialized successfully.")

	// 3. 初始化 Qdrant 语义向量仓储
	qdrantRepo, err := repositories.NewQdrantRepository()
	if err != nil {
		fmt.Printf("CRITICAL: Failed to initialize Qdrant client: %v\n", err)
		os.Exit(1)
	}
	defer qdrantRepo.Close()
	fmt.Println("Qdrant client connected successfully.")

	// 4. 初始化 Eino AI 工作流编排引擎
	einoEngine := ai.NewEinoEngine(sqliteRepo, qdrantRepo)

	// 5. 初始化业务逻辑服务层与控制器
	assistantService := services.NewAssistantService(sqliteRepo, qdrantRepo, einoEngine)
	
	// 5.5 初始化并启动 Telegram Bot 服务
	telegramService := services.NewTelegramService(assistantService)
	assistantService.RegisterNotifyListener(telegramService.SendNotification)
	telegramService.Start(context.Background())

	apiHandler := handlers.NewHandler(assistantService)

	// 6. 注册 HTTP 路由
	mux := http.NewServeMux()
	apiHandler.RegisterRoutes(mux)

	// 增加基本健康检查端点
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"UP","time":"` + time.Now().Format(time.RFC3339) + `"}`))
	})

	server := &http.Server{
		Addr:    ":" + config.GlobalConfig.Port,
		Handler: mux,
	}

	// 7. 实现优雅停机监听机制 (Graceful Shutdown)
	shutdownChan := make(chan os.Signal, 1)
	signal.Notify(shutdownChan, syscall.SIGINT, syscall.SIGTERM)

	// 在独立协程中启动 HTTP 服务
	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Printf("CRITICAL: HTTP Server failed: %v\n", err)
			os.Exit(1)
		}
	}()
	fmt.Printf("HTTP Server is listening on %s\n", server.Addr)

	// 阻塞等待退出信号
	sig := <-shutdownChan
	fmt.Printf("Received signal: %v. Initiating graceful shutdown...\n", sig)

	// 限制 10 秒超时用于平滑断开网络和数据库连接
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		fmt.Printf("ERROR: HTTP server forced shutdown failed: %v\n", err)
	} else {
		fmt.Println("HTTP Server closed gracefully.")
	}

	// 停止 Telegram Bot 轮询监听
	telegramService.Stop()

	fmt.Println("Assistant Backend stopped.")
}
