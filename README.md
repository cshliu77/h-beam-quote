# H-Beam Quote Service

[![CI](https://github.com/cshliu77/h-beam-quote/actions/workflows/ci.yml/badge.svg)](https://github.com/cshliu77/h-beam-quote/actions/workflows/ci.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-h--beam--quote-2496ED?logo=docker&logoColor=white)](https://github.com/cshliu77/h-beam-quote/pkgs/container/h-beam-quote)

> GDG **Agent Runtime Hands-on Lab** · 2026/05/21
>
> 一個用 Go + SQLite 打造的單檔 container,作為 ADK Agent 的後端服務。
> 系統使用者:**公司業務員 / 報價助理(內部使用)**
> 對話內容:外部客戶與其專案的報價需求

## Lab Day Quickstart(用講師預先 build 好的 GHCR image)

學員只需 **gcloud / uv / agents-cli** 三個 CLI(不需 docker 也不需 go):

```bash
git clone https://github.com/cshliu77/h-beam-quote
cd h-beam-quote
export GCP_PROJECT=your-gcp-project
./scripts/lab-bootstrap.sh
```

腳本會跳過 `Cloud Build / Artifact Registry`,直接在 Cloud Run 拉 `ghcr.io/cshliu77/h-beam-quote:latest`。
從 `git clone` 到 Agent 部署完成 < 5 分鐘。

### 鎖版(Lab Day 避免上課中途漂移)

```bash
H_BEAM_IMAGE=ghcr.io/cshliu77/h-beam-quote:v0.1.0 ./scripts/lab-bootstrap.sh
```

### 自己改 Go 程式碼?走本機 build(escape hatch)

```bash
BUILD_LOCAL=true ./scripts/lab-bootstrap.sh
# 改回 9-phase 流程:Cloud Build → Artifact Registry → Cloud Run
```

### 看狀態 / 清資源

```bash
./scripts/lab-status.sh           # 看當前部署狀態
./scripts/lab-teardown.sh --yes   # Lab 結束後清掉所有資源
```

詳細 7 段教學流程見 `h-beam-quote/agent/lab_script.md`。

## 架構

```
┌─────────────────────────────────────────────────────────┐
│  Cloud Run (single container)                           │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Go binary (server)                                │ │
│  │  ├─ Gin HTTP router                                │ │
│  │  ├─ SQLite (modernc, pure Go, no CGO)              │ │
│  │  ├─ Frontend embedded via go:embed                 │ │
│  │  └─ /tmp/h-beam.db (re-seeded on cold start)       │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
                       ▲
                       │ HTTPS (REST)
            ┌──────────┴──────────┐
            │   ADK Agent         │
            │   FunctionTool x 7  │
            │   + load_memory     │
            └──────────┬──────────┘
                       │
            ┌──────────▼──────────┐
            │  Vertex AI          │
            │  Agent Engine       │
            │  Memory Bank        │
            └─────────────────────┘
```

## 本地執行

```bash
go mod tidy        # 第一次執行,下載依賴並產生 go.sum
go run .
# 開啟 http://localhost:8080
```

## Docker 執行

```bash
docker build -t h-beam-quote .
docker run -p 8080:8080 h-beam-quote
```

最終映像基於 `distroless/static-debian12`,binary 約 15 MB。

## 部署到 Cloud Run

```bash
PROJECT_ID=your-gcp-project
REGION=us-central1                # 注意:asia-east1 沒 Gemini 模型

gcloud builds submit --tag gcr.io/$PROJECT_ID/h-beam-quote
gcloud run deploy h-beam-quote \
  --image gcr.io/$PROJECT_ID/h-beam-quote \
  --region $REGION \
  --allow-unauthenticated \
  --port 8080 \
  --memory 256Mi \
  --cpu 1 --min-instances 0 --max-instances 3
```

## API 端點

| Method | Path | 用途 |
| --- | --- | --- |
| GET  | `/api/products` | 列出產品(可 `?category=`)|
| GET  | `/api/products/{code}` | 取單一產品 |
| GET  | `/api/grades` | 列出材質與單價 |
| POST | `/api/quotes` | 計算報價(支援議價:係數 / 折讓 / 加成)|
| POST | `/api/quotes/match` | **反向反推:給目標一口價 → 算所需折讓 or 加成** |
| POST | `/api/quotes/save` | 計算 + 保存,回傳 `quote_id` |
| GET  | `/api/quotes` | 列出已存報價(可 `?customer=`、`?sales_user_id=`)|
| GET  | `/api/quotes/{id}` | 取單一已存報價(完整 items + 議價軌跡)|
| GET  | `/api/health` | Health check |

**計算公式:**
```
F = S × f - C + G
S=小計  f=折扣係數(0,1]  C=折讓≥0  G=加成≥0  C×G=0(互斥)
```

無自動階梯折扣 — 所有折扣由業務員透過議價工具手動處理。

### 範例

```bash
# 計算(原價)
curl -X POST http://localhost:8080/api/quotes \
  -H "Content-Type: application/json" \
  -d '{
    "items": [{"product_code":"HW300x300","grade":"SS400","length_m":6,"quantity":20}]
  }'

# 計算 + 議價(打 95 折再折讓 5000)
curl -X POST http://localhost:8080/api/quotes \
  -H "Content-Type: application/json" \
  -d '{
    "items": [{"product_code":"HW300x300","grade":"SS400","length_m":6,"quantity":20}],
    "manual_discount_factor": 0.95,
    "manual_concession_ntd": 5000
  }'

# 反向:客戶給 28 萬,系統算出需折讓多少
curl -X POST http://localhost:8080/api/quotes/match \
  -H "Content-Type: application/json" \
  -d '{
    "items": [{"product_code":"HW300x300","grade":"SS400","length_m":6,"quantity":20}],
    "target_final_ntd": 280000
  }'

# 反向:湊 50 萬整,系統算出需加成多少(對應 500 萬問題)
curl -X POST http://localhost:8080/api/quotes/match \
  -H "Content-Type: application/json" \
  -d '{
    "items": [{"product_code":"HW300x300","grade":"SS400","length_m":6,"quantity":20}],
    "target_final_ntd": 500000
  }'

# 計算 + 存檔(完整議價軌跡保留)
curl -X POST http://localhost:8080/api/quotes/save \
  -H "Content-Type: application/json" \
  -d '{
    "customer":"明陽營造",
    "project":"板橋廠案",
    "sales_user_id":"sales_chen",
    "items":[{"product_code":"HN400x200","grade":"SS400","length_m":12,"quantity":30}],
    "manual_concession_ntd": 25406,
    "note": "客戶一口價需求 NT$ 280,000"
  }'
# → 回 {"id": 1, "customer": "明陽營造", ..., "final_total_ntd": 280000}

# 取已存報價
curl http://localhost:8080/api/quotes/1

# 列某客戶的歷史
curl 'http://localhost:8080/api/quotes?customer=明陽營造'
```

## 預設資料

- **10 筆 H 型鋼產品**:涵蓋廣幅 HW、中幅 HM、細幅 HN
- **4 種材質**:SS400 / SM490 / SN490 / A572
- 來源:CNS 1490 G1011 / JIS G 3192

> Cloud Run 容器檔案系統是 ephemeral,SQLite 資料每次冷啟動會 reset 為 seed。
> 對 Lab 反而是好事 — 每次都從乾淨狀態開始。

## ADK Agent

`agent/` 目錄含 **3 個檔案**:

| 檔案 | 用途 | Tier |
| --- | --- | --- |
| `agent_basic.py` | 4 個 tool,基本問答與試算 | Tier 1–3 |
| `agent_with_memory.py` | 7 個 tool + `load_memory`,接 Vertex AI Memory Bank | Tier 4–5 |
| `lab_script.md` | 講師逐步腳本,含 timing 與每段 demo 重點 | (講師用) |

### 跑 basic 版

```bash
cd agent
pip install google-adk requests
export QUOTE_API_URL=http://localhost:8080
python agent_basic.py
```

### 跑 memory 版

本機暖身(InMemoryMemoryService,不需 GCP 設定):
```bash
export USE_VERTEX_MEMORY=false
python agent_with_memory.py
```

接 Vertex AI Memory Bank(需先建好 Agent Engine):
```bash
export USE_VERTEX_MEMORY=true
export GCP_PROJECT_ID=your-project
export GCP_LOCATION=us-central1
export AGENT_ENGINE_ID=projects/.../reasoningEngines/...
pip install google-cloud-aiplatform
python agent_with_memory.py
```

## Lab 流程速覽

詳見 `agent/lab_script.md`。大綱:

| Part | 時間 | 內容 |
| --- | --- | --- |
| 0 | 3 min | 場景設定:內部業務員 vs 外部客戶的角色釐清 |
| 1 | 15 min | 預備:Quote Service 連線確認、ADK 安裝 |
| 2 | 15 min | Tier 1–3:基礎 tool use,規格速查、多 tool 串接、推薦 |
| 3A | 10 min | 對話式報價、session state、改規格與材質 |
| 3B | 15 min | **議價試算**(折扣係數、折讓、加成、目標反推、整數一口價) |
| 4 | 35 min | **Memory Bank 主場**:跨 session 客戶脈絡 + 議價習性 |
| 5 | 剩餘 | 進階:部署 Agent Engine、加 email tool、客戶禁忌記憶 |
| 6 | 5 min | 收場:四個 take-away |

## 檔案結構

```
h-beam-quote/
├── main.go                    # Gin server, embed FS
├── db.go                      # SQLite init + seed (含 quotes 表)
├── handlers.go                # 8 個 API handler
├── models.go                  # struct + JSON tags + 驗證
├── go.mod
├── Dockerfile                 # multi-stage, distroless
├── .dockerignore
├── web/
│   └── index.html             # Tailwind CDN 工程藍圖風前端
├── agent/
│   ├── agent_basic.py         # Tier 1-3
│   ├── agent_with_memory.py   # Tier 4-5
│   └── lab_script.md          # 講師腳本
└── README.md                  # 本檔
```
