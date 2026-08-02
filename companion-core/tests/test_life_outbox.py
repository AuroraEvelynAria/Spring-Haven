from __future__ import annotations

import json
import tempfile
import time
import unittest
from pathlib import Path

from aiohttp.test_utils import TestClient, TestServer

from spring_haven_core.app import build_app
from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.provider import ProviderReply
from spring_haven_core.roles import RoleRegistry
from spring_haven_core.service import CompanionService


class _Provider:
    def __init__(self):
        self.calls: list[tuple[str, list[dict[str, str]]]] = []

    async def complete(self, system_prompt, messages):
        self.calls.append((system_prompt, messages))
        return ProviderReply(
            text="我刚给窗边的花浇了水，叶片上的水珠很好看。忽然有点想你了。",
            input_tokens=240,
            output_tokens=42,
            cached_tokens=180,
            finish_reason="stop",
        )


def _registry(root: Path) -> RoleRegistry:
    personas = root / "personas"
    personas.mkdir()
    (personas / "ling.md").write_text("你是小玲，只以小玲的身份自然生活和说话。", encoding="utf-8")
    (personas / "nai.md").write_text("你是小奈，只以小奈的身份自然生活和说话。", encoding="utf-8")
    roles_path = root / "roles.json"
    roles_path.write_text(
        json.dumps(
            {
                "roles": [
                    {
                        "role_id": "ling",
                        "display_name": "小玲",
                        "full_name": "春日铃音",
                        "aliases": ["小玲"],
                        "prompt_file": "personas/ling.md",
                    },
                    {
                        "role_id": "nai",
                        "display_name": "小奈",
                        "full_name": "白濑雪奈",
                        "aliases": ["小奈"],
                        "prompt_file": "personas/nai.md",
                    },
                ]
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    return RoleRegistry.load(roles_path)


class LifeOutboxStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(
            Path(self.temp.name) / "heartloom.sqlite3", ["ling", "nai"]
        )

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_delivery_is_durable_idempotent_and_acknowledged(self):
        now = 100_000
        state = self.store.sync_life_state(
            save_id="save-1",
            selected_role_id="ling",
            snapshot={"roles": {"ling": {"stats": {"hunger": 80}}}},
            last_user_activity_at=now - 7_200,
            next_event_at=now + 60,
            now=now,
        )
        self.assertEqual(state["next_event_at"], now + 60)
        self.assertEqual(len(self.store.due_life_states(now + 60)), 1)

        first = self.store.enqueue_life_delivery(
            delivery_id="life-delivery-save-1-0001",
            save_id="save-1",
            role_id="ling",
            kind="offline_life",
            payload={"protocol": "spring_haven.life_delivery.v1", "text": "测试"},
            created_at=now + 60,
        )
        second = self.store.enqueue_life_delivery(
            delivery_id="life-delivery-save-1-0001",
            save_id="save-1",
            role_id="ling",
            kind="offline_life",
            payload={"protocol": "spring_haven.life_delivery.v1", "text": "不会覆盖"},
            created_at=now + 61,
        )
        self.assertEqual(first, second)
        self.assertEqual(self.store.due_life_states(now + 61), [])
        polled = self.store.poll_life_outbox("save-1", now=now + 61)
        self.assertEqual(len(polled), 1)
        self.assertEqual(polled[0]["payload"]["text"], "测试")
        self.assertEqual(
            self.store.ack_life_outbox(
                "save-1", ["life-delivery-save-1-0001"], now=now + 62
            ),
            1,
        )
        self.assertEqual(self.store.poll_life_outbox("save-1", now=now + 63), [])


class OfflineLifeGenerationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.provider = _Provider()
        self.store = HeartloomStore(self.root / "heartloom.sqlite3", ["ling", "nai"])
        self.service = CompanionService(
            _registry(self.root), self.provider, self.store, memory_organizer_enabled=False
        )

    async def asyncTearDown(self):
        self.service.close()
        self.temp.cleanup()

    async def test_due_offline_event_calls_role_model_and_enters_outbox(self):
        now = int(time.time())
        self.store.sync_life_state(
            save_id="save-offline",
            selected_role_id="ling",
            snapshot={
                "roles": {
                    "ling": {
                        "role_id": "ling",
                        "stats": {"hunger": 82.0, "thirst": 20.0, "mood": 70.0},
                        "sensations": ["很饿"],
                    },
                    "nai": {"role_id": "nai", "stats": {"hunger": 20.0}},
                }
            },
            last_user_activity_at=now - 7_200,
            next_event_at=now - 1,
            now=now - 3_600,
        )
        result = await self.service.run_due_life_events(now=now)
        self.assertEqual(result["generated"], 1)
        self.assertEqual(len(self.provider.calls), 1)
        deliveries = self.service.poll_life_outbox("save-offline")
        self.assertEqual(len(deliveries), 1)
        payload = deliveries[0]["payload"]
        self.assertEqual(payload["protocol"], "spring_haven.life_delivery.v1")
        self.assertEqual(payload["role_id"], "ling")
        self.assertEqual(payload["event"]["kind"], "self_care_eat")
        self.assertIn("想你", payload["text"])


class LifeOutboxHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = HeartloomStore(self.root / "heartloom.sqlite3", ["ling", "nai"])
        self.service = CompanionService(_registry(self.root), _Provider(), self.store)
        self.client = TestClient(
            TestServer(
                build_app(
                    CoreConfig(api_key="l" * 64, provider_model="test"),
                    self.service.roles,
                    self.service,
                )
            )
        )
        await self.client.start_server()
        self.headers = {"X-API-Key": "l" * 64}

    async def asyncTearDown(self):
        await self.client.close()
        self.service.close()
        self.temp.cleanup()

    async def test_sync_poll_and_ack_http_contract(self):
        response = await self.client.post(
            "/life/sync",
            headers=self.headers,
            json={
                "save_id": "http-save",
                "selected_role_id": "ling",
                "last_user_activity_at": int(time.time()),
                "snapshot": {"roles": {"ling": {"stats": {"mood": 80}}}},
            },
        )
        self.assertEqual(response.status, 200)
        self.store.enqueue_life_delivery(
            delivery_id="life-delivery-http-save-1",
            save_id="http-save",
            role_id="ling",
            kind="offline_life",
            payload={"protocol": "spring_haven.life_delivery.v1", "text": "HTTP 测试"},
        )
        response = await self.client.get(
            "/life/outbox?save_id=http-save", headers=self.headers
        )
        body = await response.json()
        self.assertEqual(body["data"]["count"], 1)
        response = await self.client.post(
            "/life/outbox/ack",
            headers=self.headers,
            json={
                "save_id": "http-save",
                "delivery_ids": ["life-delivery-http-save-1"],
            },
        )
        body = await response.json()
        self.assertEqual(body["data"]["acknowledged"], 1)


if __name__ == "__main__":
    unittest.main()
