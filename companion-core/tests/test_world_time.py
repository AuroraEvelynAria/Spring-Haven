from __future__ import annotations

import sqlite3
import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.memory import (
    ARCHIVE_CONFIDENCE_THRESHOLD,
    DORMANT_AFTER_WORLD_DAYS,
    LIFE_OUTBOX_TTL_WORLD_DAYS,
    SCHEMA_VERSION,
    HeartloomStore,
    MemoryStoreError,
)

BASE_TS = 1_700_000_000
DAY = 86_400

V5_SCHEMA = """
CREATE TABLE IF NOT EXISTS heartloom_meta (
    key TEXT PRIMARY KEY, value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS memory_entries (
    memory_id TEXT PRIMARY KEY, save_id TEXT NOT NULL,
    scope_role_id TEXT NOT NULL DEFAULT '*', kind TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '', content TEXT NOT NULL,
    trigger_terms_json TEXT NOT NULL DEFAULT '[]',
    always_active INTEGER NOT NULL DEFAULT 0, priority INTEGER NOT NULL DEFAULT 0,
    importance REAL NOT NULL DEFAULT 0.5, confidence REAL NOT NULL DEFAULT 1.0,
    valence REAL NOT NULL DEFAULT 0.0, half_life_days REAL NOT NULL DEFAULT 90.0,
    influence_json TEXT NOT NULL DEFAULT '{}', source TEXT NOT NULL DEFAULT 'manual',
    source_event_id TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL, last_recalled_at INTEGER NOT NULL DEFAULT 0,
    recall_count INTEGER NOT NULL DEFAULT 0, enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS life_outbox (
    delivery_id TEXT PRIMARY KEY, save_id TEXT NOT NULL, role_id TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'proactive', payload_json TEXT NOT NULL,
    created_at INTEGER NOT NULL, available_at INTEGER NOT NULL,
    acked_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS life_events (
    event_id TEXT NOT NULL, save_id TEXT NOT NULL, role_id TEXT NOT NULL,
    action TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
    occurred_at_unix INTEGER NOT NULL, created_at INTEGER NOT NULL,
    PRIMARY KEY (event_id, save_id)
);
CREATE TABLE IF NOT EXISTS digest_state (
    save_id TEXT NOT NULL, role_id TEXT NOT NULL, day_key TEXT NOT NULL,
    memory_id TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
    PRIMARY KEY (save_id, role_id, day_key)
);
"""


def _make_v5_db(path: Path, *, with_second_hand: bool = False, with_outbox: bool = True) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(V5_SCHEMA)
    rows = [
        ("mem-old-1", BASE_TS),
        ("mem-old-2", BASE_TS + DAY),
        ("mem-old-3", BASE_TS + 2 * DAY),
    ]
    for memory_id, created_at in rows:
        conn.execute(
            """
            INSERT INTO memory_entries (
                memory_id, save_id, kind, content, importance, confidence,
                half_life_days, source, created_at, updated_at
            ) VALUES (?, 'save-1', 'episodic', ?, 0.7, 0.9, 90.0, ?, ?, ?)
            """,
            (
                memory_id,
                f"记忆 {memory_id}",
                "heard_from_ling" if (with_second_hand and memory_id == "mem-old-3") else "organizer",
                created_at,
                created_at,
            ),
        )
    if with_outbox:
        conn.execute(
            """
            INSERT INTO life_outbox (
                delivery_id, save_id, role_id, kind, payload_json,
                created_at, available_at, acked_at
            ) VALUES ('dlv-1', 'save-1', 'ling', 'proactive', '{}', ?, ?, 0)
            """,
            (BASE_TS + DAY, BASE_TS + DAY),
        )
    conn.execute(
        """
        INSERT INTO life_events (event_id, save_id, role_id, action, occurred_at_unix, created_at)
        VALUES ('evt-1', 'save-1', 'ling', 'hug', ?, ?)
        """,
        (BASE_TS + 3600, BASE_TS + 3600),
    )
    conn.execute(
        "INSERT INTO heartloom_meta (key, value) VALUES ('schema_version', '5')"
    )
    conn.commit()
    conn.close()


class MigrationDrillTests(unittest.TestCase):
    """ADR-001 Phase 1 验收:三类旧存档的 v6 迁移演练。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def _open(self, name: str) -> HeartloomStore:
        return HeartloomStore(self.root / name, ["ling", "nai"])

    def test_minimal_archive_upgrade(self):
        path = self.root / "minimal.sqlite3"
        conn = sqlite3.connect(path)
        conn.executescript(V5_SCHEMA)
        conn.execute("INSERT INTO heartloom_meta (key, value) VALUES ('schema_version', '5')")
        conn.commit()
        conn.close()
        store = self._open("minimal.sqlite3")
        try:
            version = store._connection.execute(
                "SELECT value FROM heartloom_meta WHERE key = 'schema_version'"
            ).fetchone()[0]
            self.assertEqual(str(version), str(SCHEMA_VERSION))
        finally:
            store.close()

    def test_legacy_archive_upgrade_backfills_world_columns(self):
        path = self.root / "legacy.sqlite3"
        _make_v5_db(path)
        store = self._open("legacy.sqlite3")
        try:
            rows = store._connection.execute(
                """
                SELECT memory_id, world_created_at, world_updated_at, is_second_hand
                FROM memory_entries ORDER BY world_created_at ASC
                """
            ).fetchall()
            self.assertEqual(len(rows), 3)
            self.assertAlmostEqual(float(rows[0]["world_created_at"]), 0.0, places=4)
            self.assertAlmostEqual(float(rows[1]["world_created_at"]), 1.0, places=4)
            self.assertAlmostEqual(float(rows[2]["world_created_at"]), 2.0, places=4)
            for row in rows:
                self.assertEqual(int(row["is_second_hand"]), 0)
            clock = store._connection.execute(
                "SELECT anchor_real, rate FROM journey_clock WHERE save_id = 'save-1'"
            ).fetchone()
            self.assertIsNotNone(clock)
            self.assertEqual(int(clock["anchor_real"]), BASE_TS)
            self.assertAlmostEqual(float(clock["rate"]), 1.0, places=6)
        finally:
            store.close()

    def test_second_hand_memories_are_flagged(self):
        path = self.root / "second-hand.sqlite3"
        _make_v5_db(path, with_second_hand=True)
        store = self._open("second-hand.sqlite3")
        try:
            flags = dict(
                store._connection.execute(
                    "SELECT memory_id, is_second_hand FROM memory_entries"
                ).fetchall()
            )
            self.assertEqual(int(flags["mem-old-3"]), 1)
            self.assertEqual(int(flags["mem-old-1"]), 0)
        finally:
            store.close()

    def test_upgrade_creates_backup_and_is_idempotent(self):
        path = self.root / "backup.sqlite3"
        _make_v5_db(path)
        store = self._open("backup.sqlite3")
        store.close()
        self.assertTrue(Path(str(path) + ".pre-v6.backup").exists())
        conn = sqlite3.connect(path)
        conn.row_factory = sqlite3.Row
        try:
            before = conn.execute(
                "SELECT memory_id, world_created_at FROM memory_entries ORDER BY world_created_at"
            ).fetchall()
        finally:
            conn.close()
        again = self._open("backup.sqlite3")
        try:
            after = again._connection.execute(
                "SELECT memory_id, world_created_at FROM memory_entries ORDER BY world_created_at"
            ).fetchall()
        finally:
            again.close()
        self.assertEqual(
            [(str(r["memory_id"]), float(r["world_created_at"])) for r in before],
            [(str(r["memory_id"]), float(r["world_created_at"])) for r in after],
        )

    def test_outbox_world_created_at_backfilled(self):
        path = self.root / "outbox.sqlite3"
        _make_v5_db(path)
        store = self._open("outbox.sqlite3")
        try:
            value = store._connection.execute(
                "SELECT world_created_at FROM life_outbox WHERE delivery_id = 'dlv-1'"
            ).fetchone()[0]
            self.assertAlmostEqual(float(value), 1.0, places=4)
        finally:
            store.close()

    def test_v6_forward_compat_guard_still_applies(self):
        path = self.root / "future.sqlite3"
        _make_v5_db(path)
        conn = sqlite3.connect(path)
        conn.execute("UPDATE heartloom_meta SET value = '999' WHERE key = 'schema_version'")
        conn.commit()
        conn.close()
        with self.assertRaises(MemoryStoreError):
            self._open("future.sqlite3")


class WorldClockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "clock.sqlite3", ["ling", "nai"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_constants_are_frozen(self):
        self.assertEqual(DORMANT_AFTER_WORLD_DAYS, 14.0)
        self.assertEqual(ARCHIVE_CONFIDENCE_THRESHOLD, 0.15)
        self.assertEqual(LIFE_OUTBOX_TTL_WORLD_DAYS, 7.0)

    def test_world_now_starts_at_journey_anchor(self):
        now_real = int(time.time())
        value = self.store.world_now("save-a")
        self.assertGreaterEqual(value, 0.0)
        self.assertLess(value - (now_real - self.store._journey_clock("save-a")[0]) / DAY, 0.01)

    def test_per_journey_clocks_are_isolated(self):
        now_real = int(time.time())
        # 直接注入不同锚点的时钟行,确定性验证双旅程世界时间独立推进
        self.store._connection.execute(
            "INSERT INTO journey_clock (save_id, anchor_real, world_value, rate) VALUES ('save-a', ?, 0.0, 1.0)",
            (now_real - DAY,),
        )
        self.store._connection.execute(
            "INSERT INTO journey_clock (save_id, anchor_real, world_value, rate) VALUES ('save-b', ?, 0.0, 1.0)",
            (now_real,),
        )
        self.store._connection.commit()
        world_a = self.store.world_now("save-a")
        world_b = self.store.world_now("save-b")
        self.assertGreater(world_a, world_b)
        self.assertAlmostEqual(world_a - world_b, 1.0, places=4,
                               msg="锚点相差一天的两个旅程,世界时间差应约为 1 世界天")

    def test_rate_scaling_advances_world_time_faster(self):
        self.store.put_memory(
            {"save_id": "save-a", "scope_role_id": "ling", "kind": "episodic", "content": "锚点"}
        )
        self.store.set_journey_rate("save-a", 2.0)
        started_real = time.time()
        world_before = self.store.world_now("save-a")
        time.sleep(0.2)
        world_after = self.store.world_now("save-a")
        real_elapsed = time.time() - started_real
        world_elapsed = world_after - world_before
        self.assertGreater(
            world_elapsed,
            real_elapsed / DAY * 1.5,
            msg="2 倍率下世界时间推进应明显快于现实时间",
        )
        self.assertLess(world_elapsed, real_elapsed / DAY * 2.5)

    def test_set_journey_rate_rejects_invalid(self):
        with self.assertRaises(MemoryStoreError):
            self.store.set_journey_rate("save-a", 0.0)


class WorldTtlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "ttl.sqlite3", ["ling", "nai"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def _enqueue(self, delivery_id: str):
        self.store.enqueue_life_delivery(
            delivery_id=delivery_id,
            save_id="save-1",
            role_id="ling",
            kind="proactive",
            payload={"text": "想你"},
        )

    def test_fresh_delivery_is_polled(self):
        self._enqueue("dlv-1")
        polled = self.store.poll_life_outbox("save-1")
        self.assertEqual(len(polled), 1)

    def test_expired_delivery_is_not_polled_and_purged(self):
        self._enqueue("dlv-old")
        world_now = self.store.world_now("save-1")
        self.store._connection.execute(
            "UPDATE life_outbox SET world_created_at = ? WHERE delivery_id = 'dlv-old'",
            (world_now - LIFE_OUTBOX_TTL_WORLD_DAYS - 1.0,),
        )
        self.store._connection.commit()
        self.assertEqual(self.store.poll_life_outbox("save-1"), [])
        self.store.due_life_states()
        remaining = self.store._connection.execute(
            "SELECT COUNT(*) FROM life_outbox WHERE delivery_id = 'dlv-old'"
        ).fetchone()[0]
        self.assertEqual(int(remaining), 0)

    def test_expired_delivery_unblocks_offline_generation(self):
        self.store.enqueue_life_delivery(
            delivery_id="dlv-block",
            save_id="save-1",
            role_id="ling",
            kind="proactive",
            payload={"text": "想你"},
        )
        self.store._connection.execute(
            "INSERT INTO life_state (save_id, snapshot_json, updated_at) VALUES ('save-1', '{}', 0)"
        )
        self.store._connection.execute(
            "UPDATE life_state SET next_event_at = 1 WHERE save_id = 'save-1'"
        )
        self.store._connection.commit()
        self.assertEqual(self.store.due_life_states(), [])
        world_now = self.store.world_now("save-1")
        self.store._connection.execute(
            "UPDATE life_outbox SET world_created_at = ? WHERE delivery_id = 'dlv-block'",
            (world_now - LIFE_OUTBOX_TTL_WORLD_DAYS - 1.0,),
        )
        self.store._connection.commit()
        due = self.store.due_life_states()
        self.assertEqual(len(due), 1)


class RecallWorldAgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "decay.sqlite3", ["ling"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_decay_follows_world_age(self):
        self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "ling",
                "kind": "episodic",
                "title": "老记忆",
                "content": "一起去看日出",
                "importance": 0.8,
                "half_life_days": 10.0,
                "source_event_id": "old-1",
            }
        )
        self.store.put_memory(
            {
                "save_id": "save-1",
                "scope_role_id": "ling",
                "kind": "episodic",
                "title": "新记忆",
                "content": "一起去看日出",
                "importance": 0.8,
                "half_life_days": 10.0,
                "source_event_id": "new-1",
            }
        )
        # 把第一段记忆的世界时间回拨 40 世界天(half_life=10 → 衰减到 1/16)
        self.store._connection.execute(
            """
            UPDATE memory_entries
            SET world_created_at = world_created_at - 40.0,
                world_updated_at = world_updated_at - 40.0
            WHERE title = '老记忆'
            """
        )
        self.store._connection.commit()
        recalled = self.store.recall(save_id="save-1", role_id="ling", query="一起去看日出")
        self.assertEqual(len(recalled), 2)
        self.assertEqual(recalled[0]["title"], "新记忆", "世界时间更近的记忆应排在前面")


if __name__ == "__main__":
    unittest.main()
