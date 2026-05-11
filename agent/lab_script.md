# Agent Runtime Hands-on Lab — 講師腳本

**GDG · 2026/05/21**
**主題:用 Google ADK + agents-cli 把企業內部 H 型鋼報價助理部署到 Vertex AI Agent Runtime**

> Lab 採線性流程,**不分階段** — 一份程式碼從程式碼導覽走到 Agent Runtime 部署上線。

---

## 0. 場景設定(3 分鐘)

> 鋼鐵供應商「鋼骨王」要為內部業務員/報價助理導入 AI 助理。
> 業務員平常工作:接客戶電話 → 查 H 型鋼規格 → 算重量 → 估價 → **議價** → 報出去。

**關鍵釐清:** Agent 的【使用者】是公司業務員,【對話內容】是關於外部客戶。
這個區分會貫穿整堂 lab,尤其影響 Memory Bank 與議價語意設計。

**架構:**
```
業務員 ─對話─→ ADK Agent (asia-east1) ─tool call─→ Quote Service (Cloud Run)
                  │           ↑                       ├─ /api/products
                  │           │                       ├─ /api/grades
                  │   gemini-3-flash-preview          ├─ /api/quotes        (計算+議價)
                  │   (global endpoint!)              ├─ /api/quotes/match  (一口價反推)
                  │                                   ├─ /api/quotes/save   (存檔)
                  │                                   └─ /api/quotes/:id    (查歷史)
                  │
                  └─→ Memory Bank (Vertex AI Agent Engine,內建)
                       客戶偏好、聯絡人、議價習性、歷史 quote_id
```

---

## 1. 環境準備(10 分鐘)

### 會眾機器需要(三個 CLI 即可)

- `gcloud` CLI 已登入並 `gcloud auth application-default login`
- [`uv`](https://docs.astral.sh/uv/):`curl -LsSf https://astral.sh/uv/install.sh | sh`
- `agents-cli` v0.1.1+:`uv tool install google-agents-cli`

> **學員不需要本機裝 docker / go**(後端 image 已經在 GHCR),
> 也不需要事先建任何 GCP 資源 — `lab-bootstrap.sh` 會 idempotent 完成所有設定。

### 後端 Quote Service:不用學員 build,Cloud Run 直接拉 GHCR image

```
ghcr.io/cshliu77/h-beam-quote:latest    ← 講師預先用 GitHub Actions build + push
```

`lab-bootstrap.sh` 會在 Cloud Run 部署時用 `--image ghcr.io/cshliu77/h-beam-quote:latest` 直接拉,**跳過 Cloud Build / Artifact Registry**。

### Lab Day 鎖版

老師事先 `git tag v0.1.0 && git push --tags` → GitHub Actions 自動產 `v0.1.0` image。Lab Day 學員用:

```bash
export H_BEAM_IMAGE=ghcr.io/cshliu77/h-beam-quote:v0.1.0
```

### 想自己改 Go 程式碼?走本機 build(escape hatch)

```bash
BUILD_LOCAL=true ./scripts/lab-bootstrap.sh
# 還原為原 9-phase:Cloud Build → Artifact Registry → Cloud Run
```

### 起 Agent 開發環境

```bash
cd h-beam-quote/agent
agents-cli install        # = uv sync(產出 .venv 與 uv.lock)
# .env 由 lab-bootstrap.sh Phase G 自動填,不需手動編輯
```

---

## 2. 程式碼導覽(15 分鐘)

`agent/app/` 是整個 Agent 的核心,**只有 4 個檔案**,各司其職:

### 2.1 `app/agent.py` — 主 agent

**重點看三件事:**

**a) Global Endpoint env 預設(line 27-29):**
```python
os.environ["GOOGLE_CLOUD_PROJECT"] = project_id
os.environ["GOOGLE_CLOUD_LOCATION"] = "global"   # ← 關鍵
os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "True"
```

> 講師:Gemini 3 系列只能透過 global endpoint 呼叫(asia-east1 的 endpoint 會回 404)。
> 模組載入時就強制設好,本地開發、agents-cli playground、Agent Runtime 都吃這份。

**b) root_agent + Gemini 3:**
```python
root_agent = Agent(
    name="h_beam_quote_assistant",
    model=Gemini(model="gemini-3-flash-preview", retry_options=...),
    instruction=INSTRUCTION,
    tools=[*H_BEAM_TOOLS, load_memory],   # 8 自製 + 1 ADK 內建
)
```

**c) INSTRUCTION 三大區塊:**
- 工作原則(規格走 tool、估價先確認材質、確認後存檔)
- **議價語意對照表**(自然語言 → tool 參數,5 種模式)
- **Memory Bank 使用守則**(結構化覆述句型 — 萃取靠這個)

### 2.2 `app/tools.py` — 8 個 FunctionTool

```python
H_BEAM_TOOLS = [
    list_products, get_product, list_grades,         # 規格類
    calculate_quote, match_target_price,             # 計算/議價
    save_quote, get_quote_by_id, list_customer_quotes,   # 持久化/查詢
]
```

> 講師:**ADK FunctionTool 的核心是 docstring** — docstring 寫好就是 prompt 寫好。
> 看 `save_quote` 的 docstring,有專段教 LLM「note 欄位要寫議價理由,因為 Memory Bank 萃這個」。

### 2.3 `app/agent_runtime_app.py` — Agent Runtime 包裝

**Global Endpoint 還原機制(由 agents-cli 模板自動生成):**
```python
gemini_location = os.environ.get("GOOGLE_CLOUD_LOCATION")  # 模組載入時快照

class AgentEngineApp(AdkApp):
    def set_up(self) -> None:
        vertexai.init()
        setup_telemetry()
        super().set_up()                # ← Agent Engine 在這裡會把 location 蓋成 asia-east1
        ...
        if gemini_location:
            os.environ["GOOGLE_CLOUD_LOCATION"] = gemini_location  # ← 還原成 global
```

> 講師:這就是 LLM_Global_Endpoint.md 方案 B(adk-python issue #3628)的解法。
> Agent Engine 部署在 asia-east1(離客戶近),但 Gemini 呼叫透過 global endpoint。

### 2.4 `app/app_utils/telemetry.py` — Cloud Trace 自動接線

只要 `deployment_target=='agent_runtime'`,模板會自動設:
```python
os.environ.setdefault("GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY", "true")
```

部署後 Cloud Trace 會自動有完整 span 樹:
`agent.invoke → llm.generate → tool.execute → http.client`

---

## 3. 本地試跑(15 分鐘)

```bash
agents-cli playground
# 開瀏覽器到 http://localhost:8501
```

跑下列 5 個 query 觀察 tool routing:

### 3.1 規格速查
```
HW300x300 多重?
```
預期:`get_product("HW300x300")` → 答 94 kg/m。

### 3.2 多 tool 串接
```
HN400x200 跟 HN500x200 各 6m 20 支差多少?
```
預期:`get_product` × 2 + `calculate_quote` × 2 → 算重量差。

### 3.3 折扣計算
```
估給太平洋:HW300x300 SS400 6m 20 支,幫我打 95 折
```
預期:`calculate_quote(items, manual_discount_factor=0.95)` → NT$ 305,406。

### 3.4 目標反推 ⭐
```
客戶說只給 28 萬,看怎麼喬?(items 同上)
```
預期:`match_target_price(target_final_ntd=280000)` → 反推折讓 NT$ 41,480,議價 12.9%。

### 3.5 加成情境(對應 500 萬問題)
```
拉到 50 萬整數一口價試試
```
預期:`match_target_price(target=500000)` → 需加成 NT$ 178,520,加成 55.5%。

> 講師:**這是議價最常見場景** — 客戶心裡有個數字,業務反推怎麼湊。
> Agent 不自己算數學,讓 tool 算。

---

## 4. 議價語意對照(10 分鐘)

打開 `app/agent.py` 看 INSTRUCTION 第二段「議價語意對照」,直接朗讀:

| 業務說的話 | 對應 tool 與參數 |
| --- | --- |
| 「打 95 折」「9 折」 | `calculate_quote(manual_discount_factor=0.95 / 0.9)` |
| 「折讓 5000」「現折 1 萬」 | `calculate_quote(manual_concession_ntd=5000 / 10000)` |
| 「加成 3%」「服務費 5000」「急單加 5%」 | `calculate_quote(manual_surcharge_ntd=...)` |
| 「殺到 95 萬」「拉到 500 萬整」「客戶只給 X」 | `match_target_price(target_final_ntd=...)` |
| 「9 折再折讓 1 萬」 | `factor + concession` 同時填 |

**規則:**
- 折讓與加成互斥(`C × G = 0`)
- 目標一口價走 `match_target_price`
- 加成情境(急單/服務費/整數)不要忽略 — 對應「500 萬問題」

**現場展示混淆測試:**
```
業務:9 折再加 5000 服務費
Agent:折讓與加成不能同時。要不打 9 折就不加,
       或者改用「9 折後加 5000」變成 calculate_quote(factor=0.9, surcharge=5000)?
```

> 講師:LLM 解析自然語言 + 遵守 API 互斥規則的能力,**完全來自 instruction 對照表**。

---

## 5. Memory Bank 跨 session(15 分鐘)

agents-cli playground 預設用 in-memory session,Agent Runtime 部署後**自動接 Vertex AI Memory Bank**。本段先講機制,部署完到 Console 看實際效果。

### 5.1 結構化覆述句型(萃取的命脈)

打開 INSTRUCTION 第三段「客戶記憶守則」第 6/7 點:

> save_quote 完成後,務必結構化覆述含議價結果,例如:
> ✅「已存,quote_id=3,客戶=明陽營造,案場=板橋廠案,
>    原小計 NT$ 321,480,手動折讓 NT$ 41,480,
>    最終一口價 NT$ 280,000(議價 12.9%),備註:客戶一口價需求」

> 講師:**Memory Bank 萃取靠 LLM 從對話事件挑事實**。
> 「ok 我會記住」會被萃出空白。
> 上面那種句型才會被萃成可被未來 query 檢索的 entry。

### 5.2 預期被萃出的記憶條目

部署後跑兩個 session(明陽折讓、公賢加成),Console 會看到:

- `Customer 明陽營造 prefers SS400 grade and 12m length, contact 鄭工 0912-345-678`
- `Customer 明陽營造's recent quote (id=1) for 板橋廠案 totaled NT$ 280,000 with 12.9% concession (lump-sum negotiation request)`
- `Customer 公賢營造 accepts surcharge for rush orders (5% applied for 桃園倉儲案)`

### 5.3 跨 session 主場展示(部署後)

業務員在新 session 說:「明陽追加 50 支 HN500x200」(沒給材質長度)。

預期 agent:
1. `load_memory("明陽")` → 撈到 SS400 / 12m 偏好
2. `calculate_quote(items, ...)` 自動帶入偏好材質長度
3. 回覆:「依您之前記錄的明陽偏好(SS400 / 12m),50 支 HN500x200 為...」

如果業務員問「拉個合理價估給他」:
- 從議價歷史推:「明陽近一次議價 12.9%,我先抓 13% 折讓估給您看?」

> 講師:**這就是 session state 跟 Memory Bank 的本質差異** — 前者活在一次對話,
> 後者跨會話跟著 user_id 累積客戶**行為模式**。

---

## 6. 部署到 Agent Runtime(15 分鐘)— 主菜

### 6.1 One-shot 部署(scripts/lab-bootstrap.sh)

整個 Lab 部署流程濃縮為單一指令,**可重跑**:

```bash
# 從 repo root 執行
export GCP_PROJECT=your-gcp-project    # 換成你的 project ID
./scripts/lab-bootstrap.sh
```

腳本依序做(idempotent — 重跑不會出錯):

| 階段 | 動作 | 預設 GHCR 模式 | BUILD_LOCAL=true |
|---|---|:---:|:---:|
| Preflight | 確認 gcloud / uv / agents-cli + 鎖定 ADC quota project | ✓ | ✓ |
| A | 啟用 8 個 GCP API(run / cloudbuild / aiplatform / cloudtrace 等) | ✓ | ✓ |
| B | 建立 `h-beam-agent` SA + 綁 5 個 IAM 角色(含 ⚠️ `serviceUsageConsumer`) | ✓ | ✓ |
| C | 建立 Artifact Registry repo `h-beam-images` | **跳過** | ✓ |
| D | 確保 `go.sum` 存在(Cloud Build 需要) | **跳過** | ✓ |
| E | Cloud Build 推 image 到 Artifact Registry | **跳過** | ✓(~3 分鐘) |
| F | 部署 Quote Service 到 Cloud Run(`--image $H_BEAM_IMAGE`) | ✓ 拉 GHCR | ✓ 拉 AR |
| G | 抓 Cloud Run URL → 寫進 `agent/.env` | ✓ | ✓ |
| H | `agents-cli deploy` 部署 Agent(帶 `--update-env-vars QUOTE_API_URL=...`) | ✓ | ✓ |
| I | 遠端煙霧:`agents-cli run "HW300x300 多重?"` 應回 94 | ✓ | ✓ |

**預設 GHCR 模式**(學員)= 6 phases,實測 ~3 分鐘(主要是 H agents-cli deploy 5-10 分鐘)。
**BUILD_LOCAL=true** = 9 phases,Cloud Build 多花 ~3 分鐘。

> ⚠️ **`roles/serviceusage.serviceUsageConsumer` 是腳本自動綁的**。
> 沒綁這個角色,OTel exporter 會回 `403 USER_PROJECT_DENIED`,Cloud Trace 全部丟失。
> 這是 agentcli-poc/Observability.md §4.4 記錄的踩坑,腳本內建解了。

### 6.2 看當前部署狀態

```bash
./scripts/lab-status.sh
# 列出:API 啟用 / SA + IAM / Artifact Registry / Cloud Run / Agent Runtime
```

### 6.3 互動測試(部署完直接打)

```bash
RID=$(python3 -c "import json; print(json.load(open('h-beam-quote/agent/deployment_metadata.json'))['remote_agent_runtime_id'])")
URL="https://asia-east1-aiplatform.googleapis.com/v1/${RID}"

agents-cli run "HW300x300 SS400 6m 20 支多少?" --url "$URL" --mode adk
# 預期:agent 呼叫 calculate_quote tool,回 NT$ 321,480
```

### 6.4 Cloud Trace 驗證

打開 [Cloud Trace](https://console.cloud.google.com/traces/list)。

預期看到完整 span 樹:
```
agent.invoke (Agent Runtime)
└─ llm.generate (gemini-3-flash-preview)        ← 走 global endpoint
   └─ tool.execute (calculate_quote)
      └─ http.client (POST /api/quotes)         ← Quote Service
```

### 6.5 Global Endpoint 驗證(關鍵)

```bash
gcloud logging read \
  'resource.type="aiplatform.googleapis.com/ReasoningEngine"' \
  --limit 50 --project=$GCP_PROJECT \
  | grep -E "locations/(global|us-central1|asia-east1)" | head
# 預期:只看到 locations/global,沒有區域 location
```

也檢查沒被 OTel 403 卡住:
```bash
gcloud logging read \
  'severity>=WARNING AND textPayload:"USER_PROJECT_DENIED"' \
  --limit 5 --project=$GCP_PROJECT
# 預期:無結果
```

### 6.6 到 Memory Bank Console 看萃出來的條目

```
GCP Console > Vertex AI > Agent Engine > 你的 instance > Memory
```

跑完 §5.3 的兩個 session,等 30 秒讓 Memory Bank 萃取,
**親眼看到** LLM 萃出的客戶條目 — 整堂課的視覺高潮。

### 6.6 Lab 結束:清掉所有資源

```bash
./scripts/lab-teardown.sh           # 互動式確認
./scripts/lab-teardown.sh --yes     # 不問直接刪
```

清掉:Agent Engine 實例、Cloud Run service、Artifact Registry repo + images、Service Account。
**API 啟用狀態保留**(避免影響你 GCP 專案的其他工作)。

---

## 7. 收場(5 分鐘)

**四個 take-away:**

1. **ADK FunctionTool 的核心是 docstring** — docstring 寫好就是 prompt 寫好,LLM 看著它判斷何時呼叫
2. **議價語意要明確分類** — 折扣係數 / 折讓 / 加成 / 目標反推,各對應一個語意,instruction 必須有對照表
3. **Memory Bank 萃取靠回覆結構化** — 議價軌跡、客戶習性、quote_id 都需要明確覆述
4. **Gemini 3 + Agent Runtime 必須處理 Global Endpoint** — `gemini-3-flash-preview` 只在 global endpoint 提供,asia-east1 部署 + global 模型呼叫的解法已內建在 `agent_runtime_app.py`(`adk-python` issue #3628)

**回家作業:**

把您工作上某個重複任務拆成 3-5 個 tool 試做 agent。
1. `agents-cli create your-agent --adk -d agent_runtime --region asia-east1`
2. 把 tools 寫進 `app/tools.py`,instruction 寫對照表
3. `agents-cli playground` 試跑
4. `agents-cli deploy` 上線

---

## 附錄 A:議價公式速查

```
S = Σ 各項小計 (subtotal_ntd)
f = 手動折扣係數 (default 1.0, 0 < f ≤ 1)
C = 手動折讓 (default 0, ≥ 0)
G = 手動加成 (default 0, ≥ 0)
constraint: C × G = 0 (互斥)

F = S × f - C + G          ← 最終一口價

正向計算:給 f, C, G → 算 F      用 /api/quotes
反向計算:給 F → 算 implied C 或 G   用 /api/quotes/match
```

## 附錄 B:常見問題 / 故障排除

| 症狀 | 原因 | 解法 |
| --- | --- | --- |
| 模型回 404 | `gemini-3-flash-preview` 在區域 endpoint 不存在 | 確認 `GOOGLE_CLOUD_LOCATION=global`(本機 + Agent Runtime) |
| Cloud Trace 沒資料 | OTel exporter 403 USER_PROJECT_DENIED | SA 加 `roles/serviceusage.serviceUsageConsumer` |
| `load_memory` 回空 | 還沒跨 session,記憶尚未萃取 | 先跑前一個 session 並等 ~30s |
| Memory 萃出垃圾 | Agent 回覆沒結構化 | 強化 instruction 結構化覆述規則 |
| 議價算錯 | 折讓加成同時 > 0 | API 拒絕,agent 應拆兩次 call 或重新詢問 |
| `match_target_price` 回 surcharge > 0 | target 比小計高 | 正常 — 業務確認加成是否合理(對應 500 萬問題)|
| Agent 憑空回答規格 | 沒走 tool | 強化 instruction「不憑空回答」+ docstring |

## 附錄 C:延伸方向(時間有餘再做)

- **(A) 加 `draft_email` tool** — 把 quote_id 內容包成 email 寄給客戶
- **(B) 加客戶禁忌規則** — 例如「華城從不接 SN490」,推薦時自動排除
- **(C) Memory Bank 議價策略 query** — 「這個客戶歷史平均接受幾折?」(`list_customer_quotes` + 加權平均)
- **(D) 加 CI/CD** — `agents-cli scaffold enhance . --cicd-runner google_cloud_build`,自動部署
