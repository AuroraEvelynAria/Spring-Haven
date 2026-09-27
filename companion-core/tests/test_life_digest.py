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

    def _anchor_clock(self, save_id: str, *, anchor_real: int, world_value: float) -> None:
        """把世界时钟锚到测试时刻:anchor_real 时刻 == world_value 世界日。"""
        self.store._connection.execute(
            "INSERT INTO journey_clock(save_id, anchor_real, world_value, rate) "
            "VALUES (?, ?, ?, 1.0) "
            "ON CONFLICT(save_id) DO UPDATE SET "
            "anchor_real = excluded.anchor_real, world_value = excluded.world_value, rate = 1.0",
            (save_id, anchor_real, world_value),
        )
        self.store._connection.commit()

    def test_digest_state_idempotent(self) -> None:
        self.assertFalse(self.store.digest_completed(save_id="s", role_id="ling", day_key="w0000"))
        self.store.mark_digest_completed(save_id="s", role_id="ling", day_key="w0000", memory_id="hm_x")
        self.assertTrue(self.store.digest_completed(save_id="s", role_id="ling", day_key="w0000"))
        self.store.mark_digest_completed(save_id="s", role_id="ling", day_key="w0000", memory_id="hm_y")
        self.assertTrue(self.store.digest_completed(save_id="s", role_id="ling", day_key="w0000"))

    def test_digest_day_events_world_day_window(self) -> None:
        day_start = int(time.mktime((2026, 8, 1, 0, 0, 0, -1, -1, -1)))
        # 锚定:day_start 时刻 == 世界第 0 天开始(rate=1 → 世界日与现实时长一致)
        self._anchor_clock("s", anchor_real=day_start, world_value=0.0)
        self._record_events("s", "ling", day_start)
        events = self.store.digest_day_events(save_id="s", role_id="ling", world_day=0)
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
        # 100_000s ≈ 1.16 世界日 → 落在第 1 天;第 0 天窗口不受影响
        self.assertEqual(len(self.store.digest_day_events(save_id="s", role_id="ling", world_day=0)), 2)
        self.assertEqual(len(self.store.digest_day_events(save_id="s", role_id="ling", world_day=1)), 1)

    def test_digest_pending_saves_filters_fresh_and_digested(self) -> None:
        now = int(time.time())
        day_start = int(time.mktime((2026, 1, 5, 0, 0, 0, -1, -1, -1)))
        # s-old:锚在 2026-01-05 → 世界日 0 的事件早已「过完」(世界时钟随现实推进)
        self._anchor_clock("s-old", anchor_real=day_start, world_value=0.0)
        self._record_events("s-old", "ling", day_start)
        # s-fresh:锚在现在,事件就发生在当前世界日内
        self._anchor_clock("s-fresh", anchor_real=now, world_value=100.5)
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
        self.assertIn(("s-old", "ling", "w0000"), pending_keys)
        self.assertNotIn("s-fresh", {p["save_id"] for p in pending})
        self.store.mark_digest_completed(save_id="s-old", role_id="ling", day_key="w0000")
        pending = self.store.digest_pending_saves(now)
        self.assertNotIn(("s-old", "ling", "w0000"), {(p["save_id"], p["role_id"], p["day_key"]) for p in pending})

    def test_digest_pending_waits_until_the_world_day_is_over(self) -> None:
        now = int(time.time())
        # 世界时钟锚在当前世界日的正中:1 小时前的事件仍属「今天」
        self._anchor_clock("partial", anchor_real=now, world_value=100.5)
        self.store.record_life_events(
            save_id="partial",
            events=[
                {
                    "event_id": "partial-morning",
                    "role_id": "ling",
                    "action": "read_by_window",
                    "description": "早上看书",
                    "occurred_at_unix": now - 7 * 3600,
                },
                {
                    "event_id": "partial-evening",
                    "role_id": "ling",
                    "action": "cook_dinner",
                    "description": "晚饭做菜",
                    "occurred_at_unix": now - 1 * 3600,
                },
            ],
        )
        pending = self.store.digest_pending_saves(now)
        self.assertNotIn("partial", {item["save_id"] for item in pending})
        # 世界时间推进一天(rate=1 下等价于锚点回退一天) → 该世界日结束,进入待 digest
        self.store._connection.execute(
            "UPDATE journey_clock SET world_value = world_value + 1.0 WHERE save_id = 'partial'"
        )
        self.store._connection.commit()
        pending = self.store.digest_pending_saves(now)
        self.assertIn(("partial", "ling", "w0100"), {
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
        # 锚在 2026-02-10(世界第 0 天);世界时钟随现实推进,该天早已结束
        self.store._connection.execute(
            "INSERT INTO journey_clock(save_id, anchor_real, world_value, rate) "
            "VALUES (?, ?, 0.0, 1.0) "
            "ON CONFLICT(save_id) DO UPDATE SET "
            "anchor_real = excluded.anchor_real, world_value = 0.0, rate = 1.0",
            (save_id, day_start),
        )
        self.store._connection.commit()
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
        return "w0000"

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
