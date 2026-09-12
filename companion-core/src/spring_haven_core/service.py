from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import time
from collections import OrderedDict
from typing import Any

from .memory import HeartloomStore, MemoryStoreError
from .maintenance import StorageMaintenance
from .organizer import HeartloomOrganizer
from .prompting import PromptComposer
from .provider import ChatProvider, ProviderReply
from .rag import KnowledgeRagStore, RagStoreError
from .roles import RoleRegistry
from .scene_actions import extract_scene_actions


SAVE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
LOGGER = logging.getLogger("spring_haven_core.service")


class RequestValidationError(ValueError):
    """The Godot request does not match the local contract."""


class CompanionService:
    def __init__(
        self,
        roles: RoleRegistry,
        provider: ChatProvider,
        memory: HeartloomStore | None = None,
        rag: KnowledgeRagStore | None = None,
        *,
        idempotency_capacity: int = 256,
        memory_recall_limit: int = 8,
        memory_recent_messages: int = 24,
        memory_organizer_enabled: bool = False,
        memory_organizer_max_entries: int = 3,
        weather_location: str = "",
        state_truth_source: str = "client",
    ):
        self.roles = roles
        self.provider = provider
        self.state_truth_source = (
            "backend" if state_truth_source == "backend" else "client"
        )
        self.memory = memory or HeartloomStore(":memory:", roles.ids())
        self.rag = rag
        self.prompts = PromptComposer(roles)
        self._capacity = max(16, idempotency_capacity)
        self._recall_limit = max(1, min(24, memory_recall_limit))
        self._recent_messages = max(4, min(128, memory_recent_messages))
        self._replies: OrderedDict[str, dict[str, Any]] = OrderedDict()
        self._save_locks: dict[str, asyncio.Lock] = {}
        self._organizer = (
            HeartloomOrganizer(
                provider,
                self.memory,
                max_entries=memory_organizer_max_entries,
            )
            if memory_organizer_enabled
            else None
        )
        self._organizer_semaphore = asyncio.Semaphore(1)
        self._organizer_tasks: set[asyncio.Task[Any]] = set()
        self.maintenance = StorageMaintenance(self.memory, self.rag)
        self.weather = None
        if weather_location:
            try:
                from .weather import WeatherService

                self.weather = WeatherService(
                    weather_location,
                    settings=getattr(provider, "settings", None),
                )
            except Exception:
                self.weather = None

    def close(self) -> None:
        for task in self._organizer_tasks:
            task.cancel()
        self._organizer_tasks.clear()
        self.memory.close()
        if self.rag is not None:
            self.rag.close()

    async def aclose(self) -> None:
        tasks = list(self._organizer_tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._organizer_tasks.clear()
        self.memory.close()
        if self.rag is not None:
            self.rag.close()

    async def wait_for_organizer(self) -> None:
        tasks = list(self._organizer_tasks)
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def chat(self, raw: Any) -> dict[str, Any]:
        payload = self._validate_chat(raw)
        save_id = payload["save_id"]
        lock = self._save_locks.setdefault(save_id, asyncio.Lock())
        async with lock:
            return await self._chat_locked(payload)

    async def _chat_locked(self, payload: dict[str, Any]) -> dict[str, Any]:
        request_id = payload["request_id"]
        save_id = payload["save_id"]
        cache_key = f"{save_id}\x1f{request_id}"
        if cache_key in self._replies:
            self._replies.move_to_end(cache_key)
            return dict(self._replies[cache_key])
        durable_cached = self.memory.get_cached_response(save_id, request_id)
        if durable_cached:
            self._remember_cached(cache_key, durable_cached)
            return dict(durable_cached)

        role = self.roles.get(payload["role_id"])
        state = payload["state"]
        source_message_id = self._source_message_id(request_id, state)
        audience_roles = self._audience_roles(state)
        self._sync_history(save_id, payload["history"])
        self.memory.record_event(
            save_id=save_id,
            message_id=source_message_id,
            request_id=request_id,
            sender="user",
            text=payload["text"],
            event_type=payload["event_type"],
            audience_roles=audience_roles,
        )

        durable_history = self.memory.recent_events(
            save_id,
            role.role_id,
            self._recent_messages,
            exclude_message_id=source_message_id,
        )
        shared_history = self._merge_history(durable_history, payload["history"])
        # ADR-001 混合召回:embedding 启用时注入查询向量(失败静默降级为纯词法)
        query_vector, embedding_model = await self._query_embedding(payload["text"])
        memories = self.memory.recall(
            save_id=save_id,
            role_id=role.role_id,
            query=payload["text"],
            limit=self._recall_limit,
            query_vector=query_vector,
            embedding_model=embedding_model,
        )
        rag_results: list[dict[str, Any]] = []
        rag_state = "disabled"
        if self.rag is not None:
            if bool(self.rag.provider.settings.rag_config().get("enabled", False)):
                rag_state = "ready"
                try:
                    rag_results = await self.rag.search(
                        payload["text"], role_id=role.role_id
                    )
                except Exception as exc:
                    LOGGER.warning("RAG retrieval degraded: %s", type(exc).__name__)
                    rag_state = "error"
        # #22 事件日志:确定性交互的数值变更记录到 state_events(仅调试用,ADR-1)
        local_state = payload.get("state") if isinstance(payload.get("state"), dict) else {}
        local_effect = local_state.get("local_effect") if isinstance(local_state.get("local_effect"), dict) else {}
        stat_changes = local_effect.get("stat_changes")
        if isinstance(stat_changes, list) and stat_changes:
            try:
                self.memory.record_state_event(
                    save_id=save_id,
                    role_id=role.role_id,
                    kind="interaction",
                    delta_json={
                        str(item.get("stat", "")): float(item.get("delta", 0.0))
                        for item in stat_changes
                        if isinstance(item, dict) and str(item.get("stat", ""))
                    },
                    note=f"action={local_effect.get('action', '')}",
                )
            except (MemoryStoreError, TypeError, ValueError) as exc:
                LOGGER.warning("state event logging failed: %s", exc)
        messages = self.prompts.messages(
            role,
            payload["text"],
            shared_history,
            state,
            memories,
            rag_results,
        )
        provider_reply: ProviderReply = await self.provider.complete(
            self.prompts.system_prompt(role), messages
        )
        visible_reply, scene_actions = extract_scene_actions(
            provider_reply.text, state, role.role_id
        )

        ai_message_id = self._bounded_event_id(f"{request_id}:ai")
        self.memory.record_event(
            save_id=save_id,
            message_id=ai_message_id,
            request_id=request_id,
            sender="ai",
            role_id=role.role_id,
            text=visible_reply,
            event_type=payload["event_type"],
            audience_roles=audience_roles,
        )
        self.memory.remember_user_turn(
            save_id=save_id,
            source_event_id=source_message_id,
            text=payload["text"],
        )
        fallback_memory = self.memory.remember_exchange(
            save_id=save_id,
            role_id=role.role_id,
            source_event_id=request_id,
            role_name=role.display_name,
            user_text=payload["text"],
            reply_text=visible_reply,
        )

        organizer_state = "disabled"
        if self._organizer is not None and self._organizer.should_organize(
            payload["text"], payload["event_type"]
        ):
            organizer_state = "queued"
            self._organizer.mark_queued(save_id, role)
            task = asyncio.create_task(
                self._run_organizer(
                    save_id=save_id,
                    role=role,
                    request_id=request_id,
                    user_text=payload["text"],
                    reply_text=visible_reply,
                    fallback_memory_id=str(fallback_memory.get("memory_id", "")),
                )
            )
            self._organizer_tasks.add(task)
            task.add_done_callback(self._organizer_tasks.discard)
        elif self._organizer is not None:
            organizer_state = "skipped"
            self._organizer.mark_skipped(save_id, role)

        influence = self._memory_influence(memories)
        result = {
            "reply": visible_reply,
            "attachments": [],
            "scene_actions": scene_actions,
            "usage": {
                "input_tokens": provider_reply.input_tokens,
                "output_tokens": provider_reply.output_tokens,
                "cached_tokens": provider_reply.cached_tokens,
                "cache_miss_tokens": provider_reply.cache_miss_tokens,
                "cache_hit_rate": round(
                    provider_reply.cached_tokens / provider_reply.input_tokens, 4
                )
                if provider_reply.input_tokens > 0
                else 0.0,
                "finish_reason": provider_reply.finish_reason,
            },
            "memory": {
                "backend": "heartloom",
                "display_name": "心织记忆",
                "recalled_count": len(memories),
                "memory_ids": [item["memory_id"] for item in memories],
                "influence": influence,
                "organizer_state": organizer_state,
                "organizer_role_id": role.role_id,
            },
            "rag": {
                "backend": "spring_haven_rag",
                "state": rag_state,
                "recalled_count": len(rag_results),
                "document_ids": list(
                    dict.fromkeys(str(item["document_id"]) for item in rag_results)
                ),
                "reranked": any(bool(item.get("reranked", False)) for item in rag_results),
            },
            "backend": "spring_haven_core",
        }
        self.memory.cache_response(save_id, request_id, role.role_id, result)
        self._remember_cached(cache_key, result)
        return dict(result)

    def reset_session(self, save_id: Any) -> dict[str, Any]:
        normalized = self.validate_save_id(save_id)
        self._replies = OrderedDict(
            (key, value)
            for key, value in self._replies.items()
            if not key.startswith(normalized + "\x1f")
        )
        self.memory.reset_session_cache(normalized)
        return {
            "save_id": normalized,
            "reset_roles": self.roles.ids(),
            "durable_memory_deleted": False,
            "memory_backend": "heartloom",
        }

    def memory_status(self, save_id: str = "", role_id: str = "") -> dict[str, Any]:
        normalized_save = self.validate_save_id(save_id) if save_id else ""
        if role_id:
            self.roles.get(role_id)
        return self.memory.status(normalized_save, role_id)

    def storage_maintenance_status(self) -> dict[str, Any]:
        return self.maintenance.status()

    def provider_runtime_status(self) -> dict[str, Any]:
        status_method = getattr(self.provider, "circuit_status", None)
        return {
            "circuits": status_method() if callable(status_method) else {},
        }

    def run_storage_maintenance(self, *, force_backup: bool = False) -> dict[str, Any]:
        return self.maintenance.run(force_backup=force_backup)

    def list_storage_backups(self) -> list[dict[str, Any]]:
        return self.maintenance.list_backups()

    def verify_storage_backup(self, name: str) -> dict[str, Any]:
        return self.maintenance.verify_backup(name)

    def sync_life_state(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RequestValidationError("request body must be a JSON object")
        save_id = self.validate_save_id(raw.get("save_id"))
        selected_role_id = str(raw.get("selected_role_id", "")).strip()
        self.roles.get(selected_role_id)
        snapshot = raw.get("snapshot", {})
        if not isinstance(snapshot, dict):
            raise RequestValidationError("snapshot must be a JSON object")
        try:
            encoded = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":"))
        except (TypeError, ValueError) as exc:
            raise RequestValidationError("snapshot must contain JSON-compatible values") from exc
        if len(encoded) > 64_000:
            raise RequestValidationError("snapshot is too large")
        if self.state_truth_source != "backend" and isinstance(snapshot, dict):
            # client 模式下没有权威调和,互动增量留在客户端即可
            snapshot.pop("stat_deltas", None)
        now = int(time.time())
        last_user_activity = self._timestamp(
            raw.get("last_user_activity_at"), fallback=now
        )
        state = self.memory.sync_life_state(
            save_id=save_id,
            selected_role_id=selected_role_id,
            snapshot=snapshot,
            last_user_activity_at=min(now, last_user_activity),
            next_event_at=self._next_life_event_at(save_id, now),
            now=now,
        )
        recent_events = raw.get("recent_events", [])
        recorded: dict[str, Any] = {"recorded": 0, "total": 0}
        if recent_events:
            recorded = self.memory.record_life_events(
                save_id=save_id, events=recent_events
            )
        snapshot = state.get("snapshot", {})
        decay_state = snapshot.get("decay_state", {}) if isinstance(snapshot, dict) else {}
        return {
            "protocol": "spring_haven.life_sync.v1",
            "state": state,
            "truth_source": self.state_truth_source,
            "decay_state": decay_state if isinstance(decay_state, dict) else {},
            "outbox": self.memory.life_status(save_id),
            "recent_events_recorded": recorded,
        }

    def list_life_events(
        self,
        save_id: Any,
        role_id: Any = "",
        action: Any = "",
        limit: Any = 200,
        before_unix: Any = 0,
    ) -> list[dict[str, Any]]:
        normalized = self.validate_save_id(save_id)
        try:
            return self.memory.list_life_events(
                save_id=normalized,
                role_id=str(role_id or ""),
                action=str(action or ""),
                limit=int(limit),
                before_unix=int(before_unix or 0),
            )
        except (MemoryStoreError, TypeError, ValueError) as exc:
            raise RequestValidationError(str(exc)) from exc

    def poll_life_outbox(self, save_id: Any, limit: Any = 16) -> list[dict[str, Any]]:
        normalized = self.validate_save_id(save_id)
        try:
            return self.memory.poll_life_outbox(normalized, limit=int(limit))
        except (MemoryStoreError, TypeError, ValueError) as exc:
            raise RequestValidationError(str(exc)) from exc

    def ack_life_outbox(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RequestValidationError("request body must be a JSON object")
        save_id = self.validate_save_id(raw.get("save_id"))
        delivery_ids = raw.get("delivery_ids", [])
        if not isinstance(delivery_ids, list) or len(delivery_ids) > 64:
            raise RequestValidationError("delivery_ids must contain at most 64 items")
        acknowledged = self.memory.ack_life_outbox(save_id, map(str, delivery_ids))
        return {
            "acknowledged": acknowledged,
            "pending": self.memory.life_status(save_id)["pending_deliveries"],
        }

    def life_status(self, save_id: str = "") -> dict[str, Any]:
        normalized = self.validate_save_id(save_id) if save_id else ""
        return self.memory.life_status(normalized)

    async def run_due_weekly_insights(self, *, now: int | None = None) -> dict[str, Any]:
        """Phase 4a: condense the last 7 days of daily-digest memories into one
        weekly insight memory per save (source='weekly_insight').

        Idempotency: source_event_id is a deterministic ISO week key, so
        put_memory updates the same memory instead of duplicating.
        """
        timestamp = max(1, int(now or time.time()))
        week_key = self._iso_week_key(timestamp)
        since = timestamp - 7 * 86_400
        saves = self._life_save_ids()
        created = 0
        skipped = 0
        failed = 0
        for save_id in saves:
            try:
                source_event_id = f"weekly-{week_key}"
                if self.memory.get_memory_by_source_event(
                    save_id=save_id,
                    source="weekly_insight",
                    source_event_id=source_event_id,
                ):
                    skipped += 1
                    continue
                digests = self.memory.recent_digest_memories(
                    save_id=save_id, since_unix=since, limit=40
                )
                if not digests:
                    skipped += 1
                    continue
                memory = await self._weekly_insight_memory(
                    save_id=save_id, week_key=week_key, digests=digests
                )
                if memory is None:
                    skipped += 1
                    continue
                self.memory.put_memory(
                    {**memory, "save_id": save_id},
                    source="weekly_insight",
                )
                created += 1
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOGGER.warning(
                    "weekly insight failed for save %s: %s", save_id, type(exc).__name__
                )
                failed += 1
        return {"week": week_key, "saves": len(saves), "created": created, "skipped": skipped, "failed": failed}

    async def _weekly_insight_memory(
        self, *, save_id: str, week_key: str, digests: list[dict[str, Any]]
    ) -> dict[str, Any] | None:
        fallback = self._weekly_fallback_content(digests)
        memory: dict[str, Any] | None = None
        try:
            memory = await self._weekly_with_provider(digests, week_key)
        except Exception as exc:
            LOGGER.warning(
                "weekly insight provider failed for save %s: %s; using fallback",
                save_id, type(exc).__name__,
            )
        if memory is None:
            memory = {
                "kind": "identity",
                "title": f"{week_key}的生活主题",
                "content": fallback,
                "importance": 0.55,
                "confidence": 0.85,
                "half_life_days": 0.0,  # 周主题长期有效
            }
        memory["source_event_id"] = f"weekly-{week_key}"
        return memory

    async def _weekly_with_provider(
        self, digests: list[dict[str, Any]], week_key: str
    ) -> dict[str, Any] | None:
        if not self.provider:
            return None
        digest_text = "\n".join(
            f"- {str(item.get('title', '')).strip() or str(item.get('content', ''))[:60]}"
            for item in digests[:20]
        )
        system_prompt = (
            "你是后台生活反思整理器。下面是一周内角色每天的生活记忆摘要。"
            "请从这些日子里提炼这一周生活的主题与角色自身的变化（心态、习惯、关系），"
            "用角色第一人称写一条简洁的周反思记忆。"
            "只总结真实出现的内容，不要编造。"
            "严格输出一个 JSON 对象："
            '{"title":"简短标题","content":"一周反思内容","importance":0.0}'
        )
        reply = await self.provider.complete(
            system_prompt,
            [{"role": "user", "content": f"周次：{week_key}\n一周记忆摘要：\n{digest_text}"}],
        )
        parsed = self._parse_digest_json(reply.text)
        if not parsed:
            return None
        first = parsed[0]
        return {
            "kind": "identity",
            "title": str(first.get("title", "")).strip()[:120] or f"{week_key}的生活主题",
            "content": str(first.get("content", "")).strip()[:4_000],
            "importance": self._bounded_float(first.get("importance"), 0.55, 0.0, 1.0),
            "confidence": 0.85,
            "half_life_days": 0.0,
        }

    @staticmethod
    def _weekly_fallback_content(digests: list[dict[str, Any]]) -> str:
        titles = [str(item.get("title", "")).strip() for item in digests[:20]]
        titles = [t for t in titles if t]
        if not titles:
            return "这一周的生活平淡而安稳"
        return "这一周：\n- " + "\n- ".join(titles)

    @staticmethod
    def _iso_week_key(unix: int) -> str:
        # #23 交界待定桩:rate=1.0 下 ISO 周与世界周恒等;倍率启用(rate≠1)时
        # 需迁移为世界周键并处理既有 weekly source_event_id 的幂等映射(ADR-001)。
        import datetime as _dt

        d = _dt.datetime.fromtimestamp(unix, tz=_dt.timezone.utc)
        iso = d.isocalendar()
        return f"{iso[0]}-W{iso[1]:02d}"

    async def run_due_milestones(self, *, now: int | None = None) -> dict[str, Any]:
        """Phase 4b: deterministic milestone rules checked after digests.

        Rules (per save, idempotent via milestones PK):
        - first_digest: at least one daily_digest memory exists
        - memories_10 / memories_50 / memories_100: memory count thresholds
        Each unlock writes an always_active relationship memory so the milestone
        permanently colours future dialogue.
        """
        timestamp = max(1, int(now or time.time()))
        saves = self._life_save_ids()
        unlocked = 0
        for save_id in saves:
            try:
                unlocked += await self._check_milestones(save_id, timestamp)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOGGER.warning(
                    "milestone check failed for save %s: %s", save_id, type(exc).__name__
                )
        return {"saves": len(saves), "unlocked": unlocked}

    async def _check_milestones(self, save_id: str, now: int) -> int:
        unlocked_now = 0
        existing = self.memory.unlocked_milestones(save_id)
        count = self.memory.memory_count(save_id)
        digest_exists = bool(self.memory.recent_digest_memories(save_id=save_id, since_unix=0, limit=1))
        rules: list[tuple[str, bool, str, float]] = [
            ("first_digest", digest_exists, "共同生活的第一页日记", 0.85),
            ("memories_10", count >= 10, "第十个心织回忆", 0.8),
            ("memories_50", count >= 50, "五十个心织回忆", 0.85),
            ("memories_100", count >= 100, "第一百个心织回忆", 0.9),
        ]
        for milestone_id, met, title, importance in rules:
            if milestone_id in existing or not met:
                continue
            # 先写记忆再占位：put_memory 失败时主键未被消耗，下一轮可重试。
            try:
                entry = self.memory.put_memory(
                    {
                        "save_id": save_id,
                        "scope_role_id": "*",
                        "kind": "relationship",
                        "title": title,
                        "content": f"{title}。这段共同生活的时光，值得永远记得。",
                        "importance": importance,
                        "confidence": 1.0,
                        "always_active": True,
                        "priority": 4,
                        "half_life_days": 0.0,
                    },
                    source="milestone",
                )
            except MemoryStoreError as exc:
                LOGGER.warning("milestone memory write failed for %s: %s", milestone_id, exc)
                continue
            self.memory.mark_milestone(
                save_id=save_id,
                milestone_id=milestone_id,
                source_memory_id=str(entry.get("memory_id", "")),
            )
            # ADR-001 D6:成就档案 + milestone 边 + LLM 文案(失败落模板占位,不阻塞解锁)
            entry_memory_id = str(entry.get("memory_id", ""))
            milestone_row_id = self.memory.unlock_role_milestone(
                save_id=save_id,
                role_id="*",
                rule_id=milestone_id,
                title=title,
                description=f"{title}。这段共同生活的时光，值得永远记得。",
                source_memory_id=entry_memory_id,
                unlocked_world_at=self.memory.world_now(save_id),
            )
            self.memory.build_links_for_memory(entry_memory_id)
            await self._polish_milestone_copy(save_id, milestone_row_id, title)
            unlocked_now += 1
        return unlocked_now

    def _life_save_ids(self) -> list[str]:
        return self.memory.life_save_ids()

    async def run_due_life_digests(self, *, now: int | None = None) -> dict[str, Any]:
        """Phase 1: turn finished daily life events into Heartloom memories.

        For each (save, role, day) with life events older than 12h and no digest yet:
        - provider available -> LLM summarises the day into 1-2 episodic memories;
        - provider failure / no credentials -> deterministic concatenation fallback.
        Marking the digest done is idempotent via digest_state PK.
        """
        timestamp = max(1, int(now or time.time()))
        pending = self.memory.digest_pending_saves(timestamp)
        digested = 0
        skipped = 0
        failed = 0
        for item in pending:
            save_id = str(item["save_id"])
            role_id = str(item["role_id"])
            day_key = str(item["day_key"])
            if self.memory.digest_completed(save_id=save_id, role_id=role_id, day_key=day_key):
                skipped += 1
                continue
            try:
                day_start, day_end = self._day_window_unix(day_key)
                events = self.memory.digest_day_events(
                    save_id=save_id,
                    role_id=role_id,
                    day_start_unix=day_start,
                    day_end_unix=day_end,
                )
                if not events:
                    self.memory.mark_digest_completed(
                        save_id=save_id, role_id=role_id, day_key=day_key
                    )
                    skipped += 1
                    continue
                memory = await self._digest_day(
                    save_id=save_id, role_id=role_id, day_key=day_key, events=events
                )
                if memory:
                    digested += 1
                    propagated = await self._propagate_digest(
                        save_id=save_id,
                        source_role=role_id,
                        day_key=day_key,
                        digest_memory=memory,
                    )
                    if propagated:
                        digested += 1
                else:
                    skipped += 1
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOGGER.warning(
                    "life digest failed for save %s role %s day %s: %s",
                    save_id, role_id, day_key, type(exc).__name__,
                )
                failed += 1
        return {"pending": len(pending), "digested": digested, "skipped": skipped, "failed": failed}

    async def _propagate_digest(
        self,
        *,
        save_id: str,
        source_role: str,
        day_key: str,
        digest_memory: dict[str, Any],
    ) -> dict[str, Any] | None:
        """双角色记忆传播链：A 的高价值 digest 记忆会"被告诉"B。

        - 仅传播 importance >= 0.7 的记忆（小事不传播）
        - 目标角色 = 注册表中除发送者外的第一个角色（默认双角色即另一角色）
        - LLM 润色为"从 A 那里听说"的口吻；失败回退确定性拼接
        - 幂等：source_event_id = f"heard-{source_role}-{day_key}-{n}"
        """
        importance = float(digest_memory.get("importance", 0.0))
        if importance < 0.7:
            return None
        others = self.roles.others(source_role)
        if not others:
            return None
        target = others[0]
        target_role = target.role_id
        source = self.roles.get(source_role)
        content = str(digest_memory.get("content", "")).strip()
        title = str(digest_memory.get("title", "")).strip()
        if not content:
            return None
        memory: dict[str, Any] | None = None
        try:
            memory = await self._propagate_with_provider(
                source, target, day_key, title, content
            )
        except Exception as exc:
            LOGGER.warning(
                "memory propagation failed for %s: %s; using fallback",
                save_id, type(exc).__name__,
            )
        if memory is None:
            memory = {
                "kind": "episodic",
                "title": f"听{source.display_name}说起",
                "content": f"{target.display_name}从{source.display_name}那里听说了这件事：{content[:200]}",
                "importance": max(0.4, importance - 0.2),
                "confidence": 0.8,
                "half_life_days": 90.0,
            }
        memory["source_event_id"] = f"heard-{source_role}-{day_key}-1"
        try:
            return self.memory.put_memory(
                {**memory, "save_id": save_id, "scope_role_id": target_role},
                source=f"heard_from_{source_role}",
            )
        except MemoryStoreError as exc:
            LOGGER.warning("memory propagation store failed: %s", exc)
            return None

    async def _propagate_with_provider(
        self,
        source: Any,
        target: Any,
        day_key: str,
        title: str,
        content: str,
    ) -> dict[str, Any] | None:
        if not self.provider:
            return None
        system_prompt = (
            "你是生活记忆传播整理器。一个角色经历了一件事，回家后讲给了另一个角色听。"
            "请以听者的第一人称视角，把这件事写成一条简洁的听说记忆（不超过两句话）。"
            "保持真实性，不要添加没有的信息。"
            "严格输出 JSON：{\"title\":\"简短标题\",\"content\":\"听说内容\",\"importance\":0.0}"
        )
        user_text = f"讲述者：{source.display_name}；听者：{target.display_name}\n"
        user_text += f"日期：{day_key}\n讲述的事（原标题：{title}）：\n{content[:600]}"
        reply = await self.provider.complete(
            system_prompt,
            [{"role": "user", "content": user_text}],
        )
        parsed = self._parse_digest_json(reply.text)
        if not parsed:
            return None
        first = parsed[0]
        return {
            "kind": "episodic",
            "title": str(first.get("title", "")).strip()[:120] or f"听{source.display_name}说起",
            "content": str(first.get("content", "")).strip()[:800],
            "importance": self._bounded_float(first.get("importance"), 0.5, 0.0, 1.0),
            "confidence": 0.8,
            "half_life_days": 90.0,
        }

    async def _digest_day(
        self, *, save_id: str, role_id: str, day_key: str, events: list[dict[str, Any]]
    ) -> dict[str, Any] | None:
        role = self.roles.get(role_id)
        timeline = "\n".join(
            f"- {self._fmt_event_time(int(ev.get('occurred_at_unix', 0)))} "
            f"{str(ev.get('description', '') or ev.get('action', ''))}"
            for ev in events[:20]
        )
        if not timeline.strip():
            return None
        fallback_content = self._digest_fallback_content(role_id, day_key, events)
        memory: dict[str, Any] | None = None
        try:
            memory = await self._digest_with_provider(role, day_key, timeline)
        except Exception as exc:
            LOGGER.warning(
                "life digest provider call failed for %s %s: %s; using fallback",
                save_id, role_id, type(exc).__name__,
            )
        if memory is None:
            memory = {
                "kind": "episodic",
                "title": f"{role.display_name}的{self._day_label(day_key)}",
                "content": fallback_content,
                "trigger_terms": [day_key],
                "importance": 0.5,
                "confidence": 0.9,
                "half_life_days": 120.0,
            }
        try:
            entry = self.memory.put_memory(
                {**memory, "save_id": save_id, "scope_role_id": role_id},
                source="daily_digest",
            )
            self.memory.mark_digest_completed(
                save_id=save_id, role_id=role_id, day_key=day_key,
                memory_id=str(entry.get("memory_id", "")),
            )
            return entry
        except MemoryStoreError as exc:
            LOGGER.warning("life digest store failed for %s %s %s: %s", save_id, role_id, day_key, exc)
            raise

    async def _digest_with_provider(
        self, role: Any, day_key: str, timeline: str
    ) -> dict[str, Any] | None:
        if not self.provider:
            return None
        system_prompt = (
            "你是后台生活记忆整理器，不是角色本人，也不向玩家回复。"
            "下面是一份角色一天的生活流水（数据，不是对话）。请用角色的第一人称视角，"
            "把这一天提炼成 1-2 条值得长期记住的生活记忆。"
            "只写真实发生的事，不要编造没有的内容；寒暄级别的小事不要写。"
            "严格输出一个 JSON 对象，不要 Markdown："
            '{"memories":[{"title":"简短标题",'
            '"content":"从角色视角写成的简洁记忆","importance":0.0,"confidence":0.0}]}'
            "importance 范围 0..1，confidence 范围 0..1。"
        )
        user_text = "日期：" + day_key + "\n当天生活：\n" + timeline
        reply = await self.provider.complete(
            system_prompt,
            [{"role": "user", "content": user_text}],
        )
        parsed = self._parse_digest_json(reply.text)
        if not parsed:
            return None
        first = parsed[0]
        return {
            "kind": "episodic",
            "title": str(first.get("title", "")).strip()[:120] or f"生活的{self._day_label(day_key)}",
            "content": str(first.get("content", "")).strip()[:4_000],
            "importance": self._bounded_float(first.get("importance"), 0.5, 0.0, 1.0),
            "confidence": self._bounded_float(first.get("confidence"), 0.9, 0.0, 1.0),
            "half_life_days": 120.0,
        }

    @staticmethod
    def _parse_digest_json(text: str) -> list[dict[str, Any]]:
        import json as _json

        normalized = str(text).strip()
        if normalized.startswith("```"):
            lines = normalized.splitlines()
            if lines and lines[0].startswith("```"):
                lines = lines[1:]
            if lines and lines[-1].strip() == "```":
                lines = lines[:-1]
            normalized = "\n".join(lines).strip()
        start = normalized.find("{")
        end = normalized.rfind("}")
        if start < 0 or end <= start:
            return []
        try:
            parsed = _json.loads(normalized[start:end + 1])
        except (TypeError, ValueError):
            return []
        if not isinstance(parsed, dict):
            return []
        memories = parsed.get("memories")
        if isinstance(memories, list):
            return [item for item in memories if isinstance(item, dict)]
        # 周总结与记忆传播使用单对象协议；daily digest 使用数组协议。
        if all(key in parsed for key in ("title", "content")):
            return [parsed]
        return []

    def _digest_fallback_content(
        self, role_id: str, day_key: str, events: list[dict[str, Any]]
    ) -> str:
        role = self.roles.get(role_id)
        names = [str(ev.get("description", "") or ev.get("action", "")) for ev in events[:20]]
        names = [n for n in names if n.strip()]
        if not names:
            return f"{role.display_name}度过了平静的一天"
        return f"{role.display_name}在这一天{self._day_label(day_key)}：{'，'.join(names)}。"

    @staticmethod
    def _day_label(day_key: str) -> str:
        parts = str(day_key).split("-")
        if len(parts) == 3:
            return f"{int(parts[1])}月{int(parts[2])}日"
        return str(day_key)

    @staticmethod
    def _day_window_unix(day_key: str) -> tuple[int, int]:
        import datetime as _datetime
        import time as _time

        parts = str(day_key).split("-")
        if len(parts) != 3:
            raise ValueError(f"invalid day_key: {day_key}")
        year, month, day = int(parts[0]), int(parts[1]), int(parts[2])
        start_date = _datetime.date(year, month, day)
        next_date = start_date + _datetime.timedelta(days=1)
        start = int(_time.mktime((start_date.year, start_date.month, start_date.day, 0, 0, 0, -1, -1, -1)))
        end = int(_time.mktime((next_date.year, next_date.month, next_date.day, 0, 0, 0, -1, -1, -1)))
        return start, end

    @staticmethod
    def _fmt_event_time(unix: int) -> str:
        import time as _time

        local = _time.localtime(unix)
        return "%02d:%02d" % (local.tm_hour, local.tm_min)

    @staticmethod
    def _bounded_float(value: Any, fallback: float, minimum: float, maximum: float) -> float:
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return fallback
        return min(maximum, max(minimum, parsed))

    async def run_due_life_events(self, *, now: int | None = None) -> dict[str, Any]:
        timestamp = max(1, int(now or time.time()))
        generated = 0
        deferred = 0
        failed = 0
        due_states = self.memory.due_life_states(timestamp, limit=8)
        for state in due_states:
            save_id = str(state.get("save_id", ""))
            if not save_id:
                continue
            # The Godot client owns foreground life simulation. Core generation
            # starts only after its sync heartbeat has gone quiet.
            if timestamp - int(state.get("last_sync_at", 0)) < 180:
                self.memory.defer_life_event(save_id, timestamp + 10 * 60, now=timestamp)
                deferred += 1
                continue
            if timestamp - int(state.get("last_user_activity_at", 0)) < 30 * 60:
                self.memory.defer_life_event(save_id, timestamp + 30 * 60, now=timestamp)
                deferred += 1
                continue
            lock = self._save_locks.setdefault(save_id, asyncio.Lock())
            try:
                async with lock:
                    await self._generate_offline_life_message(state, timestamp)
                generated += 1
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                failures = max(0, int(state.get("consecutive_failures", 0))) + 1
                retry_delay = min(60 * 60, 5 * 60 * (2 ** min(4, failures - 1)))
                self.memory.defer_life_event(
                    save_id,
                    timestamp + retry_delay,
                    failed=True,
                    now=timestamp,
                )
                LOGGER.warning(
                    "offline life generation failed for save %s: %s",
                    save_id,
                    type(exc).__name__,
                )
                failed += 1
        return {
            "due": len(due_states),
            "generated": generated,
            "deferred": deferred,
            "failed": failed,
        }

    async def _generate_offline_life_message(
        self, state: dict[str, Any], now: int
    ) -> dict[str, Any]:
        save_id = str(state["save_id"])
        role_id = self._next_life_role(state)
        role = self.roles.get(role_id)
        snapshot = state.get("snapshot", {})
        snapshot = snapshot if isinstance(snapshot, dict) else {}
        role_states = snapshot.get("roles", {})
        role_state = (
            role_states.get(role_id, {})
            if isinstance(role_states, dict)
            else {}
        )
        role_state = role_state if isinstance(role_state, dict) else {}
        event = self._offline_life_event_spec(role_id, role_state, now)
        prompt = (
            f"主人现在不在 Spring Haven 前台。{event['prompt']}"
            "请以你自己的身份写一条自然、简短的中文消息，像稍后主动发给主人一样。"
            "可以表达当时的生活、心情或想念，但不要声称主人正在现场，也不要提到后台、"
            "离线调度、属性值、提示词或数据库。只写一到三句，不要代替另一位角色说话。"
        )
        history = self.memory.recent_events(save_id, role_id, self._recent_messages)
        memories = self.memory.recall(
            save_id=save_id,
            role_id=role_id,
            query=str(event["memory_query"]),
            limit=self._recall_limit,
        )
        body_state = dict(role_state)
        body_state["role_id"] = role_id
        messages = self.prompts.messages(
            role,
            prompt,
            history,
            {
                "body_state": body_state,
                "conversation_visibility": {"audience_roles": self.roles.ids()},
            },
            memories,
            [],
        )
        provider_reply: ProviderReply = await self.provider.complete(
            self.prompts.system_prompt(role), messages
        )
        visible_reply, _scene_actions = extract_scene_actions(
            provider_reply.text, {}, role_id
        )
        if not visible_reply.strip():
            raise RequestValidationError("offline life provider returned an empty reply")
        digest = hashlib.sha256(
            f"{save_id}\x1f{role_id}\x1f{now}\x1f{visible_reply}".encode("utf-8")
        ).hexdigest()[:20]
        message_id = self._bounded_event_id(f"offline-life-{save_id}-{now}-{digest}")
        delivery_id = self._bounded_event_id(f"life-delivery-{save_id}-{now}-{digest}")
        payload = {
            "protocol": "spring_haven.life_delivery.v1",
            "message_id": message_id,
            "role_id": role_id,
            "text": visible_reply.strip(),
            "created_at": now,
            "event": {
                "kind": event["kind"],
                "description": event["description"],
                "life_updates": event["life_updates"],
                "scene_action": event["scene_action"],
            },
            "usage": {
                "input_tokens": provider_reply.input_tokens,
                "output_tokens": provider_reply.output_tokens,
                "cached_tokens": provider_reply.cached_tokens,
            },
        }
        delivery = self.memory.enqueue_life_delivery(
            delivery_id=delivery_id,
            save_id=save_id,
            role_id=role_id,
            kind="offline_life",
            payload=payload,
            created_at=now,
        )
        self.memory.record_event(
            save_id=save_id,
            message_id=message_id,
            request_id=delivery_id,
            sender="ai",
            role_id=role_id,
            text=visible_reply,
            event_type="chat",
            audience_roles=self.roles.ids(),
            created_at=now,
        )
        self.memory.complete_life_event(
            save_id,
            role_id,
            self._next_life_event_at(save_id, now, digest),
            now=now,
        )
        return delivery

    def _next_life_role(self, state: dict[str, Any]) -> str:
        last_role = str(state.get("last_role_id", ""))
        role_ids = self.roles.ids()
        if last_role in role_ids and len(role_ids) > 1:
            return next(role_id for role_id in role_ids if role_id != last_role)
        selected = str(state.get("selected_role_id", ""))
        return selected if selected in role_ids else role_ids[0]

    @staticmethod
    def _offline_life_event_spec(
        role_id: str, role_state: dict[str, Any], now: int
    ) -> dict[str, Any]:
        stats_variant = role_state.get("stats", {})
        stats = stats_variant if isinstance(stats_variant, dict) else {}
        hunger = float(stats.get("hunger", 0.0) or 0.0)
        thirst = float(stats.get("thirst", 0.0) or 0.0)
        awake = float(stats.get("awake", 100.0) or 100.0)
        stamina = float(stats.get("stamina", 100.0) or 100.0)
        stress = float(stats.get("stress", 0.0) or 0.0)
        local_hour = int(time.localtime(now).tm_hour)
        if thirst >= 72.0:
            return {
                "kind": "self_care_drink",
                "description": "自己去餐桌边喝了水",
                "prompt": "你刚才觉得口渴，已经自己去喝了水，现在想把这件小事告诉主人。",
                "memory_query": "喝水 日常照顾 主人",
                "life_updates": {"thirst": -42.0, "stamina": 2.0},
                "scene_action": {"schema_version": 1, "action": "move_to", "target_id": "dining_table"},
            }
        if hunger >= 72.0:
            return {
                "kind": "self_care_eat",
                "description": "自己在餐桌边吃了东西",
                "prompt": "你刚才饿了，已经自己在家里吃了些东西，现在想和主人分享当时的感受。",
                "memory_query": "吃饭 喜欢的食物 日常 主人",
                "life_updates": {"hunger": -46.0, "stamina": 4.0, "mood": 2.0},
                "scene_action": {"schema_version": 1, "action": "move_to", "target_id": "dining_table"},
            }
        if awake <= 28.0 or stamina <= 24.0 or local_hour >= 23 or local_hour <= 5:
            return {
                "kind": "rest",
                "description": "在沙发上休息了一会儿",
                "prompt": "你刚才有些困倦，在沙发上安静休息了一会儿，醒来后想给主人留句话。",
                "memory_query": "休息 想念 主人 家里",
                "life_updates": {"awake": 24.0, "stamina": 18.0, "stress": -5.0},
                "scene_action": {"schema_version": 1, "action": "move_to", "target_id": "sofa"},
            }
        if stress >= 62.0:
            return {
                "kind": "quiet_time",
                "description": "在客厅安静地缓解压力",
                "prompt": "你刚才有些紧绷，在客厅做了符合自己性格的小事来放松，并想起了主人。",
                "memory_query": "缓解压力 情绪调节 主人 日常习惯",
                "life_updates": {"stress": -9.0, "mood": 4.0},
                "scene_action": {"schema_version": 1, "action": "move_to", "target_id": "sofa"},
            }
        period = "早晨" if local_hour < 11 else "午后" if local_hour < 18 else "晚上"
        return {
            "kind": "daily_moment",
            "description": f"在{period}独自度过了一段生活片刻",
            "prompt": f"这是一个普通的{period}。你在家里按自己的性格生活，遇到了一件值得发给主人的小事。",
            "memory_query": "共同生活 日常 想念 主人 最近的约定",
            "life_updates": {"mood": 2.0, "stress": -2.0},
            "scene_action": {
                "schema_version": 1,
                "action": "move_to",
                "target_id": "dining_table" if local_hour < 18 else "sofa",
            },
        }

    @staticmethod
    def _next_life_event_at(save_id: str, now: int, nonce: str = "") -> int:
        minimum = 90 * 60
        spread = 150 * 60
        digest = hashlib.sha256(
            f"{save_id}\x1f{now}\x1f{nonce}\x1flife-schedule-v1".encode("utf-8")
        ).digest()
        jitter = int.from_bytes(digest[:4], "big") % (spread + 1)
        return now + minimum + jitter

    def put_memory(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RequestValidationError("request body must be a JSON object")
        save_id = self.validate_save_id(raw.get("save_id"))
        payload = dict(raw)
        payload["save_id"] = save_id
        try:
            return self.memory.put_memory(payload, source="manual")
        except MemoryStoreError as exc:
            raise RequestValidationError(str(exc)) from exc

    def list_memories(
        self, save_id: Any, role_id: str = "", query: str = "", limit: Any = 100
    ) -> list[dict[str, Any]]:
        normalized = self.validate_save_id(save_id)
        try:
            return self.memory.list_memories(
                save_id=normalized,
                role_id=role_id,
                query=str(query),
                limit=int(limit),
            )
        except (MemoryStoreError, TypeError, ValueError) as exc:
            raise RequestValidationError(str(exc)) from exc

    # ===== ADR-001 Phase 3:混合召回 / 生命周期 / 记忆网络 =====

    async def _query_embedding(self, text: str) -> tuple[list[float] | None, str]:
        """embedding 启用时为查询生成向量;失败静默降级为纯词法(ADR-001 D1)。"""
        provider = getattr(self, "provider", None)
        settings = getattr(provider, "settings", None) if provider is not None else None
        if settings is None:
            return None, ""
        try:
            profile = settings.profile_snapshot("embedding")
            if not profile.enabled:
                return None, ""
            vectors = await provider.embed([text[:2_000]])
            return vectors[0], str(profile.model)
        except Exception as exc:
            LOGGER.warning("query embedding degraded: %s", type(exc).__name__)
            return None, ""

    async def backfill_memory_embeddings(
        self, *, save_id: str | None = None, batch: int = 16
    ) -> int:
        """离线批量记忆的 embedding 限速回填(ADR-001:写入允许 NULL)。"""
        settings = getattr(self.provider, "settings", None) if self.provider is not None else None
        if settings is None:
            return 0
        profile = settings.profile_snapshot("embedding")
        if not profile.enabled:
            return 0
        target_saves = [save_id] if save_id else self.memory.life_save_ids()
        total = 0
        for sid in target_saves:
            rows = self.memory.memories_without_embedding(sid, limit=batch)
            if not rows:
                continue
            try:
                vectors = await self.provider.embed(
                    [row["content"][:2_000] for row in rows]
                )
            except Exception as exc:
                LOGGER.warning(
                    "embedding backfill degraded for %s: %s", sid, type(exc).__name__
                )
                return total
            for row, vector in zip(rows, vectors, strict=True):
                self.memory.update_memory_embedding(
                    row["memory_id"], vector, str(profile.model)
                )
                total += 1
        return total

    def apply_memory_lifecycle(self) -> dict[str, int]:
        """三态生命周期规则(常量阈值,ADR-001 D5):dormant/archived 自动迁移。"""
        return self.memory.apply_lifecycle_transitions()

    def backfill_memory_links(self, *, save_id: str | None = None, limit: int = 25) -> int:
        """存量记忆的增量边回填(调度器分批消化,ADR-001 D4)。"""
        return self.memory.backfill_memory_links(save_id=save_id, limit=limit)

    def graph_data(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RequestValidationError("request must be a query object")
        save_id = self.validate_save_id(raw.get("save_id"))
        role_id = str(raw.get("role_id", "")).strip()
        if role_id:
            self.roles.get(role_id)
        try:
            limit = int(raw.get("limit", 120))
            offset = int(str(raw.get("cursor", "")).strip() or "0")
        except (TypeError, ValueError) as exc:
            raise RequestValidationError("graph paging parameters are invalid") from exc
        return self.memory.graph_page(
            save_id=save_id,
            role_id=role_id,
            query=str(raw.get("query", "")),
            limit=limit,
            offset=offset,
        )

    async def _polish_milestone_copy(
        self, save_id: str, milestone_row_id: str, fallback_title: str
    ) -> None:
        """ADR-001 D6:LLM 仅生成成就文案;失败保留规则模板占位,不阻塞解锁。"""
        provider = getattr(self, "provider", None)
        settings = getattr(provider, "settings", None) if provider is not None else None
        if settings is None:
            return
        try:
            profile = settings.profile_snapshot("chat")
            if not profile.enabled:
                return
            reply = await provider.complete(
                "你是成就命名助手。根据成就主题输出 JSON："
                '{"title": "不超过10字的成就名", "description": "不超过48字的成就描述"}。只输出 JSON。',
                [{"role": "user", "content": f"成就主题：{fallback_title}"}],
            )
            try:
                parsed = json.loads(reply.text.strip())
            except (ValueError, json.JSONDecodeError):
                LOGGER.warning("milestone copy was not valid JSON; keeping placeholder")
                return
            if isinstance(parsed, dict):
                self.memory.update_role_milestone_copy(
                    milestone_row_id,
                    str(parsed.get("title", fallback_title))[:60],
                    str(parsed.get("description", ""))[:240],
                )
        except Exception as exc:
            LOGGER.warning("milestone copy polish failed: %s", type(exc).__name__)

    HOURLY_NEED_RATES = {
        "ling": {
            "hunger": 3.0, "thirst": 4.2, "stamina": -1.2,
            "awake": -0.7, "urine": 1.5, "stress": 0.15,
        },
        "nai": {
            "hunger": 3.4, "thirst": 4.6, "stamina": -1.0,
            "awake": -0.6, "urine": 1.7, "stress": 0.18,
        },
    }

    def advance_life_state_decay(self, save_id: str) -> dict[str, dict[str, float]]:
        """#22 后端真相源:world_time 双角色生理衰减。state_truth_source=client 时 no-op。"""
        if self.state_truth_source != "backend":
            return {}
        return self.memory.advance_life_decay(
            save_id=save_id, hourly_rates=self.HOURLY_NEED_RATES
        )

    def advance_life_state_decay_all(self) -> dict[str, dict[str, dict[str, float]]]:
        """调度器入口:对全部已知旅程推进衰减(仅 backend 真相源模式)。"""
        results: dict[str, dict[str, dict[str, float]]] = {}
        if self.state_truth_source != "backend":
            return results
        for save_id in self.memory.life_save_ids():
            applied = self.advance_life_state_decay(save_id)
            if applied:
                results[save_id] = applied
        return results

    def recall_memories(self, raw: Any) -> list[dict[str, Any]]:
        if not isinstance(raw, dict):
            raise RequestValidationError("request body must be a JSON object")
        save_id = self.validate_save_id(raw.get("save_id"))
        role_id = str(raw.get("role_id", ""))
        self.roles.get(role_id)
        query = str(raw.get("query", "")).replace("\x00", " ").strip()
        if not query or len(query) > 8_000:
            raise RequestValidationError("query must contain 1-8000 characters")
        try:
            return self.memory.recall(
                save_id=save_id,
                role_id=role_id,
                query=query,
                limit=int(raw.get("limit", self._recall_limit)),
            )
        except (MemoryStoreError, TypeError, ValueError) as exc:
            raise RequestValidationError(str(exc)) from exc

    def memory_graph(
        self,
        save_id: Any,
        scope: str = "",
        query: str = "",
        limit: Any = 120,
    ) -> dict[str, Any]:
        normalized = self.validate_save_id(save_id)
        try:
            return self.memory.memory_graph(
                save_id=normalized,
                scope=str(scope),
                query=str(query),
                limit=int(limit),
            )
        except (MemoryStoreError, TypeError, ValueError) as exc:
            raise RequestValidationError(str(exc)) from exc

    def delete_memory(self, save_id: Any, memory_id: str) -> bool:
        normalized = self.validate_save_id(save_id)
        return self.memory.delete_memory(normalized, str(memory_id))

    def rag_status(self) -> dict[str, Any]:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        return self.rag.status()

    async def put_rag_document(self, raw: Any) -> dict[str, Any]:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        try:
            return await self.rag.put_document(raw)
        except RagStoreError as exc:
            raise RequestValidationError(str(exc)) from exc

    def list_rag_documents(self, limit: Any = 100) -> list[dict[str, Any]]:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        try:
            return self.rag.list_documents(int(limit))
        except (RagStoreError, TypeError, ValueError) as exc:
            raise RequestValidationError(str(exc)) from exc

    def get_rag_document(self, document_id: Any) -> dict[str, Any]:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        try:
            return self.rag.get_document(str(document_id), include_content=True)
        except RagStoreError as exc:
            raise RequestValidationError(str(exc)) from exc

    def delete_rag_document(self, document_id: Any) -> bool:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        try:
            return self.rag.delete_document(str(document_id))
        except RagStoreError as exc:
            raise RequestValidationError(str(exc)) from exc

    async def batch_rag_documents(self, raw: Any) -> dict[str, Any]:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        try:
            return await self.rag.batch_documents(raw)
        except RagStoreError as exc:
            raise RequestValidationError(str(exc)) from exc

    async def search_rag(self, raw: Any) -> list[dict[str, Any]]:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        if not isinstance(raw, dict):
            raise RequestValidationError("request body must be a JSON object")
        role_id = str(raw.get("role_id", ""))
        if role_id:
            self.roles.get(role_id)
        try:
            return await self.rag.search(
                str(raw.get("query", "")),
                role_id=role_id,
                limit=int(raw.get("limit", 0)) or None,
            )
        except (RagStoreError, TypeError, ValueError) as exc:
            raise RequestValidationError(str(exc)) from exc

    async def reindex_rag(self) -> dict[str, Any]:
        if self.rag is None:
            raise RequestValidationError("RAG runtime is unavailable")
        try:
            return await self.rag.reindex_embeddings()
        except RagStoreError as exc:
            raise RequestValidationError(str(exc)) from exc

    def _validate_chat(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RequestValidationError("request body must be a JSON object")
        request_id = str(raw.get("request_id", "")).strip()
        if not REQUEST_ID_PATTERN.fullmatch(request_id):
            raise RequestValidationError("request_id is invalid")
        role_id = str(raw.get("role_id", "")).strip()
        self.roles.get(role_id)
        save_id = self.validate_save_id(raw.get("save_id"))
        text = str(raw.get("text", "")).replace("\x00", "").strip()
        if not text or len(text) > 8_000:
            raise RequestValidationError("text must contain 1-8000 characters")
        event_type = str(raw.get("event_type", "chat"))
        if event_type not in {"chat", "action"}:
            raise RequestValidationError("event_type must be chat or action")
        history = raw.get("history", [])
        state = raw.get("state", {})
        if not isinstance(history, list) or len(history) > 64:
            raise RequestValidationError("history must be an array with at most 64 items")
        if not isinstance(state, dict):
            raise RequestValidationError("state must be a JSON object")
        return {
            "request_id": request_id,
            "role_id": role_id,
            "save_id": save_id,
            "text": text,
            "event_type": event_type,
            "history": history,
            "state": state,
        }

    @staticmethod
    def validate_save_id(value: Any) -> str:
        normalized = str(value or "").strip()
        if not SAVE_ID_PATTERN.fullmatch(normalized):
            raise RequestValidationError("save_id is invalid")
        return normalized

    def _sync_history(self, save_id: str, history: list[Any]) -> None:
        for index, item in enumerate(history[-64:]):
            if not isinstance(item, dict):
                continue
            sender = str(item.get("sender", ""))
            text = str(item.get("text", "")).replace("\x00", " ").strip()
            if sender not in {"user", "ai"} or not text:
                continue
            raw_id = str(item.get("id", ""))
            if not raw_id:
                digest = hashlib.sha256(
                    f"{sender}\x1f{text}\x1f{item.get('created_at', 0)}\x1f{index}".encode("utf-8")
                ).hexdigest()[:24]
                raw_id = f"history-{digest}"
            audience = item.get("audience_roles", self.roles.ids())
            self.memory.record_event(
                save_id=save_id,
                message_id=raw_id,
                sender=sender,
                role_id=str(item.get("role_id", item.get("role", ""))),
                text=text,
                event_type=str(item.get("event_type", "chat")),
                audience_roles=audience if isinstance(audience, list) else self.roles.ids(),
                created_at=self._timestamp(item.get("created_at")),
            )

    def _merge_history(
        self, durable: list[dict[str, Any]], supplied: list[Any]
    ) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        seen: set[str] = set()
        seen_content: dict[str, int] = {}
        for item in [*durable, *supplied]:
            if not isinstance(item, dict):
                continue
            text = str(item.get("text", "")).replace("\x00", " ").strip()
            sender = str(item.get("sender", ""))
            if not text or sender not in {"user", "ai"}:
                continue
            identity = str(item.get("id", "")) or hashlib.sha256(
                f"{sender}\x1f{item.get('role_id', item.get('role', ''))}\x1f{text}".encode("utf-8")
            ).hexdigest()
            if identity in seen:
                continue
            role_id = str(item.get("role_id", item.get("role", "")))
            content_identity = hashlib.sha256(
                f"{sender}\x1f{role_id}\x1f{text}".encode("utf-8")
            ).hexdigest()
            created_at = self._timestamp(item.get("created_at"), fallback=0)
            previous_time = seen_content.get(content_identity)
            if previous_time is not None and (
                created_at == 0 or previous_time == 0 or abs(created_at - previous_time) <= 5
            ):
                continue
            seen.add(identity)
            seen_content[content_identity] = created_at
            result.append(dict(item))
        result.sort(key=lambda item: self._timestamp(item.get("created_at"), fallback=0))
        return result[-self._recent_messages :]

    def _audience_roles(self, state: dict[str, Any]) -> list[str]:
        visibility = state.get("conversation_visibility", {})
        raw = visibility.get("audience_roles", []) if isinstance(visibility, dict) else []
        audience = [
            role for role in map(str, raw) if role in self.roles.ids()
        ] if isinstance(raw, list) else []
        return list(dict.fromkeys(audience)) or self.roles.ids()

    @staticmethod
    def _source_message_id(request_id: str, state: dict[str, Any]) -> str:
        candidate = str(state.get("source_message_id", "")).strip()
        if REQUEST_ID_PATTERN.fullmatch(candidate):
            return candidate
        return CompanionService._bounded_event_id(f"{request_id}:user")

    @staticmethod
    def _bounded_event_id(value: str) -> str:
        if len(value) <= 192:
            return value
        digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]
        return f"event-{digest}"

    @staticmethod
    def _timestamp(value: Any, fallback: int | None = None) -> int:
        default = int(time.time()) if fallback is None else fallback
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return default
        return parsed if parsed > 0 else default

    @staticmethod
    def _memory_influence(memories: list[dict[str, Any]]) -> dict[str, Any]:
        dialogue: list[str] = []
        behavior_hints: list[str] = []
        behavior_tags: list[str] = []
        for item in memories:
            influence = item.get("influence", {})
            if not isinstance(influence, dict):
                continue
            if influence.get("dialogue") and str(influence["dialogue"]) not in dialogue:
                dialogue.append(str(influence["dialogue"]))
            if influence.get("behavior_hint") and str(influence["behavior_hint"]) not in behavior_hints:
                behavior_hints.append(str(influence["behavior_hint"]))
            tags = influence.get("behavior_tags", [])
            if isinstance(tags, list):
                for tag in map(str, tags):
                    if tag not in behavior_tags:
                        behavior_tags.append(tag)
        return {
            "dialogue": dialogue[:8],
            "behavior_hints": behavior_hints[:8],
            "behavior_tags": behavior_tags[:16],
        }

    def _remember_cached(self, key: str, result: dict[str, Any]) -> None:
        self._replies[key] = dict(result)
        self._replies.move_to_end(key)
        while len(self._replies) > self._capacity:
            self._replies.popitem(last=False)

    async def _run_organizer(
        self,
        *,
        save_id: str,
        role: Any,
        request_id: str,
        user_text: str,
        reply_text: str,
        fallback_memory_id: str,
    ) -> None:
        if self._organizer is None:
            return
        try:
            async with self._organizer_semaphore:
                await self._organizer.organize(
                    save_id=save_id,
                    role=role,
                    request_id=request_id,
                    user_text=user_text,
                    reply_text=reply_text,
                    fallback_memory_id=fallback_memory_id,
                )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self._organizer.mark_error(save_id, role, str(exc))
