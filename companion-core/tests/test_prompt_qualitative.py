from __future__ import annotations

# #29 验收测试:① 结构断言(runtime 无数值键) ② 数字审计(字段名+数值配对扫描)
# ③ 分桶滞回单元测试。依据 issue #29 的三条验收标准。

import json
import re
import unittest

from spring_haven_core.prompting import (
    RUNTIME_CLOSE,
    RUNTIME_OPEN,
    _BucketHysteresis,
    PromptComposer,
)

try:  # discover 模式可直接导入;单模块直跑时回退包路径
    from test_contract import FakeProvider, make_registry, valid_payload
except ImportError:
    from tests.test_contract import FakeProvider, make_registry, valid_payload

BUCKET_LABELS = {"很高", "偏高", "普通", "偏低", "很低"}
GUARDED_FIELDS = {
    "hunger", "thirst", "stamina", "awake", "urine", "mood",
    "stress", "health", "intimacy", "fertility", "implantation",
}
FIELD_LABELS = ["饥饿", "口渴", "体力", "清醒", "膀胱充盈", "心情", "压力", "好感度"]


class QualitativeStructureTests(unittest.IsolatedAsyncioTestCase):
    """验收①:runtime 块中受控字段不得携带数值。"""

    def setUp(self):
        self.roles = make_registry(_tmp_root("qual-structure"))
        self.provider = FakeProvider()
        self.service = _make_service(self.roles, self.provider)

    async def test_runtime_block_has_no_numeric_guarded_fields(self):
        payload = valid_payload()
        payload["state"]["body_state"] = {
            "protocol": "spring_haven.body_state.v2",
            "role_id": "ling",
            "stats": {"hunger": 72.5, "thirst": 91.2, "mood": 66.0, "urine": 88.8},
            "sensations": {"hunger": "有些饿", "thirst": "有些口渴"},
        }
        payload["state"]["life_lab_event"] = {
            "protocol": "spring_haven.life_lab.social_event.v1",
            "event_id": "lab-1",
            "action": "dine",
            "action_label": "一起用餐",
            "station_id": "dining",
            "actor_role_id": "ling",
            "participant_role_ids": ["ling", "nai"],
            "initiated_by": "user",
            "needs_by_role": {
                "ling": {"hunger": 10.4, "mood": 88.2},
                "nai": {"thirst": 73.6, "stamina": 41.1},
            },
            "visual_summary": "餐桌旁有两套餐具。",
        }
        await self.service.chat(payload)
        user_content = self.provider.calls[0][1][-1]["content"]
        runtime_json = user_content.split(RUNTIME_OPEN, 1)[1].split(RUNTIME_CLOSE, 1)[0]
        runtime = json.loads(runtime_json)
        body_state = runtime.get("body_state", {})
        self.assertNotIn("stats", body_state)
        self.assertIn("state_summary", body_state)
        event = runtime.get("life_lab_event", {})
        for role_id, needs in dict(event.get("needs_by_role", {})).items():
            self.assertTrue(needs, "参与者需求不应为空")
            for key, value in needs.items():
                self.assertIn(key, GUARDED_FIELDS)
                self.assertIsInstance(value, str, f"{role_id}.{key} 仍是数值")
                self.assertIn(value, BUCKET_LABELS)

    async def test_memory_context_drops_numeric_metadata(self):
        payload = valid_payload()
        payload["heartloom_memories"] = [{
            "memory_id": "hm-1",
            "kind": "episodic",
            "title": "一起看过日出",
            "content": "主人和小玲在窗边一起看了日出。",
            "confidence": 0.97,
            "importance": 0.86,
            "updated_at": 1789215426,
            "influence": {"mood": 1.5},
        }]
        await self.service.chat(payload)
        user_content = self.provider.calls[0][1][-1]["content"]
        self.assertNotIn('"confidence"', user_content)
        self.assertNotIn('"importance"', user_content)
        self.assertNotIn('"influence"', user_content)
        self.assertNotIn("1789215426", user_content)


class NumericAuditTests(unittest.IsolatedAsyncioTestCase):
    """验收②:字段名+数值配对扫描(非裸正则,放行'第 3 天'类合法时间文本)。"""

    def setUp(self):
        self.roles = make_registry(_tmp_root("qual-audit"))
        self.provider = FakeProvider()
        self.service = _make_service(self.roles, self.provider)

    async def test_no_field_anchored_numeric_pairs_in_prompt(self):
        payload = valid_payload()
        payload["state"]["body_state"] = {
            "protocol": "spring_haven.body_state.v2",
            "role_id": "ling",
            "stats": {
                "hunger": 72.5, "thirst": 91.2, "mood": 66.0, "stress": 18.4,
                "stamina": 45.0, "awake": 80.0, "urine": 88.8, "health": 76.0,
                "intimacy": 42.0, "fertility": 3.0, "implantation": 0.5,
            },
            "sensations": {"hunger": "有些饿", "thirst": "有些口渴"},
        }
        payload["state"]["life_lab_event"] = {
            "protocol": "spring_haven.life_lab.social_event.v1",
            "event_id": "lab-audit",
            "action": "socialize",
            "action_label": "闲聊",
            "station_id": "living",
            "actor_role_id": "nai",
            "participant_role_ids": ["ling", "nai"],
            "initiated_by": "autonomous",
            "needs_by_role": {
                "ling": {"hunger": 72.5, "mood": 66.0},
                "nai": {"thirst": 91.2, "stamina": 45.0},
            },
            "visual_summary": "客厅里两个人在闲聊。",
        }
        await self.service.chat(payload)
        user_content = self.provider.calls[0][1][-1]["content"]
        pattern = re.compile(
            r"(?:条件键[\"']?|[\"']?(?:"
            + "|".join(GUARDED_FIELDS)
            + r")[\"']?\s*[:=]\s*)-?\d+(?:\.\d+)?"
        )
        leaked = pattern.findall(user_content)
        self.assertEqual(leaked, [], f"prompt 泄露数值字段: {leaked[:6]}")
        for label in FIELD_LABELS:
            for match in re.finditer(label + r"[=:]?\s*([0-9]+(?:\.[0-9]+)?)", user_content):
                self.fail(f"中文字段名后跟随数值: {label}={match.group(1)}")


class BucketHysteresisTests(unittest.TestCase):
    """验收③:相邻档位需越过边界 ±MARGIN 才切换;跨档立即生效。"""

    def setUp(self):
        self.hysteresis = _BucketHysteresis()

    def test_first_value_adopts_raw_bucket(self):
        self.assertEqual(self.hysteresis.resolve("ling", "hunger", 90.0), "很高")

    def test_adjacent_move_requires_crossing_margin(self):
        self.hysteresis.resolve("ling", "hunger", 90.0)
        # 84 在边界(85)内侧 margin 内:保持很高
        self.assertEqual(self.hysteresis.resolve("ling", "hunger", 84.0), "很高")
        # 82 越过 85-2=83:切换偏高
        self.assertEqual(self.hysteresis.resolve("ling", "hunger", 82.0), "偏高")
        # 60 越过 65-2=63:切换普通
        self.assertEqual(self.hysteresis.resolve("ling", "hunger", 60.0), "普通")
        # 63.5 在边界(65)下方 margin 内:保持普通
        self.assertEqual(self.hysteresis.resolve("ling", "hunger", 63.5), "普通")
        # 67 越过 65+2=67:切回偏高
        self.assertEqual(self.hysteresis.resolve("ling", "hunger", 67.0), "偏高")
        # 不同 key 是全新取样:66 直接落在原始分桶偏高
        self.assertEqual(self.hysteresis.resolve("ling", "mood", 66.0), "偏高")

    def test_multi_bucket_jump_applies_immediately(self):
        self.hysteresis.resolve("nai", "stamina", 92.0)
        # 从很高直接掉到偏低(跨两档):不受滞回阻碍
        self.assertEqual(self.hysteresis.resolve("nai", "stamina", 20.0), "偏低")

    def test_states_are_tracked_per_subject_and_stat(self):
        self.hysteresis.resolve("ling", "mood", 90.0)
        self.assertEqual(self.hysteresis.resolve("nai", "mood", 40.0), "普通")
        self.assertEqual(self.hysteresis.resolve("ling", "mood", 88.0), "很高")

    def test_composer_uses_hysteresis_across_requests(self):
        composer = PromptComposer(make_registry(_tmp_root("qual-composer")))
        self.assertEqual(
            composer._hysteresis.resolve("ling", "hunger", 90.0), "很高"
        )
        self.assertEqual(
            composer._hysteresis.resolve("ling", "hunger", 84.5), "很高"
        )


def _tmp_root(tag: str):
    import tempfile
    from pathlib import Path
    return Path(tempfile.mkdtemp(prefix=f"spring-haven-{tag}-"))


def _make_service(roles, provider):
    from spring_haven_core.memory import HeartloomStore
    from spring_haven_core.service import CompanionService
    store = HeartloomStore(":memory:", roles.ids())
    return CompanionService(roles, provider, memory=store)


if __name__ == "__main__":
    unittest.main()
