"""存量清理:把"自主消息提示词"误存成的记忆停用(enabled=0)。

背景:修复前,客户端主动消息(proactive)的提示词经 remember_user_turn
被当成主人发言存成记忆(source=conversation_user,通用标题如"彼此的关系"),
内容形如"主人曾说:这是你的后台生活主动联系时刻…"。源头已在
service.chat 修复(自主回合不再落用户记忆/对话流水/整理器),本工具清存量:
命中提示词特征串的记忆置 enabled=0 —— 可逆(改回 1 即恢复),不删除正文。

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
        clauses = " OR ".join("content LIKE ?" for _ in SIGNATURES)
        params = tuple(f"%{signature}%" for signature in SIGNATURES)
        rows = store._connection.execute(
            f"SELECT memory_id, save_id, source, substr(content, 1, 48) AS head "
            f"FROM memory_entries WHERE enabled = 1 AND ({clauses})",
            params,
        ).fetchall()
        print(f"命中提示词特征的记忆:{len(rows)} 条")
        for row in rows[:12]:
            print(f"  [{row['source']}] {row['head']}…")
        if not rows:
            return 0
        if not args.apply:
            print("（干跑结束;确认无误后加 --apply 备份并停用）")
            return 0
        backup_path = args.db.with_name(args.db.name + ".pre-autonomous-cleanup.backup")
        store.backup_to(backup_path)
        print(f"已备份到 {backup_path}")
        with store._lock, store._connection:
            store._connection.execute(
                f"UPDATE memory_entries SET enabled = 0 WHERE enabled = 1 AND ({clauses})",
                params,
            )
        print(f"已停用 {len(rows)} 条(可逆:将 enabled 改回 1 即恢复)")
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
