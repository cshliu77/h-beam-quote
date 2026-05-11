"""H 型鋼報價助理 — 8 個 FunctionTool。

所有 tool 都包裝 Quote Service REST API(http://QUOTE_API_URL/api/...)。
docstring 是 LLM 工具選擇的關鍵 — 內容越具體,routing 越準。
"""
import os
from typing import Optional

import requests

API_URL = os.getenv("QUOTE_API_URL", "http://localhost:8080")
TIMEOUT = 10


def list_products(category: Optional[str] = None) -> dict:
    """列出 H 型鋼產品目錄。category 可填 '柱材'/'樑材'/'柱樑兩用',或省略取全部。"""
    params = {"category": category} if category else None
    r = requests.get(f"{API_URL}/api/products", params=params, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def get_product(code: str) -> dict:
    """查單一 H 型鋼產品詳細規格。code 例:'HW300x300'。"""
    r = requests.get(f"{API_URL}/api/products/{code}", timeout=TIMEOUT)
    if r.status_code == 404:
        return {"error": f"找不到產品 {code}"}
    r.raise_for_status()
    return r.json()


def list_grades() -> dict:
    """列出材質與單價 (SS400/SM490/SN490/A572)。"""
    r = requests.get(f"{API_URL}/api/grades", timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def calculate_quote(
    items: list[dict],
    manual_discount_factor: float = 1.0,
    manual_concession_ntd: float = 0,
    manual_surcharge_ntd: float = 0,
) -> dict:
    """計算報價(支援議價:折扣係數、折讓、加成)。

    用於正向計算 — 業務告訴你要套用什麼折扣或加成。若是反向(只給目標總價),
    改用 match_target_price。

    Args:
        items: 報價品項清單,每筆需要 product_code, grade, length_m, quantity。
        manual_discount_factor: 折扣係數,範圍 (0, 1]。0.95 = 95 折,預設 1.0。
        manual_concession_ntd: 折讓金額,≥ 0。預設 0。
        manual_surcharge_ntd: 加成金額,≥ 0。預設 0。
            注意:concession 與 surcharge 互斥,不可同時 > 0。

    Returns:
        含完整議價軌跡 + final_total_ntd + adjustment_type + effective_discount_rate。
    """
    payload = {"items": items}
    if manual_discount_factor != 1.0:
        payload["manual_discount_factor"] = manual_discount_factor
    if manual_concession_ntd > 0:
        payload["manual_concession_ntd"] = manual_concession_ntd
    if manual_surcharge_ntd > 0:
        payload["manual_surcharge_ntd"] = manual_surcharge_ntd
    r = requests.post(f"{API_URL}/api/quotes", json=payload, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def match_target_price(items: list[dict], target_final_ntd: float) -> dict:
    """根據業務指定的目標總價(一口價),反推折讓或加成。

    當業務說「殺到 95 萬」「拉到 500 萬整」「客戶只給 X」「湊整數」時用此工具。
    系統自動判斷 target 比小計高還是低,回對應的 implied_concession_ntd
    或 implied_surcharge_ntd(其一)。

    Args:
        items: 報價品項清單。
        target_final_ntd: 業務指定的最終總價,需 > 0。

    Returns:
        含 adjustment_type (折讓/加成/原價)、implied_concession_ntd、
        implied_surcharge_ntd、effective_discount_rate(可正可負)。
    """
    r = requests.post(
        f"{API_URL}/api/quotes/match",
        json={"items": items, "target_final_ntd": target_final_ntd},
        timeout=TIMEOUT,
    )
    r.raise_for_status()
    return r.json()


def save_quote(
    customer: str,
    items: list[dict],
    project: Optional[str] = None,
    sales_user_id: Optional[str] = None,
    manual_discount_factor: float = 1.0,
    manual_concession_ntd: float = 0,
    manual_surcharge_ntd: float = 0,
    note: Optional[str] = None,
) -> dict:
    """確認並保存報價(含完整議價軌跡),回傳 quote_id 供日後查詢。

    當業務員確認要送出/存檔報價時呼叫。完整議價結果(原始小計、自動折扣、
    手動係數、折讓/加成、最終一口價)都會存進 DB。

    請務必在 note 欄位寫議價理由,例如:
      - "客戶一口價需求"
      - "急單加成 5%"
      - "整合服務費"
      - "VIP 客戶長期合作折讓"
    這個 note 對 Memory Bank 萃取「客戶議價習性」非常重要,日後同一客戶來
    詢價時 agent 才能從記憶中拿到「明陽常要 12% 折讓」「公賢常接受急單加成」
    這類 actionable 的客戶模式。

    Args:
        customer: 客戶名稱(必填),例如 '明陽營造'。
        items: 報價品項清單。
        project: 案場/專案名稱,例如 '板橋廠案'。
        sales_user_id: 業務員代號(用於 list_customer_quotes 過濾)。
        manual_discount_factor: 折扣係數 (0, 1]。
        manual_concession_ntd: 折讓金額 ≥ 0。
        manual_surcharge_ntd: 加成金額 ≥ 0。
        note: 議價理由備註(對 Memory Bank 萃取很重要)。

    Returns:
        含 id (quote_id)、customer、project、final_total_ntd 與所有議價欄位。
    """
    payload = {"customer": customer, "items": items}
    if project:
        payload["project"] = project
    if sales_user_id:
        payload["sales_user_id"] = sales_user_id
    if manual_discount_factor != 1.0:
        payload["manual_discount_factor"] = manual_discount_factor
    if manual_concession_ntd > 0:
        payload["manual_concession_ntd"] = manual_concession_ntd
    if manual_surcharge_ntd > 0:
        payload["manual_surcharge_ntd"] = manual_surcharge_ntd
    if note:
        payload["note"] = note
    r = requests.post(f"{API_URL}/api/quotes/save", json=payload, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def get_quote_by_id(quote_id: int) -> dict:
    """依 quote_id 取出歷史報價的完整明細(含議價軌跡)。"""
    r = requests.get(f"{API_URL}/api/quotes/{quote_id}", timeout=TIMEOUT)
    if r.status_code == 404:
        return {"error": f"找不到 quote {quote_id}"}
    r.raise_for_status()
    return r.json()


def list_customer_quotes(customer: str) -> dict:
    """列出特定客戶的所有歷史報價(摘要)。

    當業務員問「明陽過去的所有報價」「最近一次給太平洋的價」時用這支。
    """
    r = requests.get(
        f"{API_URL}/api/quotes",
        params={"customer": customer},
        timeout=TIMEOUT,
    )
    r.raise_for_status()
    return r.json()


H_BEAM_TOOLS = [
    list_products,
    get_product,
    list_grades,
    calculate_quote,
    match_target_price,
    save_quote,
    get_quote_by_id,
    list_customer_quotes,
]
