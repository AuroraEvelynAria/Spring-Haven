"""ADR-014:艾宾浩斯正式化测试。

覆盖:方向修正(高 intrinsic 衰减更慢=护盾) / 乘法稳定度增长与封顶 /
v10 迁移倒数重映射(有效半衰期不变) + 备份 / recall_decay 载荷。
"""

from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.memory import (
    SCHEMA_VERSION,
    WAKE_GROWTH_FACTOR,
    WAKE_REWARD_CAP,
    HeartloomStore,
)


class EbbinghausDynamicsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "ebb.sqlite3", ["ling"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def _advance_world_days(self, days: float) -> None:
        with self.store._lock, self.store._connection:
            self.store._connection.execute(
                "UPDATE journey_clock SET world_value = world_value + ?, anchor_real = ? "
                "WHERE save_id = 's'",
                (days, time.time()),
            )

    def _seed(self, tag: str, intrinsic: float) -> str:
        memory_id = str(
            self.store.put_memory(
                {
                    "save_id": "s",
                    "scope_role_id": "ling",
                    "kind": "episodic",
                    "title": f"记忆{tag}",
                    "content": f"锚点细节{tag}",
                    "trigger_terms": ["锚点"],
                    "source_event_id": f"ebb-{tag}",
                },
                source="organizer_ling",
            )["memory_id"]
        )
        with self.store._lock, self.store._connection:
            self.store._connection.execute(
                "UPDATE memory_entries SET intrinsic = ? WHERE memory_id = ?",
                (intrinsic, memory_id),
            )
        return memory_id

    def test_higher_intrinsic_decays_slower(self):
        """方向修正:同样老化 120 世界天后,高 intrinsic 的 R(t) 更高(护盾)。"""
        high = self._seed("high", 4.0)
        low = self._seed("low", 1.0)
        self._advance_world_days(120.0)
        rows = self.store.recall_pool(
            save_id="s", role_id="ling", query="锚点", limit=8
        )
        decay = {str(item["memory_id"]): item["recall_decay"] for item in rows}
        self.assertIn(high, decay)
        self.assertIn(low, decay)
        self.assertGreater(decay[high], decay[low])
        # 1.0 = 标称半衰期:120 天后应恰好衰减一半
        self.assertAlmostEqual(decay[low], 0.5, places=3)

    def test_wake_growth_is_multiplicative_and_capped(self):
        memory_id = self._seed("grow", 1.0)
        expected = 1.0
        for _ in range(5):
            self.store.commit_recall_access(
                save_id="s", role_id="ling", memory_ids=[memory_id], record_access=True
            )
            expected = min(WAKE_REWARD_CAP, expected * WAKE_GROWTH_FACTOR)
            current = float(
                self.store._connection.execute(
                    "SELECT intrinsic FROM memory_entries WHERE memory_id = ?",
                    (memory_id,),
                ).fetchone()[0]
            )
            self.assertAlmostEqual(current, expected, places=6)
        # 已达封顶:继续召回保持上限
        self.store.commit_recall_access(
            save_id="s", role_id="ling", memory_ids=[memory_id], record_access=True
        )
        current = float(
            self.store._connection.execute(
                "SELECT intrinsic FROM memory_entries WHERE memory_id = ?",
                (memory_id,),
            ).fetchone()[0]
        )
        self.assertAlmostEqual(current, WAKE_REWARD_CAP, places=6)

    def test_recall_decay_payload_present(self):
        self._seed("payload", 1.0)
        rows = self.store.recall_pool(
            save_id="s", role_id="ling", query="锚点", limit=4
        )
        self.assertTrue(rows)
        self.assertIn("recall_decay", rows[0])
        self.assertLessEqual(rows[0]["recall_decay"], 1.0)


class EbbinghausMigrationTests(unittest.TestCase):
    def test_v9_to_v10_remaps_intrinsic_and_backs_up(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "v10.sqlite3"
            store = HeartloomStore(path, ["ling"])
            try:
                ids = {}
                for tag, intrinsic in (("a", 0.5), ("b", 1.0), ("c", 0.05)):
                    memory_id = str(
                        store.put_memory(
                            {
                                "save_id": "s",
                                "scope_role_id": "ling",
                                "kind": "episodic",
                                "title": tag,
                                "content": f"迁移样本{tag}",
                                "source_event_id": f"mig-{tag}",
                            },
                            source="organizer_ling",
                        )["memory_id"]
                    )
                    store._connection.execute(
                        "UPDATE memory_entries SET intrinsic = ? WHERE memory_id = ?",
                        (intrinsic, memory_id),
                    )
                    ids[tag] = memory_id
                # 回退版本戳到 v9,模拟升级前存档
                store._connection.execute(
                    "UPDATE heartloom_meta SET value = '9' WHERE key = 'schema_version'"
                )
                store._connection.commit()
            finally:
                store.close()
            # 重开:触发 v10 迁移
            reopened = HeartloomStore(path, ["ling"])
            try:
                values = {
                    tag: float(
                        reopened._connection.execute(
                            "SELECT intrinsic FROM memory_entries WHERE memory_id = ?",
                            (memory_id,),
                        ).fetchone()[0]
                    )
                    for tag, memory_id in ids.items()
                }
                self.assertAlmostEqual(values["a"], 2.0, places=6)  # 0.5 → 2.0(有效半衰期不变)
                self.assertAlmostEqual(values["b"], 1.0, places=6)  # 1.0 → 1.0
                self.assertAlmostEqual(values["c"], 4.0, places=6)  # 0.05 → 20,封顶 4.0
                version = reopened._connection.execute(
                    "SELECT value FROM heartloom_meta WHERE key = 'schema_version'"
                ).fetchone()[0]
                self.assertEqual(int(version), SCHEMA_VERSION)
                self.assertTrue(Path(str(path) + ".pre-v10.backup").is_file())
            finally:
                reopened.close()


if __name__ == "__main__":
    unittest.main()
