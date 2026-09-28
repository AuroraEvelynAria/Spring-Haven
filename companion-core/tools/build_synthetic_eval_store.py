"""确定性合成评测语料生成器 —— 仓库内评测夹具的唯一真源。

背景(2026-09-28 安全整改):旧评测夹具用真实存档标注(真实记忆 ID + 真实
游玩主题查询),已按「公开仓库不得含任何真实用户数据」原则从全部 git 历史
中抹除。真实存档回归锚保留在本机 user_data/recall_eval_set.real.json
(gitignored),只在本机对 user_data/heartloom_eval_snapshot.sqlite3 使用。

本生成器产出一套**全合成**语料(工坊/家务类中性主题,与任何真实游玩记录
无关)+ 与之配套的评测夹具。记忆 ID 由 source_event_id 确定性派生:
同输入必得同 ID,测试据此锁定「夹具 ⇔ 语料」一致性,漂移即报错。

用法:
    python tools/build_synthetic_eval_store.py --db /tmp/evalsyn.sqlite3 \
        [--fixture tests/fixtures/recall_eval_set.json]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

CORE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CORE_ROOT / "src"))

from spring_haven_core.memory import HeartloomStore  # noqa: E402

SAVE_ID = "evalsyn"
ROLES = ("ling", "nai")

# (source_event_id, scope, kind, title, content, trigger_terms, extra)
SEED_MEMORIES: list[tuple[str, str, str, str, str, list[str], dict[str, Any]]] = [
    (
        "syn-01", "ling", "routine", "阳台晨读",
        "主人习惯每天清晨在阳台读一小时书,读之前先把椅子擦一遍。",
        ["阳台", "晨读"], {"importance": 0.55},
    ),
    (
        "syn-02", "ling", "preference", "乌龙茶的偏好",
        "主人最喜欢乌龙茶,尤其是秋天收的那一批,说回甘最长。",
        ["乌龙茶"], {"importance": 0.6},
    ),
    (
        "syn-03", "nai", "preference", "小奈的邮票册",
        "小奈收藏了一整套邮票册,按年份排得整整齐齐,谁都不许碰。",
        ["邮票"], {"importance": 0.6},
    ),
    (
        "syn-04", "ling", "episodic", "修好旧收音机",
        "主人把车库里那台旧收音机修好了,拧开开关时滋啦响了两声就出了声。",
        ["收音机"], {"importance": 0.65},
    ),
    (
        "syn-05", "nai", "episodic", "市集买的蓝陶壶",
        "小奈在周末市集买了一把蓝陶壶,回来路上一直抱在怀里怕磕着。",
        ["蓝陶壶"], {"importance": 0.6},
    ),
    (
        "syn-06", "*", "episodic", "擦亮门厅铜灯",
        "周末大家一起把门厅那盏铜灯擦得锃亮,顺手换了新的灯芯。",
        ["铜灯"], {"importance": 0.55},
    ),
    (
        "syn-07", "ling", "identity", "动手能力很强的人",
        "主人是个动手能力很强的人,家里东西坏了都是他自己修,几乎不往外送。",
        ["动手"], {"importance": 0.8, "always_active": True, "half_life_days": 0.0},
    ),
    (
        "syn-08", "ling", "episodic", "门垫下的备用钥匙",
        "主人把工坊的备用钥匙藏在了门垫下面,只告诉了小玲一个人。",
        ["门垫"], {"importance": 0.7},
    ),
    (
        "syn-09", "nai", "episodic", "学会吹口琴",
        "小奈最近学会了吹口琴,只会一首曲子,翻来覆去地练。",
        ["口琴"], {"importance": 0.7},
    ),
    (
        "syn-10", "ling", "episodic", "给摇椅上漆",
        "主人给院里的摇椅刷了第二遍漆,说要晾足两天才能坐。",
        ["摇椅"], {"importance": 0.6},
    ),
    (
        "syn-11", "nai", "episodic", "橘子皮装罐",
        "小奈把晒干的橘子皮装进玻璃罐,说留着冬天煮茶用。",
        ["橘子皮"], {"importance": 0.55},
    ),
    (
        "syn-12", "*", "episodic", "院子里看星图",
        "傍晚一家人在院子里铺开星图,对照着找出了三颗亮星。",
        ["星图"], {"importance": 0.6},
    ),
    (
        "syn-13", "*", "relationship", "第一百个心织回忆",
        "这是我们共同生活的第一百个心织回忆,值得永远记得。",
        ["心织回忆", "里程碑"],
        {"importance": 0.85, "always_active": True, "priority": 4, "half_life_days": 0.0},
    ),
    (
        "syn-14", "ling", "episodic", "书房台灯修好了",
        "书房那盏台灯闪了好几天,主人换了电容,现在一点不闪了。",
        ["台灯"], {"importance": 0.55},
    ),
    (
        "syn-15", "nai", "episodic", "腌萝卜的坛子",
        "小奈封了一坛腌萝卜,压上石头,写上日期放进储藏间。",
        ["腌萝卜"], {"importance": 0.55},
    ),
]


def build_synthetic_eval_store(db_path: Path) -> dict[str, Any]:
    """在给定路径建一份全新合成语料库,返回配套评测夹具(dict)。

    确定性:记忆 ID 由 (save_id, source, source_event_id, scope) 派生,
    同输入必得同 ID;时间只影响 world_created_at(评测冻结后归零)。
    """
    if db_path.exists():
        db_path.unlink()
    for suffix in ("-wal", "-shm"):
        extra = Path(str(db_path) + suffix)
        if extra.exists():
            extra.unlink()
    db_path.parent.mkdir(parents=True, exist_ok=True)

    store = HeartloomStore(str(db_path), list(ROLES))
    try:
        with store._lock, store._connection:
            store._connection.execute(
                "INSERT INTO journey_clock(save_id, anchor_real, world_value, rate) "
                "VALUES (?, ?, 0.0, 1.0) "
                "ON CONFLICT(save_id) DO UPDATE SET anchor_real = excluded.anchor_real",
                (SAVE_ID, int(time.time())),
            )
        id_by_event: dict[str, str] = {}
        for event_id, scope, kind, title, content, terms, extra in SEED_MEMORIES:
            entry = store.put_memory(
                {
                    "save_id": SAVE_ID,
                    "scope_role_id": scope,
                    "kind": kind,
                    "title": title,
                    "content": content,
                    "trigger_terms": terms,
                    "source_event_id": event_id,
                    **extra,
                },
                source=f"organizer_{scope}" if scope != "*" else "daily_digest",
            )
            id_by_event[event_id] = str(entry["memory_id"])
    finally:
        store.close()

    def mid(event_id: str) -> str:
        return id_by_event[event_id]

    cases: list[dict[str, Any]] = [
        {
            "id": "q001", "query": "阳台晨读",
            "expect_memory_ids": [mid("syn-01")], "expect_actor": "ling",
            "notes": "routine/semantic:合成日常习惯",
        },
        {
            "id": "q002", "query": "乌龙茶的味道",
            "expect_memory_ids": [mid("syn-02")], "expect_actor": "ling",
            "notes": "偏好类记忆",
        },
        {
            "id": "q003", "query": "邮票册",
            "expect_memory_ids": [mid("syn-03")], "expect_actor": "nai",
            "notes": "偏好类记忆",
        },
        {
            "id": "q004", "query": "那台旧收音机后来怎么样了",
            "expect_memory_ids": [mid("syn-04")], "expect_actor": "ling",
            "notes": "episodic:改写式查询,依赖词法锚",
        },
        {
            "id": "q005", "query": "蓝陶壶",
            "expect_memory_ids": [mid("syn-05")], "expect_actor": "nai",
            "notes": "episodic",
        },
        {
            "id": "q006", "query": "铜灯擦干净了吗",
            "expect_memory_ids": [mid("syn-06")], "expect_actor": "",
            "notes": "'*' 家庭共享:任一角色可见即算",
        },
        {
            "id": "q007", "query": "主人的动手能力怎么样",
            "expect_memory_ids": [mid("syn-07")], "expect_actor": "ling",
            "notes": "identity/always_active",
        },
        {
            "id": "q008", "query": "门垫下的钥匙,还有小奈练的曲子",
            "expect_memory_ids": [mid("syn-08"), mid("syn-09")],
            "expect_actor": "",
            "notes": "跨私有作用域:每条期望记忆须在其所有者角色的 top-N",
        },
        {
            "id": "q009", "query": "听说的新鲜事",
            "expect_memory_ids": [], "expect_actor": "",
            "notes": "pending:合成语料无 heard_from 记忆,保留传播链用例位",
        },
        {
            "id": "q010", "query": "摇椅",
            "expect_memory_ids": [mid("syn-10")], "expect_actor": "ling",
            "notes": "episodic",
        },
        {
            "id": "q011", "query": "橘子皮干什么用了",
            "expect_memory_ids": [mid("syn-11")], "expect_actor": "nai",
            "notes": "episodic",
        },
        {
            "id": "q012", "query": "星图",
            "expect_memory_ids": [mid("syn-12")], "expect_actor": "",
            "notes": "'*' 家庭共享",
        },
        {
            "id": "q013", "query": "第一百个心织回忆",
            "expect_memory_ids": [mid("syn-13")], "expect_actor": "",
            "notes": "里程碑记忆(source=milestone,always_active)",
        },
        {
            "id": "q014", "query": "书房的台灯还闪吗",
            "expect_memory_ids": [mid("syn-14")], "expect_actor": "ling",
            "notes": "episodic",
        },
        {
            "id": "q015", "query": "腌萝卜",
            "expect_memory_ids": [mid("syn-15")], "expect_actor": "nai",
            "notes": "episodic",
        },
        {
            "id": "q016", "query": "季度财报",
            "expect_memory_ids": [], "expect_actor": "",
            "notes": "负例:无相关记忆,期望无词法泄漏(仅 always_active 可出现)",
        },
        {"id": "q017", "query": "", "expect_memory_ids": [], "expect_actor": "", "notes": "保留位"},
        {"id": "q018", "query": "", "expect_memory_ids": [], "expect_actor": "", "notes": "保留位"},
        {"id": "q019", "query": "", "expect_memory_ids": [], "expect_actor": "", "notes": "保留位"},
        {"id": "q020", "query": "", "expect_memory_ids": [], "expect_actor": "", "notes": "保留位"},
    ]
    return {
        "_comment": (
            "ADR-001 混合召回评测集 —— 全合成语料版(2026-09-28 安全整改)。\n"
            "本夹具由 tools/build_synthetic_eval_store.py 确定性生成:全部记忆为\n"
            "工坊/家务类合成内容,记忆 ID 由 source_event_id 派生,不含任何真实\n"
            "用户数据。真实存档回归锚保留在本机 user_data/recall_eval_set.real.json\n"
            "(gitignored),配合 user_data/heartloom_eval_snapshot.sqlite3 本地使用。\n"
            "判定口径见 tests/test_recall_eval.py 与 tools/recall_eval.py。"
        ),
        "_usage": (
            "tests/test_recall_eval.py 加载并驱动:CI 上对合成语料全量回归;\n"
            "本机真实存档棘轮见测试文件内的 RecallEvalSnapshotTests(缺本地\n"
            "快照/真实夹具时自动跳过)。"
        ),
        "cases": cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build deterministic synthetic eval corpus")
    parser.add_argument("--db", type=Path, required=True, help="合成语料库输出路径")
    parser.add_argument("--fixture", type=Path, default=None, help="同时写出夹具 JSON")
    args = parser.parse_args()
    fixture = build_synthetic_eval_store(args.db)
    if args.fixture is not None:
        args.fixture.parent.mkdir(parents=True, exist_ok=True)
        args.fixture.write_text(
            json.dumps(fixture, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"fixture written: {args.fixture}")
    print(f"store written: {args.db}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
