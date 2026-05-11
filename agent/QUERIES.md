# Agent 提問指南 — 我可以問什麼?

> 給 Lab 學員的快速操作參考。Agent **不是萬能 AI**,是針對 H 型鋼報價的內部業務員助理。
> 用「你是業務員,正在跟客戶通話」的口氣問,效果最好。

## 怎麼跟 Agent 對話

部署完成後,在 Vertex AI Console 開 Playground:

```
https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/asia-east1/agent-engines/<RID>/playground?project=<YOUR_PROJECT>
```

或本機跑單次 query:

```bash
RID=$(python3 -c "import json; print(json.load(open('agent/deployment_metadata.json'))['remote_agent_runtime_id'])")
URL="https://asia-east1-aiplatform.googleapis.com/v1/${RID}"
agents-cli run "HW300x300 多重?" --url "$URL" --mode adk
```

---

## 8 大情境(從簡到難)

### 1. 規格速查 — 「這個料多重?幾號用的?」

**Tool:** `get_product` / `list_products`

```
HW300x300 多重?
列一下所有柱材的規格
HN400x200 跟 HN500x200 哪個比較重?
廣幅 HW 系列有哪些型號?
```

Agent 會回:單位重量(kg/m)、系列、用途、尺寸(腹板/翼板厚度等)。

### 2. 多 tool 串接 — 「兩個料比較看看」

```
HN400x200 跟 HN500x200 各 6m 20 支,重量差多少?
HW300x300 SS400 跟 HW400x400 SS400 同樣 6m 30 支,哪個比較貴?
```

Agent 自動串 `get_product` × 2 + `list_grades` + `calculate_quote` × 2 並比較。

### 3. 正向估價 — 「直接算給我看」

**Tool:** `calculate_quote`

```
估給太平洋:HW300x300 SS400 6m 20 支
HN400x200 SM490 12m 30 支多少錢?
HW400x400 SS400 6m 15 支 + HN300x150 SS400 12m 20 支,總共多少?
```

Agent 回:總重量 / 原始小計 / 最終一口價。

### 4. 議價策略 ⭐ Lab 主菜 —「業務說的話 → tool 參數」

四種模式對應 INSTRUCTION 內的語意對照表:

| 業務說的話 | Agent 做的事 |
|---|---|
| 「打 95 折」、「打 9 折」、「85 折」 | `manual_discount_factor=0.95 / 0.9 / 0.85` |
| 「折讓 5000」、「現折 1 萬」、「再折 3000」 | `manual_concession_ntd=5000 / 10000 / 3000` |
| 「加成 3%」、「加 5000 服務費」、「整合費 1 萬」、「急單加 5%」 | `manual_surcharge_ntd=...`(百分比先換算金額) |
| 「殺到 95 萬」、「拉到 500 萬整」、「客戶只給 X」 | 用 `match_target_price`(見 §5) |

```
估給明陽:HW300x300 SS400 6m 20 支,幫我打 95 折
再多折 5000 表誠意
急單,加 5% 服務費
9 折再給折讓 1 萬
```

> **注意**:折讓與加成**互斥**(API 不接受同時 > 0)。
> 你說「9 折再加 5000 服務費」,Agent 會幫你拆兩種解讀請你選。

### 5. 目標反推 ⭐⭐ 主菜中的主菜 —「客戶只給 X,反推」

**Tool:** `match_target_price`

業務場景最常見:**客戶心裡有個數字,業務反推怎麼湊**。

```
客戶說只給 28 萬,看怎麼喬?(items 同前)
拉到 50 萬整數一口價試試
湊個整數,讓 final 變成 100 萬
殺到 95 萬給他
```

Agent 自動算:
- target < 小計 → 回 `implied_concession_ntd`(需折讓)
- target > 小計 → 回 `implied_surcharge_ntd`(需加成 — 急單 / 整合費場景)

### 6. 存檔 — 「就這樣送出」

**Tool:** `save_quote`(寫進 DB,回 quote_id)

```
好,就這樣存檔,project 寫板橋廠案,note 寫客戶一口價需求
存檔給太平洋,業務員是我 sales_chen,案場「桃園廠案 5 號」
```

Agent **務必結構化覆述**(Memory Bank 萃取需要):

```
已存,quote_id=3,客戶=明陽營造,案場=板橋廠案,
原小計 NT$ 321,480,手動折讓 NT$ 41,480,
最終一口價 NT$ 280,000(議價 12.9%),備註:客戶一口價需求
```

### 7. 歷史查詢 — 「上次給他的單還在嗎?」

**Tool:** `list_customer_quotes` / `get_quote_by_id`

```
明陽過去的所有報價列出來
最近一次給太平洋的價是多少?
拉一下 quote_id=3 的完整明細
```

### 8. 客戶記憶 ⭐⭐⭐ Lab 高潮 — 跨 session 記住客戶

**Tool:** `load_memory`(ADK 內建,Memory Bank 自動萃取)

**第一次告訴 Agent:**

```
他們公司都用 SS400,長度都是 12m,聯絡人就是鄭工 0912-345-678
明陽常要 12% 左右的折讓
```

Agent 結構化覆述:

```
已記錄:客戶 明陽營造,慣用材質 SS400,慣用長度 12m,
聯絡人 鄭工 0912-345-678,議價習性約 12%
```

**等 30 秒讓 Memory Bank 萃取完,開新 session(或第二天):**

```
明陽追加 50 支 HN500x200
```

Agent 自動:
1. `load_memory("明陽營造")` → 撈出記憶
2. 依偏好補預設(SS400 / 12m)
3. 主動建議:「依明陽的議價習性,我先抓 13% 折讓估給您看?」

---

## 7 個情境組合範例(完整對話)

### 情境 A:新客戶報價 + 議價 + 存檔(完整 Lab demo)

```
你:估給明陽:HW300x300 SS400 6m 20 支
Agent:[計算] 原小計 NT$ 321,480

你:客戶說只給 28 萬,看怎麼喬?
Agent:[match_target_price] 需折讓 NT$ 41,480,議價 12.9%,一口價 NT$ 280,000

你:OK 就這樣存檔,project 寫板橋廠案,note 寫客戶一口價需求
Agent:[save_quote] 已存,quote_id=1,客戶=明陽營造...

你:他們公司都用 SS400,長度都是 12m,聯絡人就是鄭工 0912-345-678
Agent:[結構化覆述] 已記錄:客戶 明陽營造,慣用材質 SS400...
```

### 情境 B:急單加成情境(對比)

```
你:公賢營造下緊急採購單:HW400x400 SM490 6m 12 支,他們願意付加成
Agent:[報價]

你:加成 5% 成交,存檔,note 寫急單加成 5%,project 桃園倉儲案
Agent:[save_quote] 已存,quote_id=2,加成 NT$...
```

### 情境 C:跨 session 記憶(隔天再來)

```
[開新 session]
你:明陽追加 50 支 HN500x200
Agent:[load_memory("明陽")] 取到偏好 SS400 / 12m
      [calculate_quote(SS400, 12m, 50 支)]
      依您之前記錄的明陽偏好(SS400 / 12m),50 支 HN500x200 為 NT$ ...

你:幫我拉個合理價估給他
Agent:依明陽的議價習性近一次 12.9%,我先抓 13% 折讓估給您看?
```

---

## ⚠️ Agent 不會回答的事(超出範圍)

| 情境 | 為什麼 |
|---|---|
| 「鋼價未來會漲嗎?」 | Agent 沒有市場分析工具,**不會憑空猜** |
| 「推薦一位建築師給我」 | 不是業務 scope |
| 「幫我寫合約」 | 不是 tool 覆蓋範圍 |
| 「我女兒今天生日該送什麼?」 | 不在系統使用者(內部業務員)的工作脈絡內 |
| 「Python 怎麼寫遞迴?」 | 同上,會婉拒 |

如果你想擴充,新增 tool(例如 `predict_steel_price` / `draft_email`)再加進 `app/tools.py` 並更新 INSTRUCTION 即可。

---

## 🧪 Lab 講師 demo 推薦劇本(順時鐘 9 個 query)

| # | Query | 目的 | 預期 tool |
|---|---|---|---|
| 1 | `HW300x300 多重?` | 暖身 — 規格速查 | `get_product` |
| 2 | `HN400x200 跟 HN500x200 各 6m 20 支差多少?` | 多 tool 串接 | `get_product` × 2 + `calculate_quote` × 2 |
| 3 | `估給太平洋:HW300x300 SS400 6m 20 支,幫我打 95 折` | 折扣係數 | `calculate_quote(factor=0.95)` |
| 4 | `客戶說只給 28 萬,看怎麼喬?` | 目標反推 ⭐ | `match_target_price(280000)` |
| 5 | `拉到 50 萬整數一口價試試` | 加成情境 ⭐ | `match_target_price(500000)` |
| 6 | `好,就這樣存檔,project 寫板橋廠案,note 寫客戶一口價需求` | 存檔 + 結構化覆述 | `save_quote` |
| 7 | `他們公司都用 SS400,長度都是 12m,聯絡人鄭工 0912-345-678` | 寫入記憶 | (純對話,Memory Bank 萃取) |
| 8 | (新 session)`明陽追加 50 支 HN500x200` | 跨 session 記憶 ⭐⭐ | `load_memory` + `calculate_quote` |
| 9 | `幫我拉個合理價估給他` | 議價習性建議 | (基於記憶 + 工具) |

跑完這 9 個 query,**完整覆蓋 9 個 tool 與 Memory Bank**。整段約 15-20 分鐘。

---

## 💡 提問技巧

1. **用業務員語氣**:「估給」、「殺到」、「湊個整數」、「拉到」、「再給折讓」、「急單加 5%」— 對 INSTRUCTION 友善
2. **客戶名稱明確化**:「明陽」「太平洋」「公賢」 — 觸發 `load_memory`
3. **議價條件用日常說法**:「打 95 折」、「折讓 5000」、「服務費 1 萬」— Agent INSTRUCTION 有對照表
4. **存檔要主動說 note**:「note 寫客戶一口價需求」— 對 Memory Bank 萃取「議價理由」很關鍵
5. **目標一口價用 `match_target_price` 觸發詞**:「殺到 X」「客戶只給 X」「拉到 X 整」「湊 X 整數」— 不要說「我要打到 X 折」(那會走 factor)

---

## 🔍 看 tool routing 是否正確

```bash
# 看 Cloud Trace 的 span 樹(部署後 1-2 分鐘有資料)
echo "https://console.cloud.google.com/traces/list?project=$GCP_PROJECT"
```

完整 span 樹應該是:
```
agent.invoke (Agent Runtime)
└─ llm.generate (gemini-3-flash-preview)        ← 走 global endpoint
   └─ tool.execute (calculate_quote)             ← 你的 query 觸發
      └─ http.client (POST /api/quotes)          ← Quote Service
```

---

## 📚 參考

- 完整 Lab 教學流程:[`lab_script.md`](./lab_script.md)
- Agent 程式碼 / INSTRUCTION:[`app/agent.py`](./app/agent.py)
- 8 個自製 tool 的 docstring:[`app/tools.py`](./app/tools.py)
- 議價公式:`F = S × factor - concession + surcharge`(`F`=最終, `S`=小計)
