from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

MEMORY_ID_RE = re.compile(r"^(?:hm_)?[0-9a-f]{32,40}$")

try:  # discover 模式可直接导入;单模块直跑时回退包路径
    from tools.recall_eval import DEFAULT_DB, evaluate, load_cases
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
    from recall_eval import DEFAULT_DB, evaluate, load_cases

FIXTURE = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "recall_eval_set.json"

# 回归下限(ratchet):记录当前冻结语料基线;任何检索改进使数字上升后应同步抬高此值。
# 2026-09-27 首次基线 = 2/15(0.1333);同日修复 always_active 无条件占位 +
# 词法池内局部 IDF + 触发词平面削平移除后 = 7/15(0.4667)。
BASELINE_HIT_RATE = 0.4667


class RecallEvalFixtureTests(unittest.TestCase):
    """评测集自身完整性 —— 无需本地存档,CI 上也要跑。"""

    def test_fixture_structure(self) -> None:
        cases = load_cases(FIXTURE)
        self.assertEqual(len(cases), 20)
        ids = [case["id"] for case in cases]
        self.assertEqual(len(ids), len(set(ids)))
        by_status: dict[str, int] = {}
        for case in cases:
            by_status[case["status"]] = by_status.get(case["status"], 0) + 1
        # q018-q020 保留位、q017 负例;q009 在传播链写入前为 pending
        self.assertGreaterEqual(by_status.get("active", 0), 14)
        self.assertEqual(by_status.get("negative", 0), 1)
        for case in cases:
            if case["status"] == "active":
                self.assertTrue(case["expect"], f"{case['id']} 缺少期望记忆")
                for mid in case["expect"]:
                    self.assertRegex(mid, MEMORY_ID_RE, f"{case['id']} 非法记忆 id")


class RecallEvalSnapshotTests(unittest.TestCase):
    """真实存档上的召回回归。

    依赖 user_data/heartloom_eval_snapshot.sqlite3(用 sqlite3 backup API
    从活档做只读快照,不入库不入 Git);缺失时跳过,不影响 CI。
    冻结模式把副本重置到标注时刻语料状态,专测检索排序本身。
    """

    def test_frozen_baseline_ratchet(self) -> None:
        if not DEFAULT_DB.is_file():
            self.skipTest(f"no eval snapshot at {DEFAULT_DB}")
        result = evaluate(DEFAULT_DB, FIXTURE, freeze=True)
        summary = result["summary"]
        self.assertTrue(summary["negative_ok"], "负例用例出现词法泄漏")
        self.assertGreaterEqual(
            summary["hit_rate"],
            BASELINE_HIT_RATE,
            "召回命中率跌破已知基线(冻结语料模式):\n"
            + "\n".join(
                f"{case['id']} {case['status']} missed={case.get('missed')}"
                for case in result["cases"]
                if case["status"] == "active" and not case.get("hit")
            ),
        )


if __name__ == "__main__":
    unittest.main()
