"""Heartloom 召回评测集驱动(ADR-001 D1 / 验收②「评测集上混合召回优于纯词法基线」)。

评测集:tests/fixtures/recall_eval_set.json,期望命中已用真实存档标注。
判定规则(2026-09-28 修正为按记忆归属):每条期望记忆必须出现在其所有者
角色的 top-N(默认 5)召回结果中;'*' 家庭共享记忆任一角色看到即算。
（旧口径「任一角色全覆盖」对跨私有作用域的期望结构性不可满足。）
  - 负例(notes 含「负例」):期望无词法泄漏,返回结果只能包含 always_active 记忆。
  - 保留位(空 query 且无期望):跳过。
  - 其余零期望用例(如 q009 二手记忆):标注为 pending,不计入通过率。

用法:
    python tools/recall_eval.py --db user_data/heartloom_eval_snapshot.sqlite3
    python tools/recall_eval.py --json   # 机器可读输出

评测在数据库副本上运行(record_access=False),不会触碰原始存档。
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path
from typing import Any

from spring_haven_core.memory import HeartloomStore

COMPANION_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = COMPANION_ROOT / "tests" / "fixtures" / "recall_eval_set.json"
DEFAULT_DB = COMPANION_ROOT / "user_data" / "heartloom_eval_snapshot.sqlite3"


def load_cases(fixture_path: Path) -> list[dict[str, Any]]:
    data = json.loads(fixture_path.read_text(encoding="utf-8"))
    cases: list[dict[str, Any]] = []
    for raw in data["cases"]:
        case = {
            "id": str(raw["id"]),
            "query": str(raw.get("query", "")),
            "expect": list(
                dict.fromkeys(str(item) for item in raw.get("expect_memory_ids", []))
            ),
            "notes": str(raw.get("notes", "")),
            "actor": str(raw.get("expect_actor") or "") or None,
        }
        if not case["query"] and not case["expect"]:
            case["status"] = "reserved"
        elif "负例" in case["notes"]:
            case["status"] = "negative"
        elif not case["expect"]:
            case["status"] = "pending"
        else:
            case["status"] = "active"
        cases.append(case)
    return cases


def _freeze_corpus(conn: sqlite3.Connection) -> None:
    """把评测副本固定到「标注时刻」语料状态,保证回归可复现。

    标注时期望记忆全部新鲜(active,decay/recency≈1);活档随后被世界时间
    推着走完 Active→Dormant,直接在活档上跑测的是老化行为而不是检索排序。
    冻结 = 生命周期全部重置 active + 世界时钟停在最新记忆之后一天(倍率
    压到忽略不计),让 decay/recency 回到标注时的量级。
    """
    import time as _time

    conn.execute("UPDATE memory_entries SET lifecycle = 'active'")
    saves = [str(row[0]) for row in conn.execute("SELECT DISTINCT save_id FROM journey_clock")]
    for save_id in saves:
        row = conn.execute(
            "SELECT MAX(world_updated_at) FROM memory_entries WHERE save_id = ?",
            (save_id,),
        ).fetchone()
        frozen_now = float(row[0]) + 1.0 if row and row[0] is not None else 0.0
        conn.execute(
            """
            UPDATE journey_clock
            SET anchor_real = ?, world_value = ?, rate = 1e-9
            WHERE save_id = ?
            """,
            (int(_time.time()), frozen_now, save_id),
        )
    conn.commit()


def _resolve_context(
    conn: sqlite3.Connection, expect_ids: list[str]
) -> tuple[str, list[str]]:
    """从期望记忆反查评测用的 save_id 与目标角色。

    角色取期望记忆里非 '*' 的 scope;全为 '*'(家庭共享)时返回空表,
    由调用方对每个角色各跑一次、任一命中即算通过。
    """
    row = conn.execute(
        "SELECT save_id FROM memory_entries WHERE memory_id = ?", (expect_ids[0],)
    ).fetchone()
    save_id = str(row[0]) if row else ""
    placeholders = ",".join("?" * len(expect_ids))
    roles: list[str] = []
    for (scope,) in conn.execute(
        f"SELECT DISTINCT scope_role_id FROM memory_entries "
        f"WHERE memory_id IN ({placeholders}) ORDER BY 1",
        expect_ids,
    ):
        if scope != "*":
            roles.append(str(scope))
    return save_id, roles


def _largest_real_save(conn: sqlite3.Connection) -> str:
    """负例没有期望记忆可用,取条目最多的非诊断 save_id 作为评测现场。"""
    row = conn.execute(
        """
        SELECT save_id, COUNT(*) AS n FROM memory_entries
        WHERE save_id NOT LIKE 'diagnostic-%' AND save_id NOT LIKE '%_life_lab'
        GROUP BY save_id ORDER BY n DESC LIMIT 1
        """
    ).fetchone()
    return str(row[0]) if row else ""


def evaluate(
    db_path: Path,
    fixture_path: Path = DEFAULT_FIXTURE,
    *,
    limit: int = 5,
    freeze: bool = True,
) -> dict[str, Any]:
    cases = load_cases(fixture_path)
    report: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / db_path.name
        shutil.copy2(db_path, work)
        conn = sqlite3.connect(work)
        store: HeartloomStore | None = None
        try:
            if freeze:
                _freeze_corpus(conn)
            store_roles = [
                str(row[0])
                for row in conn.execute(
                    "SELECT DISTINCT scope_role_id FROM memory_entries "
                    "WHERE scope_role_id != '*' ORDER BY 1"
                )
            ]
            store = HeartloomStore(str(work), store_roles)
            for case in cases:
                entry = dict(case)
                if case["status"] == "active":
                    save_id, target_roles = _resolve_context(conn, case["expect"])
                    ordered_roles = list(
                        dict.fromkeys(
                            ([case["actor"]] if case["actor"] else [])
                            + (target_roles or store_roles)
                        )
                    )
                    # 逐角色各跑一次召回,再按「记忆归属」判定(2026-09-28 修正):
                    # 期望记忆跨私有作用域时(小玲的 + 小奈的各一条),单角色
                    # 的 top-N 永远看不到对方的私密记忆——旧口径「任一角色
                    # 全覆盖」对 q008/q012/q015 结构性不可满足。正确口径:
                    # 每条期望记忆必须出现在其**所有者角色**的 top-N 中
                    # ('*' 家庭共享记忆:任一角色看到即算)。这与标注时
                    # 「站在每个角色自己的视角检索」的意图一致。
                    ranks_by_role: dict[str, dict[str, int]] = {}
                    top_scores: list[float] = []
                    for role in ordered_roles:
                        rows = store.recall(
                            save_id=save_id,
                            role_id=role,
                            query=case["query"],
                            limit=limit,
                            record_access=False,
                        )
                        ranks_by_role[role] = {
                            str(row["memory_id"]): index + 1
                            for index, row in enumerate(rows)
                        }
                        top_scores.append(
                            float(rows[0].get("recall_score", 0.0)) if rows else 0.0
                        )
                    scope_map: dict[str, str] = {}
                    for memory_id in case["expect"]:
                        scope_row = conn.execute(
                            "SELECT scope_role_id FROM memory_entries WHERE memory_id = ?",
                            (memory_id,),
                        ).fetchone()
                        scope_map[memory_id] = (
                            str(scope_row[0]) if scope_row else "*"
                        )
                    missed: list[str] = []
                    ranks: dict[str, int | None] = {}
                    for memory_id in case["expect"]:
                        scope = scope_map[memory_id]
                        candidate_roles = (
                            ordered_roles if scope == "*" else [scope]
                        )
                        found: int | None = None
                        for role in candidate_roles:
                            rank = ranks_by_role.get(role, {}).get(memory_id)
                            if rank is not None and (found is None or rank < found):
                                found = rank
                        ranks[memory_id] = found
                        if found is None:
                            missed.append(memory_id)
                    entry.update(
                        {
                            "role": case["actor"] or "multi",
                            "actor": case["actor"],
                            "hit": not missed,
                            "missed": missed,
                            "ranks": ranks,
                            "top_score": round(max(top_scores, default=0.0), 4),
                            "returned": sum(
                                len(value) for value in ranks_by_role.values()
                            ),
                        }
                    )
                elif case["status"] == "negative":
                    save_id = _largest_real_save(conn)
                    leaks: list[str] = []
                    for role in store_roles:
                        rows = store.recall(
                            save_id=save_id,
                            role_id=role,
                            query=case["query"],
                            limit=limit,
                            record_access=False,
                        )
                        leaks.extend(
                            str(row["memory_id"])
                            for row in rows
                            if not bool(row.get("always_active"))
                        )
                    entry["hit"] = not leaks
                    entry["leaked_ids"] = leaks
                report.append(entry)
        finally:
            if store is not None:
                store.close()
            conn.close()

    active = [case for case in report if case["status"] == "active"]
    negative = [case for case in report if case["status"] == "negative"]
    passed = sum(1 for case in active if case.get("hit"))
    return {
        "cases": report,
        "summary": {
            "active_cases": len(active),
            "passed": passed,
            "hit_rate": round(passed / len(active), 4) if active else 0.0,
            "negative_ok": bool(negative) and all(case.get("hit") for case in negative),
            "pending": [case["id"] for case in report if case["status"] == "pending"],
            "limit": limit,
            "freeze": freeze,
        },
    }


def format_report(result: dict[str, Any]) -> str:
    lines: list[str] = []
    summary = result["summary"]
    for case in result["cases"]:
        status = case["status"]
        if status == "reserved":
            lines.append(f"{case['id']:5}  reserved(跳过)")
        elif status == "pending":
            lines.append(f"{case['id']:5}  pending({case['notes'][:40]})")
        elif status == "negative":
            verdict = "ok" if case.get("hit") else f"LEAK {case.get('leaked_ids')}"
            lines.append(f"{case['id']:5}  negative  {verdict}")
        else:
            mark = "PASS" if case.get("hit") else "MISS"
            detail = ""
            if not case.get("hit"):
                detail = f" missed={case.get('missed')}"
            lines.append(
                f"{case['id']:5}  {mark:4}  role={case.get('role')} "
                f"top={case.get('top_score')} n={case.get('returned')}{detail}"
            )
    lines.append(
        f"== {summary['passed']}/{summary['active_cases']} active cases passed "
        f"(hit_rate={summary['hit_rate']}, negative_ok={summary['negative_ok']}, "
        f"pending={summary['pending']}, freeze={summary['freeze']}) =="
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Heartloom recall eval driver")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument(
        "--no-freeze",
        action="store_true",
        help="不在副本上冻结生命周期/世界时钟,测活档当前的老化状态",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    if not args.db.is_file():
        print(f"eval db not found: {args.db}", file=sys.stderr)
        print(
            "先用 sqlite3 backup API 从活档做只读快照,"
            "或用 --db 指向其他 heartloom.sqlite3 副本。",
            file=sys.stderr,
        )
        return 2
    result = evaluate(args.db, args.fixture, limit=args.limit, freeze=not args.no_freeze)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(format_report(result))
    summary = result["summary"]
    return 0 if summary["hit_rate"] == 1.0 and summary["negative_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
