# H-Beam Quote Agent

> H 型鋼報價 ADK Agent,部署到 **Vertex AI Agent Runtime @ asia-east1**,
> 模型透過 **Global Endpoint** 呼叫 `gemini-3-flash-preview`。
>
> 用 [agents-cli](https://github.com/GoogleCloudPlatform/agents-cli) v0.1.1+ 標準 scaffold 結構。

## 為什麼這份 scaffold 特別

`gemini-3-flash-preview` 只能透過 Global Endpoint 呼叫,但 Agent Runtime 在 `AdkApp.set_up()` 會把 `GOOGLE_CLOUD_LOCATION` 蓋成部署區域,造成 404。
本 scaffold 內建 Google 工程師 @eliasecchig 在 [adk-python issue #3628](https://github.com/google/adk-python/issues/3628) 提出的解法 — 繼承 `AdkApp` 在 `super().set_up()` 後還原 `GOOGLE_CLOUD_LOCATION=global`。

**部署在 asia-east1(離客戶近)+ 模型呼叫走 global endpoint(模型可用),兩者並存。**

## 專案結構

```
agent/
├── pyproject.toml                # [tool.agents-cli] deployment_target=agent_runtime, region=asia-east1
├── uv.lock                       # 鎖依賴(uv 自動產出)
├── .python-version               # 鎖 Python 版本(3.11)
├── .env.example                  # GCP_PROJECT、QUOTE_API_URL、SERVICE_ACCOUNT 等
├── deployment_metadata.json      # agents-cli 部署紀錄(remote_agent_runtime_id)
├── lab_script.md                 # 講師腳本(線性流程,從導覽到部署)
├── QUERIES.md                    # 學員提問指南:8 大情境 + demo 劇本 + 提問技巧
├── README.md                     # 本檔
│
├── app/                          # Agent 主目錄
│   ├── agent.py                  # root_agent + INSTRUCTION + Global Endpoint env
│   ├── tools.py                  # 8 個 H-Beam FunctionTool(包 Quote Service REST)
│   ├── agent_runtime_app.py      # AgentEngineApp(AdkApp) — Global Endpoint 還原
│   └── app_utils/
│       ├── telemetry.py          # Cloud Trace + Cloud Logging 接線
│       └── typing.py             # Feedback Pydantic model
│
└── tests/
    ├── unit/test_dummy.py
    ├── integration/test_agent.py             # mock requests + 真 Gemini 呼叫
    ├── integration/test_agent_runtime_app.py # 測 AgentEngineApp set_up + register_feedback
    └── eval/evalsets/basic.evalset.json      # 5 個 H-Beam 情境(規格/打折/反推/加成/Memory)
```

## 前置需求

- **Python 3.11**(由 `.python-version` 鎖定;`pyproject.toml` 的 `requires-python` 寫 `>=3.11,<3.14`)
- [`uv`](https://docs.astral.sh/uv/) — `curl -LsSf https://astral.sh/uv/install.sh | sh`
- `agents-cli` — `uv tool install google-agents-cli`
- `gcloud` CLI 已 `gcloud auth application-default login`
- 後端 H-Beam Quote Service 跑著(本地 docker 或 Cloud Run 部署)

## 本地開發

### 1. 起後端

```bash
# 本地 docker(已 build)
docker run -d --rm --name h-beam-quote -p 8080:8080 h-beam-quote:local
curl http://localhost:8080/api/health     # {"status":"ok"}
```

### 2. 安裝依賴

```bash
agents-cli install        # = uv sync
```

### 3. 設定 .env

```bash
cp .env.example .env
# 至少要填:
#   GCP_PROJECT=your-project
#   QUOTE_API_URL=http://localhost:8080
```

### 4. 互動式 Playground

```bash
agents-cli playground
# 開瀏覽器 → http://localhost:8501
```

試打:
- `HW300x300 多重?`(規格速查)
- `估給太平洋:HW300x300 SS400 6m 20 支,幫我打 95 折`(計算 + 議價)
- `客戶說只給 28 萬,看怎麼喬?`(目標反推)

### 5. 單次 query

```bash
agents-cli run "HW300x300 SS400 6m 20 支多少?"
```

## 部署到 Agent Runtime

### A. One-shot 部署(推薦,預設拉 GHCR pre-built image)

從 repo root 跑單一指令,完成 6 階段(API → SA + IAM → Cloud Run 直接拉 GHCR → 寫 .env → agents-cli deploy → 煙霧):

```bash
cd /path/to/h-beam-quote     # repo root(等同 git clone 後 cd 進去的目錄)
export GCP_PROJECT=your-gcp-project
./scripts/lab-bootstrap.sh
```

預設 image:`ghcr.io/cshliu77/h-beam-quote:latest`(由 GitHub Actions 自動 build + push,multi-arch)。
鎖版:`H_BEAM_IMAGE=ghcr.io/cshliu77/h-beam-quote:v0.1.0 ./scripts/lab-bootstrap.sh`
自己 build:`BUILD_LOCAL=true ./scripts/lab-bootstrap.sh`(9 phases,多 ~3 分鐘)

腳本是 idempotent。看狀態:`./scripts/lab-status.sh`。清掉:`./scripts/lab-teardown.sh`。

### B. 手動部署(如果想拆步驟)

每一步都對應 `lab-bootstrap.sh` 裡的一個 phase。如果要進階客製、或想看 agents-cli 在做什麼,展開來跑:

```bash
# 1. API 啟用
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com aiplatform.googleapis.com \
  cloudtrace.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com telemetry.googleapis.com \
  --project=$GCP_PROJECT

# 2. SA + IAM(注意 serviceUsageConsumer)
SA="h-beam-agent@$GCP_PROJECT.iam.gserviceaccount.com"
gcloud iam service-accounts create h-beam-agent --project=$GCP_PROJECT
for role in roles/cloudtrace.agent roles/logging.logWriter \
            roles/monitoring.metricWriter \
            roles/serviceusage.serviceUsageConsumer roles/aiplatform.user; do
  gcloud projects add-iam-policy-binding $GCP_PROJECT \
    --member="serviceAccount:$SA" --role=$role --condition=None
done

# 3. Quote Service:Cloud Build + Cloud Run(略,見 lab-bootstrap.sh phase E/F)

# 4. Agent 部署 — 要透過 --update-env-vars 注入 QUOTE_API_URL
#    agents-cli 不會自動讀 .env 給 Agent Runtime
agents-cli deploy --update-env-vars "QUOTE_API_URL=https://your-quote-service-url"
```

> ⚠️ **`roles/serviceusage.serviceUsageConsumer` 一定要給**,否則 OTel exporter 回 `403 USER_PROJECT_DENIED`,Cloud Trace 全部丟失。

### C. 驗證

```bash
# 1. 遠端 query
agents-cli run "HW300x300 多重?"

# 2. Cloud Trace UI(瀏覽器)
echo "https://console.cloud.google.com/traces/list?project=$GCP_PROJECT"
# 預期 span 樹:agent.invoke → llm.generate → tool.execute → http.client

# 3. Global Endpoint 驗證
gcloud logging read \
  'resource.type="aiplatform.googleapis.com/ReasoningEngine"' \
  --limit 50 --project=$GCP_PROJECT \
  | grep -E "locations/(global|us-central1|asia-east1)"
# 預期:只看到 locations/global

# 4. 沒有 OTel 403
gcloud logging read \
  'severity>=WARNING AND textPayload:"USER_PROJECT_DENIED"' \
  --limit 5 --project=$GCP_PROJECT
# 預期:無結果
```

## 常用指令

| 指令 | 用途 |
|---|---|
| `agents-cli install` | 同步依賴(uv sync) |
| `agents-cli playground` | 本地互動 UI |
| `agents-cli run "..."` | 單次 query(本地或遠端) |
| `agents-cli deploy` | 部署到 Agent Runtime |
| `agents-cli deploy --list` | 列出已部署 instance |
| `agents-cli deploy --no-wait` | 背景部署,稍後用 `--status` 查 |
| `agents-cli scaffold enhance .` | 加 CI/CD / Terraform |
| `agents-cli scaffold upgrade` | 升 agents-cli 版本 |
| `uv run pytest tests/unit tests/integration` | 跑測試 |

## Memory Bank

部署到 Agent Runtime 後 Memory Bank 自動可用,不需額外設定。
跑兩個 session 後到 GCP Console:
```
Vertex AI > Agent Engine > 你的 instance > Memory
```
看 LLM 萃取出的客戶條目(偏好、議價習性、歷史 quote_id)。

INSTRUCTION 第三段「客戶記憶守則」第 6/7 點的**結構化覆述句型**是萃取品質的關鍵 — 詳見 `app/agent.py`。

## 教學脈絡

如果是 GDG Lab 學員,建議從 `lab_script.md` 開始走完線性流程:
1. 環境準備 → 2. 程式碼導覽 → 3. 本地試跑 → 4. 議價語意 → 5. Memory Bank → 6. 部署到 Agent Runtime → 7. 收場

## 參考文件

- [LLM_Global_Endpoint.md](https://github.com/cshliu77/agentcli-poc/blob/main/LLM_Global_Endpoint.md) — Global Endpoint 完整測試紀錄
- [adk-python issue #3628](https://github.com/google/adk-python/issues/3628) — Gemini 3 + Agent Engine 問題
- [Agent Runtime / Agent Engine 文件](https://docs.cloud.google.com/agent-builder/agent-engine)
- [agents-cli 文件](https://github.com/GoogleCloudPlatform/agents-cli)
