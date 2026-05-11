# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""H-Beam Agent 整合測試 — Quote Service REST 由 monkeypatch mock,
但 Gemini 呼叫真實會出去(走 ADC)。這份測試驗證的是 root_agent 能
正確 routing 到 get_product tool 並把回應轉成中文。

跑法:
    uv run pytest tests/integration/test_agent.py -v

需要:
    - GOOGLE_APPLICATION_CREDENTIALS 或 ADC 已設定(才能呼叫 Gemini)
    - 不需要 Quote Service 在跑(已 mock)
"""

from unittest.mock import MagicMock

import pytest
from google.adk.agents.run_config import RunConfig, StreamingMode
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from app.agent import root_agent

# 假回應 — 對齊 Quote Service `/api/products/HW300x300` 真實 schema
HW300_SPEC = {
    "code": "HW300x300",
    "series": "廣幅 HW",
    "category": "柱材",
    "height_mm": 300,
    "width_mm": 300,
    "web_thick_mm": 10,
    "flange_thick_mm": 15,
    "unit_weight_kg_per_m": 94,
    "application": "中高樓層柱",
}


@pytest.fixture
def mock_quote_service(monkeypatch: pytest.MonkeyPatch) -> None:
    """攔截 app.tools 裡的 requests.get / requests.post 呼叫,讓測試 hermetic。"""

    def fake_get(url, params=None, timeout=None):
        resp = MagicMock()
        resp.status_code = 200
        if "/api/products/HW300x300" in url:
            resp.json.return_value = HW300_SPEC
        elif "/api/products" in url:
            resp.json.return_value = {"products": [HW300_SPEC], "count": 1}
        elif "/api/grades" in url:
            resp.json.return_value = {
                "grades": [
                    {"code": "SS400", "name": "一般結構用碳鋼", "unit_price_ntd_per_kg": 28.5},
                ],
                "count": 1,
            }
        else:
            resp.status_code = 404
            resp.json.return_value = {"error": "not found"}
        resp.raise_for_status = MagicMock()
        return resp

    def fake_post(url, json=None, timeout=None):
        resp = MagicMock()
        resp.status_code = 200
        resp.json.return_value = {"ok": True}
        resp.raise_for_status = MagicMock()
        return resp

    monkeypatch.setattr("app.tools.requests.get", fake_get)
    monkeypatch.setattr("app.tools.requests.post", fake_post)


def test_agent_spec_lookup(mock_quote_service) -> None:
    """送『HW300x300 多重?』,確認:
       1. agent 有 stream 出回應
       2. 回應提到 94(單位重量 kg/m)
    """
    session_service = InMemorySessionService()
    session = session_service.create_session_sync(user_id="test_user", app_name="test")
    runner = Runner(agent=root_agent, session_service=session_service, app_name="test")

    message = types.Content(
        role="user",
        parts=[types.Part.from_text(text="HW300x300 多重?")],
    )

    events = list(
        runner.run(
            new_message=message,
            user_id="test_user",
            session_id=session.id,
            run_config=RunConfig(streaming_mode=StreamingMode.SSE),
        )
    )

    assert len(events) > 0, "Expected at least one event"

    # 收集所有文字回應(包含 tool response 與 final 回覆)
    all_text = ""
    for event in events:
        if event.content and event.content.parts:
            for part in event.content.parts:
                if part.text:
                    all_text += part.text + "\n"

    assert all_text.strip(), "Expected text content in events"
    # 重量應該出現在 tool response 與/或 final 回覆中
    assert "94" in all_text, (
        f"Expected '94' (HW300x300 unit weight) in agent output, got:\n{all_text}"
    )
