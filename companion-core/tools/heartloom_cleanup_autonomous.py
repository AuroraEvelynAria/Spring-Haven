"""存量清理:隔离误存的自主消息脚手架。

修复前,客户端 proactive 提示词既可能经 remember_user_turn 被当成主人发言
存成 conversation_user 记忆，也可能进入 conversation_events。工具默认只干跑；
--apply 会先备份，再停用明确的 conversation_user 记忆并删除明确的伪用户事件。

用法(companion-core 目录):
  PYTHONPATH=src python tools/heartloom_cleanup_autonomous.py          # 干跑
  PYTHONPATH=src python tools/heartloom_cleanup_autonomous.py --apply  # 备份后执行
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CORE_ROOT = REPO_ROOT / "companion-core"
sys.path.insert(0, str(CORE_ROOT / "src"))

from spring_haven_core.memory import HeartloomStore  # noqa: E402
from spring_haven_core.roles import RoleRegistry  # noqa: E402

DEFAULT_DB = CORE_ROOT / "user_data" / "heartloom.sqlite3"
# 主动消息提示词的稳定特征串(任一命中即判为脚手架文本)
SIGNATURES = ("后台生活主动联系", "请以你自己的人格")


def main() -> int:
    parser = argparse.ArgumentParser(description="停用误存的自主消息提示词记忆")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument(
        "--apply", action="store_true", help="备份后执行停用(缺省只干跑统计)"
    )
    args = parser.parse_args()

    roles = RoleRegistry.load(CORE_ROOT / "user_data" / "roles.json")
    store = HeartloomStore(args.db, roles.ids())
    try:
        memory_clauses = " OR ".join("content LIKE ?" for _ in SIGNATURES)
        event_clauses = " OR ".join("text LIKE ?" for _ in SIGNATURES)
        params = tuple(f"%{signature}%" for signature in SIGNATURES)
        memory_rows = store._connection.execute(
            f"SELECT memory_id, save_id, source, substr(content, 1, 48) AS head "
            f"FROM memory_entries WHERE enabled = 1 AND source = 'conversation_user' "
            f"AND ({memory_clauses})",
            params,
        ).fetchall()
        event_rows = store._connection.execute(
            f"SELECT id, save_id, message_id, substr(text, 1, 48) AS head "
            f"FROM conversation_events WHERE sender = 'user' AND ({event_clauses})",
            params,
        ).fetchall()
        print(f"命中脚手架特征的用户记忆:{len(memory_rows)} 条")
        for row in memory_rows[:12]:
            print(f"  [{row['source']}] {row['head']}…")
        print(f"命中脚手架特征的伪用户事件:{len(event_rows)} 条")
        for row in event_rows[:12]:
            print(f"  [{row['message_id']}] {row['head']}…")
        if not memory_rows and not event_rows:
            return 0
        if not args.apply:
            print("（干跑结束;确认无误后加 --apply 备份并隔离）")
            return 0
        backup_path = args.db.with_name(args.db.name + ".pre-autonomous-cleanup.backup")
        store.backup_to(backup_path)
        print(f"已备份到 {backup_path}")
        with store._lock, store._connection:
            store._connection.execute(
                f"UPDATE memory_entries SET enabled = 0 "
                f"WHERE enabled = 1 AND source = 'conversation_user' AND ({memory_clauses})",
                params,
            )
            store._connection.execute(
                f"DELETE FROM conversation_events WHERE sender = 'user' AND ({event_clauses})",
                params,
            )
        print(
            f"已停用 {len(memory_rows)} 条记忆、删除 {len(event_rows)} 条伪用户事件"
            "（记忆可逆；事件仅能从备份恢复）"
        )
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
