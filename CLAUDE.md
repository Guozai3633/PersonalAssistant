# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Personal AI Assistant** -- a single-user, self-hosted, open-source personal information management system. Users input raw information (text, images, notes) and the system automatically handles extraction, tagging, vectorization, and AI-powered retrieval via natural language queries. The project uses BYOK (Bring Your Own Key) -- users provide their own LLM API keys.

**Tech stack:** Go backend, Flutter frontend, SQLite (relational), Qdrant (vector), CloudWeGo Eino (AI workflow orchestration).

## Common Commands

```bash
# Run backend locally (requires CGO for go-sqlite3)
go run main.go

# Build backend
go build -o assistant-backend main.go

# Run tests (RRF algorithm tests only -- no DB required)
go test ./ai/ -v

# Docker Compose (recommended -- starts Qdrant + Backend)
docker-compose up --build

# Docker Compose (detach mode)
docker-compose up -d

# Stop all services
docker-compose down
```

The backend HTTP server listens on port 8080 (mapped to 8082 on host via docker-compose).

## Architecture

The backend follows a strict three-layer architecture + AI engine:

```
Handler (HTTP) -> Service (Business Logic) -> Repository (Data Access) + AI Engine (Eino)
```

**Key files by layer:**

- **Entry point:** `main.go` -- bootstraps server, registers routes, handles graceful shutdown
- **Config:** `config/config.go` -- environment-based configuration (PORT, DB_PATH, QDRANT_*)
- **Handler:** `handlers/handlers.go` -- HTTP endpoints with CORS middleware. Calls AssistantService. No direct DB access.
- **Service:** `services/assistant_service.go` -- business logic. Calls repositories and AI engine.
- **Repository:** `repositories/sqlite_repository.go` (SQLite CRUD) and `repositories/qdrant_repository.go` (vector operations)
- **AI Engine:** `ai/eino_engine.go` -- LLM metadata extraction, embedding, query intent parsing, OCR, dual-track retrieval with RRF fusion, answer generation. Uses `sync.Map` caches keyed by SHA256(config).

**Data flow for ingestion:** HTTP -> Handler -> Service -> EinoEngine (OCR if image -> extract metadata via LLM -> embed -> save Qdrant -> save SQLite)

**Data flow for queries:** HTTP -> Handler -> Service -> EinoEngine (parse intent -> SQLite precise search + Qdrant vector search -> RRF fusion -> LLM answer generation -> persist conversation)

**Database design:**
- **SQLite:** stores structured facts (memories, tags, chat sessions/messages, AI config). Soft-delete via `deleted_at`. WAL mode.
- **Qdrant:** stores embeddings with payload indexes on memory_id, tags, extracted_time, priority, created_at. Collection-per-provider-dimension naming (`memories_{provider}_{dimension}`).

**Key architectural patterns:**
- Handlers cannot call repositories directly -- must go through services
- All config from environment variables, no hardcoding
- AI providers are dynamic and cacheable (OpenAI-compatible API)
- Self-healing: background vector reconciliation auto-repairs missing Qdrant vectors
- Idempotent ingestion: SHA256 in-flight lock + 5-minute content dedup

## Documentation-First Workflow

This repository enforces a documentation-first philosophy (see `.agent/AGENT.md`):

- **Before adding features:** Read `docs/01-product/PRD.md` and `mvp.md`, check related design docs, update roadmap and API/architecture docs
- **Before fixing bugs:** Check `docs/05-operation/issues.md`
- **Database changes:** Must update `docs/02-architecture/database-design.md`
- **RAG/AI changes:** Must update `docs/02-architecture/rag-design.md` and `docs/08-ai/`
- **API changes:** Must update `docs/03-api/`

MVP-stage forbidden features: multi-user, SaaS, permissions, agent auto-execution, auto-reminders, knowledge graphs, plugin markets, enterprise collaboration.

## Agent Rules Summary

Key rules from `.agent/skills/`:
- Functions should be under 100 lines; use camelCase variables, PascalCase structs
- No `panic()` -- use proper error handling with context propagation
- SQLite stores facts, Qdrant stores semantics; vectors must retain source/time/tags
- AI modules (Prompt, Workflow, Retriever, Embedding, Rerank) must be independent

# 全局指令 (Global Instructions)

1. **Language Requirement:** You MUST always respond to the user in Simplified Chinese (简体中文). Whether the user's input is in English, code, or error logs, your explanations, comments, and daily communication must be in Chinese.
2. **Agent Workflow:** 这是一个拥有自定义工作流的项目。关于你的角色设定、核心工作流以及技能，请严格读取并遵循 `.agent/AGENT.md` 文件中的内容。此外，在执行特定任务时，请按需查阅 `.agent/skills`、`.agent/templates` 和 `.agent/workflow` 目录下的相关文件。
