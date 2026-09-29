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

    def test_private_claim_does_not_supersede_shared_fact(self):
        """跨 scope 的主张不得互相顶替。

        修复前修订键只有 (subject, predicate),与来源角色无关 —— 小奈的私有主张
        能顶掉共享记忆写下的事实,读取端再过一遍可见性过滤,共享事实就在小玲视图
        和「仅共享」视图里静默消失,而且没有任何冲突提示。
        """
        self.store.close()
        self.store = HeartloomStore(":memory:", ["ling", "nai"])
        shared_memory = self._memory("共享茶事", role_id="*")
        nai_memory = self._memory("小奈咖啡", role_id="nai")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "在用", "object": "工夫茶"}],
            source_memory_id=shared_memory,
        )
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "在用", "object": "手冲咖啡"}],
            source_memory_id=nai_memory,
        )
        for role_id in ("ling", "*"):
            page = self.store.graph_page(
                save_id="s", role_id=role_id, limit=20, include_entities=True
            )
            claim_edges = [
                e for e in page["edges"] if e["link_type"] == "claim"
            ]
            self.assertEqual(
                {e["object_text"] for e in claim_edges},
                {"工夫茶"},
                f"{role_id} 视图应只看见共享事实",
            )
            # 关键:共享事实必须仍然是"现行"。只查边上的宾语不够 —— 被顶替的
            # 旧主张同样带着自己的宾语挂在图上,真正的伤害是 world_to 被写上、
            # 于是它从"当前事实"里消失了。
            self.assertTrue(
                all(e["world_to"] is None for e in claim_edges),
                f"{role_id} 视图里的共享事实不应被标记为已顶替",
            )
            counts = {
                n["name"]: n["claim_count"]
                for n in page["nodes"]
                if n["node_type"] == "entity"
            }
            self.assertEqual(counts.get("主人"), 1)
        nai_page = self.store.graph_page(
            save_id="s", role_id="nai", limit=20, include_entities=True
        )
        nai_objects = {
            e["object_text"] for e in nai_page["edges"] if e["link_type"] == "claim"
        }
        # 不同 scope 的主张是不同持有者的信念,并存而不是互相顶替
        self.assertEqual(nai_objects, {"工夫茶", "手冲咖啡"})

    def test_current_claims_prefers_local_belief_over_shared(self):
        """同一读者视角里同一 (主语, 谓词) 只留一条当前主张。

        修订按 scope 隔离之后,不同 scope 的信念会并存;但对某一个读者来说,
        「喜欢工夫茶」和「喜欢手冲咖啡」同时作为"当前事实"会让 prompt 自相矛盾。
        """
        self.store.close()
        self.store = HeartloomStore(":memory:", ["ling", "nai"])
        shared_memory = self._memory("共享茶事", role_id="*")
        nai_memory = self._memory("小奈咖啡", role_id="nai")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "在用", "object": "工夫茶"}],
            source_memory_id=shared_memory,
        )
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "主人", "predicate": "在用", "object": "手冲咖啡"}],
            source_memory_id=nai_memory,
        )
        subject_id = str(
            self.store._connection.execute(
                "SELECT entity_id FROM entities WHERE save_id = 's' AND name = '主人'"
            ).fetchone()["entity_id"]
        )
        ling_claims = self.store.current_claims(
            save_id="s", entity_ids=[subject_id], role_id="ling"
        )
        self.assertEqual([c["object"] for c in ling_claims], ["工夫茶"])
        nai_claims = self.store.current_claims(
            save_id="s", entity_ids=[subject_id], role_id="nai"
        )
        # 自己写的信念优先于共享,而不是两条并列
        self.assertEqual([c["object"] for c in nai_claims], ["手冲咖啡"])

    def test_recent_entity_names_is_scoped_by_role(self):
        """实体锚定清单会进该角色自己的 organizer 提示词,不能带上别人的私有实体。

        不过滤时,小奈的私有实体名会出现在小玲的提示词里,而 organizer 的输出
        又写成小玲的私有记忆 —— 正好和隔离目标相反。
        """
        self.store.close()
        self.store = HeartloomStore(":memory:", ["ling", "nai"])
        ling_memory = self._memory("小玲私物", role_id="ling")
        nai_memory = self._memory("小奈私物", role_id="nai")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "小玲", "predicate": "收在", "object": "小玲私物"}],
            source_memory_id=ling_memory,
        )
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "小奈", "predicate": "收在", "object": "小奈私物"}],
            source_memory_id=nai_memory,
        )
        self.assertIn("小玲私物", self.store.recent_entity_names("s", "ling"))
        self.assertNotIn("小奈私物", self.store.recent_entity_names("s", "ling"))
        self.assertIn("小奈私物", self.store.recent_entity_names("s", "nai"))
        self.assertNotIn("小玲私物", self.store.recent_entity_names("s", "nai"))
        # 无角色时保留全量,审计视图不受影响
        audit_names = self.store.recent_entity_names("s")
        self.assertIn("小玲私物", audit_names)
        self.assertIn("小奈私物", audit_names)

    def test_entity_visibility_respects_as_of_boundary(self):
        """实体不能只因为"有一条未来才成立的可见主张"就对过去视角可见。

        修复前实体可见性只查有没有可见来源、不过时间,于是回溯到那一刻会看到一个
        claim_count 为 0 的孤立实体 —— 名字被越权露出,而且和计数自相矛盾。
        """
        self.store.close()
        self.store = HeartloomStore(":memory:", ["ling", "nai"])
        private_memory = self._memory("小奈先见", role_id="nai")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "共同的熟人", "predicate": "住在", "object": "城西"}],
            source_memory_id=private_memory,
        )
        self._advance_world_days(10.0)
        ling_memory = self._memory("小玲后知", role_id="ling")
        self.store.put_claims(
            save_id="s",
            claims=[{"subject": "共同的熟人", "predicate": "住在", "object": "城东"}],
            source_memory_id=ling_memory,
        )
        past = self.store.graph_page(
            save_id="s", role_id="ling", limit=20, include_entities=True,
            as_of_world=5.0,
        )
        past_names = {n["name"] for n in past["nodes"] if n["node_type"] == "entity"}
        self.assertNotIn("共同的熟人", past_names)
        self.assertNotIn("城东", past_names)
        current = self.store.graph_page(
            save_id="s", role_id="ling", limit=20, include_entities=True
        )
        current_names = {n["name"] for n in current["nodes"] if n["node_type"] == "entity"}
        self.assertIn("共同的熟人", current_names)
        self.assertIn("城东", current_names)
        self.assertNotIn("城西", current_names)


if __name__ == "__main__":
    unittest.main()
