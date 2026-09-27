"""ADR-010 时间游标测试:graph_page(as_of_world) 的节点/边过滤与 world_range。"""

from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.memory import HeartloomStore, MemoryStoreError
from spring_haven_core.service import CompanionService, RequestValidationError

try:
    from test_contract import make_registry
except ImportError:
    from tests.test_contract import make_registry


class GraphAsOfStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "asof.sqlite3", ["ling", "nai"])
        self._anchor_clock(world_value=0.0)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def _anchor_clock(self, *, world_value: float) -> None:
        """把 save-1 的世界时钟锚到「现在 = world_value 世界日」。"""
        self.store._connection.execute(
            "INSERT INTO journey_clock(save_id, anchor_real, world_value, rate) "
            "VALUES ('s', ?, ?, 1.0) "
            "ON CONFLICT(save_id) DO UPDATE SET "
            "anchor_real = excluded.anchor_real, world_value = excluded.world_value, rate = 1.0",
            (int(time.time()), world_value),
        )
        self.store._connection.commit()

    def _advance_world_days(self, days: float) -> None:
        self.store._connection.execute(
            "UPDATE journey_clock SET world_value = world_value + ? WHERE save_id = 's'",
            (days,),
        )
        self.store._connection.commit()

    def _put(self, hint: str, content: str) -> str:
        return str(
            self.store.put_memory(
                {
                    "save_id": "s",
                    "scope_role_id": "ling",
                    "kind": "episodic",
                    "content": content,
                    "source_event_id": f"evt-{hint}",
                },
                source="organizer",
            )["memory_id"]
        )

    def test_as_of_filters_nodes_by_world_creation(self):
        early_id = self._put("early", "世界第 0 天种下的薄荷")
        self._advance_world_days(5.0)
        late_id = self._put("late", "世界第 5 天薄荷开了花")
        live = self.store.graph_page(save_id="s", limit=50)
        self.assertEqual(live["node_count"], 2)
        self.assertIsNone(live["as_of_world"])
        past = self.store.graph_page(save_id="s", limit=50, as_of_world=2.0)
        ids = {str(node["memory_id"]) for node in past["nodes"]}
        self.assertEqual(ids, {early_id})
        self.assertEqual(past["as_of_world"], 2.0)
        # 回到"现在" = 全量(+1 天余量抵消 world_now 的 4 位小数舍入)
        now = self.store.graph_page(
            save_id="s", limit=50, as_of_world=float(live["world_now"]) + 1.0
        )
        self.assertEqual(now["node_count"], 2)

    def test_as_of_filters_edges_by_link_creation(self):
        m1 = self._put("a", "一起照顾窗边的栀子花")
        self._advance_world_days(4.0)
        m2 = self._put("b", "栀子花浇水的日常记录")
        # m2 写入时增量建边(ADR-001 D4),边的 world_created_at = 第 4 天
        before = self.store.graph_page(save_id="s", limit=50, as_of_world=2.0)
        self.assertEqual(before["node_count"], 1)  # m2 尚未诞生
        self.assertEqual(len(before["edges"]), 0)  # 边在它诞生时才建立
        after = self.store.graph_page(save_id="s", limit=50, as_of_world=5.0)
        self.assertEqual(after["node_count"], 2)
        self.assertGreaterEqual(len(after["edges"]), 1)
        # 增量建边是单向 src=new→dst=old(m2 为新);边 payload 自带诞生时刻(客户端调光用)
        target_edge = next(
            edge
            for edge in after["edges"]
            if {str(edge["src"]), str(edge["dst"])} == {m1, m2}
        )
        self.assertIn("world_created_at", target_edge)
        self.assertGreaterEqual(float(target_edge["world_created_at"]), 3.9)

    def test_world_range_ignores_as_of(self):
        self._put("a", "最早的记忆")
        self._advance_world_days(9.0)
        self._put("b", "最晚的记忆")
        result = self.store.graph_page(save_id="s", limit=50, as_of_world=1.0)
        world_range = result["world_range"]
        self.assertLessEqual(world_range["earliest"], 1.0)
        self.assertGreaterEqual(world_range["latest"], 9.0)

    def test_invalid_as_of_rejected(self):
        with self.assertRaises(MemoryStoreError):
            self.store.graph_page(save_id="s", limit=50, as_of_world=-3.0)


class GraphAsOfServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.store = HeartloomStore(root / "svc.sqlite3", ["ling", "nai"])
        self.service = CompanionService(make_registry(root), None, self.store)

    def tearDown(self):
        self.service.close()
        self.temp.cleanup()

    def test_service_parses_and_validates_as_of(self):
        result = self.service.graph_data({"save_id": "s", "as_of_world": " 3.5 "})
        self.assertEqual(result["as_of_world"], 3.5)
        live = self.service.graph_data({"save_id": "s"})
        self.assertIsNone(live["as_of_world"])
        with self.assertRaises(RequestValidationError):
            self.service.graph_data({"save_id": "s", "as_of_world": "第三天"})


if __name__ == "__main__":
    unittest.main()
