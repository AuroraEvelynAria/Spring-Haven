"""Manual test driver for the life engine (Phase 0-4).

Lets you test time-driven features without waiting:
  seed      inject life events (past timestamps) for a save
  seed-mem  inject daily-digest memories (for weekly/milestones)
  digest    run daily digest (LLM or fallback)
  weekly    run weekly insight (LLM or fallback)
  milestones run milestone checks
  status    show events / memories / milestones for a save

Usage (from F:\SpringHaven-Dev\companion-core):
  .\.venv\Scripts\python.exe ..\tools\manual_life_test.py seed --save demo --role ling --days-ago 1
  .\.venv\Scripts\python.exe ..\tools\manual_life_test.py digest
  .\.venv\Scripts\python.exe ..\tools\manual_life_test.py status --save demo
"""
import argparse
import asyncio
import calendar
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(r"F:\SpringHaven-Dev\companion-core\src")))
os.chdir(r"F:\SpringHaven-Dev\companion-core")

from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.provider import OpenAICompatibleProvider
from spring_haven_core.provider_settings import ProviderSettingsStore
from spring_haven_core.roles import RoleRegistry
from spring_haven_core.service import CompanionService


def _build_service():
    config = CoreConfig.load("user_data/core_config.json")
    roles = RoleRegistry.load("user_data/roles.json")
    store = HeartloomStore("user_data/heartloom.sqlite3", roles.ids())
    settings = ProviderSettingsStore(
        config, "user_data/provider_settings.json", "user_data/provider_key.dpapi"
    )
    provider = OpenAICompatibleProvider(config, settings)
    return CompanionService(roles, provider, store), store


def _day_start(days_ago: int) -> int:
    now = time.time()
    utc = calendar.timegm(time.gmtime(now - days_ago * 86400))
    # 转本地日界
    lt = time.localtime(now - days_ago * 86400)
    return calendar.timegm((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0))


def seed(args) -> int:
    service, store = _build_service()
    role = args.role
    save = args.save
    now = int(time.time())
    # 注册 save 到 life_state（milestone/weekly 需要）
    store.sync_life_state(
        save_id=save, selected_role_id=role,
        snapshot={"roles": {}}, last_user_activity_at=now,
        next_event_at=0, now=now,
    )
    # 事件时间戳用 now - 小时，确保超过 digest 的 12h 冷却
    events = [
        {
            "event_id": f"dailyplan-{role}-sunbathe-{now - 30 * 3600}",
            "role_id": role, "target_role": "",
            "action": "sunbathe",
            "description": "在窗边晒了会儿太阳，尾巴慢慢放松下来",
            "occurred_at_unix": now - 30 * 3600,
        },
        {
            "event_id": f"dailyplan-{role}-cook_dinner-{now - 26 * 3600}",
            "role_id": role, "target_role": "nai" if role == "ling" else "ling",
            "action": "cook_dinner",
            "description": "和小奈一起做了晚饭" if role == "ling" else "和小玲一起做了晚饭",
            "occurred_at_unix": now - 26 * 3600,
        },
    ]
    result = store.record_life_events(save_id=save, events=events)
    print(f"seeded: {result}  (events at now-30h / now-26h, 超过 12h 冷却)")
    service.close()
    return 0


def seed_mem(args) -> int:
    service, store = _build_service()
    for i in range(args.count):
        store.put_memory(
            {
                "save_id": args.save, "scope_role_id": args.role,
                "kind": "episodic", "title": f"测试记忆{i}", "content": f"第{i}天：窗边看书、散步。",
            },
            source="daily_digest",
        )
    print(f"seeded {args.count} daily_digest memories for {args.save}")
    service.close()
    return 0


async def digest(args) -> int:
    service, _ = _build_service()
    result = await service.run_due_life_digests()
    print(f"digest: {result}")
    await service.aclose()
    return 0


async def weekly(args) -> int:
    service, _ = _build_service()
    result = await service.run_due_weekly_insights()
    print(f"weekly: {result}")
    await service.aclose()
    return 0


async def milestones(args) -> int:
    service, _ = _build_service()
    result = await service.run_due_milestones()
    print(f"milestones: {result}")
    await service.aclose()
    return 0


def status(args) -> int:
    service, store = _build_service()
    save = args.save
    events = store.list_life_events(save_id=save, limit=20)
    print(f"life_events ({len(events)}):")
    for ev in events[:10]:
        ts = time.strftime("%m-%d %H:%M", time.localtime(ev["occurred_at_unix"]))
        print(f"  [{ts}] {ev['role_id']} -> {ev['target_role'] or '-'} {ev['action']}: {ev['description'][:40]}")
    memories = store.list_memories(save_id=save, limit=20)
    print(f"memories ({len(memories)}):")
    for m in memories[:10]:
        print(f"  [{m['source']}] {m['title']}: {m['content'][:50]}")
    ms = store.unlocked_milestones(save)
    print(f"milestones ({len(ms)}): {list(ms.keys())}")
    service.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Manual life engine test driver")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_seed = sub.add_parser("seed", help="inject life events")
    p_seed.add_argument("--save", default="demo")
    p_seed.add_argument("--role", default="ling", choices=["ling", "nai"])
    p_seed.add_argument("--days-ago", type=int, default=1)
    p_seed.set_defaults(func=seed)

    p_sm = sub.add_parser("seed-mem", help="inject daily_digest memories")
    p_sm.add_argument("--save", default="demo")
    p_sm.add_argument("--role", default="ling", choices=["ling", "nai"])
    p_sm.add_argument("--count", type=int, default=3)
    p_sm.set_defaults(func=seed_mem)

    for name, fn in [("digest", digest), ("weekly", weekly), ("milestones", milestones)]:
        p = sub.add_parser(name, help=f"run {name}")
        p.set_defaults(func=fn)

    p_st = sub.add_parser("status", help="show events/memories/milestones")
    p_st.add_argument("--save", default="demo")
    p_st.set_defaults(func=status)

    args = parser.parse_args()
    fn = args.func
    if fn in (digest, weekly, milestones):
        return asyncio.run(fn(args))
    return fn(args)


if __name__ == "__main__":
    sys.exit(main())
