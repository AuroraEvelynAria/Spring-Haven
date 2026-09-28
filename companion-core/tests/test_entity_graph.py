"""ADR-015:实体星座图测试。

覆盖:缺省关闭向后兼容 / 实体节点载荷 / claim 边与 claim_source 边 /
world_to 信念修订下发 / as_of 过滤(实体诞生与 claim 生效) / 现行计数。
"""

from __future__ import annotations

import time
import unittest

from spring_haven_core.memory import HeartloomStore


class EntityConstellationTests(unittest.TestCase):
    def setUp(self):
        self.store = HeartloomStore(":memory:", ["ling"])

    def tearDown(self):
        self.store.close()

    def _advance_world_days(self, days: float) -> None:
        with self.store._lock, self.store._connection:
            self.store._connection.execute(
                "UPDATE journey_clock SET world_value = world_value + ?, anchor_real = ? "
                "WHERE save_id = 's'",
                (days, time.time()),
            )

    def _memory(self, tag: str, role_id: str = "ling") -> str:
        return str(
            self.store.put_memory(
                {
                    "save_id": "s",
                    "scope_role_id": role_id,
                    "kind": "episodic",
                    "title": f"记忆{tag}",
                    "content": f"关于{tag}的一段经历",
                    "trigger_terms": [tag],
                    "source_event_id": f"eg-{role_id}-{tag}",
                },
                source=f"organizer_{role_id}",
            )["memory_id"]
        )

    def test_default_payload_has_no_entity_layer(self):
        memory_id = self._memory("茶")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "喜欢", "object": "工夫茶"}],
            source_memory_id=memory_id,
        )
        page = self.store.graph_page(save_id="s", role_id="ling", limit=20)
        for node in page["nodes"]:
            self.assertNotIn("node_type", node)
            self.assertNotIn("node_id", node)
        for edge in page["edges"]:
            self.assertNotIn(edge["link_type"], {"claim", "claim_source"})

    def test_include_entities_adds_nodes_and_claim_edges(self):
        memory_id = self._memory("茶")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "喜欢", "object": "工夫茶"}],
            source_memory_id=memory_id,
        )
        page = self.store.graph_page(
            save_id="s", role_id="ling", limit=20, include_entities=True
        )
        by_type: dict[str, list[dict]] = {"memory": [], "entity": []}
        for node in page["nodes"]:
            by_type[node["node_type"]].append(node)
        self.assertEqual(len(by_type["memory"]), 1)
        self.assertEqual(by_type["memory"][0]["node_id"], memory_id)
        names = {node["name"] for node in by_type["entity"]}
        self.assertEqual(names, {"主人", "工夫茶"})
        subject = next(n for n in by_type["entity"] if n["name"] == "主人")
        self.assertEqual(subject["claim_count"], 1)
        claim_edges = [e for e in page["edges"] if e["link_type"] == "claim"]
        self.assertEqual(len(claim_edges), 1)
        claim = claim_edges[0]
        self.assertEqual(claim["predicate"], "喜欢")
        self.assertIsNone(claim["world_to"])
        entity_ids = {n["node_id"] for n in by_type["entity"]}
        self.assertIn(claim["src"], entity_ids)
        self.assertIn(claim["dst"], entity_ids)
        # claim_source 边把记忆层缝到实体层
        source_edges = [e for e in page["edges"] if e["link_type"] == "claim_source"]
        self.assertEqual(len(source_edges), 1)
        self.assertEqual(source_edges[0]["src"], memory_id)
        self.assertEqual(source_edges[0]["dst"], claim["src"])

    def test_superseded_claim_carries_world_to(self):
        memory_id = self._memory("饮品")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "在用", "object": "工夫茶"}],
            source_memory_id=memory_id,
        )
        self._advance_world_days(3.0)
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "在用", "object": "手冲咖啡"}],
            source_memory_id=memory_id,
        )
        page = self.store.graph_page(
            save_id="s", role_id="ling", limit=20, include_entities=True
        )
        claims = [e for e in page["edges"] if e["link_type"] == "claim"]
        self.assertEqual(len(claims), 2)
        old = next(e for e in claims if e["object_text"] == "工夫茶")
        new = next(e for e in claims if e["object_text"] == "手冲咖啡")
        self.assertIsNotNone(old["world_to"])
        self.assertIsNone(new["world_to"])
        # 排序:现行主张在前
        self.assertEqual(claims[0]["object_text"], "手冲咖啡")
        # 现行计数只算未顶替
        subject = next(
            n for n in page["nodes"]
            if n["node_type"] == "entity" and n["name"] == "主人"
        )
        self.assertEqual(subject["claim_count"], 1)

    def test_role_graph_hides_private_claims_from_other_roles(self):
        # 本测试需要第二角色，模拟两人各自拥有不共享的来源记忆。
        self.store.close()
        self.store = HeartloomStore(":memory:", ["ling", "nai"])
        ling_memory = self._memory("玲的私事", "ling")
        nai_memory = self._memory("奈的私事", "nai")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "小玲私人物", "predicate": "收在", "object": "玲的抽屉"}],
            source_memory_id=ling_memory,
        )
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "小奈私人物", "predicate": "收在", "object": "奈的抽屉"}],
            source_memory_id=nai_memory,
        )

        ling_page = self.store.graph_page(
            save_id="s", role_id="ling", limit=20, include_entities=True
        )
        ling_entity_names = {
            node["name"] for node in ling_page["nodes"] if node["node_type"] == "entity"
        }
        ling_predicates = {
            edge["predicate"] for edge in ling_page["edges"] if edge["link_type"] == "claim"
        }
        self.assertIn("小玲私人物", ling_entity_names)
        self.assertNotIn("小奈私人物", ling_entity_names)
        self.assertEqual(ling_predicates, {"收在"})
        self.assertTrue(
            all(
                edge["src"] != nai_memory
                for edge in ling_page["edges"]
                if edge["link_type"] == "claim_source"
            )
        )

        full_page = self.store.graph_page(save_id="s", limit=20, include_entities=True)
        full_entity_names = {
            node["name"] for node in full_page["nodes"] if node["node_type"] == "entity"
        }
        self.assertIn("小玲私人物", full_entity_names)
        self.assertIn("小奈私人物", full_entity_names)

    def test_as_of_filters_entities_and_claims(self):
        early_memory = self._memory("早期")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "小玲", "predicate": "喜欢", "object": "窗台"}],
            source_memory_id=early_memory,
        )
        self._advance_world_days(10.0)
        late_memory = self._memory("后期")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "小玲", "predicate": "在读", "object": "《三体》"}],
            source_memory_id=late_memory,
        )
        page = self.store.graph_page(
            save_id="s", role_id="ling", limit=20, include_entities=True,
            as_of_world=5.0,
        )
        names = {n["name"] for n in page["nodes"] if n["node_type"] == "entity"}
        self.assertIn("窗台", names)
        self.assertNotIn("《三体》", names)
        predicates = {
            e["predicate"] for e in page["edges"] if e["link_type"] == "claim"
        }
        self.assertEqual(predicates, {"喜欢"})


if __name__ == "__main__":
    unittest.main()
