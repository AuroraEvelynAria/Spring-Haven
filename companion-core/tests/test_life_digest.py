"""Tests for daily digest (Phase 1): life_events -> Heartloom memories."""

import json
import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.memory import HeartloomStore
from spring_haven_core.roles import RoleRegistry
from spring_haven_core.service import CompanionService


def _registry(root: Path) -> RoleRegistry:
    personas = root / "personas"
    personas.mkdir()
    (personas / "ling.md").write_text("你是小玲。", encoding="utf-8")
    (personas / "nai.md").write_text("你是小奈。", encoding="utf-8")
    roles_path = root / "roles.json"
    roles_path.write_text(
        json.dumps(
            {
                "roles": [
                    {
                        "role_id": "ling",
                        "display_name": "小玲",
                        "full_name": "春日铃音",
                        "aliases": ["小玲"],
                        "prompt_file": "personas/ling.md",
                    },
                    {
                        "role_id": "nai",
                        "display_name": "小奈",
                        "full_name": "白濑雪奈",
                        "aliases": ["小奈"],
                        "prompt_file": "personas/nai.md",
                    },
                ]
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    return RoleRegistry.load(roles_path)


class _FakeProvider:
    """Provider that returns a fixed digest JSON; can be switched to failing."""

    def __init__(self) -> None:
        self.fail = False

    async def complete(self, system_prompt, messages):
        if self.fail:
            raise RuntimeError("provider down")
        return _Reply(
            '{"memories":[{"title":"窗边的一天","content":"今天在窗边看了很久的书，'
            '阳光很好。","importance":0.6,"confidence":0.9}]}'
        )


class _Reply:
    def __init__(self, text: str) -> None:
        self.text = text
        self.input_tokens = 10
        self.output_tokens = 20
        self.cached_tokens = 0


class DigestStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self._tmp.name) / "heartloom.sqlite3", ["ling", "nai"])

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def _record_events(self, save_id: str, role: str, day_unix: int) -> None:
        self.store.record_life_events(
            save_id=save_id,
            events=[
                {
                    "event_id": f"dailyplan-{role}-read-{day_unix}",
                    "role_id": role,
                    "action": "read_by_window",
                    "description": "窗边看书",
                    "occurred_at_unix": day_unix + 36_000,
                },
                {
                    "event_id": f"dailyplan-{role}-cook-{day_unix}",
                    "role_id": role,
                    "action": "cook_dinner",
                    "description": "做了晚饭",
                    "occurred_at_unix": day_unix + 65_000,
                },
            ],
        )

    def test_digest_state_idempotent(self) -> None:
        self.assertFalse(self.store.digest_completed(save_id="s", role_id="ling", day_key="2026-08-01"))
        self.store.mark_digest_completed(save_id="s", role_id="ling", day_key="2026-08-01", memory_id="hm_x")
        self.assertTrue(self.store.digest_completed(save_id="s", role_id="ling", day_key="2026-08-01"))
        self.store.mark_digest_completed(save_id="s", role_id="ling", day_key="2026-08-01", memory_id="hm_y")
        self.assertTrue(self.store.digest_completed(save_id="s", role_id="ling", day_key="2026-08-01"))

    def test_digest_day_events_window(self) -> None:
        day_start = int(time.mktime((2026, 8, 1, 0, 0, 0, -1, -1, -1)))
        self._record_events("s", "ling", day_start)
        events = self.store.digest_day_events(
            save_id="s", role_id="ling",
            day_start_unix=day_start, day_end_unix=day_start + 86_400,
        )
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["action"], "read_by_window")
        self.store.record_life_events(
            save_id="s",
            events=[{
                "event_id": "dailyplan-ling-late-999",
                "role_id": "ling",
                "action": "night_patrol",
                "description": "夜巡",
                "occurred_at_unix": day_start + 100_000,
            }],
        )
        events = self.store.digest_day_events(
            save_id="s", role_id="ling",
            day_start_unix=day_start, day_end_unix=day_start + 86_400,
        )
        self.assertEqual(len(events), 2)

    def test_digest_pending_saves_filters_fresh_and_digested(self) -> None:
        now = int(time.time())
        day_start = int(time.mktime((2026, 1, 5, 0, 0, 0, -1, -1, -1)))
        self._record_events("s-old", "ling", day_start)
        self.store.record_life_events(
            save_id="s-fresh",
            events=[{
                "event_id": "fresh-1",
                "role_id": "ling",
                "action": "sunbathe",
                "description": "晒太阳",
                "occurred_at_unix": now - 3_600,
            }],
        )
        pending = self.store.digest_pending_saves(now)
        pending_keys = {(p["save_id"], p["role_id"], p["day_key"]) for p in pending}
        self.assertIn(("s-old", "ling", "2026-01-05"), pending_keys)
        self.assertNotIn("s-fresh", {p["save_id"] for p in pending})
        self.store.mark_digest_completed(save_id="s-old", role_id="ling", day_key="2026-01-05")
        pending = self.store.digest_pending_saves(now)
        self.assertNotIn(("s-old", "ling", "2026-01-05"), {(p["save_id"], p["role_id"], p["day_key"]) for p in pending})

    def test_digest_pending_waits_until_the_whole_day_is_old(self) -> None:
        now = int(time.mktime((2026, 8, 1, 20, 0, 0, -1, -1, -1)))
        day_start = int(time.mktime((2026, 8, 1, 0, 0, 0, -1, -1, -1)))
        self.store.record_life_events(
            save_id="partial",
            events=[
                {
                    "event_id": "partial-morning",
                    "role_id": "ling",
                    "action": "read_by_window",
                    "description": "早上看书",
                    "occurred_at_unix": day_start + 7 * 3600,
                },
                {
                    "event_id": "partial-evening",
                    "role_id": "ling",
                    "action": "cook_dinner",
                    "description": "晚饭做菜",
                    "occurred_at_unix": day_start + 19 * 3600,
                },
            ],
        )
        pending = self.store.digest_pending_saves(now)
        self.assertNotIn("partial", {item["save_id"] for item in pending})
        pending = self.store.digest_pending_saves(now + 13 * 3600)
        self.assertIn(("partial", "ling", "2026-08-01"), {
            (item["save_id"], item["role_id"], item["day_key"])
            for item in pending
        })


class DigestServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.store = HeartloomStore(self.root / "heartloom.sqlite3", ["ling", "nai"])
        self.provider = _FakeProvider()
        self.service = CompanionService(_registry(self.root), self.provider, self.store)

    async def asyncTearDown(self) -> None:
        self.service.close()
        self._tmp.cleanup()

    async def _seed_old_day(self, save_id: str, role: str) -> str:
        day_start = int(time.mktime((2026, 2, 10, 0, 0, 0, -1, -1, -1)))
        self.store.record_life_events(
            save_id=save_id,
            events=[
                {
                    "event_id": f"dailyplan-{role}-a-{day_start}",
                    "role_id": role,
                    "action": "read_by_window",
                    "description": "窗边看书",
                    "occurred_at_unix": day_start + 10_000,
                },
                {
                    "event_id": f"dailyplan-{role}-b-{day_start}",
                    "role_id": role,
                    "action": "cook_dinner",
                    "description": "做了晚饭",
                    "occurred_at_unix": day_start + 60_000,
                },
            ],
        )
        return "2026-02-10"

    async def test_digest_with_provider_creates_memory(self) -> None:
        await self._seed_old_day("s", "ling")
        result = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result["digested"], 1, result)
        memories = self.store.list_memories(save_id="s", role_id="ling")
        self.assertEqual(len(memories), 1)
        self.assertEqual(memories[0]["source"], "daily_digest")
        self.assertEqual(memories[0]["title"], "窗边的一天")
        result = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result["digested"], 0)
        self.assertEqual(len(self.store.list_memories(save_id="s", role_id="ling")), 1)

    async def test_digest_fallback_when_provider_fails(self) -> None:
        self.provider.fail = True
        await self._seed_old_day("s", "ling")
        result = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result["digested"], 1, result)
        memories = self.store.list_memories(save_id="s", role_id="ling")
        self.assertEqual(len(memories), 1)
        self.assertIn("窗边看书", memories[0]["content"])
        self.assertIn("做了晚饭", memories[0]["content"])

    async def test_digest_skips_when_no_events(self) -> None:
        result = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result, {"pending": 0, "digested": 0, "skipped": 0, "failed": 0})


if __name__ == "__main__":
    unittest.main()
