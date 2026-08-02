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
    ):
        self.roles = roles
        self.provider = provider
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
        memories = self.memory.recall(
            save_id=save_id,
            role_id=role.role_id,
            query=payload["text"],
            limit=self._recall_limit,
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
        return {
            "protocol": "spring_haven.life_sync.v1",
            "state": state,
            "outbox": self.memory.life_status(save_id),
        }

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
