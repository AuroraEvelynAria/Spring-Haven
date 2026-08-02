from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import threading
import time
import unicodedata
import uuid
from pathlib import Path
from typing import Any, Iterable


HEARTLOOM_NAME = "Heartloom Memory"
HEARTLOOM_DISPLAY_NAME = "心织记忆"
SCHEMA_VERSION = 2
SHARED_SCOPE = "*"

MEMORY_KINDS = {
    "episodic",
    "semantic",
    "relationship",
    "preference",
    "identity",
    "routine",
    "worldbook",
}
SOURCE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,191}$")
TAG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
ASCII_TERM_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]{1,63}")
HAN_SEQUENCE_PATTERN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]{2,}")

_STOP_TERMS = {
    "一个",
    "一些",
    "不是",
    "什么",
    "他们",
    "你们",
    "我们",
    "她们",
    "这个",
    "那个",
    "可以",
    "就是",
    "因为",
    "所以",
    "然后",
    "但是",
    "还是",
    "已经",
    "现在",
    "今天",
    "知道",
    "觉得",
    "一下",
}

_GRAPH_STOP_TERMS = _STOP_TERMS | {
    "主人",
    "小玲",
    "小奈",
    "角色",
    "记忆",
    "曾说",
    "回应",
    "一次",
    "对话",
    "自己",
}


class MemoryStoreError(RuntimeError):
    """Raised when the local Heartloom database cannot complete an operation."""


class HeartloomStore:
    """Durable, local-only memory and shared conversation storage.

    The database intentionally uses only Python's sqlite3 module. WAL mode,
    bounded transactions and indexed trigger terms make it suitable for a
    long-running local process without any external bot framework dependency.
    """

    def __init__(self, path: str | Path, role_ids: Iterable[str]):
        raw_path = str(path)
        self.path = raw_path if raw_path == ":memory:" else str(Path(path).resolve())
        self.role_ids = tuple(dict.fromkeys(str(item) for item in role_ids))
        if not self.role_ids:
            raise MemoryStoreError("Heartloom requires at least one role")
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(
            self.path,
            timeout=5.0,
            check_same_thread=False,
        )
        self._connection.row_factory = sqlite3.Row
        self._configure()
        self._migrate()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def integrity_check(self) -> str:
        with self._lock:
            rows = self._connection.execute("PRAGMA quick_check").fetchall()
        messages = [str(row[0]) for row in rows]
        return "ok" if messages == ["ok"] else "; ".join(messages)[:1_000]

    def checkpoint(self) -> dict[str, int]:
        if self.path == ":memory:":
            return {"busy": 0, "log_frames": 0, "checkpointed_frames": 0}
        with self._lock:
            row = self._connection.execute("PRAGMA wal_checkpoint(PASSIVE)").fetchone()
        return {
            "busy": int(row[0]),
            "log_frames": int(row[1]),
            "checkpointed_frames": int(row[2]),
        }

    def backup_to(self, destination: str | Path) -> None:
        target_path = Path(destination).resolve()
        target_path.parent.mkdir(parents=True, exist_ok=True)
        target = sqlite3.connect(target_path, timeout=10.0)
        try:
            with self._lock:
                self._connection.backup(target)
            result = str(target.execute("PRAGMA quick_check").fetchone()[0])
            if result != "ok":
                raise MemoryStoreError(f"Heartloom backup integrity check failed: {result}")
        finally:
            target.close()

    def _configure(self) -> None:
        with self._lock:
            self._connection.execute("PRAGMA foreign_keys = ON")
            self._connection.execute("PRAGMA busy_timeout = 5000")
            self._connection.execute("PRAGMA synchronous = NORMAL")
            if self.path != ":memory:":
                self._connection.execute("PRAGMA journal_mode = WAL")

    def _migrate(self) -> None:
        schema = """
        CREATE TABLE IF NOT EXISTS heartloom_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS conversation_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            save_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            request_id TEXT NOT NULL DEFAULT '',
            sender TEXT NOT NULL CHECK(sender IN ('user', 'ai')),
            role_id TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL,
            event_type TEXT NOT NULL DEFAULT 'chat',
            audience_json TEXT NOT NULL DEFAULT '[]',
            created_at INTEGER NOT NULL,
            recorded_at INTEGER NOT NULL,
            UNIQUE(save_id, message_id)
        );
        CREATE INDEX IF NOT EXISTS idx_events_save_time
            ON conversation_events(save_id, created_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_events_save_role
            ON conversation_events(save_id, role_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS memory_entries (
            memory_id TEXT PRIMARY KEY,
            save_id TEXT NOT NULL,
            scope_role_id TEXT NOT NULL DEFAULT '*',
            kind TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL,
            trigger_terms_json TEXT NOT NULL DEFAULT '[]',
            always_active INTEGER NOT NULL DEFAULT 0,
            priority INTEGER NOT NULL DEFAULT 0,
            importance REAL NOT NULL DEFAULT 0.5,
            confidence REAL NOT NULL DEFAULT 1.0,
            valence REAL NOT NULL DEFAULT 0.0,
            half_life_days REAL NOT NULL DEFAULT 90.0,
            influence_json TEXT NOT NULL DEFAULT '{}',
            source TEXT NOT NULL DEFAULT 'manual',
            source_event_id TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            last_recalled_at INTEGER NOT NULL DEFAULT 0,
            recall_count INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_memory_scope
            ON memory_entries(save_id, scope_role_id, enabled, importance DESC);
        CREATE INDEX IF NOT EXISTS idx_memory_updated
            ON memory_entries(save_id, updated_at DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_source_unique
            ON memory_entries(save_id, source, source_event_id, scope_role_id)
            WHERE source_event_id != '';

        CREATE TABLE IF NOT EXISTS memory_terms (
            memory_id TEXT NOT NULL REFERENCES memory_entries(memory_id) ON DELETE CASCADE,
            term TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1.0,
            PRIMARY KEY(memory_id, term)
        );
        CREATE INDEX IF NOT EXISTS idx_memory_terms_term
            ON memory_terms(term, memory_id);

        CREATE TABLE IF NOT EXISTS replay_cache (
            save_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            role_id TEXT NOT NULL,
            response_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY(save_id, request_id)
        );
        CREATE INDEX IF NOT EXISTS idx_replay_created
            ON replay_cache(created_at);

        CREATE TABLE IF NOT EXISTS session_state (
            save_id TEXT PRIMARY KEY,
            selected_role_id TEXT NOT NULL DEFAULT '',
            turn_index INTEGER NOT NULL DEFAULT 0,
            last_message_id TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS life_state (
            save_id TEXT PRIMARY KEY,
            selected_role_id TEXT NOT NULL DEFAULT '',
            snapshot_json TEXT NOT NULL DEFAULT '{}',
            last_user_activity_at INTEGER NOT NULL DEFAULT 0,
            last_sync_at INTEGER NOT NULL DEFAULT 0,
            next_event_at INTEGER NOT NULL DEFAULT 0,
            last_event_at INTEGER NOT NULL DEFAULT 0,
            last_role_id TEXT NOT NULL DEFAULT '',
            consecutive_failures INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_life_state_due
            ON life_state(next_event_at, last_sync_at);

        CREATE TABLE IF NOT EXISTS life_outbox (
            delivery_id TEXT PRIMARY KEY,
            save_id TEXT NOT NULL,
            role_id TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'proactive',
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            available_at INTEGER NOT NULL,
            acked_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_life_outbox_pending
            ON life_outbox(save_id, acked_at, available_at, created_at);
        """
        with self._lock, self._connection:
            self._connection.executescript(schema)
            self._set_meta("schema_version", str(SCHEMA_VERSION))
            self._set_meta("engine", "heartloom")
            self._set_meta("display_name", HEARTLOOM_DISPLAY_NAME)

    def record_event(
        self,
        *,
        save_id: str,
        message_id: str,
        sender: str,
        text: str,
        role_id: str = "",
        request_id: str = "",
        event_type: str = "chat",
        audience_roles: Iterable[str] = (),
        created_at: int | None = None,
    ) -> None:
        normalized_text = _clean_text(text, 8_000)
        if not normalized_text or sender not in {"user", "ai"}:
            return
        normalized_message_id = _safe_source_id(message_id, normalized_text)
        normalized_role = role_id if role_id in self.role_ids else ""
        normalized_audience = [
            item for item in dict.fromkeys(map(str, audience_roles)) if item in self.role_ids
        ]
        if not normalized_audience:
            normalized_audience = list(self.role_ids)
        timestamp = max(1, int(created_at or time.time()))
        now = int(time.time())
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO conversation_events (
                    save_id, message_id, request_id, sender, role_id, text,
                    event_type, audience_json, created_at, recorded_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(save_id, message_id) DO UPDATE SET
                    request_id = excluded.request_id,
                    sender = excluded.sender,
                    role_id = excluded.role_id,
                    text = excluded.text,
                    event_type = excluded.event_type,
                    audience_json = excluded.audience_json,
                    created_at = excluded.created_at
                """,
                (
                    save_id,
                    normalized_message_id,
                    _clean_text(request_id, 192),
                    sender,
                    normalized_role,
                    normalized_text,
                    event_type if event_type in {"chat", "action"} else "chat",
                    _json(normalized_audience),
                    timestamp,
                    now,
                ),
            )

    def recent_events(
        self,
        save_id: str,
        role_id: str,
        limit: int = 24,
        exclude_message_id: str = "",
    ) -> list[dict[str, Any]]:
        requested = max(1, min(128, int(limit)))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT message_id, sender, role_id, text, event_type,
                       audience_json, created_at
                FROM conversation_events
                WHERE save_id = ? AND message_id != ?
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """,
                (save_id, exclude_message_id, requested * 4),
            ).fetchall()
        result: list[dict[str, Any]] = []
        for row in rows:
            audience = _json_list(row["audience_json"])
            if audience and role_id not in audience:
                continue
            event = {
                "id": row["message_id"],
                "sender": row["sender"],
                "text": row["text"],
                "event_type": row["event_type"],
                "created_at": int(row["created_at"]),
                "audience_roles": audience,
            }
            if row["sender"] == "ai" and row["role_id"] in self.role_ids:
                event["role_id"] = row["role_id"]
            result.append(event)
            if len(result) >= requested:
                break
        result.reverse()
        return result

    def put_memory(self, raw: dict[str, Any], *, source: str = "manual") -> dict[str, Any]:
        save_id = _clean_text(raw.get("save_id", ""), 64)
        if not save_id:
            raise MemoryStoreError("save_id is required")
        scope = str(raw.get("scope_role_id", SHARED_SCOPE)).strip()
        if scope != SHARED_SCOPE and scope not in self.role_ids:
            raise MemoryStoreError("scope_role_id is invalid")
        kind = str(raw.get("kind", "worldbook" if source == "manual" else "episodic"))
        if kind not in MEMORY_KINDS:
            raise MemoryStoreError("memory kind is invalid")
        content = _clean_text(raw.get("content", ""), 8_000)
        if not content:
            raise MemoryStoreError("memory content is required")
        title = _clean_text(raw.get("title", ""), 120)
        source_event_id = _clean_text(raw.get("source_event_id", ""), 192)
        memory_id = _clean_text(raw.get("memory_id", ""), 80)
        if source_event_id:
            with self._lock:
                source_row = self._connection.execute(
                    """
                    SELECT memory_id FROM memory_entries
                    WHERE save_id = ? AND source = ? AND source_event_id = ?
                      AND scope_role_id = ?
                    """,
                    (save_id, source, source_event_id, scope),
                ).fetchone()
            if source_row:
                memory_id = str(source_row["memory_id"])
        if not memory_id:
            if source_event_id:
                memory_id = _deterministic_memory_id(save_id, source, source_event_id, scope)
            else:
                memory_id = uuid.uuid4().hex
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{15,79}", memory_id):
            raise MemoryStoreError("memory_id is invalid")

        triggers = _clean_terms(raw.get("trigger_terms", []), content)
        influence = _clean_influence(raw.get("influence", {}), source == "manual")
        always_active = bool(raw.get("always_active", False))
        priority = _bounded_int(raw.get("priority", 0), -10, 10, "priority")
        importance = _bounded_float(raw.get("importance", 0.65), 0.0, 1.0, "importance")
        confidence = _bounded_float(raw.get("confidence", 1.0), 0.0, 1.0, "confidence")
        valence = _bounded_float(raw.get("valence", 0.0), -1.0, 1.0, "valence")
        default_half_life = 0.0 if source == "manual" else 120.0
        half_life = _bounded_float(
            raw.get("half_life_days", default_half_life), 0.0, 36_500.0, "half_life_days"
        )
        enabled = bool(raw.get("enabled", True))
        now = int(time.time())

        with self._lock, self._connection:
            existing = self._connection.execute(
                "SELECT created_at FROM memory_entries WHERE memory_id = ?",
                (memory_id,),
            ).fetchone()
            created_at = int(existing["created_at"]) if existing else now
            self._connection.execute(
                """
                INSERT INTO memory_entries (
                    memory_id, save_id, scope_role_id, kind, title, content,
                    trigger_terms_json, always_active, priority, importance,
                    confidence, valence, half_life_days, influence_json, source,
                    source_event_id, created_at, updated_at, enabled
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(memory_id) DO UPDATE SET
                    save_id = excluded.save_id,
                    scope_role_id = excluded.scope_role_id,
                    kind = excluded.kind,
                    title = excluded.title,
                    content = excluded.content,
                    trigger_terms_json = excluded.trigger_terms_json,
                    always_active = excluded.always_active,
                    priority = excluded.priority,
                    importance = excluded.importance,
                    confidence = excluded.confidence,
                    valence = excluded.valence,
                    half_life_days = excluded.half_life_days,
                    influence_json = excluded.influence_json,
                    updated_at = excluded.updated_at,
                    enabled = excluded.enabled
                """,
                (
                    memory_id,
                    save_id,
                    scope,
                    kind,
                    title,
                    content,
                    _json(triggers),
                    int(always_active),
                    priority,
                    importance,
                    confidence,
                    valence,
                    half_life,
                    _json(influence),
                    source,
                    source_event_id,
                    created_at,
                    now,
                    int(enabled),
                ),
            )
            self._connection.execute("DELETE FROM memory_terms WHERE memory_id = ?", (memory_id,))
            explicit = set(triggers)
            weighted_terms = _extract_terms(content)
            for term in explicit:
                weighted_terms[term] = max(3.0, weighted_terms.get(term, 0.0))
            self._connection.executemany(
                "INSERT INTO memory_terms(memory_id, term, weight) VALUES (?, ?, ?)",
                [(memory_id, term, weight) for term, weight in weighted_terms.items()],
            )
            self._set_meta("last_write_at", str(now))
        return self.get_memory(save_id, memory_id) or {}

    def remember_user_turn(
        self,
        *,
        save_id: str,
        source_event_id: str,
        text: str,
    ) -> dict[str, Any]:
        kind = _classify_memory(text)
        return self.put_memory(
            {
                "save_id": save_id,
                "scope_role_id": SHARED_SCOPE,
                "kind": kind,
                "title": _automatic_title(kind),
                "content": f"主人曾说：{_clean_text(text, 4_000)}",
                "source_event_id": source_event_id,
                "importance": _estimate_importance(text),
                "confidence": 1.0,
                "half_life_days": _automatic_half_life(kind),
            },
            source="conversation_user",
        )

    def remember_exchange(
        self,
        *,
        save_id: str,
        role_id: str,
        source_event_id: str,
        role_name: str,
        user_text: str,
        reply_text: str,
    ) -> dict[str, Any]:
        combined = (
            f"主人说：{_clean_text(user_text, 2_500)}\n"
            f"{_clean_text(role_name, 80)}回应：{_clean_text(reply_text, 3_500)}"
        )
        return self.put_memory(
            {
                "save_id": save_id,
                "scope_role_id": role_id,
                "kind": "episodic",
                "title": f"与主人的一次对话",
                "content": combined,
                "source_event_id": source_event_id,
                "importance": min(1.0, _estimate_importance(user_text) + 0.08),
                "confidence": 1.0,
                "half_life_days": 120.0,
            },
            source="conversation_exchange",
        )

    def recall(
        self,
        *,
        save_id: str,
        role_id: str,
        query: str,
        limit: int = 8,
        record_access: bool = True,
    ) -> list[dict[str, Any]]:
        if role_id not in self.role_ids:
            raise MemoryStoreError("role_id is invalid")
        requested = max(1, min(24, int(limit)))
        query_terms = set(_extract_terms(query))
        params: list[Any] = [save_id, SHARED_SCOPE, role_id]
        term_clause = ""
        if query_terms:
            placeholders = ",".join("?" for _ in query_terms)
            term_clause = (
                " OR memory_id IN (SELECT memory_id FROM memory_terms "
                f"WHERE term IN ({placeholders}))"
            )
            params.extend(sorted(query_terms))
        params.append(max(100, requested * 30))
        sql = f"""
            SELECT * FROM memory_entries
            WHERE save_id = ?
              AND scope_role_id IN (?, ?)
              AND enabled = 1
              AND (always_active = 1 {term_clause})
            ORDER BY always_active DESC, priority DESC, importance DESC, updated_at DESC
            LIMIT ?
        """
        with self._lock:
            rows = self._connection.execute(sql, params).fetchall()
            term_weights: dict[str, dict[str, float]] = {}
            if rows:
                memory_ids = [str(row["memory_id"]) for row in rows]
                placeholders = ",".join("?" for _ in memory_ids)
                for item in self._connection.execute(
                    f"SELECT memory_id, term, weight FROM memory_terms WHERE memory_id IN ({placeholders})",
                    memory_ids,
                ).fetchall():
                    term_weights.setdefault(str(item["memory_id"]), {})[str(item["term"])] = float(
                        item["weight"]
                    )

        now = int(time.time())
        scored: list[tuple[float, sqlite3.Row]] = []
        normalized_query = _normalize_text(query)
        for row in rows:
            terms = term_weights.get(str(row["memory_id"]), {})
            intersection = query_terms.intersection(terms)
            lexical = sum(min(3.0, terms[item]) for item in intersection)
            lexical /= max(1.0, min(8.0, float(len(query_terms))))
            triggers = _json_list(row["trigger_terms_json"])
            trigger_hit = any(_normalize_text(item) in normalized_query for item in triggers if item)
            if trigger_hit:
                lexical = max(lexical, 1.0)
            age_days = max(0.0, (now - int(row["updated_at"])) / 86_400.0)
            half_life = float(row["half_life_days"])
            decay = 1.0 if half_life <= 0.0 else math.pow(0.5, age_days / half_life)
            importance = float(row["importance"]) * decay
            recency = math.pow(0.5, age_days / 30.0)
            reinforcement = min(0.08, math.log1p(int(row["recall_count"])) * 0.015)
            priority = (int(row["priority"]) + 10) / 20.0
            score = lexical * 0.55 + importance * 0.24 + recency * 0.08 + priority * 0.05 + reinforcement
            if bool(row["always_active"]):
                score = max(score, 0.82 + priority * 0.12)
            if bool(row["always_active"]) or lexical > 0.0:
                scored.append((score, row))
        scored.sort(key=lambda item: (item[0], int(item[1]["updated_at"])), reverse=True)
        selected = scored[:requested]
        result = [self._memory_row(row, score=score) for score, row in selected]

        if record_access:
            with self._lock, self._connection:
                if selected:
                    self._connection.executemany(
                        """
                        UPDATE memory_entries
                        SET last_recalled_at = ?, recall_count = recall_count + 1
                        WHERE memory_id = ?
                        """,
                        [(now, str(row["memory_id"])) for _, row in selected],
                    )
                self._set_meta("last_recall_at", str(now))
                self._set_meta("last_recall_count", str(len(selected)))
                self._set_meta("last_recall_role", role_id)
                self._set_meta("last_recall_save", save_id)
        return result

    def list_memories(
        self,
        *,
        save_id: str,
        role_id: str = "",
        query: str = "",
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        requested = max(1, min(500, int(limit)))
        clauses = ["save_id = ?"]
        params: list[Any] = [save_id]
        if role_id:
            if role_id not in self.role_ids:
                raise MemoryStoreError("role_id is invalid")
            clauses.append("scope_role_id IN (?, ?)")
            params.extend([SHARED_SCOPE, role_id])
        normalized_query = _clean_text(query, 200)
        if normalized_query:
            clauses.append("(title LIKE ? OR content LIKE ?)")
            like = f"%{normalized_query}%"
            params.extend([like, like])
        params.append(requested)
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT * FROM memory_entries
                WHERE {' AND '.join(clauses)}
                ORDER BY priority DESC, importance DESC, updated_at DESC
                LIMIT ?
                """,
                params,
            ).fetchall()
        return [self._memory_row(row) for row in rows]

    def memory_graph(
        self,
        *,
        save_id: str,
        scope: str = "",
        query: str = "",
        limit: int = 120,
    ) -> dict[str, Any]:
        normalized_scope = str(scope).strip()
        if normalized_scope not in {"", SHARED_SCOPE, *self.role_ids}:
            raise MemoryStoreError("memory graph scope is invalid")
        requested = max(1, min(200, int(limit)))
        # Read a bounded superset before exact scope filtering so a busy shared
        # scope cannot hide role-specific nodes.
        entries = self.list_memories(
            save_id=save_id,
            query=query,
            limit=500,
        )
        if normalized_scope:
            entries = [
                item
                for item in entries
                if str(item.get("scope_role_id", "")) == normalized_scope
            ]
        available_count = len(entries)
        entries = entries[:requested]
        memory_ids = [str(item["memory_id"]) for item in entries]
        term_maps: dict[str, dict[str, float]] = {memory_id: {} for memory_id in memory_ids}
        if memory_ids:
            placeholders = ",".join("?" for _ in memory_ids)
            with self._lock:
                rows = self._connection.execute(
                    f"SELECT memory_id, term, weight FROM memory_terms "
                    f"WHERE memory_id IN ({placeholders})",
                    memory_ids,
                ).fetchall()
            for row in rows:
                memory_id = str(row["memory_id"])
                term = str(row["term"])
                if _graph_term_is_useful(term):
                    term_maps.setdefault(memory_id, {})[term] = float(row["weight"])
        document_frequency: dict[str, int] = {}
        for terms in term_maps.values():
            for term in terms:
                document_frequency[term] = document_frequency.get(term, 0) + 1
        maximum_discriminating_frequency = max(3, int(len(entries) * 0.35))
        term_idf = {
            term: math.log(
                (len(entries) + 1.0) / (frequency + 1.0)
            ) + 0.25
            for term, frequency in document_frequency.items()
            if frequency <= maximum_discriminating_frequency
        }
        vector_maps: dict[str, dict[str, float]] = {}
        vector_norms: dict[str, float] = {}
        for memory_id, terms in term_maps.items():
            vector = {
                term: weight * term_idf[term]
                for term, weight in terms.items()
                if term in term_idf and term_idf[term] > 0.0
            }
            vector_maps[memory_id] = vector
            vector_norms[memory_id] = math.sqrt(
                sum(value * value for value in vector.values())
            )

        nodes: list[dict[str, Any]] = []
        by_id: dict[str, dict[str, Any]] = {}
        for entry in entries:
            memory_id = str(entry["memory_id"])
            terms = vector_maps.get(memory_id, {})
            ranked_terms = sorted(
                terms,
                key=lambda term: (terms[term], len(term), term),
                reverse=True,
            )
            title = str(entry.get("title", "")).strip()
            content = str(entry.get("content", "")).strip()
            node = {
                "id": memory_id,
                "memory_id": memory_id,
                "scope_role_id": str(entry.get("scope_role_id", SHARED_SCOPE)),
                "kind": str(entry.get("kind", "episodic")),
                "title": title or _graph_preview(content, 28),
                "content": content,
                "keywords": ranked_terms[:6],
                "trigger_terms": list(entry.get("trigger_terms", []))[:12],
                "importance": round(float(entry.get("importance", 0.5)), 4),
                "confidence": round(float(entry.get("confidence", 1.0)), 4),
                "valence": round(float(entry.get("valence", 0.0)), 4),
                "source": str(entry.get("source", "")),
                "source_event_id": str(entry.get("source_event_id", "")),
                "created_at": int(entry.get("created_at", 0)),
                "updated_at": int(entry.get("updated_at", 0)),
                "last_recalled_at": int(entry.get("last_recalled_at", 0)),
                "recall_count": int(entry.get("recall_count", 0)),
                "always_active": bool(entry.get("always_active", False)),
                "enabled": bool(entry.get("enabled", True)),
                "connection_count": 0,
            }
            nodes.append(node)
            by_id[memory_id] = node

        title_counts: dict[str, int] = {}
        for node in nodes:
            normalized_title = _normalize_text(node["title"])
            title_counts[normalized_title] = title_counts.get(normalized_title, 0) + 1
        for node in nodes:
            title = str(node["title"])
            display_title = title
            if title_counts.get(_normalize_text(title), 0) > 1:
                qualifier = next(
                    (
                        str(term)
                        for term in node.get("keywords", [])
                        if _normalize_text(term) not in _normalize_text(title)
                    ),
                    "",
                )
                if qualifier:
                    display_title = f"{title} · {qualifier}"
            node["display_title"] = _graph_preview(display_title, 42)

        candidates: list[dict[str, Any]] = []
        for left_index, left in enumerate(entries):
            left_id = str(left["memory_id"])
            left_terms = vector_maps.get(left_id, {})
            left_triggers = {
                _normalize_text(item)
                for item in left.get("trigger_terms", [])
                if _graph_term_is_useful(_normalize_text(item))
            }
            for right in entries[left_index + 1 :]:
                right_id = str(right["memory_id"])
                right_terms = vector_maps.get(right_id, {})
                weighted_shared_terms = sorted(
                    [
                        (
                            term,
                            left_terms[term] * right_terms[term],
                        )
                        for term in set(left_terms).intersection(right_terms)
                    ],
                    key=lambda item: (item[1], len(item[0]), item[0]),
                    reverse=True,
                )
                shared_terms = [term for term, _weight in weighted_shared_terms]
                denominator = vector_norms.get(left_id, 0.0) * vector_norms.get(right_id, 0.0)
                cosine_similarity = (
                    sum(weight for _term, weight in weighted_shared_terms) / denominator
                    if denominator > 0.0
                    else 0.0
                )
                right_triggers = {
                    _normalize_text(item)
                    for item in right.get("trigger_terms", [])
                    if _graph_term_is_useful(_normalize_text(item))
                }
                shared_triggers = sorted(
                    term
                    for term in left_triggers.intersection(right_triggers)
                    if document_frequency.get(term, 0) <= max(3, int(len(entries) * 0.22))
                )
                left_source = _graph_source_family(str(left.get("source_event_id", "")))
                right_source = _graph_source_family(str(right.get("source_event_id", "")))
                same_event = bool(left_source and left_source == right_source)
                if cosine_similarity < 0.08 and not shared_triggers and not same_event:
                    continue
                strength = min(0.78, cosine_similarity * 0.82)
                reasons: list[str] = []
                if cosine_similarity >= 0.80:
                    reasons.append("内容高度相似")
                if shared_terms:
                    reasons.append("共享主题：" + "、".join(shared_terms[:4]))
                if shared_triggers:
                    strength += 0.10
                    reasons.append("相同触发词：" + "、".join(shared_triggers[:3]))
                if same_event:
                    strength += 0.40
                    reasons.append("来自同一次经历")
                if str(left.get("kind", "")) == str(right.get("kind", "")):
                    strength += 0.015
                if str(left.get("scope_role_id", "")) == str(right.get("scope_role_id", "")):
                    strength += 0.010
                time_gap = abs(int(left.get("created_at", 0)) - int(right.get("created_at", 0)))
                if time_gap <= 3_600:
                    strength += 0.015
                candidates.append(
                    {
                        "source": left_id,
                        "target": right_id,
                        "strength": round(min(1.0, strength), 4),
                        "shared_terms": shared_terms[:6],
                        "reasons": reasons[:3],
                        "same_source_event": same_event,
                        "time_gap_seconds": time_gap,
                    }
                )

        candidates.sort(
            key=lambda edge: (float(edge["strength"]), len(edge["shared_terms"])),
            reverse=True,
        )
        degrees = {memory_id: 0 for memory_id in memory_ids}
        edges: list[dict[str, Any]] = []
        for edge in candidates:
            source = str(edge["source"])
            target = str(edge["target"])
            if degrees[source] >= 7 or degrees[target] >= 7:
                continue
            edges.append(edge)
            degrees[source] += 1
            degrees[target] += 1
            if len(edges) >= 600:
                break
        for memory_id, degree in degrees.items():
            by_id[memory_id]["connection_count"] = degree
        connected = sum(1 for degree in degrees.values() if degree > 0)
        return {
            "schema_version": 1,
            "backend": "heartloom",
            "generated_at": int(time.time()),
            "scope": normalized_scope,
            "query": _clean_text(query, 200),
            "nodes": nodes,
            "edges": edges,
            "summary": {
                "node_count": len(nodes),
                "available_node_count": available_count,
                "edge_count": len(edges),
                "connected_node_count": connected,
                "isolated_node_count": len(nodes) - connected,
                "truncated": available_count > requested,
            },
        }

    def get_memory(self, save_id: str, memory_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM memory_entries WHERE save_id = ? AND memory_id = ?",
                (save_id, memory_id),
            ).fetchone()
        return self._memory_row(row) if row else None

    def delete_memory(self, save_id: str, memory_id: str) -> bool:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "DELETE FROM memory_entries WHERE save_id = ? AND memory_id = ?",
                (save_id, memory_id),
            )
            if cursor.rowcount:
                self._set_meta("last_write_at", str(int(time.time())))
            return cursor.rowcount > 0

    def get_cached_response(self, save_id: str, request_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT response_json FROM replay_cache WHERE save_id = ? AND request_id = ?",
                (save_id, request_id),
            ).fetchone()
        if not row:
            return None
        parsed = _json_object(row["response_json"])
        return parsed or None

    def cache_response(
        self, save_id: str, request_id: str, role_id: str, response: dict[str, Any]
    ) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO replay_cache(save_id, request_id, role_id, response_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(save_id, request_id) DO UPDATE SET
                    role_id = excluded.role_id,
                    response_json = excluded.response_json,
                    created_at = excluded.created_at
                """,
                (save_id, request_id, role_id, _json(response), int(time.time())),
            )

    def update_session(self, save_id: str, selected_role_id: str, message_id: str) -> dict[str, Any]:
        if selected_role_id not in self.role_ids:
            raise MemoryStoreError("selected_role_id is invalid")
        now = int(time.time())
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO session_state(save_id, selected_role_id, turn_index, last_message_id, updated_at)
                VALUES (?, ?, 1, ?, ?)
                ON CONFLICT(save_id) DO UPDATE SET
                    selected_role_id = excluded.selected_role_id,
                    turn_index = CASE
                        WHEN session_state.last_message_id = excluded.last_message_id
                        THEN session_state.turn_index
                        ELSE session_state.turn_index + 1
                    END,
                    last_message_id = excluded.last_message_id,
                    updated_at = excluded.updated_at
                """,
                (save_id, selected_role_id, message_id, now),
            )
            row = self._connection.execute(
                "SELECT * FROM session_state WHERE save_id = ?", (save_id,)
            ).fetchone()
        return dict(row) if row else {}

    def reset_session_cache(self, save_id: str) -> None:
        with self._lock, self._connection:
            self._connection.execute("DELETE FROM replay_cache WHERE save_id = ?", (save_id,))
            self._connection.execute("DELETE FROM session_state WHERE save_id = ?", (save_id,))

    def sync_life_state(
        self,
        *,
        save_id: str,
        selected_role_id: str,
        snapshot: dict[str, Any],
        last_user_activity_at: int,
        next_event_at: int,
        now: int | None = None,
    ) -> dict[str, Any]:
        if selected_role_id not in self.role_ids:
            raise MemoryStoreError("selected_role_id is invalid")
        timestamp = max(1, int(now or time.time()))
        encoded_snapshot = _json(snapshot)
        if len(encoded_snapshot) > 64_000:
            raise MemoryStoreError("life snapshot is too large")
        next_due = max(timestamp + 60, int(next_event_at))
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO life_state (
                    save_id, selected_role_id, snapshot_json,
                    last_user_activity_at, last_sync_at, next_event_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(save_id) DO UPDATE SET
                    selected_role_id = excluded.selected_role_id,
                    snapshot_json = excluded.snapshot_json,
                    last_user_activity_at = excluded.last_user_activity_at,
                    last_sync_at = excluded.last_sync_at,
                    next_event_at = CASE
                        WHEN life_state.next_event_at <= 0 THEN excluded.next_event_at
                        ELSE life_state.next_event_at
                    END,
                    updated_at = excluded.updated_at
                """,
                (
                    save_id,
                    selected_role_id,
                    encoded_snapshot,
                    max(0, int(last_user_activity_at)),
                    timestamp,
                    next_due,
                    timestamp,
                ),
            )
            row = self._connection.execute(
                "SELECT * FROM life_state WHERE save_id = ?", (save_id,)
            ).fetchone()
        return self._life_state_row(row) if row else {}

    def due_life_states(self, now: int | None = None, limit: int = 8) -> list[dict[str, Any]]:
        timestamp = max(1, int(now or time.time()))
        requested = max(1, min(32, int(limit)))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT state.*
                FROM life_state AS state
                WHERE state.next_event_at > 0
                  AND state.next_event_at <= ?
                  AND NOT EXISTS (
                      SELECT 1 FROM life_outbox AS outbox
                      WHERE outbox.save_id = state.save_id AND outbox.acked_at = 0
                  )
                ORDER BY state.next_event_at ASC
                LIMIT ?
                """,
                (timestamp, requested),
            ).fetchall()
        return [self._life_state_row(row) for row in rows]

    def defer_life_event(
        self,
        save_id: str,
        next_event_at: int,
        *,
        failed: bool = False,
        now: int | None = None,
    ) -> None:
        timestamp = max(1, int(now or time.time()))
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE life_state
                SET next_event_at = ?,
                    consecutive_failures = CASE
                        WHEN ? THEN consecutive_failures + 1 ELSE consecutive_failures
                    END,
                    updated_at = ?
                WHERE save_id = ?
                """,
                (max(timestamp + 60, int(next_event_at)), int(bool(failed)), timestamp, save_id),
            )

    def complete_life_event(
        self,
        save_id: str,
        role_id: str,
        next_event_at: int,
        *,
        now: int | None = None,
    ) -> None:
        if role_id not in self.role_ids:
            raise MemoryStoreError("role_id is invalid")
        timestamp = max(1, int(now or time.time()))
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE life_state
                SET next_event_at = ?, last_event_at = ?, last_role_id = ?,
                    consecutive_failures = 0, updated_at = ?
                WHERE save_id = ?
                """,
                (
                    max(timestamp + 60, int(next_event_at)),
                    timestamp,
                    role_id,
                    timestamp,
                    save_id,
                ),
            )

    def enqueue_life_delivery(
        self,
        *,
        delivery_id: str,
        save_id: str,
        role_id: str,
        kind: str,
        payload: dict[str, Any],
        created_at: int | None = None,
        available_at: int | None = None,
    ) -> dict[str, Any]:
        if role_id not in self.role_ids:
            raise MemoryStoreError("role_id is invalid")
        normalized_id = _safe_source_id(delivery_id, _json(payload))
        timestamp = max(1, int(created_at or time.time()))
        available = max(1, int(available_at or timestamp))
        encoded_payload = _json(payload)
        if len(encoded_payload) > 64_000:
            raise MemoryStoreError("life outbox payload is too large")
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO life_outbox (
                    delivery_id, save_id, role_id, kind, payload_json,
                    created_at, available_at, acked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(delivery_id) DO NOTHING
                """,
                (
                    normalized_id,
                    save_id,
                    role_id,
                    _clean_text(kind, 40) or "proactive",
                    encoded_payload,
                    timestamp,
                    available,
                ),
            )
            row = self._connection.execute(
                "SELECT * FROM life_outbox WHERE delivery_id = ?", (normalized_id,)
            ).fetchone()
        return self._life_outbox_row(row) if row else {}

    def poll_life_outbox(
        self,
        save_id: str,
        *,
        limit: int = 16,
        now: int | None = None,
    ) -> list[dict[str, Any]]:
        timestamp = max(1, int(now or time.time()))
        requested = max(1, min(64, int(limit)))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM life_outbox
                WHERE save_id = ? AND acked_at = 0 AND available_at <= ?
                ORDER BY created_at ASC, delivery_id ASC
                LIMIT ?
                """,
                (save_id, timestamp, requested),
            ).fetchall()
        return [self._life_outbox_row(row) for row in rows]

    def ack_life_outbox(
        self,
        save_id: str,
        delivery_ids: Iterable[str],
        *,
        now: int | None = None,
    ) -> int:
        normalized_ids = [
            str(item).strip()[:192]
            for item in dict.fromkeys(delivery_ids)
            if str(item).strip()
        ][:64]
        if not normalized_ids:
            return 0
        timestamp = max(1, int(now or time.time()))
        placeholders = ",".join("?" for _ in normalized_ids)
        with self._lock, self._connection:
            cursor = self._connection.execute(
                f"""
                UPDATE life_outbox SET acked_at = ?
                WHERE save_id = ? AND acked_at = 0
                  AND delivery_id IN ({placeholders})
                """,
                [timestamp, save_id, *normalized_ids],
            )
        return max(0, int(cursor.rowcount))

    def life_status(self, save_id: str = "") -> dict[str, Any]:
        params: list[Any] = []
        state_where = ""
        outbox_where = " WHERE acked_at = 0"
        if save_id:
            state_where = " WHERE save_id = ?"
            outbox_where += " AND save_id = ?"
            params.append(save_id)
        with self._lock:
            state_rows = self._connection.execute(
                f"SELECT * FROM life_state{state_where} ORDER BY updated_at DESC",
                params,
            ).fetchall()
            pending = int(
                self._connection.execute(
                    f"SELECT COUNT(*) FROM life_outbox{outbox_where}", params
                ).fetchone()[0]
            )
        return {
            "state_count": len(state_rows),
            "pending_deliveries": pending,
            "states": [self._life_state_row(row) for row in state_rows[:16]],
        }

    def set_organizer_status(
        self,
        *,
        state: str,
        save_id: str,
        role_id: str,
        message: str,
        organized_count: int = 0,
        input_tokens: int = 0,
        output_tokens: int = 0,
        cached_tokens: int = 0,
    ) -> None:
        if state not in {"queued", "processing", "success", "skipped", "error"}:
            raise MemoryStoreError("organizer state is invalid")
        now = int(time.time())
        with self._lock, self._connection:
            self._set_meta("organizer_state", state)
            self._set_meta("organizer_save", save_id)
            self._set_meta("organizer_role", role_id if role_id in self.role_ids else "")
            self._set_meta("organizer_message", _clean_text(message, 300))
            self._set_meta("organizer_count", str(max(0, organized_count)))
            self._set_meta("organizer_input_tokens", str(max(0, input_tokens)))
            self._set_meta("organizer_output_tokens", str(max(0, output_tokens)))
            self._set_meta("organizer_cached_tokens", str(max(0, cached_tokens)))
            self._set_meta("organizer_updated_at", str(now))

    def status(self, save_id: str = "", role_id: str = "") -> dict[str, Any]:
        clauses: list[str] = []
        params: list[Any] = []
        if save_id:
            clauses.append("save_id = ?")
            params.append(save_id)
        if role_id:
            clauses.append("scope_role_id IN (?, ?)")
            params.extend([SHARED_SCOPE, role_id])
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        with self._lock:
            memory_row = self._connection.execute(
                f"""
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END) AS enabled,
                       SUM(CASE WHEN source = 'manual' THEN 1 ELSE 0 END) AS worldbook
                FROM memory_entries{where}
                """,
                params,
            ).fetchone()
            event_params = [save_id] if save_id else []
            event_where = " WHERE save_id = ?" if save_id else ""
            event_count = int(
                self._connection.execute(
                    f"SELECT COUNT(*) FROM conversation_events{event_where}", event_params
                ).fetchone()[0]
            )
            meta = {
                row["key"]: row["value"]
                for row in self._connection.execute(
                    """
                    SELECT key, value FROM heartloom_meta
                    WHERE key LIKE 'last_%' OR key LIKE 'organizer_%'
                    """
                ).fetchall()
            }
        last_recall_count = _safe_int(meta.get("last_recall_count", 0))
        last_recall_at = _safe_int(meta.get("last_recall_at", 0))
        recall_matches_scope = (
            (not save_id or meta.get("last_recall_save", "") == save_id)
            and (not role_id or meta.get("last_recall_role", "") == role_id)
        )
        recent_recall = (
            recall_matches_scope
            and last_recall_at > 0
            and int(time.time()) - last_recall_at <= 30
        )
        organizer_matches_scope = (
            (not save_id or meta.get("organizer_save", "") == save_id)
            and (not role_id or meta.get("organizer_role", "") == role_id)
        )
        organizer_state = meta.get("organizer_state", "")
        organizer_at = _safe_int(meta.get("organizer_updated_at", 0))
        organizer_recent = (
            organizer_matches_scope
            and organizer_state in {"queued", "processing", "success", "skipped", "error"}
            and organizer_at > 0
            and int(time.time()) - organizer_at <= 60
        )
        if organizer_recent:
            current_state = organizer_state
            current_message = meta.get("organizer_message", "")
            status_role = meta.get("organizer_role", "")
        elif recent_recall and last_recall_count > 0:
            current_state = "success"
            current_message = f"刚刚为角色唤起 {last_recall_count} 条记忆"
            status_role = meta.get("last_recall_role", "")
        else:
            current_state = "ready"
            current_message = f"{HEARTLOOM_DISPLAY_NAME}已就绪，共 {int(memory_row['total'] or 0)} 条记忆"
            status_role = ""
        total = int(memory_row["total"] or 0)
        enabled = int(memory_row["enabled"] or 0)
        return {
            "state": current_state,
            "message": current_message,
            "backend": "heartloom",
            "name": HEARTLOOM_NAME,
            "display_name": HEARTLOOM_DISPLAY_NAME,
            "memory_count": total,
            "enabled_count": enabled,
            "worldbook_count": int(memory_row["worldbook"] or 0),
            "event_count": event_count,
            "last_recall_count": last_recall_count,
            "last_recall_at": last_recall_at,
            "organizer_count": _safe_int(meta.get("organizer_count", 0)),
            "organizer_updated_at": organizer_at,
            "organizer_usage": {
                "input_tokens": _safe_int(meta.get("organizer_input_tokens", 0)),
                "output_tokens": _safe_int(meta.get("organizer_output_tokens", 0)),
                "cached_tokens": _safe_int(meta.get("organizer_cached_tokens", 0)),
            },
            "role_id": status_role,
            "save_id": save_id,
            "schema_version": SCHEMA_VERSION,
            "database_bytes": _database_size(self.path),
        }

    def _memory_row(self, row: sqlite3.Row, score: float | None = None) -> dict[str, Any]:
        result = {
            "memory_id": row["memory_id"],
            "save_id": row["save_id"],
            "scope_role_id": row["scope_role_id"],
            "kind": row["kind"],
            "title": row["title"],
            "content": row["content"],
            "trigger_terms": _json_list(row["trigger_terms_json"]),
            "always_active": bool(row["always_active"]),
            "priority": int(row["priority"]),
            "importance": float(row["importance"]),
            "confidence": float(row["confidence"]),
            "valence": float(row["valence"]),
            "half_life_days": float(row["half_life_days"]),
            "influence": _json_object(row["influence_json"]),
            "source": row["source"],
            "source_event_id": row["source_event_id"],
            "created_at": int(row["created_at"]),
            "updated_at": int(row["updated_at"]),
            "last_recalled_at": int(row["last_recalled_at"]),
            "recall_count": int(row["recall_count"]),
            "enabled": bool(row["enabled"]),
        }
        if score is not None:
            result["recall_score"] = round(max(0.0, score), 4)
        return result

    @staticmethod
    def _life_state_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "save_id": str(row["save_id"]),
            "selected_role_id": str(row["selected_role_id"]),
            "snapshot": _json_object(row["snapshot_json"]),
            "last_user_activity_at": int(row["last_user_activity_at"]),
            "last_sync_at": int(row["last_sync_at"]),
            "next_event_at": int(row["next_event_at"]),
            "last_event_at": int(row["last_event_at"]),
            "last_role_id": str(row["last_role_id"]),
            "consecutive_failures": int(row["consecutive_failures"]),
            "updated_at": int(row["updated_at"]),
        }

    @staticmethod
    def _life_outbox_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "delivery_id": str(row["delivery_id"]),
            "save_id": str(row["save_id"]),
            "role_id": str(row["role_id"]),
            "kind": str(row["kind"]),
            "payload": _json_object(row["payload_json"]),
            "created_at": int(row["created_at"]),
            "available_at": int(row["available_at"]),
            "acked_at": int(row["acked_at"]),
        }

    def _set_meta(self, key: str, value: str) -> None:
        self._connection.execute(
            """
            INSERT INTO heartloom_meta(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            (key, value),
        )


def _normalize_text(value: Any) -> str:
    return unicodedata.normalize("NFKC", str(value)).lower().replace("\x00", " ").strip()


def _clean_text(value: Any, limit: int) -> str:
    return _normalize_text(value)[:limit] if not isinstance(value, str) else unicodedata.normalize(
        "NFKC", value
    ).replace("\x00", " ").strip()[:limit]


def _graph_term_is_useful(value: str) -> bool:
    term = _normalize_text(value)
    return len(term) >= 2 and term not in _GRAPH_STOP_TERMS and not term.isdigit()


def _graph_source_family(value: str) -> str:
    source = _clean_text(value, 192)
    if not source:
        return ""
    source = re.sub(r":\d+:(?:ling|nai)(?::\d+)?$", "", source)
    source = re.sub(r":\d+$", "", source)
    return source


def _graph_preview(value: str, limit: int) -> str:
    compact = " ".join(str(value).split())
    return compact[:limit] + ("…" if len(compact) > limit else "")


def _extract_terms(value: Any) -> dict[str, float]:
    text = _normalize_text(value)
    terms: dict[str, float] = {}
    for match in ASCII_TERM_PATTERN.findall(text):
        terms[match] = max(terms.get(match, 0.0), 1.0)
    for sequence in HAN_SEQUENCE_PATTERN.findall(text):
        bounded = sequence[:80]
        if 2 <= len(bounded) <= 8 and bounded not in _STOP_TERMS:
            terms[bounded] = max(terms.get(bounded, 0.0), 1.4)
        for size, weight in ((2, 1.0), (3, 1.2), (4, 1.35)):
            for index in range(max(0, len(bounded) - size + 1)):
                term = bounded[index : index + size]
                if term not in _STOP_TERMS:
                    terms[term] = max(terms.get(term, 0.0), weight)
                if len(terms) >= 128:
                    return terms
    return terms


def _clean_terms(raw: Any, content: str) -> list[str]:
    values = raw if isinstance(raw, list) else []
    result: list[str] = []
    for value in values[:64]:
        term = _normalize_text(value)[:80]
        if len(term) >= 2 and term not in result:
            result.append(term)
    if not result:
        ranked = sorted(_extract_terms(content).items(), key=lambda item: item[1], reverse=True)
        result = [term for term, _ in ranked[:24]]
    return result


def _clean_influence(raw: Any, allow_directives: bool) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {}
    result: dict[str, Any] = {}
    if allow_directives:
        dialogue = _clean_text(raw.get("dialogue", ""), 1_000)
        behavior_hint = _clean_text(raw.get("behavior_hint", ""), 600)
        if dialogue:
            result["dialogue"] = dialogue
        if behavior_hint:
            result["behavior_hint"] = behavior_hint
    tags: list[str] = []
    raw_tags = raw.get("behavior_tags", [])
    if isinstance(raw_tags, list):
        for item in raw_tags[:16]:
            tag = _normalize_text(item)
            if TAG_PATTERN.fullmatch(tag) and tag not in tags:
                tags.append(tag)
    if tags:
        result["behavior_tags"] = tags
    return result


def _classify_memory(text: str) -> str:
    normalized = _normalize_text(text)
    categories = (
        ("identity", ("我叫", "我是", "我的名字", "生日", "住在")),
        ("relationship", ("老婆", "爱你", "喜欢你", "关系", "朋友", "家人")),
        ("preference", ("我喜欢", "我讨厌", "最喜欢", "不喜欢", "想吃", "偏好")),
        ("routine", ("每天", "每晚", "每周", "早上", "晚上", "习惯", "通常")),
        ("semantic", ("记住", "别忘", "要知道", "事实", "永远")),
    )
    for kind, markers in categories:
        if any(marker in normalized for marker in markers):
            return kind
    return "episodic"


def _estimate_importance(text: str) -> float:
    normalized = _normalize_text(text)
    score = 0.42
    if len(normalized) >= 80:
        score += 0.08
    if any(
        marker in normalized
        for marker in (
            "记住",
            "别忘",
            "永远",
            "答应",
            "约定",
            "生日",
            "我叫",
            "我是",
            "喜欢",
            "讨厌",
            "老婆",
            "重要",
        )
    ):
        score += 0.28
    if any(marker in normalized for marker in ("爱你", "想你", "对不起", "谢谢你")):
        score += 0.12
    return round(min(1.0, score), 3)


def _automatic_half_life(kind: str) -> float:
    return {
        "identity": 0.0,
        "relationship": 720.0,
        "preference": 365.0,
        "routine": 365.0,
        "semantic": 720.0,
    }.get(kind, 120.0)


def _automatic_title(kind: str) -> str:
    return {
        "identity": "关于主人的身份",
        "relationship": "彼此的关系",
        "preference": "主人的偏好",
        "routine": "主人的日常习惯",
        "semantic": "需要记住的事情",
    }.get(kind, "与主人的一段经历")


def _safe_source_id(value: str, fallback_text: str) -> str:
    normalized = _clean_text(value, 192)
    if SOURCE_ID_PATTERN.fullmatch(normalized):
        return normalized
    digest = hashlib.sha256(fallback_text.encode("utf-8")).hexdigest()[:24]
    return f"event-{digest}"


def _deterministic_memory_id(save_id: str, source: str, source_event_id: str, scope: str) -> str:
    digest = hashlib.sha256(
        f"{save_id}\x1f{source}\x1f{source_event_id}\x1f{scope}".encode("utf-8")
    ).hexdigest()
    return f"hm_{digest[:40]}"


def _bounded_int(value: Any, minimum: int, maximum: int, field: str) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise MemoryStoreError(f"{field} must be an integer") from exc
    if not minimum <= parsed <= maximum:
        raise MemoryStoreError(f"{field} is out of range")
    return parsed


def _bounded_float(value: Any, minimum: float, maximum: float, field: str) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise MemoryStoreError(f"{field} must be numeric") from exc
    if not math.isfinite(parsed) or not minimum <= parsed <= maximum:
        raise MemoryStoreError(f"{field} is out of range")
    return parsed


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _json_list(value: Any) -> list[str]:
    try:
        parsed = json.loads(str(value))
    except (TypeError, ValueError, json.JSONDecodeError):
        return []
    return [str(item) for item in parsed] if isinstance(parsed, list) else []


def _json_object(value: Any) -> dict[str, Any]:
    try:
        parsed = json.loads(str(value))
    except (TypeError, ValueError, json.JSONDecodeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _safe_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _database_size(path: str) -> int:
    if path == ":memory:":
        return 0
    try:
        return Path(path).stat().st_size
    except OSError:
        return 0
