from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from spring_haven_core.memory import HeartloomStore

try:  # discover 模式可直接导入;单模块直跑时回退包路径
    from test_contract import make_registry
except ImportError:
    from tests.test_contract import make_registry


class UserTurnDedupTests(unittest.TestCase):
    """#22 复读根因修复:同一动作原文重复入库会放大模型复读倾向。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roles = make_registry(self.root)
        self.store = HeartloomStore(Path(self.temp.name) / "dedup.sqlite3", self.roles.ids())

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def _count(self, content: str) -> int:
        return int(
            self.store._connection.execute(
                "SELECT COUNT(*) FROM memory_entries WHERE content = ?", (content,)
            ).fetchone()[0]
        )

    def _advance_clock(self, seconds: int) -> None:
        self.store._connection.execute(
            "UPDATE journey_clock SET anchor_real = anchor_real - ? WHERE save_id = 'save-1'",
            (seconds,),
        )
        self.store._connection.commit()

    def test_repeated_action_reinforces_instead_of_duplicating(self):
        first = self.store.remember_user_turn(
            save_id="save-1", source_event_id="user-a", text="🍗 主人喂你吃了东西"
        )
        second = self.store.remember_user_turn(
            save_id="save-1", source_event_id="user-b", text="🍗 主人喂你吃了东西"
        )
        self.assertEqual(first["memory_id"], second["memory_id"], "重复动作应强化同一条记忆")
        self.assertEqual(self._count(first["content"]), 1)
        # 强化时 intrinsic 按唤醒奖励同幅度增长(默认 0.5 → 至少 0.55)
        intrinsic = float(
            self.store._connection.execute(
                "SELECT intrinsic FROM memory_entries WHERE memory_id = ?",
                (second["memory_id"],),
            ).fetchone()[0]
        )
        self.assertGreaterEqual(intrinsic, 0.55)

    def test_repeated_action_outside_window_creates_new_episode(self):
        self.store.remember_user_turn(
            save_id="save-1", source_event_id="user-a", text="🍗 主人喂你吃了东西"
        )
        self._advance_clock(3 * 86400)
        second = self.store.remember_user_turn(
            save_id="save-1", source_event_id="user-b", text="🍗 主人喂你吃了东西"
        )
        self.assertEqual(self._count(second["content"]), 2, "窗口外的重复应视为新经历")

    def test_recall_dedups_identical_content(self):
        for index, event in enumerate(["user-a", "user-b", "user-c"]):
            self.store.put_memory(
                {
                    "save_id": "save-1",
                    "scope_role_id": "*",
                    "kind": "episodic",
                    "title": "与主人的一段经历",
                    "content": "主人曾说:🍗 主人喂你吃了东西",
                    "source_event_id": event,
                    "importance": 0.6,
                    "confidence": 1.0,
                },
                source="conversation_user",
            )
        recalled = self.store.recall(
            save_id="save-1", role_id="ling", query="喂你吃东西", limit=8
        )
        matching = [item for item in recalled if "主人喂你吃了东西" in str(item.get("content", ""))]
        self.assertEqual(len(matching), 1, "召回不应被逐字重复的记忆刷屏")

    def test_consolidate_merges_existing_duplicates(self):
        ids = []
        for event in ["user-a", "user-b", "user-c"]:
            entry = self.store.put_memory(
                {
                    "save_id": "save-1",
                    "scope_role_id": "*",
                    "kind": "episodic",
                    "title": "与主人的一段经历",
                    "content": "主人曾说:🍗 主人喂你吃了东西",
                    "source_event_id": event,
                    "importance": 0.6,
                    "confidence": 1.0,
                },
                source="conversation_user",
            )
            ids.append(entry["memory_id"])
        self.store._connection.execute(
            "UPDATE memory_entries SET recall_count = 2 WHERE memory_id = ?", (ids[1],)
        )
        self.store._connection.commit()
        result = self.store.consolidate_duplicate_user_memories("save-1")
        self.assertEqual(result["merged"], 2)
        self.assertEqual(self._count("主人曾说:🍗 主人喂你吃了东西"), 1)
        # 幂等:再跑一次不再合并
        again = self.store.consolidate_duplicate_user_memories("save-1")
        self.assertEqual(again["merged"], 0)
        keeper = self.store._connection.execute(
            "SELECT recall_count FROM memory_entries WHERE content = ?",
            ("主人曾说:🍗 主人喂你吃了东西",),
        ).fetchone()[0]
        self.assertEqual(int(keeper), 2, "合并时召回计数应取和")


if __name__ == "__main__":
    unittest.main()
