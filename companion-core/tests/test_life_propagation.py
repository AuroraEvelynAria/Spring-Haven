"""Tests for the two-character memory propagation chain (heard_from)."""

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

    async def complete(self, system_prompt, messages):
        if self.fail:
            raise RuntimeError("provider down")
        content = str(messages[-1]["content"])
        if "讲述的事" in content:
            return _Reply(
                '{"title":"小玲说的事","content":"小玲今天告诉我，她在窗边晒了很久的太阳。","importance":0.6}'
            )
        return _Reply(
            '{"memories":[{"title":"窗边的一天","content":"今天在窗边看了很久的书。","importance":0.8,"confidence":0.9}]}'
        )


class PropagationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.store = HeartloomStore(self.root / "heartloom.sqlite3", ["ling", "nai"])
        self.provider = _FakeProvider()
        self.service = CompanionService(_registry(self.root), self.provider, self.store)

    async def asyncTearDown(self) -> None:
        self.service.close()
        self._tmp.cleanup()

    async def _seed(self, save_id: str, role: str, importance: float) -> None:
        now = int(time.time())
        day_start = int(time.mktime((2026, 2, 10, 0, 0, 0, -1, -1, -1)))
        self.store.record_life_events(
            save_id=save_id,
            events=[{
                "event_id": f"dailyplan-{role}-a-{now}",
                "role_id": role,
                "action": "sunbathe",
                "description": "在窗边晒太阳，尾巴放松下来",
                "occurred_at_unix": day_start + 1000,
            }],
        )

    async def test_high_importance_digest_propagates_to_other_role(self) -> None:
        await self._seed("s", "ling", 0.8)
        result = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result["digested"], 2, result)  # 1 digest + 1 propagation
        # 小奈有"听说"记忆
        nai_memories = self.store.list_memories(save_id="s", role_id="nai")
        heard = [m for m in nai_memories if m["source"] == "heard_from_ling"]
        self.assertEqual(len(heard), 1, nai_memories)
        self.assertEqual(heard[0]["scope_role_id"], "nai")
        self.assertIn("小玲", heard[0]["content"])
        # 幂等：再跑不重复传播
        result2 = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result2["digested"], 0)
        nai_memories2 = self.store.list_memories(save_id="s", role_id="nai")
        heard2 = [m for m in nai_memories2 if m["source"] == "heard_from_ling"]
        self.assertEqual(len(heard2), 1)

    async def test_low_importance_digest_does_not_propagate(self) -> None:
        # 低 importance 记忆不传播（provider 返回 0.8 会传播——用 fallback 测低值）
        self.provider.fail = True  # 触发 fallback（importance 0.5）
        await self._seed("s", "ling", 0.5)
        result = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result["digested"], 1, result)  # 只有 digest，无传播
        nai_memories = self.store.list_memories(save_id="s", role_id="nai")
        heard = [m for m in nai_memories if m["source"] == "heard_from_ling"]
        self.assertEqual(len(heard), 0)

    async def test_propagation_fallback_when_provider_fails(self) -> None:
        # 高 importance 但 provider 失败 -> 回退拼接
        class _FailAfterDigest:
            calls = 0

            async def complete(self, system_prompt, messages):
                _FailAfterDigest.calls += 1
                if _FailAfterDigest.calls <= 1:
                    return _Reply(
                        '{"memories":[{"title":"窗边的一天","content":"今天在窗边看了很久的书。","importance":0.9,"confidence":0.9}]}'
                    )
                raise RuntimeError("propagation provider down")

        self.service.provider = _FailAfterDigest()  # type: ignore[assignment]
        await self._seed("s", "ling", 0.9)
        result = await self.service.run_due_life_digests(now=int(time.time()))
        self.assertEqual(result["digested"], 2, result)
        nai_memories = self.store.list_memories(save_id="s", role_id="nai")
        heard = [m for m in nai_memories if m["source"] == "heard_from_ling"]
        self.assertEqual(len(heard), 1)
        self.assertIn("听说了", heard[0]["content"])


if __name__ == "__main__":
    unittest.main()
