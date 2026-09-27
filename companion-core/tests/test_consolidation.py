"""ADR-013:夜织 / 周织归档清扫 / 季织测试。"""

from __future__ import annotations

import asyncio
import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.memory import HeartloomStore
from spring_haven_core.roles import RoleDefinition, RoleRegistry
from spring_haven_core.service import CompanionService


class _Reply:
    def __init__(self, text: str) -> None:
        self.text = text


class _FakeProvider:
    """按 prompt 关键词分流的桩:夜织/季织/周织各自返回固定 JSON。"""

    def __init__(self) -> None:
        self.night_calls = 0
        self.season_calls = 0
        self.week_calls = 0
        self.night_payloads: list[str] = []
        self.fail_night = False

    async def complete(self, system_prompt, messages):
        text = str(messages[-1]["content"])
        if "夜织" in system_prompt:
            self.night_calls += 1
            self.night_payloads.append(text)
            if self.fail_night:
                raise RuntimeError("nightweave provider down")
            return _Reply(
                '{"memories":[{"title":"沙发上的一天","content":"这一整天都在客厅度过：'
                '主人聊了稀土新闻，院子里的青菜也收拾了。","trigger_terms":["客厅","青菜"],'
                '"importance":0.9,"valence":0.2}]}'
            )
        if "季织" in system_prompt:
            self.season_calls += 1
            return _Reply(
                '{"memories":[{"title":"最初的季节","content":"这一季从稀土新闻与青菜开始，'
                '生活慢慢安稳下来。","valence":0.3}]}'
            )
        if "周次" in text or "一周记忆摘要" in text:
            self.week_calls += 1
            return _Reply(
                '{"title":"平静的一周","content":"这一周大多在整理院子。","importance":0.6}'
            )
        raise AssertionError(f"未预期的 provider 调用: {text[:60]}")


def _roles() -> RoleRegistry:
    return RoleRegistry(
        {"ling": RoleDefinition("ling", "小玲", "春日 铃音", ("小玲",), "你是小玲。")}
    )


class ConsolidationTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self._tmp.name) / "weave.sqlite3", ["ling"])
        self.provider = _FakeProvider()
        self.service = CompanionService(
            _roles(),
            self.provider,
            self.store,
            memory_organizer_enabled=False,
        )

    async def asyncTearDown(self) -> None:
        self.service.close()
        self.store.close()
        self._tmp.cleanup()

    def _advance_world_days(self, days: float) -> None:
        with self.store._lock, self.store._connection:
            self.store._connection.execute(
                "UPDATE journey_clock SET world_value = world_value + ?, anchor_real = ? "
                "WHERE save_id = 's'",
                (days, time.time()),
            )

    def _seed_memories(self, count: int, prefix: str = "seed") -> list[str]:
        ids = []
        for index in range(count):
            ids.append(
                str(
                    self.store.put_memory(
                        {
                            "save_id": "s",
                            "scope_role_id": "ling",
                            "kind": "episodic",
                            "title": f"{prefix}{index}",
                            "content": f"{prefix}第{index}条：客厅里的日常小事{index}",
                            "trigger_terms": ["客厅"],
                            "source_event_id": f"{prefix}-{index}",
                        },
                        source="organizer_ling",
                    )["memory_id"]
                )
            )
        return ids

    async def test_nightweave_weaves_closed_day_with_links(self) -> None:
        ids = self._seed_memories(3)
        self._advance_world_days(2.0)
        result = await self.service.run_due_nightly_consolidation()
        self.assertEqual(result["woven"], 1, result)
        memories = self.store.list_memories(save_id="s")
        weaves = [m for m in memories if m["source"] == "consolidation_ling"]
        self.assertEqual(len(weaves), 1)
        weave = weaves[0]
        self.assertEqual(weave["kind"], "semantic")
        self.assertEqual(weave["source_event_id"], "nightly-world-d0000")
        self.assertLessEqual(float(weave["importance"]), 0.65)
        # 关联边:织结节 → 各源记忆,reason=consolidated
        links = self.store._connection.execute(
            "SELECT dst_memory_id FROM memory_links WHERE reason = 'consolidated' "
            "AND link_type = 'association'"
        ).fetchall()
        linked_ids = {str(row["dst_memory_id"]) for row in links}
        self.assertTrue(set(ids).issubset(linked_ids))

    async def test_nightweave_idempotent_per_day(self) -> None:
        self._seed_memories(3)
        self._advance_world_days(2.0)
        first = await self.service.run_due_nightly_consolidation()
        self.assertEqual(first["woven"], 1)
        second = await self.service.run_due_nightly_consolidation()
        self.assertEqual(second["woven"], 0)
        self.assertEqual(self.provider.night_calls, 1)

    async def test_nightweave_skips_unclosed_day_and_small_days(self) -> None:
        self._seed_memories(2)  # 当日未关闭且不足 3 条
        result = await self.service.run_due_nightly_consolidation()
        self.assertEqual(result["woven"], 0)
        self.assertEqual(self.provider.night_calls, 0)
        # 补足 3 条但日未关闭(world_now ≈ 0.x,day 0 需要 ≥1.0)
        self._seed_memories(1, prefix="more")
        result = await self.service.run_due_nightly_consolidation()
        self.assertEqual(result["woven"], 0)

    async def test_nightweave_provider_failure_leaves_day_retryable(self) -> None:
        self._seed_memories(3)
        self._advance_world_days(2.0)
        self.provider.fail_night = True
        result = await self.service.run_due_nightly_consolidation()
        self.assertEqual(result["woven"], 0)
        # 失败后该日仍可重试(未留织结节)
        due = self.store.unconsolidated_world_days("s")
        self.assertEqual(len(due), 1)

    async def test_weekly_sweep_folds_archived_with_audit_links(self) -> None:
        archived_id = self._seed_memories(1, prefix="old")[0]
        self.store.set_memory_lifecycle(archived_id, "archived")
        # weekly 管线以 life_state 注册的存档为枚举口径(与 phase24 测试同姿势)
        self.store.sync_life_state(
            save_id="s",
            selected_role_id="ling",
            snapshot={"roles": {}},
            last_user_activity_at=int(time.time()),
            next_event_at=0,
            now=int(time.time()),
        )
        for index in range(3):
            self.store.put_memory(
                {
                    "save_id": "s",
                    "scope_role_id": "ling",
                    "kind": "episodic",
                    "title": f"第{index}天",
                    "content": f"第{index}天的生活",
                },
                source="daily_digest",
            )
        result = await self.service.run_due_weekly_insights()
        self.assertEqual(result["created"], 1, result)
        links = self.store._connection.execute(
            "SELECT src_memory_id, dst_memory_id FROM memory_links WHERE reason = 'archived_sweep'"
        ).fetchall()
        self.assertEqual(len(links), 1)
        self.assertEqual(str(links[0]["dst_memory_id"]), archived_id)

    async def test_season_weave_weaves_completed_season(self) -> None:
        # 直接落两条 weekly_insight(代表第 0 季的周织产物)
        for tag in ("a", "b"):
            self.store.put_memory(
                {
                    "save_id": "s",
                    "scope_role_id": "ling",
                    "kind": "identity",
                    "title": f"周织{tag}",
                    "content": f"第{tag}周的反思",
                    "source_event_id": f"weekly-world-w000-{tag}",
                },
                source="weekly_insight",
            )
        self._advance_world_days(91.0)  # world_now ≈ 91 → 第 0 季已完结
        result = await self.service.run_due_season_weave()
        self.assertEqual(result["woven"], 1, result)
        memories = self.store.list_memories(save_id="s")
        seasons = [m for m in memories if m["source"] == "season_weave"]
        self.assertEqual(len(seasons), 1)
        season = seasons[0]
        self.assertEqual(season["kind"], "identity")
        self.assertTrue(season["always_active"])
        self.assertEqual(float(season["half_life_days"]), 0.0)
        links = self.store._connection.execute(
            "SELECT dst_memory_id FROM memory_links WHERE reason = 'season_weave' "
            "AND link_type = 'milestone'"
        ).fetchall()
        self.assertEqual(len(links), 2)
        # 哨兵幂等
        again = await self.service.run_due_season_weave()
        self.assertEqual(again["woven"], 0)
        self.assertEqual(self.provider.season_calls, 1)

    async def test_season_weave_skips_incomplete_season(self) -> None:
        self._advance_world_days(45.0)  # 第 0 季尚未完结(45 < 90)
        result = await self.service.run_due_season_weave()
        self.assertEqual(result["woven"], 0)

    async def test_graph_payload_includes_source(self) -> None:
        self._seed_memories(1)
        page = self.store.graph_page(save_id="s", role_id=None, limit=10)
        self.assertIn("source", page["nodes"][0])
        self.assertEqual(str(page["nodes"][0]["source"]), "organizer_ling")


if __name__ == "__main__":
    unittest.main()
