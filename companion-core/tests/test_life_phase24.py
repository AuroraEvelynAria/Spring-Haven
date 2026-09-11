"""Tests for Phase 2 (target_role) and Phase 4 (milestones + weekly insight)."""

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


class _Reply:
    def __init__(self, text: str) -> None:
        self.text = text
        self.input_tokens = 10
        self.output_tokens = 20
        self.cached_tokens = 0


class _FakeProvider:
    def __init__(self) -> None:
        self.fail = False
        self.calls = 0

    async def complete(self, system_prompt, messages):
        self.calls += 1
        if self.fail:
            raise RuntimeError("provider down")
        text = str(messages[-1]["content"])
        if "周次" in text or "一周记忆摘要" in text:
            return _Reply('{"title":"温柔的一周","content":"这一周大多在窗边看书，和小奈一起吃了晚饭。","importance":0.6}')
        return _Reply(
            '{"memories":[{"title":"窗边的一天","content":"今天在窗边看了很久的书。","importance":0.6,"confidence":0.9}]}'
        )


class TargetRoleTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self._tmp.name) / "heartloom.sqlite3", ["ling", "nai"])

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def test_record_event_with_target_role(self) -> None:
        now = int(time.time())
        self.store.record_life_events(
            save_id="s",
            events=[{
                "event_id": "dailyplan-ling-quiet_companion-20260802-1900",
                "role_id": "ling",
                "target_role": "nai",
                "action": "quiet_companion",
                "description": "小玲靠近小奈安静陪了她一会儿",
                "occurred_at_unix": now,
            }],
        )
        rows = self.store.list_life_events(save_id="s")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["target_role"], "nai")

    def test_invalid_target_role_is_cleared(self) -> None:
        now = int(time.time())
        self.store.record_life_events(
            save_id="s",
            events=[{
                "event_id": "evt-bad-target",
                "role_id": "ling",
                "target_role": "ghost",
                "action": "read_by_window",
                "description": "看书",
                "occurred_at_unix": now,
            }],
        )
        rows = self.store.list_life_events(save_id="s")
        self.assertEqual(rows[0]["target_role"], "")

    def test_milestone_roundtrip(self) -> None:
        self.assertTrue(self.store.mark_milestone(save_id="s", milestone_id="first_digest"))
        self.assertFalse(self.store.mark_milestone(save_id="s", milestone_id="first_digest"))
        unlocked = self.store.unlocked_milestones("s")
        self.assertIn("first_digest", unlocked)

    def test_memory_count_and_recent_digests(self) -> None:
        now = int(time.time())
        self.store.put_memory(
            {"save_id": "s", "scope_role_id": "ling", "kind": "episodic",
             "title": "a", "content": "第一条"},
            source="daily_digest",
        )
        self.store.put_memory(
            {"save_id": "s", "scope_role_id": "ling", "kind": "episodic",
             "title": "b", "content": "第二条"},
            source="daily_digest",
        )
        self.store.put_memory(
            {"save_id": "s", "scope_role_id": "ling", "kind": "episodic",
             "title": "c", "content": "手动"},
            source="manual",
        )
        self.assertEqual(self.store.memory_count("s"), 3)
        recent = self.store.recent_digest_memories(save_id="s", since_unix=now - 10)
        self.assertEqual(len(recent), 2)


class MilestoneServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.store = HeartloomStore(self.root / "heartloom.sqlite3", ["ling", "nai"])
        self.provider = _FakeProvider()
        self.service = CompanionService(_registry(self.root), self.provider, self.store)
        # 注册 life_state 使 save 进入 milestone 范围
        self.store.sync_life_state(
            save_id="ms-save", selected_role_id="ling",
            snapshot={"roles": {}}, last_user_activity_at=int(time.time()),
            next_event_at=0, now=int(time.time()),
        )

    async def asyncTearDown(self) -> None:
        self.service.close()
        self._tmp.cleanup()

    async def test_milestone_unlocks_first_digest(self) -> None:
        now = int(time.time())
        self.store.put_memory(
            {"save_id": "ms-save", "scope_role_id": "ling", "kind": "episodic",
             "title": "digest", "content": "第一天"},
            source="daily_digest",
        )
        result = await self.service.run_due_milestones(now=now)
        self.assertEqual(result["unlocked"], 1, result)
        unlocked = self.store.unlocked_milestones("ms-save")
        self.assertIn("first_digest", unlocked)
        # 幂等：再跑不重复解锁
        result = await self.service.run_due_milestones(now=now)
        self.assertEqual(result["unlocked"], 0)
        # 里程碑记忆是 always_active relationship
        memories = self.store.list_memories(save_id="ms-save")
        milestone_memories = [m for m in memories if m["source"] == "milestone"]
        self.assertEqual(len(milestone_memories), 1)
        self.assertTrue(milestone_memories[0]["always_active"])
        self.assertEqual(milestone_memories[0]["kind"], "relationship")

    async def test_weekly_insight_creates_identity_memory(self) -> None:
        now = int(time.time())
        for i in range(3):
            self.store.put_memory(
                {"save_id": "ms-save", "scope_role_id": "ling", "kind": "episodic",
                 "title": f"第{i}天", "content": f"第{i}天的生活"},
                source="daily_digest",
            )
        result = await self.service.run_due_weekly_insights(now=now)
        self.assertEqual(result["created"], 1, result)
        memories = self.store.list_memories(save_id="ms-save")
        weekly = [m for m in memories if m["source"] == "weekly_insight"]
        self.assertEqual(len(weekly), 1)
        self.assertEqual(weekly[0]["kind"], "identity")
        self.assertEqual(weekly[0]["title"], "温柔的一周")
        calls_after_first_run = self.provider.calls
        # 幂等：同周不重复创建，也不重复调用模型
        result = await self.service.run_due_weekly_insights(now=now)
        self.assertEqual(result["created"], 0)
        self.assertEqual(result["skipped"], 1)
        self.assertEqual(self.provider.calls, calls_after_first_run)
        memories = self.store.list_memories(save_id="ms-save")
        weekly = [m for m in memories if m["source"] == "weekly_insight"]
        self.assertEqual(len(weekly), 1)

    async def test_weekly_fallback_when_provider_fails(self) -> None:
        self.provider.fail = True
        now = int(time.time())
        self.store.put_memory(
            {"save_id": "ms-save", "scope_role_id": "ling", "kind": "episodic",
             "title": "窗边的一天", "content": "看书"},
            source="daily_digest",
        )
        result = await self.service.run_due_weekly_insights(now=now)
        self.assertEqual(result["created"], 1)
        memories = self.store.list_memories(save_id="ms-save")
        weekly = [m for m in memories if m["source"] == "weekly_insight"]
        self.assertIn("窗边的一天", weekly[0]["content"])


if __name__ == "__main__":
    unittest.main()
