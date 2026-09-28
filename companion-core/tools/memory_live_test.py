"""心织记忆实弹测试:独立临时库 + 全新存档 + 真实 LLM 多日对话召回评测。

不触碰 user_data/heartloom.sqlite3 活档:所有写入发生在系统临时目录里的
一次性数据库(save_id=livetest1)。LLM/Embedding 使用 provider_settings.json
里已配置的正式通道(chat=deepseek-flash,embedding=BGE-M3)。

流程:
  1. 四个"世界日"共 8 轮真实对话(经 CompanionService.chat 完整生产链路),
     其中埋入两组应被信念修订的事实(职业变更、饮品变更);
  2. 每日过后回填 embedding、跑三态生命周期与记忆链接回填;
  3. 评测:10 条召回查询(含 dormant 唤醒、修订后排名)、当前事实水合、
     唤醒奖励、修订链完整性;
  4. 产出 report.json + 控制台摘要。

用法:python tools/memory_live_test.py [--keep]
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

SAVE_ID = "livetest1"
ROLE_ID = "ling"
DB_PATH = Path(tempfile.gettempdir()) / "heartloom_live_test" / "heartloom.sqlite3"
REPORT_PATH = DB_PATH.parent / "report.json"

# 每轮对话:(轮次关键词, 用户文本, 检索期望关键词列表)
SCENARIO: list[tuple[str, str, list[str]]] = [
    (
        "t1",
        "小玲，正式认识一下。我叫林澈，是一名神经内科医生，平时喜欢下班后泡一壶工夫茶。",
        ["神经内科", "工夫茶"],
    ),
    (
        "t2",
        "我最近在重读《三体》，已经读到第二部《黑暗森林》了，周末基本不出门。",
        ["三体"],
    ),
    (
        "t3",
        "跟你说个事，我上周换科了，现在是急诊科的医生，排班比以前乱多了。",
        ["急诊"],
    ),
    (
        "t4",
        "我还领养了一只猫，叫年糕，特别怕生，只肯躲在我房间里。",
        ["年糕"],
    ),
    (
        "t5",
        "年糕昨天半夜第一次主动蹭我的手！我差点感动哭了。",
        ["年糕"],
    ),
    (
        "t6",
        "另外我把工夫茶具都收起来了，改成每天早上喝手冲咖啡，感觉精神好多了。",
        ["咖啡"],
    ),
    (
        "t7",
        "周末我们去看了露天电影，散场时突然下起大雨，我们淋着雨跑回家，年糕喵喵叫着在门口迎接。",
        ["雨"],
    ),
    (
        "t8",
        "对了，我想把《三体》第三部看完，你还记得我之前读到哪儿了吗？",
        ["三体"],
    ),
]

# (查询, 期望命中关键词;命中 = 关键词出现在 top3 的 title+content 里)
RECALL_QUERIES: list[tuple[str, list[str]]] = [
    ("我的工作现在是什么？", ["急诊"]),
    ("年糕是一只什么样的猫？", ["年糕"]),
    ("我每天早上喝什么？", ["咖啡"]),
    ("我的工夫茶具放哪了？", ["工夫茶", "茶具"]),
    ("《黑暗森林》讲到哪了？", ["三体"]),
    ("那天下雨发生了什么？", ["雨", "电影"]),
    ("当医生累不累？", ["急诊", "医生"]),
    ("年糕有没有亲近过我？", ["年糕", "蹭"]),
    ("我养了什么宠物？", ["年糕", "猫"]),
    ("那个周末我们做了什么？", ["电影"]),
]

CURRENT_FACTS_FORBIDDEN = ("神经内科", "工夫茶")
CURRENT_FACTS_EXPECTED = ("急诊", "咖啡")


def log(message: str) -> None:
    print(message, flush=True)


def advance_world_days(store: HeartloomStore, days: float) -> None:
    """把世界时钟直接前推 N 天(仅测试脚本允许绕过 set_journey_rate)。"""
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


def dump_memories(store: HeartloomStore) -> list[dict]:
    rows = store._connection.execute(
        """
        SELECT memory_id, kind, title, content, importance, confidence, intrinsic,
               half_life_days, lifecycle, source, source_event_id, world_created_at,
               recall_count, embedding_model
        FROM memory_entries WHERE save_id = ? ORDER BY world_created_at, created_at
        """,
        (SAVE_ID,),
    ).fetchall()
    world_now = store.world_now(SAVE_ID)
    result = []
    for row in rows:
        item = dict(row)
        item["age_days"] = round(world_now - float(row["world_created_at"]), 2)
        result.append(item)
    return result


def dump_claims(store: HeartloomStore) -> list[dict]:
    rows = store._connection.execute(
        """
        SELECT c.claim_id, s.name AS subject, c.predicate,
               COALESCE(o.name, c.object_text) AS object,
               c.world_from, c.world_to, c.superseded_by_claim_id,
               c.confidence, c.created_at
        FROM claims AS c
        JOIN entities AS s ON s.entity_id = c.subject_entity_id
        LEFT JOIN entities AS o ON o.entity_id = c.object_entity_id
        WHERE c.save_id = ? ORDER BY c.created_at, c.claim_id
        """,
        (SAVE_ID,),
    ).fetchall()
    return [dict(row) for row in rows]


def dump_entities(store: HeartloomStore) -> list[dict]:
    rows = store._connection.execute(
        """
        SELECT entity_id, name, name_norm, kind, aliases_json, world_created_at
        FROM entities WHERE save_id = ? ORDER BY world_created_at, name_norm
        """,
        (SAVE_ID,),
    ).fetchall()
    return [dict(row) for row in rows]


async def run_turn(service: CompanionService, index: int, text: str) -> dict:
    request_id = f"livetest1-t{index}-{int(time.time())}"
    reply = await service.chat(
        {
            "request_id": request_id,
            "role_id": ROLE_ID,
            "save_id": SAVE_ID,
            "text": text,
            "history": [],
            "event_type": "chat",
            "state": {},
        }
    )
    await service.wait_for_organizer()
    return reply


async def judge_recall(
    store: HeartloomStore,
    service: CompanionService,
    query: str,
    expect_keywords: list[str],
) -> dict:
    vector, model = await service._query_embedding(query)
    hits = store.recall(
        save_id=SAVE_ID,
        role_id=ROLE_ID,
        query=query,
        limit=3,
        query_vector=vector,
        embedding_model=model,
        record_access=False,
    )
    top = []
    for item in hits:
        row = store._connection.execute(
            "SELECT lifecycle FROM memory_entries WHERE memory_id = ?",
            (str(item["memory_id"]),),
        ).fetchone()
        top.append(
            {
                "memory_id": str(item["memory_id"]),
                "title": item.get("title", ""),
                "content": item.get("content", "")[:80],
                "score": item.get("recall_score", 0.0),
                "lifecycle": str(row["lifecycle"]) if row else "?",
            }
        )
    haystack = " ".join(item["title"] + item["content"] for item in hits)
    hit = any(keyword in haystack for keyword in expect_keywords)
    return {"query": query, "expect": expect_keywords, "hit": hit, "top3": top}


async def main_async(keep: bool) -> int:
    log("=== 心织记忆实弹测试 ===")
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
        # —— 写入阶段:4 个世界日 × 2 轮真实对话 —— #
        day_plan = [(0, SCENARIO[0:2]), (3, SCENARIO[2:4]), (10, SCENARIO[4:6]), (35, SCENARIO[6:8])]
        current_day = 0.0
        for day, turns in day_plan:
            if day > current_day:
                advance_world_days(store, day - current_day)
                current_day = float(day)
            log(f"—— 世界日 {day} ——")
            for tag, text, _ in turns:
                log(f"  👤 {text[:48]}…")
                started = time.monotonic()
                reply = await run_turn(service, tag, text)
                elapsed = time.monotonic() - started
                organizer_state = reply["memory"]["organizer_state"]
                recalled = reply["memory"]["recalled_count"]
                turn_claims = len(dump_claims(store))
                log(
                    f"  🌸 小玲({elapsed:.0f}s, 召回{recalled}, organizer={organizer_state}):"
                    f" {reply['reply'][:60]}…"
                )
                report["turns"].append(
                    {
                        "tag": tag,
                        "day": day,
                        "user_text": text,
                        "reply": reply["reply"],
                        "organizer_state": organizer_state,
                        "recalled_count": recalled,
                        "elapsed_s": round(elapsed, 1),
                        "claims_so_far": turn_claims,
                        # ADR-012 消费侧契约:响应携带 PAD(定性词 + 三维浮点)
                        "mood": reply.get("mood"),
                    }
                )
            await maintenance_pass(service, f"日{day}后")

        # —— 评测阶段 —— #
        world_now = store.world_now(SAVE_ID)
        log(f"—— 评测 @ 世界日 {world_now:.1f} ——")
        memories = dump_memories(store)
        claims = dump_claims(store)
        entities = dump_entities(store)
        organizer_memories = [m for m in memories if m["source"].startswith("organizer")]
        log(
            f"  库存: 总记忆 {len(memories)}(organizer {len(organizer_memories)}) | "
            f"实体 {len(entities)} | 主张 {len(claims)}"
        )

        # ADR-013:夜织——世界日 0/3 早已关闭,应由调度产出织结节
        nightly = await service.run_due_nightly_consolidation()
        log(f"  🌙 夜织: {nightly}")
        memories = dump_memories(store)
        weave_nodes = [
            m for m in memories if m["source"].startswith("consolidation_")
        ]
        weave_links = store._connection.execute(
            "SELECT COUNT(*) FROM memory_links WHERE reason = 'consolidated'"
        ).fetchone()[0]
        log(
            f"  🌙 织结节 {len(weave_nodes)} 条 / consolidated 边 {weave_links} 条"
            + (f"(首条: {weave_nodes[0]['title']})" if weave_nodes else "")
        )

        # ADR-015:实体星座契约(实体节点 + claim 边 + claim_source 缝合边)
        constellation = store.graph_page(
            save_id=SAVE_ID, role_id="", limit=200, include_entities=True
        )
        c_entities = [
            n for n in constellation["nodes"] if n.get("node_type") == "entity"
        ]
        c_claims = [e for e in constellation["edges"] if e.get("link_type") == "claim"]
        c_sources = [
            e for e in constellation["edges"] if e.get("link_type") == "claim_source"
        ]
        c_dead = [e for e in c_claims if e.get("world_to")]
        log(
            f"  ✨ 星座: 实体节点 {len(c_entities)} / claim 边 {len(c_claims)}"
            f"(失效 {len(c_dead)}) / claim_source 边 {len(c_sources)}"
        )

        # Phase 3 二手传闻实弹:小玲的高价值记忆「回家讲给」小奈听
        digest_memory = store.put_memory(
            {
                "save_id": SAVE_ID,
                "scope_role_id": ROLE_ID,
                "kind": "episodic",
                "title": "给年糕装了猫爬架",
                "content": "今天把新买的猫爬架装好了,年糕一开始绕着不敢上,后来自己爬上去睡了整个下午。",
                "importance": 0.85,
                "confidence": 0.9,
                "source_event_id": "livetest-digest-propagation",
            },
            source="daily_digest",
        )
        propagated = await service._propagate_digest(
            save_id=SAVE_ID,
            source_role=ROLE_ID,
            day_key="livetest-day-prop",
            digest_memory=digest_memory,
        )
        store.backfill_memory_links(save_id=SAVE_ID, limit=40)
        spread_links = int(
            store._connection.execute(
                "SELECT COUNT(*) FROM memory_links WHERE save_id = ? AND link_type = 'spread'",
                (SAVE_ID,),
            ).fetchone()[0]
        )
        second_hand_ok = False
        isolation_ok = False
        if propagated:
            target_scope = str(propagated.get("scope_role_id", ""))
            second_hand_ok = bool(propagated.get("is_second_hand", False))
            target_query = "年糕爬架"
            tvec, tmodel = await service._query_embedding(target_query)
            heard_hits = store.recall(
                save_id=SAVE_ID,
                role_id=target_scope,
                query=target_query,
                limit=5,
                query_vector=tvec,
                embedding_model=tmodel,
                record_access=False,
            )
            got_for_target = any(
                str(item["memory_id"]) == str(propagated["memory_id"])
                for item in heard_hits
            )
            svec, smodel = await service._query_embedding(target_query)
            source_hits = store.recall(
                save_id=SAVE_ID,
                role_id=ROLE_ID,
                query=target_query,
                limit=5,
                query_vector=svec,
                embedding_model=smodel,
                record_access=False,
            )
            leaked_to_source = any(
                str(item["memory_id"]) == str(propagated["memory_id"])
                for item in source_hits
            )
            isolation_ok = got_for_target and not leaked_to_source
            log(
                f"  👂 二手传闻: {target_scope} 收讫(is_second_hand={second_hand_ok})"
                f" / spread 边 {spread_links} | 听者可召回={got_for_target}"
                f" 讲者不越权={'OK' if not leaked_to_source else '泄漏!'}"
            )
        else:
            log("  👂 二手传闻: 传播未产出(importance<0.7 或 provider 失败)")

        # ADR-012:心境基线(organizer mood_delta 汇入后的当前值)
        role_home = roles.get(ROLE_ID).mood_home
        mood = store.current_mood(SAVE_ID, ROLE_ID, home=role_home)
        mood_audit = store._connection.execute(
            "SELECT COUNT(*) FROM state_events WHERE save_id = ? AND kind = 'mood'",
            (SAVE_ID,),
        ).fetchone()[0]
        log(
            f"  💭 心境: p={mood['pleasure']:.3f} a={mood['arousal']:.3f} "
            f"d={mood['dominance']:.3f}(home={role_home}, 审计 {mood_audit} 条)"
        )
        mood_payload_turns = sum(
            1 for turn in report["turns"] if isinstance(turn.get("mood"), dict)
        )
        mood_words_turns = sum(
            1
            for turn in report["turns"]
            if isinstance(turn.get("mood"), dict) and turn["mood"].get("words")
        )
        log(
            f"  💭 心境通道: {mood_payload_turns}/{len(report['turns'])} 轮携带 mood 载荷,"
            f" {mood_words_turns} 轮越过中性带出词(温和剧本本就应多为中性)"
        )

        # 1) 召回评测
        recall_results = []
        for query, expect in RECALL_QUERIES:
            result = await judge_recall(store, service, query, expect)
            recall_results.append(result)
            mark = "✅" if result["hit"] else "❌"
            top1 = result["top3"][0] if result["top3"] else {"title": "(空)", "score": 0}
            log(f"  {mark} [{query}] top1={top1['title']}({top1['score']})")
        hit_count = sum(1 for item in recall_results if item["hit"])

        # 2) 信念修订链:subject+predicate 相同 → 旧行应有 world_to/superseded_by
        revisions = {}
        for claim in claims:
            key = (claim["subject"], claim["predicate"])
            revisions.setdefault(key, []).append(claim)
        broken = []
        for (subject, predicate), group in revisions.items():
            group.sort(key=lambda item: float(item["created_at"]))
            for older, newer in zip(group, group[1:], strict=False):
                if not older["world_to"] and not older["superseded_by_claim_id"]:
                    broken.append(f"{subject}/{predicate} 旧主张未被修订")
        current_claims_rows = []
        entity_ids = [
            row["entity_id"]
            for row in store._connection.execute(
                "SELECT entity_id FROM entities WHERE save_id = ?", (SAVE_ID,)
            ).fetchall()
        ]
        if entity_ids:
            current_claims_rows = store.current_claims(
                save_id=SAVE_ID, entity_ids=entity_ids, limit=24
            )
        current_text = json.dumps(current_claims_rows, ensure_ascii=False)
        facts_leak = [w for w in CURRENT_FACTS_FORBIDDEN if w in current_text]
        facts_cover = [w for w in CURRENT_FACTS_EXPECTED if w in current_text]
        log(f"  修订链完整性: {'✅ 全部顶替闭环' if not broken else '❌ ' + ';'.join(broken)}")
        log(
            f"  当前事实: 含 {facts_cover} / 泄漏旧事实 {facts_leak or '无'}"
            f"(current_claims 共 {len(current_claims_rows)} 条)"
        )

        # 3) 三态生命周期 + 唤醒奖励:评测查询(record_access=False)前查,
        #    再用 record_access=True 重放《三体》查询观察 intrinsic 奖励
        before_intrinsic = {
            m["memory_id"]: float(m["intrinsic"])
            for m in memories
        }
        reward_result = await judge_recall(store, service, "三体第二部情节", ["三体"])
        reward_vector, reward_model = await service._query_embedding("三体第二部情节")
        store.recall(
            save_id=SAVE_ID,
            role_id=ROLE_ID,
            query="三体第二部情节",
            query_vector=reward_vector,
            embedding_model=reward_model,
            record_access=True,
        )
        after_memories = dump_memories(store)
        rewards = [
            {
                "title": m["title"],
                "before": before_intrinsic.get(m["memory_id"], 0.0),
                "after": float(m["intrinsic"]),
            }
            for m in after_memories
            if abs(float(m["intrinsic"]) - before_intrinsic.get(m["memory_id"], 0.0)) > 1e-9
        ]
        dormant_count = sum(1 for m in after_memories if m["lifecycle"] == "dormant")
        archived_count = sum(1 for m in after_memories if m["lifecycle"] == "archived")
        log(f"  生命周期: dormant {dormant_count} 条 / archived {archived_count} 条")
        log(f"  唤醒奖励(ADR-014 乘法稳定度 ×1.5/次): {len(rewards)} 条记忆获得奖励")

        # 4) embedding 通道覆盖
        embedded = sum(1 for m in memories if m["embedding_model"])
        log(f"  embedding 覆盖: {embedded}/{len(memories)}")

        report.update(
            {
                "memories": memories,
                "entities": entities,
                "claims": claims,
                "current_claims": current_claims_rows,
                "recall_eval": recall_results,
                "recall_hit_rate": round(hit_count / len(recall_results), 4),
                "revision_chains_broken": broken,
                "facts_leak": facts_leak,
                "facts_cover": facts_cover,
                "lifecycle": {"dormant": dormant_count, "archived": archived_count},
                "wake_rewards": rewards,
                "world_now": world_now,
                "nightweave": {
                    "result": nightly,
                    "weave_count": len(weave_nodes),
                    "consolidated_links": int(weave_links),
                    "weave_titles": [m["title"] for m in weave_nodes],
                },
                "second_hand": {
                    "propagated": bool(propagated),
                    "is_second_hand": second_hand_ok,
                    "spread_links": spread_links,
                    "isolation_ok": isolation_ok,
                },
                "mood": {
                    "values": mood,
                    "home": list(role_home),
                    "audit_events": int(mood_audit),
                },
            }
        )
        log("")
        log(f"=== 召回命中率: {hit_count}/{len(recall_results)} ===")
    except Exception as exc:  # 保持现场供排查
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
        if not keep and exit_code == 0:
            pass  # 保留库存档供用户查验;--keep 仅表示"脚本报错时也不删"(本就不删)
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="报错时也保留现场(默认本就保留)")
    args = parser.parse_args()
    return asyncio.run(main_async(args.keep))


if __name__ == "__main__":
    raise SystemExit(main())
