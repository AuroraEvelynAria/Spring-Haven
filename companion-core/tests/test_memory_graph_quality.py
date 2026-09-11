"""Tests for the improved memory_graph algorithm (time bands, same-source star, same-day chain, recall boost, orphan bridge)."""

import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.memory import HeartloomStore


class GraphQualityTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self._tmp.name) / "heartloom.sqlite3", ["ling", "nai"])

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def _put(self, save_id: str, title: str, content: str, *, source: str = "manual", **extra) -> dict:
        base = {
            "save_id": save_id,
            "scope_role_id": "ling",
            "title": title,
            "content": content,
        }
        base.update(extra)
        return self.store.put_memory(base, source=source)

    def test_same_day_chain_connects_daily_digest_memories(self) -> None:
        """同一天产生的 daily_digest 记忆应被时间链串联。"""
        now = int(time.time())
        day_start = now - (now % 86400)
        ids = []
        for i in range(3):
            m = self._put(
                "s", f"day-{i}",
                f"第{i}天的生活记忆，内容是{i}号发生的事",
                source="daily_digest",
            )
            self.store._connection.execute(
                "UPDATE memory_entries SET created_at = ? WHERE memory_id = ?",
                (day_start + i * 3600, m["memory_id"]),
            )
            ids.append(m["memory_id"])
        graph = self.store.memory_graph(save_id="s", limit=20)
        edges = graph["edges"]
        day_edges = [e for e in edges if "同一天的生活" in e.get("reasons", [])]
        self.assertGreaterEqual(len(day_edges), 2, edges)
        pairs = {frozenset((e["source"], e["target"])) for e in day_edges}
        self.assertIn(frozenset((ids[0], ids[1])), pairs)
        self.assertIn(frozenset((ids[1], ids[2])), pairs)

    def test_same_source_star_not_full_mesh(self) -> None:
        """同一源事件的 3 条记忆应星形连接（2 条边），而非全连接（3 条边）。"""
        base = "life-lab-aaaabbbbccccdddd"
        for i in range(3):
            self._put(
                "s", f"frag-{i}",
                f"同一对话的碎片记忆{i}，关于窗边的花和猫",
                source="life_lab",
                source_event_id=f"{base}:{i}",
            )
        graph = self.store.memory_graph(save_id="s", limit=20)
        same_source_edges = [
            e for e in graph["edges"] if e.get("same_source_event")
        ]
        self.assertEqual(len(same_source_edges), 2, graph["edges"])

    def test_time_band_reason_appears(self) -> None:
        """1 小时内创建的记忆应有'一小时内'理由。"""
        now = int(time.time())
        self._put("s", "a", "早上发生的事，关于早餐")
        self._put("s", "b", "紧接着的事，还是早餐相关")
        graph = self.store.memory_graph(save_id="s", limit=20)
        reasons = [r for e in graph["edges"] for r in e.get("reasons", [])]
        self.assertIn("一小时内", reasons)

    def test_orphan_with_no_lexical_overlap_stays_isolated(self) -> None:
        """无共享词的孤立记忆不应被强行搭桥。"""
        self._put("s", "茶", "雨天时主人在茶几旁喝桂花热茶", trigger_terms=["桂花热茶"])
        self._put("s", "钥匙", "备用钥匙放在书架最上层", trigger_terms=["备用钥匙"])
        graph = self.store.memory_graph(save_id="s", limit=20)
        isolated = graph["summary"]["isolated_node_count"]
        self.assertGreaterEqual(isolated, 1, graph["edges"])

    def test_recall_boost_adds_reason(self) -> None:
        """recall_count>=3 的记忆对有'经常被一起想起'理由。"""
        now = int(time.time())
        a = self._put("s", "a", "常被想起的事一：一起散步")
        b = self._put("s", "b", "常被想起的事二：一起散步")
        self.store._connection.execute(
            "UPDATE memory_entries SET recall_count = 5 WHERE memory_id IN (?, ?)",
            (a["memory_id"], b["memory_id"]),
        )
        graph = self.store.memory_graph(save_id="s", limit=20)
        reasons = [r for e in graph["edges"] for r in e.get("reasons", [])]
        self.assertIn("经常被一起想起", reasons)

    def test_summary_counts_are_consistent(self) -> None:
        """summary 的 connected/isolated 统计应一致。"""
        self._put("s", "a", "第一件事，窗边看书")
        self._put("s", "b", "第二件事，窗边看书")
        self._put("s", "c", "完全无关，海底捞月亮的鱼")
        graph = self.store.memory_graph(save_id="s", limit=20)
        s = graph["summary"]
        self.assertEqual(s["node_count"], 3)
        self.assertEqual(
            s["connected_node_count"] + s["isolated_node_count"],
            s["node_count"],
        )


if __name__ == "__main__":
    unittest.main()
