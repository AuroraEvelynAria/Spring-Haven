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

    def test_always_active_floor_requires_lexical_relevance(self):
        """里程碑保底分不再霸占每次召回:查询只命中普通记忆时,普通记忆第一。

        修复前 always_active 无条件 max(score, 0.82+…) → 里程碑出现在每次
        召回头部;修复后保底分仅在该记忆自身有词法关联时生效。
        """
        milestone_id = self._put(
            "milestone", "第一百个心织回忆。这段共同生活的时光,值得永远记得。",
            kind="relationship", always_active=True, priority=4,
            importance=0.9, half_life_days=0.0,
        )
        normal_id = self._put("normal", "窗台上的薄荷花开了,淡紫色很好看", importance=0.9)
        rows = self.store.recall(
            save_id="save-1", role_id="ling", query="薄荷 开花",
            limit=5, record_access=False,
        )
        self.assertTrue(rows)
        self.assertNotEqual(
            rows[0]["memory_id"], milestone_id,
            "与查询无关的里程碑不应靠保底分占据第一",
        )
        self.assertEqual(rows[0]["memory_id"], normal_id)
        # 查询本身指向里程碑时,保底分依然把它顶到最前(「永远记得」不变)
        rows = self.store.recall(
            save_id="save-1", role_id="ling", query="第一百个心织回忆",
            limit=5, record_access=False,
        )
        self.assertTrue(rows)
        self.assertEqual(rows[0]["memory_id"], milestone_id)

    def test_lexical_idf_downweights_pool_common_terms(self):
        """池内局部 IDF:全库高频词(主人)贡献被压低,稀有词记忆反超。

        11 条共享「主人」的 filler 与 1 条只含「薄荷」的记忆,重要度全部
        相同;修复前两者词法分相同(并列,靠写入顺序分先后),修复后
        稀有词记忆以 IDF 优势明确胜出。
        """
        for index in range(11):
            self._put(f"common-{index}", "主人在家休息")
        rare_id = self._put("rare", "薄荷开花了")
        rows = self.store.recall(
            save_id="save-1", role_id="ling", query="主人薄荷浇水",
            limit=12, record_access=False,
        )
        self.assertTrue(rows, "召回不应为空")
        self.assertEqual(rows[0]["memory_id"], rare_id)
        self.assertGreater(
            float(rows[0]["recall_score"]) - float(rows[1]["recall_score"]), 0.03,
            "稀有词记忆应凭 IDF 优势与高频词记忆拉开差距",
        )

    def test_embedding_backfill_selects_model_mismatch(self):
        """换 embedding 模型后,向量模型不匹配的存量必须进入重嵌清单。"""
        with_vector = self._put("with-vector", "窗台上的薄荷花开了")
        without_vector = self._put("no-vector", "阳台上晾着刚洗好的床单")
        self.store.update_memory_embedding(with_vector, [0.1, 0.9], "old-model")

        plain = self.store.memories_without_embedding("save-1")
        self.assertEqual(
            {row["memory_id"] for row in plain}, {without_vector},
            "未传 model 时只回填 NULL 向量(保持旧行为)",
        )

        stale = self.store.memories_without_embedding("save-1", model="new-model")
        self.assertEqual(
            {row["memory_id"] for row in stale},
            {with_vector, without_vector},
            "传入新 model 时,旧模型向量与 NULL 向量都应入选",
        )
        models = {row["memory_id"]: row["embedding_model"] for row in stale}
        self.assertEqual(models[with_vector], "old-model")

        same = self.store.memories_without_embedding("save-1", model="old-model")
        self.assertEqual(
            {row["memory_id"] for row in same}, {without_vector},
            "模型匹配的存量不应重复回填",
        )

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
                {"roles": [
                    {"role_id": "ling", "display_name": "小玲", "prompt_file": "personas/ling.md"},
                    {"role_id": "nai", "display_name": "小奈", "prompt_file": "personas/ling.md"},
                ]},
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
        self.assertEqual(body["memory_node_count"], 2)
        self.assertEqual(body["entity_node_count"], 0)
        self.assertTrue(body["truncated"])
        self.assertTrue(body["cursor"])

    async def test_entity_graph_cursor_advances_only_memory_page(self):
        memory_ids: list[str] = []
        for index in range(3):
            entry = self.service.memory.put_memory(
                {"save_id": "save-g", "scope_role_id": "ling", "kind": "episodic",
                 "content": f"实体分页来源记忆 {index}", "source_event_id": f"evt-entity-page-{index}"},
                source="organizer",
            )
            memory_ids.append(str(entry["memory_id"]))
            self.service.memory.put_claims(
                save_id="save-g",
                claims=[{
                    "subject": f"人物{index}",
                    "predicate": "拥有",
                    "object": f"物件{index}",
                }],
                source_memory_id=str(entry["memory_id"]),
            )
        first_response = await self.client.get(
            "/heartloom/graph",
            headers=self.headers,
            params={"save_id": "save-g", "role_id": "ling", "limit": "1", "include_entities": "1"},
        )
        first = (await first_response.json())["data"]
        self.assertEqual(first["memory_node_count"], 1)
        self.assertGreater(first["entity_node_count"], 0)
        self.assertEqual(first["cursor"], "1")
        first_memory_ids = {
            node["memory_id"] for node in first["nodes"] if node.get("node_type") == "memory"
        }
        second_response = await self.client.get(
            "/heartloom/graph",
            headers=self.headers,
            params={
                "save_id": "save-g", "role_id": "ling", "limit": "1",
                "include_entities": "1", "cursor": first["cursor"],
            },
        )
        second = (await second_response.json())["data"]
        second_memory_ids = {
            node["memory_id"] for node in second["nodes"] if node.get("node_type") == "memory"
        }
        self.assertEqual(len(second_memory_ids), 1)
        self.assertFalse(first_memory_ids & second_memory_ids)
        self.assertTrue(second_memory_ids <= set(memory_ids))

    async def test_graph_scope_supports_shared_only(self):
        for scope in ["*", "ling", "nai"]:
            self.service.memory.put_memory(
                {"save_id": "save-g", "scope_role_id": scope, "kind": "episodic",
                 "content": f"{scope} 范围记忆", "source_event_id": f"evt-scope-{scope}"},
                source="organizer",
            )
        shared_response = await self.client.get(
            "/heartloom/graph",
            headers=self.headers,
            params={"save_id": "save-g", "role_id": "*", "limit": "20"},
        )
        shared = (await shared_response.json())["data"]
        self.assertEqual({node["scope_role_id"] for node in shared["nodes"]}, {"*"})
        ling_response = await self.client.get(
            "/heartloom/graph",
            headers=self.headers,
            params={"save_id": "save-g", "role_id": "ling", "limit": "20"},
        )
        ling = (await ling_response.json())["data"]
        self.assertEqual({node["scope_role_id"] for node in ling["nodes"]}, {"*", "ling"})

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
