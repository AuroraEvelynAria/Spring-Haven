"""ADR-012:PAD 心境基线测试。

覆盖:v9 迁移演练 / EWMA+clamp / 连续稳态衰减 / state_events 审计 /
mood_words 定性映射(无数字纪律) / prompt 注入与向后兼容 / organizer 解析。
"""

from __future__ import annotations

import asyncio
import sqlite3
import tempfile
import unittest
from pathlib import Path

from spring_haven_core.memory import (
    SCHEMA_VERSION,
    HeartloomStore,
    MOOD_DELTA_LIMIT,
    MOOD_EWMA_ALPHA,
)
from spring_haven_core.organizer import HeartloomOrganizer
from spring_haven_core.prompting import PromptComposer, mood_words
from spring_haven_core.roles import DEFAULT_MOOD_HOME, RoleDefinition, RoleRegistry
from tests.test_entity_claims import META_ONLY_SCHEMA


class MoodMigrationTests(unittest.TestCase):
    """v8 档升级演练:v9 纯新增表,executescript 直建,版本戳 + pre-v9 备份。"""

    def test_v9_upgrade_creates_tables_version_and_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "v9.sqlite3"
            conn = sqlite3.connect(path)
            conn.executescript(META_ONLY_SCHEMA)
            conn.execute(
                "INSERT INTO heartloom_meta (key, value) VALUES ('schema_version', '8')"
            )
            conn.commit()
            conn.close()
            store = HeartloomStore(path, ["ling"])
            try:
                tables = {
                    str(row[0])
                    for row in store._connection.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    )
                }
                self.assertIn("mood_baseline", tables)
                version = store._connection.execute(
                    "SELECT value FROM heartloom_meta WHERE key = 'schema_version'"
                ).fetchone()[0]
                self.assertEqual(str(version), str(SCHEMA_VERSION))
                self.assertTrue(Path(str(path) + ".pre-v9.backup").is_file())
            finally:
                store.close()


class MoodDynamicsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "mood.sqlite3", ["ling"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def _advance_world_days(self, days: float) -> None:
        with self.store._lock, self.store._connection:
            self.store._connection.execute(
                "UPDATE journey_clock SET world_value = world_value + ?, anchor_real = ? "
                "WHERE save_id = 's'",
                (days, __import__("time").time()),
            )

    def test_default_mood_is_home(self):
        mood = self.store.current_mood("s", "ling")
        self.assertEqual(mood["pleasure"], DEFAULT_MOOD_HOME[0])
        self.assertEqual(mood["arousal"], DEFAULT_MOOD_HOME[1])
        self.assertEqual(mood["dominance"], DEFAULT_MOOD_HOME[2])

    def test_apply_mood_delta_ewma_and_clamp(self):
        home = (0.0, -0.1, 0.05)
        merged = self.store.apply_mood_delta("s", "ling", {"p": 5.0, "a": 0.0, "d": 0.0}, home=home)
        # 单维 clamp ±0.3,EWMA α=0.12
        self.assertAlmostEqual(merged["pleasure"], 0.0 * (1 - MOOD_EWMA_ALPHA) + MOOD_DELTA_LIMIT * MOOD_EWMA_ALPHA)
        merged2 = self.store.apply_mood_delta("s", "ling", {"p": -5.0, "a": 0.0, "d": 0.0}, home=home)
        self.assertAlmostEqual(
            merged2["pleasure"],
            merged["pleasure"] * (1 - MOOD_EWMA_ALPHA) + (-MOOD_DELTA_LIMIT) * MOOD_EWMA_ALPHA,
        )
        self.assertLess(merged2["pleasure"], merged["pleasure"])

    def test_continuous_homeostasis_decay(self):
        home = (0.0, -0.1, 0.05)
        self.store.apply_mood_delta("s", "ling", {"p": 0.3, "a": 0.3, "d": 0.3}, home=home)
        boosted = self.store.current_mood("s", "ling", home=home)
        self.assertGreater(boosted["pleasure"], 0.0)
        # 世界时间推进 10 天 → 向 home 收敛(0.9^10 ≈ 0.349)
        self._advance_world_days(10.0)
        decayed = self.store.current_mood("s", "ling", home=home)
        self.assertLess(decayed["pleasure"], boosted["pleasure"])
        self.assertGreater(decayed["pleasure"], home[0])
        expected = home[0] + (boosted["pleasure"] - home[0]) * (0.9 ** 10)
        self.assertAlmostEqual(decayed["pleasure"], expected, places=6)

    def test_mood_audit_in_state_events(self):
        self.store.apply_mood_delta("s", "ling", {"p": 0.2, "a": -0.1, "d": 0.0})
        rows = self.store._connection.execute(
            "SELECT kind, delta_json FROM state_events WHERE save_id = 's' AND kind = 'mood'"
        ).fetchall()
        self.assertEqual(len(rows), 1)
        self.assertIn('"pleasure"', str(rows[0]["delta_json"]))

    def test_invalid_delta_components_are_zero(self):
        merged = self.store.apply_mood_delta("s", "ling", {"p": "abc", "a": None, "d": [1]})
        # 全零 delta 经 EWMA 把基线向 0 收敛(0.88×home)
        self.assertAlmostEqual(merged["pleasure"], 0.0)
        self.assertAlmostEqual(merged["arousal"], DEFAULT_MOOD_HOME[1] * (1 - MOOD_EWMA_ALPHA))
        self.assertAlmostEqual(merged["dominance"], DEFAULT_MOOD_HOME[2] * (1 - MOOD_EWMA_ALPHA))


class MoodResponsePayloadTests(unittest.TestCase):
    """ADR-012 D3:chat 响应携带 mood(定性词 + 三维浮点),供 Godot 消费。"""

    def test_chat_response_carries_mood(self):
        from spring_haven_core.provider import ProviderReply
        from spring_haven_core.service import CompanionService

        class _StubProvider:
            async def complete(self, system_prompt, messages):
                return ProviderReply(text="喵。", finish_reason="stop")

        roles = RoleRegistry(
            {"ling": RoleDefinition("ling", "小玲", "春日 铃音", ("小玲",), "你是小玲。")}
        )
        store = HeartloomStore(":memory:", ["ling"])
        try:
            # 多轮累积越过 0.15 中性带(单轮 EWMA 仅 +0.036,按设计不出词)
            for _ in range(10):
                store.apply_mood_delta("s", "ling", {"p": 0.3, "a": 0.0, "d": 0.0})
            service = CompanionService(
                roles, _StubProvider(), store, memory_organizer_enabled=False
            )
            result = asyncio.run(
                service.chat(
                    {
                        "request_id": "mood-1",
                        "role_id": "ling",
                        "save_id": "s",
                        "text": "早安",
                        "history": [],
                        "event_type": "chat",
                        "state": {},
                    }
                )
            )
            mood = result.get("mood")
            self.assertIsInstance(mood, dict)
            self.assertIn("pleasure", mood)
            self.assertIn("arousal", mood)
            self.assertIn("dominance", mood)
            self.assertTrue(str(mood.get("words", "")))
        finally:
            service.close()
            store.close()


class MoodQualitativeTests(unittest.TestCase):
    def test_mood_words_bands(self):
        self.assertIn("明亮", mood_words({"pleasure": 0.7, "arousal": 0.6, "dominance": 0.2}))
        self.assertIn("阴郁", mood_words({"pleasure": -0.8, "arousal": -0.6, "dominance": -0.7}))
        self.assertIn("惶惑", mood_words({"pleasure": 0.0, "arousal": 0.0, "dominance": -0.6}))
        self.assertIn("躁动", mood_words({"pleasure": 0.0, "arousal": 0.7, "dominance": 0.0}))

    def test_mood_words_flat_or_invalid_is_empty(self):
        self.assertEqual(mood_words({"pleasure": 0.05, "arousal": -0.05, "dominance": 0.1}), "")
        self.assertEqual(mood_words(None), "")
        self.assertEqual(mood_words({"pleasure": "x"}), "")

    def test_mood_words_never_contains_digits(self):
        text = mood_words({"pleasure": -0.9, "arousal": 0.9, "dominance": -0.9})
        self.assertTrue(text)
        self.assertFalse(any(ch.isdigit() for ch in text))

    def test_messages_include_mood_words_in_runtime_block(self):
        roles = RoleRegistry(
            {"ling": RoleDefinition("ling", "小玲", "春日 铃音", ("小玲",), "你是小玲。")}
        )
        composer = PromptComposer(roles)
        role = roles.get("ling")
        messages = composer.messages(
            role, "早安", [], {}, mood={"pleasure": -0.8, "arousal": -0.6, "dominance": -0.2}
        )
        last = messages[-1]["content"]
        self.assertIn('"mood"', last)
        self.assertIn("阴郁", last)  # -0.8 命中最深带
        self.assertFalse(any(ch.isdigit() for ch in last.split("mood")[1][:40]))
        # 中性心境不占位
        messages_flat = composer.messages(
            role, "早安", [], {}, mood={"pleasure": 0.0, "arousal": 0.0, "dominance": 0.0}
        )
        self.assertNotIn('"mood"', messages_flat[-1]["content"])


class _ScriptedOrganizerProvider:
    def __init__(self, payload: str):
        self.payload = payload

    async def complete(self, system_prompt, messages):
        from spring_haven_core.provider import ProviderReply

        return ProviderReply(text=self.payload, finish_reason="stop")


class OrganizerMoodDeltaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self.temp.name) / "org.sqlite3", ["ling"])

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_parse_returns_mood_delta(self):
        memories, claims, mood = HeartloomOrganizer._parse(
            '{"memories":[],"claims":[],"mood_delta":{"p":-0.2,"a":0.1,"d":0.0}}'
        )
        self.assertEqual(mood, {"p": -0.2, "a": 0.1, "d": 0.0})
        _, _, empty = HeartloomOrganizer._parse('{"memories":[],"claims":[]}')
        self.assertEqual(empty, {})

    def test_organize_applies_mood_delta(self):
        role = RoleDefinition(
            "ling", "小玲", "春日 铃音", ("小玲",), "你是小玲。", mood_home=(0.0, -0.1, 0.05)
        )
        provider = _ScriptedOrganizerProvider(
            '{"memories":[{"kind":"episodic","title":"被夸了","content":"主人夸了小玲",'
            '"trigger_terms":["夸"],"importance":0.5,"confidence":0.8}],'
            '"claims":[],"mood_delta":{"p":0.3,"a":0.1,"d":0.1}}'
        )
        organizer = HeartloomOrganizer(provider, self.store)
        asyncio.run(
            organizer.organize(
                save_id="s",
                role=role,
                request_id="req-1",
                user_text="你今天真棒",
                reply_text="喵~",
                fallback_memory_id="",
            )
        )
        mood = self.store.current_mood("s", "ling", home=role.mood_home)
        self.assertGreater(mood["pleasure"], 0.0)

    def test_organize_without_mood_delta_still_works(self):
        role = RoleDefinition("ling", "小玲", "春日 铃音", ("小玲",), "你是小玲。")
        provider = _ScriptedOrganizerProvider(
            '{"memories":[{"kind":"episodic","title":"日常","content":"散步",'
            '"trigger_terms":["散步"],"importance":0.4,"confidence":0.8}],"claims":[]}'
        )
        organizer = HeartloomOrganizer(provider, self.store)
        result = asyncio.run(
            organizer.organize(
                save_id="s",
                role=role,
                request_id="req-2",
                user_text="我们去散步吧",
                reply_text="好呀",
                fallback_memory_id="",
            )
        )
        self.assertEqual(len(result), 1)
        mood = self.store.current_mood("s", "ling", home=role.mood_home)
        self.assertEqual(mood["pleasure"], role.mood_home[0])


if __name__ == "__main__":
    unittest.main()
