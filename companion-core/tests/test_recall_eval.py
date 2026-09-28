from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

MEMORY_ID_RE = re.compile(r"^(?:hm_)?[0-9a-f]{32,40}$")

CORE_ROOT = Path(__file__).resolve().parents[1]
FIXTURE = CORE_ROOT / "tests" / "fixtures" / "recall_eval_set.json"
# 真实存档回归锚:只存在于本机(gitignored),公开仓库里永不出现。
REAL_FIXTURE = CORE_ROOT / "user_data" / "recall_eval_set.real.json"

try:  # discover 模式可直接导入;单模块直跑时回退包路径
    from tools.build_synthetic_eval_store import build_synthetic_eval_store
    from tools.recall_eval import DEFAULT_DB, evaluate, load_cases
except ImportError:
    sys.path.insert(0, str(CORE_ROOT / "tools"))
    from build_synthetic_eval_store import build_synthetic_eval_store
    from recall_eval import DEFAULT_DB, evaluate, load_cases

# 回归下限(ratchet)。
# 合成语料基线(2026-09-28 起):语料与查询同源且确定可控,期望全量命中;
# 任何检索打分回归都会让 1.0 跌破 —— 这是比真实存档更强的 CI 棘轮。
# 真实存档棘轮沿革(本机 user_data/recall_eval_set.real.json):
# 2026-09-27 首测 2/15(0.1333) → 同日修复后 7/15(0.4667);
# 2026-09-28 判定口径修正 + always_active 让位后 11/15(0.7333)。
SYNTHETIC_BASELINE_HIT_RATE = 1.0
REAL_BASELINE_HIT_RATE = 0.7333


class RecallEvalFixtureTests(unittest.TestCase):
    """评测集自身完整性 —— 无需任何存档,CI 上也要跑。"""

    def test_fixture_structure(self) -> None:
        cases = load_cases(FIXTURE)
        self.assertEqual(len(cases), 20)
        ids = [case["id"] for case in cases]
        self.assertEqual(len(ids), len(set(ids)))
        by_status: dict[str, int] = {}
        for case in cases:
            by_status[case["status"]] = by_status.get(case["status"], 0) + 1
        # q009 pending(传播链用例位)、q016 负例、q017-q020 保留位
        self.assertEqual(by_status.get("active", 0), 14)
        self.assertEqual(by_status.get("pending", 0), 1)
        self.assertEqual(by_status.get("negative", 0), 1)
        for case in cases:
            if case["status"] == "active":
                self.assertTrue(case["expect"], f"{case['id']} 缺少期望记忆")
                for mid in case["expect"]:
                    self.assertRegex(mid, MEMORY_ID_RE, f"{case['id']} 非法记忆 id")

    def test_fixture_is_synthetic_and_matches_builder(self) -> None:
        """夹具 ⇔ 生成器一致性:ID/查询漂移即报错;且不得含真实存档数据。"""
        committed = json.loads(FIXTURE.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as tmp:
            rebuilt = build_synthetic_eval_store(Path(tmp) / "evalsyn.sqlite3")
        self.assertEqual(
            committed["cases"], rebuilt["cases"], "夹具与生成器输出漂移,请重新生成"
        )
        blob = FIXTURE.read_text(encoding="utf-8")
        # 真实存档时代的历史残留哨兵:任何一个出现都意味着真实数据回来了
        for forbidden in ("[redacted]", "[redacted]", "[redacted]", "[redacted]", "[redacted]"):
            self.assertNotIn(forbidden, blob)


class RecallEvalSyntheticTests(unittest.TestCase):
    """合成语料上的召回回归 —— CI 全平台可跑,不依赖任何本地存档。"""

    def test_synthetic_baseline_ratchet(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store_path = Path(tmp) / "evalsyn.sqlite3"
            build_synthetic_eval_store(store_path)
            result = evaluate(store_path, FIXTURE, freeze=True)
        summary = result["summary"]
        self.assertTrue(summary["negative_ok"], "负例用例出现词法泄漏")
        self.assertGreaterEqual(
            summary["hit_rate"],
            SYNTHETIC_BASELINE_HIT_RATE,
            "合成语料召回跌破基线(检索打分回归):\n"
            + "\n".join(
                f"{case['id']} missed={case.get('missed')}"
                for case in result["cases"]
                if case["status"] == "active" and not case.get("hit")
            ),
        )


class RecallEvalSnapshotTests(unittest.TestCase):
    """本机真实存档上的召回回归(不入库不入 Git)。

    依赖 user_data/heartloom_eval_snapshot.sqlite3(用 sqlite3 backup API
    从活档做只读快照)与 user_data/recall_eval_set.real.json(真实存档
    标注的期望,2026-09-28 从仓库撤出);任一缺失时跳过,不影响 CI。
    冻结模式把副本重置到标注时刻语料状态,专测检索排序本身。
    """

    def test_frozen_baseline_ratchet(self) -> None:
        if not DEFAULT_DB.is_file() or not REAL_FIXTURE.is_file():
            self.skipTest(
                f"no local real-archive anchor ({DEFAULT_DB} / {REAL_FIXTURE})"
            )
        result = evaluate(DEFAULT_DB, REAL_FIXTURE, freeze=True)
        summary = result["summary"]
        self.assertTrue(summary["negative_ok"], "负例用例出现词法泄漏")
        self.assertGreaterEqual(
            summary["hit_rate"],
            REAL_BASELINE_HIT_RATE,
            "真实存档召回命中率跌破已知基线(冻结语料模式):\n"
            + "\n".join(
                f"{case['id']} {case['status']} missed={case.get('missed')}"
                for case in result["cases"]
                if case["status"] == "active" and not case.get("hit")
            ),
        )


if __name__ == "__main__":
    unittest.main()
