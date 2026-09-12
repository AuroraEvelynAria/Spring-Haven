from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from spring_haven_core.app import build_app
from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import (
    DORMANT_AFTER_WORLD_DAYS,
    HeartloomStore,
    MemoryStoreError,
)
from spring_haven_core.provider import ProviderReply
from spring_haven_core.roles import RoleRegistry
from spring_haven_core.service import CompanionService


class FakeEmbeddingProvider:
    """最小 provider:embedding 返回注入向量,chat 返回固定文本。"""

    def __init__(self):
        self.vectors: dict[str, list[float]] = {}
        self.settings = None  # 无 settings → embedding 自动降级

    def set_vector(self, content_term: str, vector: list[float]):
        self.vectors[content_term] = vector

    async def complete(self, system_prompt, messages):
        return ProviderReply(text="好的。", input_tokens=1, output_tokens=1,
                             cached_tokens=0, finish_reason="stop")

    async def embed(self, texts):
        result = []
        for text in texts:
            for term, vector in self.vectors.items():
                if term in text:
                    result.append(vector)
                    break
            else:
                result.append([0.0, 0.0])
        return result


def make_store(temp_root: Path) -> HeartloomStore:
    return HeartloomStore(temp_root / "net.sqlite3", ["ling", "nai"])


class MemoryNetworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = make_store(Path(self.temp.name))

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def _put(self, memory_id_hint: str, content: str, **kwargs):
        payload = {
            "save_id": "save-1",
            "scope_role_id": "ling",
            "kind": "episodic",
            "content": content,
            "source_event_id": f"evt-{memory_id_hint}",
        }
        payload.update(kwargs)
        entry = self.store.put_memory(payload, source="organizer")
        return str(entry["memory_id"])

    def test_incremental_edges_are_bounded(self):
        anchor_id = self._put("anchor", "一起照顾窗边的栀子花")
        for index in range(10):
            self._put(f"filler-{index}", f"栀子花浇水的日常记录 {index}")
        new_id = self._put("new", "栀子花又开了,我们都很开心")
        built = self.store.build_links_for_memory(new_id)
        # 自动建边可能已抢先建好,此时显式调用返回空集;以库内边为准
        stored = self.store._connection.execute(
            "SELECT link_type FROM memory_links WHERE src_memory_id = ?", (new_id,)
        ).fetchall()
        self.assertGreaterEqual(len(stored), 1)
        self.assertTrue(all(str(row["link_type"]) == "association" for row in stored))
        self.assertLessEqual(len(built) + len(stored), 5 + len(stored))
        self.assertLessEqual(len(stored), 5, "单条记忆最多 3-5 条边(ADR-001 D4)")

    def test_spread_type_for_heard_from_source(self):
        base_id = self._put("base", "小玲姐姐帮我清理了兔耳")
        new_id = self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "nai",
                "kind": "episodic",
                "content": "小玲姐姐帮我清理了兔耳",
                "source_event_id": "heard-ling-1-1",
            },
            source="heard_from_ling",
        )["memory_id"]
        built = self.store.build_links_for_memory(new_id)
        stored = self.store._connection.execute(
            "SELECT link_type FROM memory_links WHERE src_memory_id = ?", (new_id,)
        ).fetchall()
        self.assertGreaterEqual(len(stored), 1)
        self.assertTrue(all(str(row["link_type"]) == "spread" for row in stored))
        self.store.close()
        self.store = make_store(Path(self.temp.name))  # 保持 tearDown 对称
        _ = base_id

    def test_edges_are_unique_per_type(self):
        self._put("first", "一起照顾窗边的栀子花")
        new_id = self._put("second", "栀子花又开了")
        first_built = self.store.build_links_for_memory(new_id)
        stored = self.store._connection.execute(
            "SELECT link_type FROM memory_links WHERE src_memory_id = ?", (new_id,)
        ).fetchall()
        self.assertGreaterEqual(len(stored), 1)
        self.assertLessEqual(len(first_built), 5)
        again = self.store.build_links_for_memory(new_id)
        self.assertEqual(again, [], "重复建边应被 UNIQUE 约束忽略,不再新增")
        count = self.store._connection.execute(
            "SELECT COUNT(*) FROM memory_links WHERE src_memory_id = ?", (new_id,)
        ).fetchone()[0]
        self.assertEqual(int(count), len(stored))

    def test_put_memory_builds_edges_automatically(self):
        self._put("anchor", "一起照顾窗边的栀子花")
        new_id = self._put("auto", "栀子花今晚浇过水了")
        count = self.store._connection.execute(
            "SELECT COUNT(*) FROM memory_links WHERE src_memory_id = ?", (new_id,)
        ).fetchone()[0]
        self.assertGreaterEqual(
            int(count), 1, "put_memory 新建记忆应自动增量建边,无需显式调用"
        )

    def test_memory_update_does_not_rebuild_edges(self):
        payload = {
            "save_id": "save-1",
            "scope_role_id": "ling",
            "kind": "episodic",
            "content": "栀子花今晚浇过水了",
            "source_event_id": "evt-auto",
        }
        new_id = str(self.store.put_memory(payload, source="organizer")["memory_id"])
        before = self.store._connection.execute(
            "SELECT COUNT(*) FROM memory_links WHERE src_memory_id = ?", (new_id,)
        ).fetchone()[0]
        self.store.put_memory(payload, source="organizer")  # 同 source_event_id 的更新
        after = self.store._connection.execute(
            "SELECT COUNT(*) FROM memory_links WHERE src_memory_id = ?", (new_id,)
        ).fetchone()[0]
        self.assertEqual(int(after), int(before), "记忆更新不应重建边")

    def test_backfill_memory_links_covers_legacy_entries(self):
        self._put("legacy-1", "一起照顾窗边的栀子花")
        self._put("legacy-2", "栀子花又开了")
        self.store._connection.execute("DELETE FROM memory_links")
        self.store._connection.commit()
        built = self.store.backfill_memory_links(save_id="save-1")
        self.assertGreaterEqual(built, 1)
        remaining = self.store._connection.execute(
            """
            SELECT COUNT(*) FROM memory_entries
            WHERE lifecycle = 'active' AND enabled = 1
              AND NOT EXISTS (
                  SELECT 1 FROM memory_links WHERE src_memory_id = memory_entries.memory_id
              )
            """
        ).fetchone()[0]
        self.assertEqual(int(remaining), 0, "回填后存量 Active 记忆应都有出边")

    def test_lifecycle_dormant_after_constant_days(self):
        memory_id = self._put("dormant", "窗台的栀子花")
        world_now = self.store.world_now("save-1")
        self.store._connection.execute(
            "UPDATE memory_entries SET world_created_at = ?, world_updated_at = ?, "
            "last_recalled_world = 0.0 WHERE memory_id = ?",
            (world_now - DORMANT_AFTER_WORLD_DAYS - 0.5, world_now - DORMANT_AFTER_WORLD_DAYS - 0.5, memory_id),
        )
        self.store._connection.commit()
        stats = self.store.apply_lifecycle_transitions("save-1")
        self.assertGreaterEqual(stats["dormant"], 1)
        lifecycle = self.store._connection.execute(
            "SELECT lifecycle FROM memory_entries WHERE memory_id = ?", (memory_id,)
        ).fetchone()[0]
        self.assertEqual(str(lifecycle), "dormant")
        # dormant 精确关键词命中自动唤醒
        recalled = self.store.recall(save_id="save-1", role_id="ling", query="栀子花")
        self.assertTrue(any(item["memory_id"] == memory_id for item in recalled))
        lifecycle = self.store._connection.execute(
            "SELECT lifecycle FROM memory_entries WHERE memory_id = ?", (memory_id,)
        ).fetchone()[0]
        self.assertEqual(str(lifecycle), "active")

    def test_lifecycle_archive_on_low_confidence(self):
        memory_id = self._put("archive", "很久之前的一段小事")
        self.store._connection.execute(
            "UPDATE memory_entries SET confidence = 0.5, half_life_days = 1.0, "
            "world_created_at = world_created_at - 10.0, world_updated_at = world_updated_at - 10.0 "
            "WHERE memory_id = ?",
            (memory_id,),
        )
        self.store._connection.commit()
        stats = self.store.apply_lifecycle_transitions("save-1")
        self.assertGreaterEqual(stats["archived"], 1)
        lifecycle = self.store._connection.execute(
            "SELECT lifecycle FROM memory_entries WHERE memory_id = ?", (memory_id,)
        ).fetchone()[0]
        self.assertEqual(str(lifecycle), "archived")
        # archived 不能被召回命中激活,只能手动恢复
        recalled = self.store.recall(save_id="save-1", role_id="ling", query="很久之前的一段小事")
        self.assertFalse(any(item["memory_id"] == memory_id for item in recalled))
        self.store.set_memory_lifecycle(memory_id, "active")
        lifecycle = self.store._connection.execute(
            "SELECT lifecycle FROM memory_entries WHERE memory_id = ?", (memory_id,)
        ).fetchone()[0]
        self.assertEqual(str(lifecycle), "active")

    def test_always_active_is_exempt_from_lifecycle(self):
        memory_id = self._put("pinned", "窗台的栀子花", always_active=True)
        world_now = self.store.world_now("save-1")
        self.store._connection.execute(
            "UPDATE memory_entries SET world_updated_at = ?, last_recalled_world = 0.0 "
            "WHERE memory_id = ?",
            (world_now - DORMANT_AFTER_WORLD_DAYS - 5.0, memory_id),
        )
        self.store._connection.commit()
        self.store.apply_lifecycle_transitions("save-1")
        lifecycle = self.store._connection.execute(
            "SELECT lifecycle FROM memory_entries WHERE memory_id = ?", (memory_id,)
        ).fetchone()[0]
        self.assertEqual(str(lifecycle), "active")

    def test_set_memory_lifecycle_rejects_invalid(self):
        memory_id = self._put("any", "随便一条")
        with self.assertRaises(MemoryStoreError):
            self.store.set_memory_lifecycle(memory_id, "frozen")


class VectorRecallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "vector.sqlite3", ["ling"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_semantic_channel_changes_ranking(self):
        id_a = self.store.put_memory(
            {"save_id": "save-1", "scope_role_id": "ling", "kind": "episodic",
             "content": "一起去看日出", "source_event_id": "evt-a"}
        )["memory_id"]
        id_b = self.store.put_memory(
            {"save_id": "save-1", "scope_role_id": "ling", "kind": "episodic",
             "content": "一起去看日出", "source_event_id": "evt-b"}
        )["memory_id"]
        # 相同词法;仅向量不同:A 与查询同向,B 正交
        self.store.update_memory_embedding(id_a, [0.95, 0.05], "test-embed")
        self.store.update_memory_embedding(id_b, [0.05, 0.95], "test-embed")
        recalled = self.store.recall(
            save_id="save-1", role_id="ling", query="一起去看日出",
            query_vector=[0.9, 0.1], embedding_model="test-embed",
        )
        self.assertEqual(len(recalled), 2)
        self.assertEqual(recalled[0]["memory_id"], id_a, "语义通道应把向量更近的记忆排前")
        # 无查询向量时(纯词法)两者词法相同 → 降级排序,不报错即可
        recalled_plain = self.store.recall(save_id="save-1", role_id="ling", query="一起去看日出")
        self.assertEqual(len(recalled_plain), 2)


class GraphEndpointTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roles = self._make_registry(self.root)
        self.provider = FakeEmbeddingProvider()
        self.service = CompanionService(self.roles, self.provider)
        self.client = None
        from aiohttp.test_utils import TestClient, TestServer
        from spring_haven_core.app import build_app
        config = CoreConfig(
            api_key="g" * 64,
            provider_base_url="http://127.0.0.1:1/v1",
            provider_model="unused",
        )
        self.client = TestClient(
            TestServer(build_app(config, self.roles, self.service))
        )
        await self.client.start_server()
        self.headers = {"X-API-Key": "g" * 64}

    async def asyncTearDown(self):
        await self.client.close()
        self.service.close()
        self.temp.cleanup()

    def _make_registry(self, root: Path) -> RoleRegistry:
        (root / "personas").mkdir(parents=True, exist_ok=True)
        (root / "personas/ling.md").write_text("你是小玲。", encoding="utf-8")
        (root / "roles.json").write_text(
            json.dumps(
                {"roles": [{"role_id": "ling", "display_name": "小玲",
                            "prompt_file": "personas/ling.md"}]},
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        return RoleRegistry.load(root / "roles.json")

    async def test_graph_endpoint_returns_nodes_and_edges(self):
        memory = self.service.memory.put_memory(
            {"save_id": "save-g", "scope_role_id": "ling", "kind": "episodic",
             "content": "一起照顾窗边的栀子花", "source_event_id": "evt-g1"},
            source="organizer",
        )
        memory_id = str(memory["memory_id"])
        self.service.memory.put_memory(
            {"save_id": "save-g", "scope_role_id": "ling", "kind": "episodic",
             "content": "栀子花又开了", "source_event_id": "evt-g2"},
            source="organizer",
        )
        linked = self.service.memory.list_memories(save_id="save-g")
        for item in linked:
            self.service.memory.build_links_for_memory(str(item["memory_id"]))
        response = await self.client.get(
            "/heartloom/graph",
            headers=self.headers,
            params={"save_id": "save-g", "role_id": "ling", "limit": "50"},
        )
        self.assertEqual(response.status, 200)
        body = (await response.json())["data"]
        self.assertEqual(body["graph_version"], 2)
        self.assertGreaterEqual(len(body["nodes"]), 2)
        self.assertTrue(all(node["lifecycle"] == "active" for node in body["nodes"]))
        self.assertTrue(all(edge["src"] in {n["memory_id"] for n in body["nodes"]}
                            and edge["dst"] in {n["memory_id"] for n in body["nodes"]}
                            for edge in body["edges"]))

    async def test_graph_pagination_respects_limit(self):
        for index in range(4):
            self.service.memory.put_memory(
                {"save_id": "save-g", "scope_role_id": "ling", "kind": "episodic",
                 "content": f"记忆条目 {index}", "source_event_id": f"evt-p{index}"},
                source="organizer",
            )
        response = await self.client.get(
            "/heartloom/graph",
            headers=self.headers,
            params={"save_id": "save-g", "limit": "2"},
        )
        body = (await response.json())["data"]
        self.assertEqual(body["node_count"], 2)
        self.assertTrue(body["truncated"])
        self.assertTrue(body["cursor"])

    async def test_state_events_logged_for_interactions(self):
        import json as _json
        payload = {
            "request_id": "req-ste-1",
            "role_id": "ling",
            "save_id": "save-1",
            "text": "小玲今天感觉怎么样？",
            "event_type": "chat",
            "history": [],
            "state": {
                "body_state": {"role_id": "ling", "stats": {"mood": 65}},
                "local_effect": {
                    "action": "hug",
                    "stat_changes": [{"stat": "intimacy", "delta": 2.0}],
                },
            },
        }
        response = await self.client.post(
            "/chat", headers=self.headers, json=payload
        )
        self.assertEqual(response.status, 200)
        rows = self.service.memory._connection.execute(
            "SELECT kind, delta_json FROM state_events WHERE save_id = 'save-1'"
        ).fetchall()
        self.assertGreaterEqual(len(rows), 1)
        self.assertEqual(rows[0]["kind"], "interaction")
        self.assertIn("intimacy", rows[0]["delta_json"])
        _ = _json


import json  # noqa: E402  (GraphEndpointTests 需要;置于文件尾部避免顶部循环依赖问题)
