from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from aiohttp.test_utils import TestClient, TestServer

from spring_haven_core.app import build_app
from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.orchestration import ConversationOrchestrator
from spring_haven_core.prompting import HEARTLOOM_OPEN
from spring_haven_core.provider import ProviderReply
from spring_haven_core.roles import RoleRegistry
from spring_haven_core.service import CompanionService


class SequenceProvider:
    def __init__(self, replies: list[str] | None = None):
        self.replies = list(replies or ["测试回复"])
        self.calls: list[tuple[str, list[dict[str, str]]]] = []

    async def complete(self, system_prompt, messages):
        self.calls.append((system_prompt, messages))
        index = min(len(self.calls) - 1, len(self.replies) - 1)
        return ProviderReply(text=self.replies[index], finish_reason="stop")


class OrganizerAwareProvider:
    def __init__(self):
        self.calls: list[tuple[str, list[dict[str, str]]]] = []

    async def complete(self, system_prompt, messages):
        self.calls.append((system_prompt, messages))
        if "[Heartloom Organizer Contract]" in system_prompt:
            role_name = "小玲" if "LING_MEMORY_PROMPT" in system_prompt else "小奈"
            return ProviderReply(
                text=json.dumps(
                    {
                        "memories": [
                            {
                                "kind": "preference",
                                "title": f"{role_name}记住的饮品偏好",
                                "content": "主人明确说自己喜欢热可可。",
                                "trigger_terms": ["热可可", "饮品偏好"],
                                "importance": 0.82,
                                "confidence": 1.0,
                                "valence": 0.4,
                                "half_life_days": 365,
                                "behavior_tags": ["offer_hot_cocoa"],
                            }
                        ]
                    },
                    ensure_ascii=False,
                )
            )
        return ProviderReply(text="我会记住你喜欢热可可。", finish_reason="stop")


def make_registry(root: Path) -> RoleRegistry:
    (root / "personas").mkdir(exist_ok=True)
    (root / "personas/ling.md").write_text("你是小玲。", encoding="utf-8")
    (root / "personas/nai.md").write_text("你是小奈。", encoding="utf-8")
    path = root / "roles.json"
    path.write_text(
        json.dumps(
            {
                "roles": [
                    {
                        "role_id": "ling",
                        "display_name": "小玲",
                        "full_name": "春日 铃音",
                        "aliases": ["小玲", "铃音"],
                        "prompt_file": "personas/ling.md",
                        "memory_prompt": "LING_MEMORY_PROMPT",
                    },
                    {
                        "role_id": "nai",
                        "display_name": "小奈",
                        "full_name": "白濑 雪奈",
                        "aliases": ["小奈", "雪奈"],
                        "prompt_file": "personas/nai.md",
                        "memory_prompt": "NAI_MEMORY_PROMPT",
                    },
                ]
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    return RoleRegistry.load(path)


def payload(request_id: str, text: str, role_id: str = "ling") -> dict:
    return {
        "request_id": request_id,
        "role_id": role_id,
        "save_id": "heartloom-test",
        "text": text,
        "history": [],
        "event_type": "chat",
        "state": {
            "source_message_id": request_id + ":source",
            "conversation_visibility": {
                "audience_roles": ["ling", "nai"],
            },
        },
    }


class HeartloomStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "heartloom.sqlite3"
        self.store = HeartloomStore(self.path, ["ling", "nai"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_worldbook_entry_persists_and_recalls_influence(self):
        entry = self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "ling",
                "kind": "worldbook",
                "title": "窗边的栀子花",
                "content": "窗边的栀子花是主人和小玲一起照顾的。",
                "trigger_terms": ["栀子花", "窗边的花"],
                "priority": 8,
                "always_active": False,
                "influence": {
                    "dialogue": "谈到花时语气更温柔。",
                    "behavior_hint": "土壤变干时优先照顾栀子花。",
                    "behavior_tags": ["care_plant"],
                },
            }
        )
        memory_id = entry["memory_id"]
        self.store.close()
        self.store = HeartloomStore(self.path, ["ling", "nai"])
        recalled = self.store.recall(
            save_id="save-1", role_id="ling", query="栀子花今天怎么样？"
        )
        self.assertEqual(recalled[0]["memory_id"], memory_id)
        self.assertEqual(recalled[0]["influence"]["behavior_tags"], ["care_plant"])

    def test_role_scoped_memory_is_not_leaked(self):
        self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "ling",
                "content": "小玲把蓝色钥匙藏在书架后面。",
                "trigger_terms": ["蓝色钥匙"],
            }
        )
        self.assertEqual(
            self.store.recall(
                save_id="save-1", role_id="nai", query="蓝色钥匙在哪里"
            ),
            [],
        )

    def test_reset_cache_does_not_delete_durable_memory(self):
        self.store.put_memory(
            {
                "save_id": "save-1",
                "content": "主人喜欢热可可。",
                "trigger_terms": ["热可可"],
            }
        )
        self.store.reset_session_cache("save-1")
        self.assertEqual(self.store.status("save-1")["memory_count"], 1)

    def test_memory_graph_connects_related_memories_with_explainable_edges(self):
        tea = self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "ling",
                "title": "雨天的热茶",
                "content": "下雨时主人和小玲在餐桌旁喝桂花热茶。",
                "trigger_terms": ["桂花热茶", "雨天"],
                "importance": 0.8,
            }
        )
        promise = self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "nai",
                "title": "泡茶的约定",
                "content": "小奈答应下次下雨时也一起泡桂花热茶。",
                "trigger_terms": ["桂花热茶", "约定"],
                "importance": 0.7,
            }
        )
        unrelated = self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "*",
                "title": "蓝色钥匙",
                "content": "备用钥匙收在书架最上层。",
                "trigger_terms": ["备用钥匙"],
            }
        )
        graph = self.store.memory_graph(save_id="save-1", limit=20)
        self.assertEqual(graph["summary"]["node_count"], 3)
        edge_pairs = {
            frozenset((edge["source"], edge["target"])): edge
            for edge in graph["edges"]
        }
        related = edge_pairs[frozenset((tea["memory_id"], promise["memory_id"]))]
        self.assertIn("桂花热茶", related["shared_terms"])
        self.assertTrue(related["reasons"])
        self.assertFalse(
            any(unrelated["memory_id"] in pair for pair in edge_pairs)
        )
        ling_graph = self.store.memory_graph(save_id="save-1", scope="ling", limit=20)
        self.assertEqual([node["scope_role_id"] for node in ling_graph["nodes"]], ["ling"])


class HeartloomServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roles = make_registry(self.root)
        self.db_path = self.root / "memory.sqlite3"
        self.provider = SequenceProvider(["我记住啦。", "当然记得你喜欢栀子花。"])
        self.service = CompanionService(
            self.roles,
            self.provider,
            HeartloomStore(self.db_path, self.roles.ids()),
        )

    async def asyncTearDown(self):
        self.service.close()
        self.temp.cleanup()

    async def test_automatic_memory_is_injected_on_later_turn(self):
        await self.service.chat(payload("turn-1", "记住，我最喜欢栀子花。"))
        second = await self.service.chat(payload("turn-2", "我喜欢的花是什么？栀子花还好吗？"))
        self.assertGreaterEqual(second["memory"]["recalled_count"], 1)
        second_messages = self.provider.calls[1][1]
        serialized = json.dumps(second_messages, ensure_ascii=False)
        self.assertTrue(
            any(HEARTLOOM_OPEN in message["content"] for message in second_messages)
        )
        self.assertIn("栀子花", serialized)
        self.assertEqual(self.provider.calls[0][0], self.provider.calls[1][0])

    async def test_idempotency_survives_service_restart(self):
        first = await self.service.chat(payload("persistent-request", "晚安。"))
        self.service.close()
        second_provider = SequenceProvider(["不应调用"])
        self.service = CompanionService(
            self.roles,
            second_provider,
            HeartloomStore(self.db_path, self.roles.ids()),
        )
        second = await self.service.chat(payload("persistent-request", "晚安。"))
        self.assertEqual(first, second)
        self.assertEqual(second_provider.calls, [])

    async def test_valid_scene_action_is_extracted_and_hidden(self):
        self.provider.replies = [
            '我去餐桌边等你。<scene_action>{"schema_version":1,"action":"move_to","target_id":"dining_table"}</scene_action>'
        ]
        request = payload("scene-turn", "去餐桌")
        request["state"]["scene_context"] = {
            "protocol": "spring_heaven.scene_actions.v1",
            "schema_version": 1,
            "scene_id": "living_dining_room",
            "vision_available": False,
            "actor_role_id": "ling",
            "available_actions": [
                {"action": "move_to", "allowed_target_ids": ["dining_table", "sofa"]}
            ],
            "entities": [{"id": "dining_table"}, {"id": "sofa"}],
        }
        result = await self.service.chat(request)
        self.assertNotIn("scene_action", result["reply"])
        self.assertEqual(result["scene_actions"][0]["target_id"], "dining_table")


class OrchestrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roles = make_registry(self.root)
        self.provider = SequenceProvider(["暗号是樱灯。", "我听见了樱灯，月铃。"])
        self.service = CompanionService(
            self.roles,
            self.provider,
            HeartloomStore(self.root / "orchestration.sqlite3", self.roles.ids()),
        )
        self.orchestrator = ConversationOrchestrator(self.roles, self.service)

    async def asyncTearDown(self):
        self.service.close()
        self.temp.cleanup()

    async def test_dual_replies_are_sequential_and_share_fresh_context(self):
        result = await self.orchestrator.orchestrate(
            {
                "request_id": "dual-turn",
                "save_id": "save-1",
                "selected_role_id": "ling",
                "reply_mode": "auto",
                "text": "你们都回答：说出暗号。",
                "history": [],
                "state": {},
            }
        )
        self.assertEqual([item["role_id"] for item in result["replies"]], ["ling", "nai"])
        self.assertFalse(result["selection_changed"])
        second_prompt = json.dumps(self.provider.calls[1][1], ensure_ascii=False)
        self.assertIn("樱灯", second_prompt)

    async def test_replaying_orchestration_reuses_both_replies_and_turn(self):
        request = {
            "request_id": "stable-life-event",
            "source_message_id": "stable-life-event",
            "save_id": "save-1",
            "selected_role_id": "ling",
            "reply_mode": "both",
            "text": "一起喝茶。",
            "history": [],
            "state": {},
        }
        first = await self.orchestrator.orchestrate(request)
        second = await self.orchestrator.orchestrate(request)
        self.assertEqual(first["replies"], second["replies"])
        self.assertEqual(first["turn_index"], second["turn_index"])
        self.assertEqual(len(self.provider.calls), 2)

    def test_both_names_without_dual_directive_keep_selected_role(self):
        decision = self.orchestrator.resolve(
            "小奈知道小玲是自己的老婆吧", "nai"
        )
        self.assertEqual(decision.roles, ("nai",))

    def test_named_delegation_never_routes_a_role_to_itself(self):
        decision = self.orchestrator.resolve("小玲去问小奈晚饭吃什么", "ling")
        self.assertEqual(decision.roles, ("ling", "nai"))
        self.assertEqual(decision.route["origin_role"], "ling")
        self.assertEqual(decision.route["target_role"], "nai")


class RoleSpecificOrganizerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roles = make_registry(self.root)
        self.provider = OrganizerAwareProvider()
        self.service = CompanionService(
            self.roles,
            self.provider,
            HeartloomStore(self.root / "organizer.sqlite3", self.roles.ids()),
            memory_organizer_enabled=True,
        )

    async def asyncTearDown(self):
        await self.service.wait_for_organizer()
        self.service.close()
        self.temp.cleanup()

    async def test_each_role_uses_its_own_stable_organizer_prompt(self):
        await self.service.chat(payload("organizer-ling-1", "记住，我喜欢热可可。", "ling"))
        await self.service.wait_for_organizer()
        await self.service.chat(payload("organizer-ling-2", "以后也请记得我喜欢热可可。", "ling"))
        await self.service.wait_for_organizer()
        await self.service.chat(payload("organizer-nai-1", "小奈也要记住，我喜欢热可可。", "nai"))
        await self.service.wait_for_organizer()

        organizer_systems = [
            system
            for system, _messages in self.provider.calls
            if "[Heartloom Organizer Contract]" in system
        ]
        self.assertEqual(len(organizer_systems), 3)
        self.assertEqual(organizer_systems[0], organizer_systems[1])
        self.assertIn("LING_MEMORY_PROMPT", organizer_systems[0])
        self.assertIn("NAI_MEMORY_PROMPT", organizer_systems[2])
        self.assertNotEqual(organizer_systems[0], organizer_systems[2])

        ling_memories = self.service.list_memories("heartloom-test", "ling")
        nai_memories = self.service.list_memories("heartloom-test", "nai")
        self.assertTrue(any(item["source"] == "organizer_ling" for item in ling_memories))
        self.assertTrue(any(item["source"] == "organizer_nai" for item in nai_memories))
        self.assertEqual(
            self.service.memory_status("heartloom-test")["state"], "success"
        )

    async def test_trivial_turn_skips_extra_llm_organizer_call(self):
        result = await self.service.chat(payload("organizer-skip", "晚安", "ling"))
        await self.service.wait_for_organizer()
        self.assertEqual(result["memory"]["organizer_state"], "skipped")
        self.assertEqual(len(self.provider.calls), 1)


class HeartloomHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.roles = make_registry(root)
        self.service = CompanionService(
            self.roles,
            SequenceProvider(),
            HeartloomStore(root / "http.sqlite3", self.roles.ids()),
        )
        config = CoreConfig(
            api_key="h" * 64,
            provider_base_url="http://127.0.0.1:1/v1",
            provider_model="test",
        )
        self.client = TestClient(TestServer(build_app(config, self.roles, self.service)))
        await self.client.start_server()
        self.headers = {"X-API-Key": "h" * 64}

    async def asyncTearDown(self):
        await self.client.close()
        self.service.close()
        self.temp.cleanup()

    async def test_memory_crud_and_recall_endpoints(self):
        response = await self.client.post(
            "/memory/entries",
            headers=self.headers,
            json={
                "save_id": "save-1",
                "scope_role_id": "*",
                "content": "餐桌旁的花瓶是主人送的。",
                "trigger_terms": ["花瓶"],
                "influence": {"behavior_tags": ["protect_vase"]},
            },
        )
        self.assertEqual(response.status, 200)
        memory_id = (await response.json())["data"]["entry"]["memory_id"]
        recalled = await self.client.post(
            "/memory/recall",
            headers=self.headers,
            json={"save_id": "save-1", "role_id": "nai", "query": "花瓶是谁送的"},
        )
        self.assertEqual((await recalled.json())["data"]["count"], 1)
        deleted = await self.client.delete(
            f"/memory/entries/{memory_id}?save_id=save-1", headers=self.headers
        )
        self.assertTrue((await deleted.json())["data"]["deleted"])

    async def test_health_reports_heartloom(self):
        response = await self.client.get("/health", headers=self.headers)
        data = (await response.json())["data"]
        self.assertEqual(data["memory_backend"], "heartloom")
        self.assertEqual(data["memory"]["display_name"], "心织记忆")

    async def test_memory_graph_endpoint_returns_nodes_edges_and_summary(self):
        for title, content, scope in [
            ("餐桌边的花瓶", "主人和小玲把栀子花插进餐桌花瓶。", "ling"),
            ("照顾栀子花", "小奈记得给餐桌旁的栀子花换水。", "nai"),
        ]:
            self.service.put_memory(
                {
                    "save_id": "save-1",
                    "scope_role_id": scope,
                    "title": title,
                    "content": content,
                    "trigger_terms": ["栀子花", "餐桌"],
                }
            )
        response = await self.client.get(
            "/memory/graph?save_id=save-1&limit=40",
            headers=self.headers,
        )
        self.assertEqual(response.status, 200)
        graph = (await response.json())["data"]
        self.assertEqual(graph["summary"]["node_count"], 2)
        self.assertEqual(graph["summary"]["edge_count"], 1)
        self.assertEqual(graph["edges"][0]["shared_terms"][0], "栀子花")

    async def test_orchestrate_endpoint_returns_two_ordered_replies(self):
        response = await self.client.post(
            "/orchestrate",
            headers=self.headers,
            json={
                "request_id": "http-dual-turn",
                "save_id": "save-1",
                "selected_role_id": "nai",
                "reply_mode": "both",
                "text": "请一起说说今天的安排。",
                "history": [],
                "state": {},
            },
        )
        self.assertEqual(response.status, 200)
        data = (await response.json())["data"]
        self.assertEqual(
            [item["role_id"] for item in data["replies"]], ["nai", "ling"]
        )
        self.assertFalse(data["selection_changed"])


if __name__ == "__main__":
    unittest.main()
