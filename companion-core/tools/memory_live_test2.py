"""心织双角色全链路实弹测试:生活事件 → 日摘要 → 二手传闻传播 → 传闻对话。

与 memory_live_test.py 的区别:那套验证的是 chat→organizer→召回主线,
二手传播是手动调用 _propagate_digest 注入的;本工具走**完整生产路径**:

  record_life_events(世界日推进后旧日自动 pending)
    → run_due_life_digests()(LLM 日摘要,digest LLM 自评 importance)
    → _propagate_digest(importance ≥ 0.7 才传播,LLM 润色「听说」口吻)
    → 对方角色真实 chat 召回传闻记忆(prompt 打 heard_secondhand 标记)

全部 LLM 调用走 provider_settings.json 的正式 chat 通道。独立临时库
(%TEMP%/heartloom_live_test2),不触碰 user_data/heartloom.sqlite3 活档。

观测点:
  1. 双角色各自 digest 产出;高重要度传播 / 低重要度不传播(小事不传播);
  2. 传闻记忆 is_second_hand=1 + spread 边 + 检索隔离(听者召得到、讲者不越权);
  3. 小奈真实对话中被问「听小玲说起过什么」,回复是否呈现转述口吻(人工阅读);
  4. 私域隔离:小奈的聊天私密记忆不得出现在小玲的召回里;
  5. 双角色 mood 通道(EWMA 汇入 + 审计落账)。

用法:python tools/memory_live_test2.py
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CORE_ROOT = REPO_ROOT / "companion-core"
sys.path.insert(0, str(CORE_ROOT / "src"))

from spring_haven_core.config import CoreConfig  # noqa: E402
from spring_haven_core.memory import HeartloomStore  # noqa: E402
from spring_haven_core.provider import OpenAICompatibleProvider  # noqa: E402
from spring_haven_core.roles import RoleRegistry  # noqa: E402
from spring_haven_core.service import CompanionService  # noqa: E402

SAVE_ID = "livetest2"
DB_PATH = Path(tempfile.gettempdir()) / "heartloom_live_test2" / "heartloom.sqlite3"
REPORT_PATH = DB_PATH.parent / "report.json"

LING = "ling"
NAI = "nai"

# (role, tag, 用户文本)
CHATS: list[tuple[str, str, str]] = [
    (
        LING,
        "d0-ling-exam",
        "小玲，跟你说个事。我报名了专科进阶考核，就在下个月，最近每天下班都要复习到半夜，压力有点大。",
    ),
    (
        NAI,
        "d6-nai-hearsay",
        "小奈，好久没跟你聊天了。你最近有没有听小玲说起过什么事呀？",
    ),
    (
        LING,
        "d6-ling-exam-recall",
        "小玲，我的进阶考核，你还记得我准备得怎么样了吗？",
    ),
    (
        LING,
        "d6-ling-probe-nai",
        "对了，小奈她最近在忙什么新鲜事？",
    ),
    (
        NAI,
        "d6-nai-tiramisu",
        "告诉你个好消息！我终于学会做提拉米苏了，第一次做就成功了，手指饼干蘸咖啡液的手感刚刚好。",
    ),
]

# 世界日 0 的生活事件(经 record_life_events 进入真实 digest 管线)。
# 小玲:高情感事件,期望 digest LLM 给出 importance ≥ 0.7 → 触发传播;
# 小奈:闲适小事,期望 digest 照常产出但 importance < 0.7 → 不传播(正确行为)。
LIFE_EVENTS_DAY0 = [
    {
        "event_id": "lt2-ling-e1",
        "role_id": LING,
        "action": "companion_stay_up",
        "description": "主人复习到凌晨两点,小玲泡了参茶陪在书桌边,不肯先去睡。",
    },
    {
        "event_id": "lt2-ling-e2",
        "role_id": LING,
        "action": "comfort",
        "description": "主人模拟测验成绩不理想,把卷子揉成一团,情绪很低落;小玲把卷子抚平,陪他聊到情绪缓和。",
    },
    {
        "event_id": "lt2-ling-e3",
        "role_id": LING,
        "action": "care_adjust",
        "description": "小玲悄悄把主人晚上那杯咖啡换成了低因,怕他更睡不着。",
    },
    {
        "event_id": "lt2-nai-e1",
        "role_id": NAI,
        "action": "garden_time",
        "description": "小奈在庭院里晒了一下午太阳,给薄荷浇了水。",
    },
    {
        "event_id": "lt2-nai-e2",
        "role_id": NAI,
        "action": "tidy",
        "description": "小奈整理了温室的货架,哼了一会儿歌。",
    },
]

EVAL_QUERIES: list[tuple[str, str, list[str]]] = [
    # (role, 查询, 期望关键词;命中 = 关键词出现在 top3 title+content)
    (LING, "主人的进阶考核准备得怎么样了？", ["考核", "复习", "考试"]),
    (NAI, "小玲那边最近发生了什么？", ["考核", "复习", "考试", "听说"]),
    (NAI, "小奈最近学会了什么甜品？", ["提拉米苏"]),
]


def log(message: str) -> None:
    print(message, flush=True)


def advance_world_days(store: HeartloomStore, days: float) -> None:
    with store._lock, store._connection:
        store._connection.execute(
            "UPDATE journey_clock SET world_value = world_value + ?, anchor_real = ? "
            "WHERE save_id = ?",
            (days, int(time.time()), SAVE_ID),
        )
    log(f"  ⏩ 世界时间 +{days:g} 天 → 第 {store.world_now(SAVE_ID):.1f} 天")


async def maintenance_pass(service: CompanionService, label: str) -> None:
    embedded = await service.backfill_memory_embeddings(save_id=SAVE_ID, batch=16)
    lifecycle = service.apply_memory_lifecycle()
    links = service.backfill_memory_links(save_id=SAVE_ID, limit=25)
    log(
        f"  🔧 [{label}] embedding回填 {embedded} 条 | 生命周期 {lifecycle} | 新增链接 {links}"
    )


async def run_chat(
    service: CompanionService, role_id: str, tag: str, text: str
) -> dict:
    request_id = f"livetest2-{tag}-{int(time.time())}"
    started = time.monotonic()
    reply = await service.chat(
        {
            "request_id": request_id,
            "role_id": role_id,
            "save_id": SAVE_ID,
            "text": text,
            "history": [],
            "event_type": "chat",
            "state": {},
        }
    )
    await service.wait_for_organizer()
    elapsed = time.monotonic() - started
    display = service.roles.get(role_id).display_name
    mood = reply.get("mood")
    mood_note = (
        f", mood={mood.get('words') or '中性'}"
        if isinstance(mood, dict)
        else ", mood=缺失!"
    )
    log(
        f"  👤 [{display}] {text[:40]}…"
        f"\n  🌸 [{display}]({elapsed:.0f}s, 召回{reply['memory']['recalled_count']}"
        f", organizer={reply['memory']['organizer_state']}{mood_note}):"
        f" {reply['reply'][:80]}…"
    )
    return {
        "tag": tag,
        "role_id": role_id,
        "text": text,
        "reply": reply["reply"],
        "recalled_count": reply["memory"]["recalled_count"],
        "organizer_state": reply["memory"]["organizer_state"],
        "mood": mood,
        "elapsed_s": round(elapsed, 1),
    }


async def judge_recall(
    store: HeartloomStore,
    service: CompanionService,
    role_id: str,
    query: str,
    expect_keywords: list[str],
) -> dict:
    vector, model = await service._query_embedding(query)
    hits = store.recall(
        save_id=SAVE_ID,
        role_id=role_id,
        query=query,
        limit=3,
        query_vector=vector,
        embedding_model=model,
        record_access=False,
    )
    top = [
        {
            "memory_id": str(item["memory_id"]),
            "title": item.get("title", ""),
            "content": item.get("content", "")[:80],
            "score": round(float(item.get("recall_score", 0.0)), 4),
            "is_second_hand": bool(item.get("is_second_hand")),
            "scope": item.get("scope_role_id", ""),
        }
        for item in hits
    ]
    haystack = " ".join(item["title"] + item["content"] for item in hits)
    hit = any(keyword in haystack for keyword in expect_keywords)
    return {
        "role_id": role_id,
        "query": query,
        "expect": expect_keywords,
        "hit": hit,
        "top3": top,
    }


def dump_rows(store: HeartloomStore, sql: str, params: tuple) -> list[dict]:
    return [dict(row) for row in store._connection.execute(sql, params).fetchall()]


async def main_async() -> int:
    log("=== 心织双角色全链路实弹测试 ===")
    log(f"临时库存档: {DB_PATH}")
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()
    for suffix in ("-wal", "-shm"):
        extra = Path(str(DB_PATH) + suffix)
        if extra.exists():
            extra.unlink()

    config = CoreConfig.load(CORE_ROOT / "user_data" / "core_config.json")
    roles = RoleRegistry.load(CORE_ROOT / "user_data" / "roles.json")
    provider = OpenAICompatibleProvider(config)
    store = HeartloomStore(DB_PATH, roles.ids())
    service = CompanionService(
        roles,
        provider,
        store,
        memory_organizer_enabled=True,
        memory_organizer_max_entries=3,
        memory_recall_limit=8,
    )

    report: dict = {"db_path": str(DB_PATH), "save_id": SAVE_ID, "turns": []}
    exit_code = 0

    try:
        # —— 世界日 0:小玲 chat 建档 + 双角色生活事件 —— #
        log("—— 世界日 0 ——")
        chat_iter = iter(CHATS)
        tag0_role, tag0_tag, tag0_text = next(chat_iter)
        turn = await run_chat(service, tag0_role, tag0_tag, tag0_text)
        report["turns"].append(turn)

        recorded = store.record_life_events(
            save_id=SAVE_ID,
            events=[dict(item, occurred_at_unix=int(time.time())) for item in LIFE_EVENTS_DAY0],
        )
        log(f"  📋 生活事件入账: {recorded}")
        await maintenance_pass(service, "日0后")

        # —— 推进到世界日 6:旧日进入 digest pending —— #
        advance_world_days(store, 6.0)
        log("—— 日摘要与传闻传播(真实生产链路 run_due_life_digests)——")
        digest_result = await service.run_due_life_digests()
        log(f"  🌗 生活摘要: {digest_result}")
        await service.wait_for_organizer()

        digests = dump_rows(
            store,
            "SELECT memory_id, scope_role_id, source, title, importance, "
            "is_second_hand, content FROM memory_entries "
            "WHERE save_id = ? AND (source LIKE 'daily_digest' OR source LIKE 'heard_from_%') "
            "ORDER BY world_created_at",
            (SAVE_ID,),
        )
        for item in digests:
            log(
                f"  📖 [{item['scope_role_id']}] src={item['source']} {item['title']}"
                f"(importance={float(item['importance']):.2f}"
                f", is_second_hand={int(item['is_second_hand'])})"
                f": {item['content'][:60]}…"
            )
        heard = [item for item in digests if int(item["is_second_hand"]) == 1]
        spread_links = int(
            store._connection.execute(
                "SELECT COUNT(*) FROM memory_links WHERE save_id = ? AND link_type = 'spread'",
                (SAVE_ID,),
            ).fetchone()[0]
        )
        propagation_ok = bool(heard) and float(heard[0]["importance"]) > 0.0
        no_leak_small_talk = all(
            float(item["importance"]) < 0.7
            for item in digests
            if item["scope_role_id"] == NAI and int(item["is_second_hand"]) != 1
        )
        log(
            f"  👂 传闻传播: {'✅ 触发' if propagation_ok else '❌ 未触发'}"
            f"(听者记忆 {len(heard)} 条, spread 边 {spread_links})"
            f" | 小奈日常摘要不传播: {'✅' if no_leak_small_talk else '⚠️ 见报告'}"
        )

        # —— 世界日 6:双角色四轮真实对话 —— #
        log("—— 世界日 6:双角色对话 ——")
        for role_id, tag, text in chat_iter:
            turn = await run_chat(service, role_id, tag, text)
            report["turns"].append(turn)
        await maintenance_pass(service, "日6后")

        # —— 夜织(世界日 0 已关闭) —— #
        nightly = await service.run_due_nightly_consolidation()
        weave_nodes = dump_rows(
            store,
            "SELECT title FROM memory_entries WHERE save_id = ? "
            "AND source LIKE 'consolidation_%'",
            (SAVE_ID,),
        )
        log(
            f"  🌙 夜织: {nightly} | 织结节 {len(weave_nodes)} 条"
            + (f"(首条: {weave_nodes[0]['title']})" if weave_nodes else "")
        )

        # —— 评测 —— #
        log("—— 评测 ——")
        memories = dump_rows(
            store,
            "SELECT memory_id, scope_role_id, kind, title, content, importance, "
            "is_second_hand, source, lifecycle, embedding_model FROM memory_entries "
            "WHERE save_id = ?",
            (SAVE_ID,),
        )
        embedded = sum(1 for m in memories if m["embedding_model"])
        log(f"  库存: 记忆 {len(memories)} 条 | embedding 覆盖 {embedded}/{len(memories)}")
        source_histogram: dict[str, int] = {}
        for m in memories:
            source_histogram[str(m["source"])] = source_histogram.get(str(m["source"]), 0) + 1
        log(f"  来源分布: {source_histogram}")

        recall_results = []
        for role_id, query, expect in EVAL_QUERIES:
            result = await judge_recall(store, service, role_id, query, expect)
            recall_results.append(result)
            mark = "✅" if result["hit"] else "❌"
            top1 = result["top3"][0] if result["top3"] else {"title": "(空)", "score": 0}
            log(f"  {mark} [{role_id}] {query} top1={top1['title']}({top1['score']})")
        hit_count = sum(1 for item in recall_results if item["hit"])

        # 传闻记忆专项:生产召回窗口(memory_recall_limit=8)内听者应能看到
        # is_second_hand=1 的行(top-3 判定过严,livetest2 实测它排第 5)
        hvec, hmodel = await service._query_embedding("小玲那边最近发生了什么？")
        heard_hits = store.recall(
            save_id=SAVE_ID,
            role_id=NAI,
            query="小玲那边最近发生了什么？",
            limit=8,
            query_vector=hvec,
            embedding_model=hmodel,
            record_access=False,
        )
        heard_flag_ok = any(bool(item.get("is_second_hand")) for item in heard_hits)
        heard_rank = next(
            (
                index + 1
                for index, item in enumerate(heard_hits)
                if bool(item.get("is_second_hand"))
            ),
            None,
        )
        log(
            f"  👂 听者召回(生产窗口 top-8)携带 is_second_hand 标记:"
            f" {'✅' if heard_flag_ok else '❌'}(排位 {heard_rank})"
        )

        # 私域隔离:小奈的提拉米苏聊天记忆不得出现在小玲的召回
        tiramisu_ids = [
            str(m["memory_id"])
            for m in memories
            if m["scope_role_id"] == NAI
            and "提拉米苏" in (str(m["title"]) + str(m["content"]))
        ]
        tvec, tmodel = await service._query_embedding("小奈学会做什么甜点了")
        ling_hits = store.recall(
            save_id=SAVE_ID,
            role_id=LING,
            query="小奈学会做什么甜点了",
            limit=5,
            query_vector=tvec,
            embedding_model=tmodel,
            record_access=False,
        )
        leaked = [
            str(item["memory_id"]) for item in ling_hits if str(item["memory_id"]) in tiramisu_ids
        ]
        isolation_ok = bool(tiramisu_ids) and not leaked
        log(
            f"  🛡️ 私域隔离(小奈聊天私密 → 小玲): {'✅ 未泄漏' if isolation_ok else '❌ 泄漏 ' + str(leaked)}"
        )

        # 双角色心境
        mood_state: dict[str, dict] = {}
        for role_id in (LING, NAI):
            home = roles.get(role_id).mood_home
            mood = store.current_mood(SAVE_ID, role_id, home=home)
            audit = int(
                store._connection.execute(
                    "SELECT COUNT(*) FROM state_events WHERE save_id = ? "
                    "AND kind = 'mood' AND role_id = ?",
                    (SAVE_ID, role_id),
                ).fetchone()[0]
            )
            mood_state[role_id] = {"mood": mood, "home": list(home), "audit_events": audit}
            log(
                f"  💭 [{role_id}] p={mood['pleasure']:.3f} a={mood['arousal']:.3f} "
                f"d={mood['dominance']:.3f}(home={list(home)}, 审计 {audit} 条)"
            )
        mood_turns = sum(1 for t in report["turns"] if isinstance(t.get("mood"), dict))
        log(f"  💭 mood 载荷: {mood_turns}/{len(report['turns'])} 轮携带")

        claims_count = int(
            store._connection.execute(
                "SELECT COUNT(*) FROM claims WHERE save_id = ?", (SAVE_ID,)
            ).fetchone()[0]
        )
        entities_count = int(
            store._connection.execute(
                "SELECT COUNT(*) FROM entities WHERE save_id = ?", (SAVE_ID,)
            ).fetchone()[0]
        )
        log(f"  ✨ 实体 {entities_count} / 主张 {claims_count}")

        report.update(
            {
                "digest_result": digest_result,
                "digests": digests,
                "propagation_ok": propagation_ok,
                "no_leak_small_talk": no_leak_small_talk,
                "nightweave": {
                    "result": nightly,
                    "weave_titles": [row["title"] for row in weave_nodes],
                },
                "recall_eval": recall_results,
                "recall_hit_rate": round(hit_count / len(recall_results), 4),
                "heard_flag_ok": heard_flag_ok,
                "heard_rank_in_production_window": heard_rank,
                "isolation_ok": isolation_ok,
                "mood": mood_state,
                "entities": entities_count,
                "claims": claims_count,
                "world_now": store.world_now(SAVE_ID),
            }
        )
        log("")
        log(
            f"=== 召回 {hit_count}/{len(recall_results)} | 传播 {'✅' if propagation_ok else '❌'}"
            f" | 听者标记 {'✅' if heard_flag_ok else '❌'}"
            f" | 隔离 {'✅' if isolation_ok else '❌'} ==="
        )
    except Exception as exc:
        exit_code = 1
        report["fatal"] = f"{type(exc).__name__}: {exc}"
        log(f"❌ 测试中断: {type(exc).__name__}: {exc}")
        raise
    finally:
        REPORT_PATH.write_text(
            json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        log(f"完整报告: {REPORT_PATH}")
        service.close()
        store.close()
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.parse_args()
    return asyncio.run(main_async())


if __name__ == "__main__":
    raise SystemExit(main())
