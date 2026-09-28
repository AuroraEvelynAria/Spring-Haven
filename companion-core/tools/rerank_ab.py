"""ADR-011 调优:rerank 短名单宽度 A/B(默认 12 vs 20)。

在线实验(2026-09-28)证据:q006 短名单 20 时 PASS(12 时 MISS),q001 反而变差
——本工具在冻结评测快照上把两条臂各跑一遍全量评测集,量化两种宽度的
召回命中差异,为是否调整 service._rerank_shortlist 提供数据。

每条臂使用独立的数据库副本(冻结 + record_access 副作用都落在副本上),
两臂共享同一 embedding/rerank 通道,判定口径与 recall_eval 完全一致
(每条期望记忆出现在其所有者角色的 top-N,'*' 任一角色看到即算)。

用法(companion-core 目录):
    PYTHONPATH=src python tools/rerank_ab.py
    PYTHONPATH=src python tools/rerank_ab.py --shortlists 12 16 20 --json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path
from typing import Any

from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.provider import OpenAICompatibleProvider
from spring_haven_core.provider_settings import ProviderSettingsStore
from spring_haven_core.roles import RoleDefinition, RoleRegistry
from spring_haven_core.service import CompanionService

sys.path.insert(0, str(Path(__file__).resolve().parent))
from recall_eval import (  # noqa: E402
    DEFAULT_DB,
    DEFAULT_FIXTURE,
    _freeze_corpus,
    _largest_real_save,
    _resolve_context,
    load_cases,
)

COMPANION_ROOT = Path(__file__).resolve().parents[1]


async def _run_arm(
    arm_name: str,
    shortlist: int,
    db_path: Path,
    fixture_path: Path,
    config: CoreConfig,
    *,
    limit: int,
    store_roles: list[str],
) -> list[dict[str, Any]]:
    work = Path(tempfile.gettempdir()) / f"heartloom_rerank_ab_{arm_name}" / db_path.name
    if work.parent.exists():
        shutil.rmtree(work.parent, ignore_errors=True)
    work.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(db_path, work)

    conn = sqlite3.connect(work)
    try:
        _freeze_corpus(conn)
        cases = load_cases(fixture_path)
        roles = RoleRegistry(
            {
                role_id: RoleDefinition(role_id, role_id, "", (role_id,), "")
                for role_id in store_roles
            }
        )
        settings = ProviderSettingsStore(
            config, config.provider_settings_path, config.provider_credential_path
        )
        provider = OpenAICompatibleProvider(config, settings)
        service = CompanionService(
            roles,
            provider,
            HeartloomStore(str(work), store_roles),
            memory_rerank_enabled=True,
        )
        service._rerank_shortlist = shortlist

        report: list[dict[str, Any]] = []
        try:
            for case in cases:
                entry: dict[str, Any] = {"id": case["id"], "status": case["status"]}
                if case["status"] == "active":
                    save_id, target_roles = _resolve_context(conn, case["expect"])
                    ordered_roles = list(
                        dict.fromkeys(
                            ([case["actor"]] if case["actor"] else [])
                            + (target_roles or store_roles)
                        )
                    )
                    ranks_by_role: dict[str, dict[str, int]] = {}
                    for role in ordered_roles:
                        query_vector, embedding_model = await service._query_embedding(
                            case["query"]
                        )
                        rows = await service._recall_with_rerank(
                            save_id=save_id,
                            role_id=role,
                            query=case["query"],
                            query_vector=query_vector,
                            embedding_model=embedding_model,
                        )
                        ranks_by_role[role] = {
                            str(row["memory_id"]): index + 1
                            for index, row in enumerate(rows)
                        }
                    scope_map: dict[str, str] = {}
                    for memory_id in case["expect"]:
                        row = conn.execute(
                            "SELECT scope_role_id FROM memory_entries WHERE memory_id = ?",
                            (memory_id,),
                        ).fetchone()
                        scope_map[memory_id] = str(row[0]) if row else "*"
                    missed: list[str] = []
                    ranks: dict[str, int | None] = {}
                    for memory_id in case["expect"]:
                        candidate_roles = (
                            ordered_roles if scope_map[memory_id] == "*" else [scope_map[memory_id]]
                        )
                        found: int | None = None
                        for role in candidate_roles:
                            rank = ranks_by_role.get(role, {}).get(memory_id)
                            if rank is not None and (found is None or rank < found):
                                found = rank
                        ranks[memory_id] = found
                        if found is None:
                            missed.append(memory_id)
                    entry.update({"hit": not missed, "ranks": ranks, "missed": missed})
                elif case["status"] == "negative":
                    save_id = _largest_real_save(conn)
                    leaks: list[str] = []
                    for role in store_roles:
                        query_vector, embedding_model = await service._query_embedding(
                            case["query"]
                        )
                        rows = await service._recall_with_rerank(
                            save_id=save_id,
                            role_id=role,
                            query=case["query"],
                            query_vector=query_vector,
                            embedding_model=embedding_model,
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
            service.close()
    finally:
        conn.close()
    return report


def _summarize(report: list[dict[str, Any]]) -> dict[str, Any]:
    active = [case for case in report if case["status"] == "active"]
    negative = [case for case in report if case["status"] == "negative"]
    passed = sum(1 for case in active if case.get("hit"))
    return {
        "active_cases": len(active),
        "passed": passed,
        "hit_rate": round(passed / len(active), 4) if active else 0.0,
        "negative_ok": bool(negative) and all(case.get("hit") for case in negative),
        "missed": [case["id"] for case in active if not case.get("hit")],
    }


def _print_side_by_side(
    arms: dict[str, list[dict[str, Any]]], summaries: dict[str, dict[str, Any]]
) -> None:
    names = list(arms)
    for name in names:
        summary = summaries[name]
        print(
            f"[短名单 {name}] {summary['passed']}/{summary['active_cases']} "
            f"hit_rate={summary['hit_rate']} negative_ok={summary['negative_ok']} "
            f"missed={summary['missed']}"
        )
    print()
    first = arms[names[0]]
    for index, case in enumerate(first):
        if case["status"] != "active":
            continue
        cells = []
        for name in names:
            twin = arms[name][index]
            mark = "PASS" if twin.get("hit") else "MISS"
            cells.append(f"{name}:{mark} ranks={twin.get('ranks')}")
        print(f"{case['id']:6} " + "  |  ".join(cells))


async def main_async(args: argparse.Namespace) -> int:
    config = CoreConfig.load(COMPANION_ROOT / "user_data" / "core_config.json")
    if not Path(config.provider_credential_path).is_file():
        print(f"凭据不存在: {config.provider_credential_path}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(args.db)
    try:
        store_roles = [
            str(row[0])
            for row in conn.execute(
                "SELECT DISTINCT scope_role_id FROM memory_entries "
                "WHERE scope_role_id != '*' ORDER BY 1"
            )
        ]
    finally:
        conn.close()

    arms: dict[str, list[dict[str, Any]]] = {}
    summaries: dict[str, dict[str, Any]] = {}
    for shortlist in args.shortlists:
        name = str(shortlist)
        print(f"== 臂:短名单 {shortlist} ==", flush=True)
        report = await _run_arm(
            name,
            shortlist,
            args.db,
            args.fixture,
            config,
            limit=args.limit,
            store_roles=store_roles,
        )
        arms[name] = report
        summaries[name] = _summarize(report)

    _print_side_by_side(arms, summaries)
    if args.json:
        print(
            json.dumps(
                {"summaries": summaries, "arms": arms}, ensure_ascii=False, indent=2
            )
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Rerank shortlist width A/B driver")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--shortlists", nargs="+", type=int, default=[12, 20])
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if not args.db.is_file():
        print(f"eval db not found: {args.db}", file=sys.stderr)
        return 2
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
