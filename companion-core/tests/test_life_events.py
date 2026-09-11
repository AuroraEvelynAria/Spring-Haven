"""Tests for the life_events table (daily-plan reporting from Godot)."""

import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.memory import HeartloomStore, MemoryStoreError

ROLE_IDS = ("ling", "nai")


class LifeEventsStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self._tmp.name) / "heartloom.sqlite3", ROLE_IDS)

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def _event(self, event_id: str, role: str = "ling", action: str = "read_by_window") -> dict:
        return {
            "event_id": event_id,
            "role_id": role,
            "action": action,
            "description": "window reading",
            "occurred_at_unix": int(time.time()),
            "stat_changes": {"mood": 3.0, "stress": -3.0},
        }

    def test_record_and_list_life_events(self) -> None:
        result = self.store.record_life_events(
            save_id="save-a", events=[self._event("dailyplan-ling-read_by_window-20260802-1000")]
        )
        self.assertEqual(result, {"recorded": 1, "total": 1})
        rows = self.store.list_life_events(save_id="save-a")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["action"], "read_by_window")
        self.assertEqual(rows[0]["role_id"], "ling")
        self.assertEqual(rows[0]["stat_changes"], {"mood": 3.0, "stress": -3.0})

    def test_duplicate_event_is_idempotent(self) -> None:
        ev = self._event("dailyplan-ling-morning_window_watch-20260802-0730")
        self.store.record_life_events(save_id="save-a", events=[ev])
        result = self.store.record_life_events(save_id="save-a", events=[ev])
        self.assertEqual(result, {"recorded": 0, "total": 1})
        self.assertEqual(len(self.store.list_life_events(save_id="save-a")), 1)

    def test_same_event_id_under_different_saves_is_allowed(self) -> None:
        ev = self._event("dailyplan-ling-night_patrol-20260802-2330")
        self.store.record_life_events(save_id="save-a", events=[ev])
        self.store.record_life_events(save_id="save-b", events=[ev])
        self.assertEqual(len(self.store.list_life_events(save_id="save-a")), 1)
        self.assertEqual(len(self.store.list_life_events(save_id="save-b")), 1)

    def test_invalid_role_is_skipped(self) -> None:
        bad = self._event("dailyplan-ghost-walk-20260802-1600", role="ghost")
        result = self.store.record_life_events(save_id="save-a", events=[bad])
        self.assertEqual(result, {"recorded": 0, "total": 1})

    def test_too_many_events_are_rejected(self) -> None:
        events = [self._event(f"evt-{i}") for i in range(21)]
        with self.assertRaises(MemoryStoreError):
            self.store.record_life_events(save_id="save-a", events=events)

    def test_list_filters_role_action_and_before_unix(self) -> None:
        now = int(time.time())
        self.store.record_life_events(
            save_id="save-a",
            events=[
                self._event("e1", role="ling", action="read_by_window"),
                self._event("e2", role="nai", action="dance_practice"),
            ],
        )
        rows = self.store.list_life_events(save_id="save-a", role_id="nai")
        self.assertEqual([r["event_id"] for r in rows], ["e2"])
        rows = self.store.list_life_events(save_id="save-a", action="read_by_window")
        self.assertEqual([r["event_id"] for r in rows], ["e1"])
        rows = self.store.list_life_events(save_id="save-a", before_unix=now - 1)
        self.assertEqual(rows, [])

    def test_event_id_sanitized_when_not_source_pattern(self) -> None:
        weird = self._event("bad id with spaces!")
        result = self.store.record_life_events(save_id="save-a", events=[weird])
        self.assertEqual(result["recorded"], 1)
        rows = self.store.list_life_events(save_id="save-a")
        self.assertTrue(rows[0]["event_id"].startswith("event-"))


if __name__ == "__main__":
    unittest.main()
