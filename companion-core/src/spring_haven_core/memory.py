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
SCHEMA_VERSION = 6
# 离线投递 TTL:7 世界天(#23 迁移后按 world_time 计算,不再使用现实时间)。
LIFE_OUTBOX_TTL_WORLD_DAYS = 7.0
# 三态生命周期阈值(ADR-001 D5,后端常量,不开放 UI 配置;Phase 3 启用)。
DORMANT_AFTER_WORLD_DAYS = 14.0
ARCHIVE_CONFIDENCE_THRESHOLD = 0.15
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
        try:
            self._configure()
            self._migrate()
        except BaseException:
            # 初始化失败必须释放句柄，否则 Windows 上存档文件保持锁定。
            self._connection.close()
            raise

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
            if self.path == ":memory:":
                with self._lock:
                    self._connection.backup(target)
            else:
                # 独立源连接执行备份：不持有主连接锁，事件循环上的查询不会被备份阻塞。
                source = sqlite3.connect(self.path, timeout=10.0)
                try:
                    source.backup(target)
                finally:
                    source.close()
            result = str(target.execute("PRAGMA quick_check").fetchone()[0])
            if result != "ok":
                raise MemoryStoreError(f"Heartloom backup integrity check failed: {result}")
        finally:
            target.close()

    def _read_schema_version(self) -> int | None:
        try:
            row = self._connection.execute(
                "SELECT value FROM heartloom_meta WHERE key = 'schema_version'"
            ).fetchone()
        except sqlite3.OperationalError:
            return None  # 全新库:meta 表尚未创建
        if row is None:
            return None
        try:
            return int(str(row[0]))
        except (TypeError, ValueError):
            return 0

    def _existing_journey_ids(self) -> list[str]:
        rows = self._connection.execute(
            """
            SELECT save_id FROM memory_entries
            UNION SELECT save_id FROM life_outbox
            UNION SELECT save_id FROM life_events
            """
        ).fetchall()
        return [str(row["save_id"]) for row in rows]

    def _journey_anchor_real(self, save_id: str) -> int:
        """旅程世界时钟锚点 = 该旅程最早一条记忆/生活事件的真实时刻。"""
        row = self._connection.execute(
            "SELECT MIN(created_at) AS first_at FROM memory_entries WHERE save_id = ?",
            (save_id,),
        ).fetchone()
        if row is not None and row["first_at"] is not None:
            return int(row["first_at"])
        row = self._connection.execute(
            "SELECT MIN(occurred_at_unix) AS first_at FROM life_events WHERE save_id = ?",
            (save_id,),
        ).fetchone()
        if row is not None and row["first_at"] is not None:
            return int(row["first_at"])
        return int(time.time())

    def _journey_clock(self, save_id: str) -> tuple[int, float, float]:
        with self._lock:
            row = self._connection.execute(
                "SELECT anchor_real, world_value, rate FROM journey_clock WHERE save_id = ?",
                (save_id,),
            ).fetchone()
            if row is not None:
                return int(row["anchor_real"]), float(row["world_value"]), float(row["rate"])
            anchor = self._journey_anchor_real(save_id)
            with self._connection:
                self._connection.execute(
                    "INSERT OR IGNORE INTO journey_clock(save_id, anchor_real, world_value, rate) "
                    "VALUES (?, ?, 0.0, 1.0)",
                    (save_id, anchor),
                )
            return anchor, 0.0, 1.0

    def world_now(self, save_id: str) -> float:
        """旅程当前世界时间(REAL,单位 = 世界天)。唯一读取现实时钟的位置。"""
        return self.world_from_real(save_id, time.time())

    def world_from_real(self, save_id: str, real_ts: float) -> float:
        anchor, world_value, rate = self._journey_clock(save_id)
        return world_value + (float(real_ts) - anchor) / 86400.0 * rate

    def set_journey_rate(self, save_id: str, rate: float) -> None:
        """Phase 2+(离线推演倍率)入口:重锚定时钟并换挡,保证时间连续。"""
        if rate <= 0:
            raise MemoryStoreError("world clock rate must be positive")
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO journey_clock(save_id, anchor_real, world_value, rate)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(save_id) DO UPDATE SET
                    anchor_real = excluded.anchor_real,
                    world_value = excluded.world_value,
                    rate = excluded.rate
                """,
                (save_id, int(time.time()), self.world_now(save_id), float(rate)),
            )

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
            acked_at INTEGER NOT NULL DEFAULT 0,
            world_created_at REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_life_outbox_pending
            ON life_outbox(save_id, acked_at, available_at, created_at);

        CREATE TABLE IF NOT EXISTS life_events (
            event_id         TEXT NOT NULL,
            save_id          TEXT NOT NULL,
            role_id          TEXT NOT NULL,
            target_role      TEXT NOT NULL DEFAULT '',
            action           TEXT NOT NULL,
            description      TEXT NOT NULL DEFAULT '',
            occurred_at_unix INTEGER NOT NULL,
            stat_changes_json TEXT NOT NULL DEFAULT '{}',
            created_at       INTEGER NOT NULL,
            PRIMARY KEY (event_id, save_id)
        );
        CREATE INDEX IF NOT EXISTS idx_life_events_save_time
            ON life_events(save_id, occurred_at_unix);

        CREATE TABLE IF NOT EXISTS digest_state (
            save_id         TEXT NOT NULL,
            role_id         TEXT NOT NULL,
            day_key         TEXT NOT NULL,   -- "YYYY-MM-DD"
            memory_id       TEXT NOT NULL DEFAULT '',
            created_at      INTEGER NOT NULL,
            PRIMARY KEY (save_id, role_id, day_key)
        );

        CREATE TABLE IF NOT EXISTS milestones (
            save_id          TEXT NOT NULL,
            milestone_id     TEXT NOT NULL,
            unlocked_at      INTEGER NOT NULL,
            source_memory_id TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (save_id, milestone_id)
        );

        CREATE TABLE IF NOT EXISTS journey_clock (
            save_id     TEXT PRIMARY KEY,
            anchor_real INTEGER NOT NULL,
            world_value REAL NOT NULL DEFAULT 0.0,
            rate        REAL NOT NULL DEFAULT 1.0
        );

        CREATE TABLE IF NOT EXISTS memory_links (
            link_id          TEXT PRIMARY KEY,
            save_id          TEXT NOT NULL,
            src_memory_id    TEXT NOT NULL,
            dst_memory_id    TEXT NOT NULL,
            link_type        TEXT NOT NULL
                             CHECK(link_type IN ('causal','association','spread','milestone')),
            link_strength    REAL NOT NULL DEFAULT 0.5,
            reason           TEXT NOT NULL DEFAULT '',
            world_created_at REAL NOT NULL,
            UNIQUE(src_memory_id, dst_memory_id, link_type)
        );
        CREATE INDEX IF NOT EXISTS idx_links_src
            ON memory_links(save_id, src_memory_id, link_strength DESC);
        CREATE INDEX IF NOT EXISTS idx_links_dst
            ON memory_links(save_id, dst_memory_id);
        CREATE INDEX IF NOT EXISTS idx_links_type
            ON memory_links(save_id, link_type);

        CREATE TABLE IF NOT EXISTS role_milestones (
            milestone_id      TEXT PRIMARY KEY,
            save_id           TEXT NOT NULL,
            role_id           TEXT NOT NULL,
            rule_id           TEXT NOT NULL,
            title             TEXT NOT NULL DEFAULT '',
            description       TEXT NOT NULL DEFAULT '',
            icon              TEXT NOT NULL DEFAULT '',
            source_memory_id  TEXT NOT NULL DEFAULT '',
            unlocked_world_at REAL NOT NULL,
            created_at        INTEGER NOT NULL,
            UNIQUE(save_id, role_id, rule_id)
        );
        CREATE INDEX IF NOT EXISTS idx_role_ms_save
            ON role_milestones(save_id, role_id, unlocked_world_at DESC);

        CREATE TABLE IF NOT EXISTS state_events (
            event_id     TEXT PRIMARY KEY,
            save_id      TEXT NOT NULL,
            role_id      TEXT NOT NULL,
            kind         TEXT NOT NULL,
            delta_json   TEXT NOT NULL DEFAULT '{}',
            world_time   REAL NOT NULL,
            real_unix    INTEGER NOT NULL,
            note         TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_state_events_save_world
            ON state_events(save_id, role_id, world_time);
        """
        # ADR-001 Phase 1:升级到 v6 前强制备份(文件库;可重复执行,已是 v6 不重复备份)
        stored_version = self._read_schema_version()
        if stored_version is not None and stored_version < 6 and self.path != ":memory:":
            self.backup_to(str(self.path) + ".pre-v6.backup")
        with self._lock, self._connection:
            self._connection.executescript(schema)
            stored_version = self._read_schema_version()
            if stored_version is not None and stored_version > SCHEMA_VERSION:
                raise MemoryStoreError(
                    f"Heartloom database schema version {stored_version} is newer "
                    f"than this build supports ({SCHEMA_VERSION}); upgrade the app to open this save"
                )
            # 老库迁移：为已存在的 life_events 表补充 target_role 列（幂等）
            columns = {
                str(row["name"])
                for row in self._connection.execute(
                    "PRAGMA table_info(life_events)"
                ).fetchall()
            }
            if "target_role" not in columns:
                self._connection.execute(
                    "ALTER TABLE life_events ADD COLUMN target_role TEXT NOT NULL DEFAULT ''"
                )
            # ===== v6(ADR-001):world_time 列守卫(幂等) =====
            memory_columns = {
                str(row["name"])
                for row in self._connection.execute(
                    "PRAGMA table_info(memory_entries)"
                ).fetchall()
            }
            for ddl in (
                "ALTER TABLE memory_entries ADD COLUMN world_created_at REAL NOT NULL DEFAULT 0",
                "ALTER TABLE memory_entries ADD COLUMN world_updated_at REAL NOT NULL DEFAULT 0",
                "ALTER TABLE memory_entries ADD COLUMN last_recalled_world REAL NOT NULL DEFAULT 0",
                "ALTER TABLE memory_entries ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active'",
                "ALTER TABLE memory_entries ADD COLUMN lifecycle_changed_world REAL NOT NULL DEFAULT 0",
                "ALTER TABLE memory_entries ADD COLUMN is_second_hand INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE memory_entries ADD COLUMN embedding_json TEXT",
                "ALTER TABLE memory_entries ADD COLUMN embedding_model TEXT NOT NULL DEFAULT ''",
            ):
                column_name = ddl.split("ADD COLUMN ", 1)[1].split(" ", 1)[0]
                if column_name not in memory_columns:
                    self._connection.execute(ddl)
            outbox_columns = {
                str(row["name"])
                for row in self._connection.execute(
                    "PRAGMA table_info(life_outbox)"
                ).fetchall()
            }
            if "world_created_at" not in outbox_columns:
                self._connection.execute(
                    "ALTER TABLE life_outbox ADD COLUMN world_created_at REAL NOT NULL DEFAULT 0"
                )
            # 既有旅程的时钟锚点初始化(新旅程在首次 world_now 时惰性创建)
            if stored_version is None or stored_version < 6:
                # 二手传闻标记:传播链记忆(heard_from_*)回填(ADR-001 D5)
                self._connection.execute(
                    "UPDATE memory_entries SET is_second_hand = 1 "
                    "WHERE source LIKE 'heard_from_%' AND is_second_hand = 0"
                )
                for save_id in self._existing_journey_ids():
                    anchor = self._journey_anchor_real(save_id)
                    self._connection.execute(
                        "INSERT OR IGNORE INTO journey_clock(save_id, anchor_real, world_value, rate) "
                        "VALUES (?, ?, 0.0, 1.0)",
                        (save_id, anchor),
                    )
                # world 列回填:经各旅程时钟换算,确定性幂等(仅升级时执行一次)
                for save_id in self._existing_journey_ids():
                    anchor, world_value, rate = self._journey_clock(save_id)
                    memory_rows = self._connection.execute(
                        "SELECT memory_id, created_at, updated_at, last_recalled_at "
                        "FROM memory_entries WHERE save_id = ?",
                        (save_id,),
                    ).fetchall()
                    self._connection.executemany(
                        """
                        UPDATE memory_entries
                        SET world_created_at = ?, world_updated_at = ?, last_recalled_world = ?
                        WHERE memory_id = ?
                        """,
                        [
                            (
                                world_value + (int(row["created_at"]) - anchor) / 86400.0 * rate,
                                world_value + (int(row["updated_at"]) - anchor) / 86400.0 * rate,
                                (
                                    world_value + (int(row["last_recalled_at"]) - anchor) / 86400.0 * rate
                                    if int(row["last_recalled_at"]) > 0
                                    else 0.0
                                ),
                                str(row["memory_id"]),
                            )
                            for row in memory_rows
                        ],
                    )
                    outbox_rows = self._connection.execute(
                        "SELECT delivery_id, created_at FROM life_outbox WHERE save_id = ?",
                        (save_id,),
                    ).fetchall()
                    self._connection.executemany(
                        "UPDATE life_outbox SET world_created_at = ? WHERE delivery_id = ?",
                        [
                            (
                                world_value + (int(row["created_at"]) - anchor) / 86400.0 * rate,
                                str(row["delivery_id"]),
                            )
                            for row in outbox_rows
                        ],
                    )
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
        world_now_value = self.world_now(save_id)
        is_second_hand = 1 if source.startswith("heard_from_") else 0

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
                    source_event_id, created_at, updated_at, enabled,
                    world_created_at, world_updated_at, is_second_hand
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    enabled = excluded.enabled,
                    world_updated_at = excluded.world_updated_at
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
                    world_now_value,
                    world_now_value,
                    is_second_hand,
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
        query_vector: list[float] | None = None,
        embedding_model: str = "",
    ) -> list[dict[str, Any]]:
        if role_id not in self.role_ids:
            raise MemoryStoreError("role_id is invalid")
        requested = max(1, min(24, int(limit)))
        query_terms = set(_extract_terms(query))
        params: list[Any] = [save_id, SHARED_SCOPE, role_id]
        term_clause = ""
        dormant_clause = ""
        if query_terms:
            placeholders = ",".join("?" for _ in query_terms)
            term_subquery = f"SELECT memory_id FROM memory_terms WHERE term IN ({placeholders})"
            term_clause = f" OR memory_id IN ({term_subquery})"
            # 精确关键词命中可唤醒 dormant 记忆(ADR-001 D5);archived 不可自动激活
            dormant_clause = f" OR (lifecycle = 'dormant' AND memory_id IN ({term_subquery}))"
            params.extend(sorted(query_terms))
            params.extend(sorted(query_terms))
        params.append(max(100, requested * 30))
        sql = f"""
            SELECT * FROM memory_entries
            WHERE save_id = ?
              AND scope_role_id IN (?, ?)
              AND enabled = 1
              AND (
                    (lifecycle = 'active' AND (always_active = 1{term_clause}))
                    {dormant_clause}
              )
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

        world_now_value = self.world_now(save_id)
        # graph_boost(ADR-001 D1):候选记忆与 always_active 常驻记忆之间的
        # 一级静态边最大强度;只读预存边,不实时计算,无邻接则为 0。
        graph_boost: dict[str, float] = {}
        candidate_ids = [str(row["memory_id"]) for row in rows]
        if candidate_ids:
            placeholders = ",".join("?" for _ in candidate_ids)
            for item in self._connection.execute(
                f"""
                SELECT l.src_memory_id AS side_a, l.dst_memory_id AS side_b, l.link_strength
                FROM memory_links AS l
                JOIN memory_entries AS pinned
                  ON (pinned.memory_id = l.src_memory_id OR pinned.memory_id = l.dst_memory_id)
                 AND pinned.always_active = 1 AND pinned.lifecycle = 'active'
                WHERE l.src_memory_id IN ({placeholders})
                   OR l.dst_memory_id IN ({placeholders})
                """,
                (*candidate_ids, *candidate_ids),
            ).fetchall():
                strength = float(item["link_strength"])
                for side in (item["side_a"], item["side_b"]):
                    side = str(side)
                    if side in candidate_ids:
                        graph_boost[side] = max(graph_boost.get(side, 0.0), strength)

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
            lexical = min(1.0, lexical)  # 归一化到 0-1,保证各通道量纲一致(ADR-001 D1)
            # 衰减/recency 全部基于 world_time(世界天),不再读取现实时间(#23)
            age_days = max(0.0, world_now_value - float(row["world_updated_at"]))
            half_life = float(row["half_life_days"])
            decay = 1.0 if half_life <= 0.0 else math.pow(0.5, age_days / half_life)
            importance = float(row["importance"]) * decay
            recency = math.pow(0.5, age_days / 30.0)
            priority = (int(row["priority"]) + 10) / 20.0
            # 语义通道(ADR-001 D1):query_vector 缺失时该路权重并回其余通道
            semantic = 0.0
            if query_vector is not None and row["embedding_json"] and str(row["embedding_model"]) == embedding_model:
                try:
                    vector = [float(item) for item in json.loads(row["embedding_json"])]
                except (TypeError, ValueError, json.JSONDecodeError):
                    vector = []
                cosine = self._memory_cosine(query_vector, vector)
                if cosine is not None:
                    semantic = max(0.0, min(1.0, (cosine + 1.0) / 2.0))
            if query_vector is not None:
                score = 0.40 * semantic + 0.25 * lexical + 0.20 * importance + 0.10 * recency + 0.05 * priority
            else:
                score = (0.25 * lexical + 0.20 * importance + 0.10 * recency + 0.05 * priority) / 0.60
            score = min(1.0, score) + 0.05 * graph_boost.get(str(row["memory_id"]), 0.0)
            if bool(row["always_active"]):
                score = max(score, 0.82 + priority * 0.12)
            if bool(row["always_active"]) or lexical > 0.0:
                scored.append((score, row))
        scored.sort(key=lambda item: (item[0], int(item[1]["updated_at"])), reverse=True)
        selected = scored[:requested]
        # dormant 命中自动唤醒(ADR-001 D5)
        dormant_hits = [str(row["memory_id"]) for _, row in selected if str(row["lifecycle"]) == "dormant"]
        if dormant_hits:
            with self._lock, self._connection:
                self._connection.executemany(
                    "UPDATE memory_entries SET lifecycle = 'active', lifecycle_changed_world = ? WHERE memory_id = ?",
                    [(world_now_value, mid) for mid in dormant_hits],
                )
        result = [self._memory_row(row, score=score) for score, row in selected]

        if record_access:
            now = int(time.time())  # 现实时间仅作日志;模拟维度写 last_recalled_world
            with self._lock, self._connection:
                if selected:
                    self._connection.executemany(
                        """
                        UPDATE memory_entries
                        SET last_recalled_at = ?, last_recalled_world = ?, recall_count = recall_count + 1
                        WHERE memory_id = ?
                        """,
                        [(now, world_now_value, str(row["memory_id"])) for _, row in selected],
                    )
                self._set_meta("last_recall_at", str(now))
                self._set_meta("last_recall_count", str(len(selected)))
                self._set_meta("last_recall_role", role_id)
                self._set_meta("last_recall_save", save_id)
        return result

    # ===== ADR-001 Phase 3:记忆网络与混合召回 =====

    def apply_lifecycle_transitions(self, save_id: str | None = None) -> dict[str, int]:
        """三态生命周期规则(常量阈值,ADR-001 D5):dormant/archived 自动迁移。"""
        stats = {"dormant": 0, "archived": 0}
        with self._lock, self._connection:
            saves = [save_id] if save_id else self._existing_journey_ids()
            for sid in saves:
                world_now_value = self.world_now(sid)
                rows = self._connection.execute(
                    """
                    SELECT memory_id, confidence, half_life_days, world_created_at,
                           world_updated_at, last_recalled_world
                    FROM memory_entries
                    WHERE save_id = ? AND lifecycle = 'active'
                      AND enabled = 1 AND always_active = 0
                    """,
                    (sid,),
                ).fetchall()
                dormant_ids: list[str] = []
                archived_ids: list[str] = []
                for row in rows:
                    # last_recalled_world=0 为"从未召回"哨兵,不得视为旅程原点的接触
                    last_touch = float(row["world_updated_at"])
                    recalled_world = float(row["last_recalled_world"])
                    if recalled_world > 0.0:
                        last_touch = max(last_touch, recalled_world)
                    if world_now_value - last_touch >= DORMANT_AFTER_WORLD_DAYS:
                        dormant_ids.append(str(row["memory_id"]))
                        continue
                    half_life = float(row["half_life_days"])
                    if half_life <= 0.0:
                        continue
                    age = max(0.0, world_now_value - float(row["world_created_at"]))
                    decayed = float(row["confidence"]) * math.pow(0.5, age / half_life)
                    if decayed < ARCHIVE_CONFIDENCE_THRESHOLD:
                        archived_ids.append(str(row["memory_id"]))
                for target, ids in (("dormant", dormant_ids), ("archived", archived_ids)):
                    if ids:
                        self._connection.executemany(
                            "UPDATE memory_entries SET lifecycle = ?, lifecycle_changed_world = ? "
                            "WHERE memory_id = ?",
                            [(target, world_now_value, mid) for mid in ids],
                        )
                        stats[target] += len(ids)
        return stats

    def set_memory_lifecycle(self, memory_id: str, lifecycle: str) -> None:
        """手动归档/恢复(archived 只能由此恢复,召回命中无法激活)。"""
        if lifecycle not in {"active", "dormant", "archived"}:
            raise MemoryStoreError("lifecycle is invalid")
        with self._lock, self._connection:
            row = self._connection.execute(
                "SELECT save_id FROM memory_entries WHERE memory_id = ?", (memory_id,)
            ).fetchone()
            if row is None:
                raise MemoryStoreError("memory_id is invalid")
            self._connection.execute(
                "UPDATE memory_entries SET lifecycle = ?, lifecycle_changed_world = ? WHERE memory_id = ?",
                (lifecycle, self.world_now(str(row["save_id"])), memory_id),
            )

    def update_memory_embedding(self, memory_id: str, vector: list[float], model: str) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE memory_entries SET embedding_json = ?, embedding_model = ? WHERE memory_id = ?",
                (_json([round(float(item), 6) for item in vector]), _clean_text(model, 80), memory_id),
            )

    def memories_without_embedding(self, save_id: str, limit: int = 16) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT memory_id, content FROM memory_entries
                WHERE save_id = ? AND embedding_json IS NULL AND enabled = 1
                  AND lifecycle = 'active'
                ORDER BY importance DESC, world_updated_at DESC
                LIMIT ?
                """,
                (save_id, max(1, min(64, int(limit)))),
            ).fetchall()
        return [{"memory_id": str(row["memory_id"]), "content": str(row["content"])} for row in rows]

    @staticmethod
    def _memory_cosine(a: list[float], b: list[float]) -> float | None:
        if not a or not b or len(a) != len(b):
            return None
        dot = sum(x * y for x, y in zip(a, b))
        norm_a = math.sqrt(sum(x * x for x in a))
        norm_b = math.sqrt(sum(x * x for x in b))
        if norm_a <= 0.0 or norm_b <= 0.0:
            return None
        return dot / (norm_a * norm_b)

    def build_links_for_memory(self, memory_id: str, max_links: int = 4) -> list[dict[str, Any]]:
        """增量建边(ADR-001 D4):候选集有界,单条新记忆最多 max_links 条边。"""
        built: list[dict[str, Any]] = []
        with self._lock, self._connection:
            new_row = self._connection.execute(
                """
                SELECT memory_id, save_id, kind, title, content, trigger_terms_json,
                       source, source_event_id, world_created_at, embedding_json, embedding_model
                FROM memory_entries WHERE memory_id = ?
                """,
                (memory_id,),
            ).fetchone()
            if new_row is None:
                return []
            save_id = str(new_row["save_id"])
            world_now_value = self.world_now(save_id)
            new_embedding_vector: list[float] | None = None
            if new_row["embedding_json"]:
                try:
                    new_embedding_vector = json.loads(new_row["embedding_json"])
                except (TypeError, ValueError):
                    new_embedding_vector = None
            candidate_ids: list[str] = []
            for row in self._connection.execute(
                """
                SELECT memory_id FROM memory_entries
                WHERE save_id = ? AND memory_id != ? AND lifecycle = 'active'
                ORDER BY world_updated_at DESC LIMIT 50
                """,
                (save_id, memory_id),
            ):
                candidate_ids.append(str(row["memory_id"]))
            new_terms = {
                str(item["term"])
                for item in self._connection.execute(
                    "SELECT term FROM memory_terms WHERE memory_id = ?", (memory_id,)
                ).fetchall()
            }
            if new_terms:
                placeholders = ",".join("?" for _ in new_terms)
                for row in self._connection.execute(
                    f"SELECT memory_id FROM memory_terms WHERE term IN ({placeholders}) "
                    "AND memory_id != ? LIMIT 20",
                    (*sorted(new_terms), memory_id),
                ):
                    if str(row["memory_id"]) not in candidate_ids:
                        candidate_ids.append(str(row["memory_id"]))
            if str(new_row["source_event_id"] or ""):
                for row in self._connection.execute(
                    "SELECT memory_id FROM memory_entries WHERE save_id = ? AND source_event_id = ? "
                    "AND memory_id != ? LIMIT 10",
                    (save_id, str(new_row["source_event_id"]), memory_id),
                ):
                    if str(row["memory_id"]) not in candidate_ids:
                        candidate_ids.append(str(row["memory_id"]))
            if not candidate_ids:
                return []
            placeholders = ",".join("?" for _ in candidate_ids)
            candidate_rows = self._connection.execute(
                f"SELECT memory_id, content FROM memory_entries WHERE memory_id IN ({placeholders})",
                tuple(candidate_ids),
            ).fetchall()
            candidate_embeddings: dict[str, list[float]] = {}
            for row in candidate_rows:
                if row["memory_id"] == memory_id:
                    continue
                own = self._connection.execute(
                    "SELECT embedding_json, embedding_model FROM memory_entries WHERE memory_id = ?",
                    (row["memory_id"],),
                ).fetchone()
                if own is not None and own["embedding_json"]:
                    try:
                        candidate_embeddings[str(row["memory_id"])] = json.loads(own["embedding_json"])
                    except (TypeError, ValueError):
                        continue
            new_terms_by_memory: dict[str, set[str]] = {}
            for item in self._connection.execute(
                f"SELECT memory_id, term FROM memory_terms WHERE memory_id IN ({placeholders})",
                tuple(candidate_ids),
            ).fetchall():
                new_terms_by_memory.setdefault(str(item["memory_id"]), set()).add(str(item["term"]))

            scored: list[tuple[float, str, str, str]] = []
            for candidate_id in candidate_ids:
                if candidate_id == memory_id:
                    continue
                shared = new_terms & new_terms_by_memory.get(candidate_id, set())
                score = min(0.6, 0.2 * len(shared))
                reason = f"共享词条:{'、'.join(sorted(shared)[:3])}" if shared else ""
                candidate_vector = candidate_embeddings.get(candidate_id)
                if candidate_vector and new_embedding_vector is not None and len(candidate_vector) == len(new_embedding_vector):
                    cosine = self._memory_cosine(new_embedding_vector, candidate_vector)
                    if cosine is not None and cosine > 0.5:
                        score = max(score, min(0.9, (cosine + 1.0) / 2.0))
                        reason = (reason + f" 语义相似 {cosine:.2f}").strip()
                if str(new_row["source_event_id"] or "") and self._connection.execute(
                    "SELECT 1 FROM memory_entries WHERE memory_id = ? AND source_event_id = ?",
                    (candidate_id, str(new_row["source_event_id"])),
                ).fetchone():
                    score = max(score, 0.85)
                    reason = "来自同一次经历"
                if score <= 0.0:
                    continue
                scored.append(
                    (
                        min(1.0, score),
                        candidate_id,
                        (
                            "milestone"
                            if str(new_row["source"]) == "milestone"
                            else "spread"
                            if str(new_row["source"]).startswith("heard_from_")
                            else "association"
                        ),
                        reason,
                    )
                )
            scored.sort(key=lambda item: item[0], reverse=True)
            for score, candidate_id, link_type, reason in scored[: max(1, min(5, int(max_links)))]:
                link_id = "lnk-" + hashlib.sha256(
                    f"{save_id}|{memory_id}|{candidate_id}|{link_type}".encode("utf-8")
                ).hexdigest()[:40]
                cursor = self._connection.execute(
                    """
                    INSERT OR IGNORE INTO memory_links (
                        link_id, save_id, src_memory_id, dst_memory_id,
                        link_type, link_strength, reason, world_created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        link_id,
                        save_id,
                        memory_id,
                        candidate_id,
                        link_type,
                        round(score, 4),
                        _clean_text(reason, 120),
                        world_now_value,
                    ),
                )
                if cursor.rowcount:
                    built.append({"candidate_id": candidate_id, "link_type": link_type, "strength": score, "reason": reason})
        return built

    def graph_page(
        self,
        *,
        save_id: str,
        role_id: str = "",
        query: str = "",
        limit: int = 120,
        offset: int = 0,
    ) -> dict[str, Any]:
        """分页节点 + 集合内部边(默认仅 Active,上限 300)。"""
        node_limit = max(1, min(300, int(limit)))
        offset = max(0, int(offset))
        role_clause = "" if not role_id else "AND (scope_role_id = ? OR scope_role_id = '*')"
        query_clause = ""
        params: list[Any] = [save_id]
        if role_id:
            params.extend([role_id])
        normalized_query = str(query).replace("\x00", " ").strip()
        if normalized_query:
            escaped = normalized_query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            query_clause = "AND (title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')"
            params.extend([f"%{escaped}%", f"%{escaped}%"])
        params.extend([node_limit + 1, offset])
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT memory_id, kind, title, content, scope_role_id, lifecycle,
                       is_second_hand, importance, world_created_at, world_updated_at
                FROM memory_entries
                WHERE save_id = ? AND lifecycle = 'active' AND enabled = 1 {role_clause} {query_clause}
                ORDER BY world_updated_at DESC, memory_id
                LIMIT ? OFFSET ?
                """,
                params,
            ).fetchall()
            truncated = len(rows) > node_limit
            nodes = rows[:node_limit]
            node_ids = [str(row["memory_id"]) for row in nodes]
            edges: list[dict[str, Any]] = []
            if node_ids:
                placeholders = ",".join("?" for _ in node_ids)
                for row in self._connection.execute(
                    f"""
                    SELECT link_id, src_memory_id, dst_memory_id, link_type,
                           link_strength, reason
                    FROM memory_links
                    WHERE save_id = ?
                      AND src_memory_id IN ({placeholders})
                      AND dst_memory_id IN ({placeholders})
                    ORDER BY link_strength DESC
                    """,
                    (save_id, *node_ids, *node_ids),
                ).fetchall():
                    edges.append(
                        {
                            "link_id": str(row["link_id"]),
                            "src": str(row["src_memory_id"]),
                            "dst": str(row["dst_memory_id"]),
                            "link_type": str(row["link_type"]),
                            "link_strength": float(row["link_strength"]),
                            "reason": str(row["reason"]),
                        }
                    )
        importance_bucket = lambda value: "high" if value >= 0.8 else "normal" if value >= 0.5 else "low"
        node_payload = [
            {
                "memory_id": str(row["memory_id"]),
                "kind": str(row["kind"]),
                "title": str(row["title"])[:80],
                "summary": str(row["content"])[:120],
                "content": str(row["content"])[:500],
                "scope_role_id": str(row["scope_role_id"]),
                "lifecycle": str(row["lifecycle"]),
                "is_second_hand": bool(row["is_second_hand"]),
                "importance_bucket": importance_bucket(float(row["importance"])),
                "world_created_at": float(row["world_created_at"]),
                "world_updated_at": float(row["world_updated_at"]),
            }
            for row in nodes
        ]
        return {
            "nodes": node_payload,
            "edges": edges,
            "cursor": str(offset + len(node_payload)) if truncated else "",
            "truncated": truncated,
            "node_count": len(node_payload),
        }

    def record_state_event(
        self, *, save_id: str, role_id: str, kind: str, delta_json: dict[str, Any], note: str = ""
    ) -> None:
        """#22 事件日志(仅调试用,不参与运行时重放)。"""
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO state_events (
                    event_id, save_id, role_id, kind, delta_json, world_time, real_unix, note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "ste-" + uuid.uuid4().hex,
                    save_id,
                    role_id,
                    _clean_text(kind, 24) or "interaction",
                    _json(delta_json),
                    self.world_now(save_id),
                    int(time.time()),
                    _clean_text(note, 200),
                ),
            )

    def unlock_role_milestone(
        self,
        *,
        save_id: str,
        role_id: str,
        rule_id: str,
        title: str,
        description: str,
        source_memory_id: str,
        unlocked_world_at: float,
    ) -> str:
        """成就档案解锁(幂等);返回 role_milestones 行 ID。"""
        milestone_id = "ach-" + hashlib.sha256(
            f"{save_id}|{role_id}|{rule_id}".encode("utf-8")
        ).hexdigest()[:40]
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT OR IGNORE INTO role_milestones (
                    milestone_id, save_id, role_id, rule_id, title, description,
                    icon, source_memory_id, unlocked_world_at, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, '', ?, ?, ?)
                """,
                (
                    milestone_id,
                    save_id,
                    role_id,
                    rule_id,
                    _clean_text(title, 60),
                    _clean_text(description, 240),
                    source_memory_id,
                    float(unlocked_world_at),
                    int(time.time()),
                ),
            )
        return milestone_id

    def update_role_milestone_copy(self, milestone_id: str, title: str, description: str) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE role_milestones SET title = ?, description = ? WHERE milestone_id = ?",
                (_clean_text(title, 60), _clean_text(description, 240), milestone_id),
            )

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
            clauses.append("(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')")
            like = "%{}%".format(
                normalized_query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            )
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
        # 世界间隔换算系数只取一次(#23):时间分段随倍率缩放,循环内不做时钟查询
        world_rate = self._journey_clock(save_id)[2]
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
                time_gap = abs(
                    int(left.get("created_at", 0)) - int(right.get("created_at", 0))
                ) * world_rate  # 世界间隔随倍率缩放(#23)
                # 时间分段权重：让时间上相关的事件自然浮现
                if time_gap <= 3_600:
                    strength += 0.18
                    reasons.append("一小时内")
                elif time_gap <= 86_400:
                    strength += 0.12
                    reasons.append("同一天")
                elif time_gap <= 7 * 86_400:
                    strength += 0.06
                    reasons.append("一周内")
                # 召回强化：经常一起被想起的记忆关联更强
                left_recall = int(left.get("recall_count", 0))
                right_recall = int(right.get("recall_count", 0))
                if left_recall >= 3 and right_recall >= 3:
                    boost = min(0.10, (math.log1p(left_recall) + math.log1p(right_recall)) * 0.015)
                    strength += boost
                    reasons.append("经常被一起想起")
                candidates.append(
                    {
                        "source": left_id,
                        "target": right_id,
                        "strength": round(min(1.0, strength), 4),
                        "shared_terms": shared_terms[:6],
                        "reasons": reasons[:5],
                        "same_source_event": same_event,
                        "time_gap_seconds": time_gap,
                    }
                )

        # 同源星形去噪：同一源事件的记忆只保留与组内最高 importance 节点的连接，
        # 避免"同一个对话的碎片"互相全连挤占度预算
        same_event_groups: dict[str, list[dict[str, Any]]] = {}
        for edge in candidates:
            if edge["same_source_event"]:
                # 用边两端记忆的 source_event_id 家族分组（不是 memory_id）
                source_family = _graph_source_family(
                    str(by_id.get(str(edge["source"]), {}).get("source_event_id", ""))
                )
                target_family = _graph_source_family(
                    str(by_id.get(str(edge["target"]), {}).get("source_event_id", ""))
                )
                family = source_family or target_family
                if family:
                    same_event_groups.setdefault(family, []).append(edge)
        suppressed_source_edge_ids: set[tuple[str, str]] = set()
        for group in same_event_groups.values():
            if len(group) <= 1:
                continue
            center_candidates: dict[str, float] = {}
            for edge in group:
                center_candidates[str(edge["source"])] = max(
                    center_candidates.get(str(edge["source"]), 0.0),
                    float(by_id.get(str(edge["source"]), {}).get("importance", 0.0)),
                )
                center_candidates[str(edge["target"])] = max(
                    center_candidates.get(str(edge["target"]), 0.0),
                    float(by_id.get(str(edge["target"]), {}).get("importance", 0.0)),
                )
            center = max(center_candidates, key=lambda item: center_candidates[item])
            for edge in group:
                if str(edge["source"]) != center and str(edge["target"]) != center:
                    suppressed_source_edge_ids.add(
                        tuple(sorted((str(edge["source"]), str(edge["target"]))))
                    )
        if suppressed_source_edge_ids:
            candidates = [
                edge
                for edge in candidates
                if tuple(sorted((str(edge["source"]), str(edge["target"]))))
                not in suppressed_source_edge_ids
            ]

        # 同天生活链（骨架优先）：同一天产生的 daily_digest 记忆按时间顺序串联，
        # 先于语义边加入，保证"一天的生活"在图上形成可读的时间线
        daily_by_day: dict[str, list[str]] = {}
        for node in nodes:
            if str(node.get("source", "")) != "daily_digest":
                continue
            day_key = time.strftime(
                "%Y-%m-%d", time.localtime(int(node.get("created_at", 0)))
            )
            daily_by_day.setdefault(day_key, []).append(str(node["id"]))
        chain_edges: list[dict[str, Any]] = []
        for day_key, ids in daily_by_day.items():
            ids.sort(
                key=lambda mid: int(by_id.get(mid, {}).get("created_at", 0))
            )
            for index in range(len(ids) - 1):
                left_id, right_id = ids[index], ids[index + 1]
                chain_edges.append(
                    {
                        "source": left_id,
                        "target": right_id,
                        "strength": 0.50,
                        "shared_terms": [],
                        "reasons": ["同一天的生活"],
                        "same_source_event": False,
                        "time_gap_seconds": abs(
                            int(by_id[left_id].get("created_at", 0))
                            - int(by_id[right_id].get("created_at", 0))
                        ),
                    }
                )

        candidates.sort(
            key=lambda edge: (float(edge["strength"]), len(edge["shared_terms"])),
            reverse=True,
        )
        degrees = {memory_id: 0 for memory_id in memory_ids}
        edges: list[dict[str, Any]] = []
        # 链边先行（骨架）
        for edge in chain_edges:
            source = str(edge["source"])
            target = str(edge["target"])
            if degrees[source] >= 7 or degrees[target] >= 7:
                continue
            edge_key = tuple(sorted((source, target)))
            if any(
                tuple(sorted((str(e["source"]), str(e["target"])))) == edge_key
                for e in edges
            ):
                continue
            edges.append(edge)
            degrees[source] += 1
            degrees[target] += 1
        # 语义边填充
        for edge in candidates:
            source = str(edge["source"])
            target = str(edge["target"])
            if degrees[source] >= 7 or degrees[target] >= 7:
                continue
            edge_key = tuple(sorted((source, target)))
            if any(
                tuple(sorted((str(e["source"]), str(e["target"])))) == edge_key
                for e in edges
            ):
                continue
            edges.append(edge)
            degrees[source] += 1
            degrees[target] += 1
            if len(edges) >= 600:
                break
        for memory_id, degree in degrees.items():
            by_id[memory_id]["connection_count"] = degree

        # 孤立节点搭桥：度=0 的节点连到词法重叠最多的邻居。
        # 仅当存在真实共享词时才搭桥——避免把完全无关的记忆强行连上。
        isolated = [
            str(node["id"])
            for node in nodes
            if degrees.get(str(node["id"]), 0) == 0
        ]
        for mid in isolated:
            if degrees[mid] >= 1:
                continue
            best_neighbor = ""
            best_overlap = 0
            mid_terms = set(term_maps.get(mid, {}))
            mid_time = int(by_id.get(mid, {}).get("created_at", 0))
            for other in memory_ids:
                if other == mid or degrees.get(other, 0) >= 7:
                    continue
                other_terms = set(term_maps.get(other, {}))
                overlap = len(mid_terms.intersection(other_terms))
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_neighbor = other
            if best_neighbor and best_overlap > 0:
                edges.append(
                    {
                        "source": mid,
                        "target": best_neighbor,
                        "strength": 0.38,
                        "shared_terms": [],
                        "reasons": ["共享主题"],
                        "same_source_event": False,
                        "time_gap_seconds": abs(
                            int(by_id.get(best_neighbor, {}).get("created_at", 0)) - mid_time
                        ),
                    }
                )
                degrees[mid] += 1
                degrees[best_neighbor] += 1

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

    def get_memory_by_source_event(
        self,
        *,
        save_id: str,
        source: str,
        source_event_id: str,
        scope_role_id: str = SHARED_SCOPE,
    ) -> dict[str, Any] | None:
        """Find an enabled deterministic memory before doing expensive work."""
        with self._lock:
            row = self._connection.execute(
                """
                SELECT * FROM memory_entries
                WHERE save_id = ? AND source = ? AND source_event_id = ?
                  AND scope_role_id = ? AND enabled = 1
                """,
                (save_id, source, source_event_id, scope_role_id),
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
        with self._lock, self._connection:
            # 过期未 ack 的投递直接清理：客户端长期不启动时避免饿死离线生成与表膨胀。
            # TTL 按 world_time(世界天)计算(#23),现实时间仅经 journey_clock 换算。
            self._connection.execute(
                """
                DELETE FROM life_outbox
                WHERE acked_at = 0
                  AND world_created_at <= (
                      SELECT jc.world_value + (? - jc.anchor_real) / 86400.0 * jc.rate
                      FROM journey_clock AS jc
                      WHERE jc.save_id = life_outbox.save_id
                  )
                """,
                (timestamp - LIFE_OUTBOX_TTL_WORLD_DAYS * 86400.0,),
            )
            rows = self._connection.execute(
                """
                SELECT state.*
                FROM life_state AS state
                WHERE state.next_event_at > 0
                  AND state.next_event_at <= ?
                  AND NOT EXISTS (
                      SELECT 1 FROM life_outbox AS outbox
                      WHERE outbox.save_id = state.save_id
                        AND outbox.acked_at = 0
                        AND outbox.world_created_at > (
                            SELECT jc.world_value + (? - jc.anchor_real) / 86400.0 * jc.rate
                            FROM journey_clock AS jc
                            WHERE jc.save_id = outbox.save_id
                        )
                  )
                ORDER BY state.next_event_at ASC
                LIMIT ?
                """,
                (timestamp, timestamp - LIFE_OUTBOX_TTL_WORLD_DAYS * 86400.0, requested),
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
                    created_at, available_at, acked_at, world_created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
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
                    self.world_now(save_id),
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
                  AND world_created_at > ?
                ORDER BY created_at ASC, delivery_id ASC
                LIMIT ?
                """,
                (save_id, timestamp, self.world_now(save_id) - LIFE_OUTBOX_TTL_WORLD_DAYS, requested),
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

    def record_life_events(
        self,
        *,
        save_id: str,
        events: list[dict[str, Any]],
    ) -> dict[str, Any]:
        """Record Godot-reported life events (daily plan / self-care / personality).

        Idempotent: PRIMARY KEY (event_id, save_id) ignores duplicates, so a
        Godot client replaying the same event after a crash cannot double-record.
        """
        if not isinstance(events, list) or len(events) > 20:
            raise MemoryStoreError("recent_events must be a list with at most 20 items")
        timestamp = max(1, int(time.time()))
        recorded = 0
        with self._lock, self._connection:
            for raw in events:
                if not isinstance(raw, dict):
                    continue
                event_id = _safe_source_id(str(raw.get("event_id", "")), _json(raw))
                role_id = str(raw.get("role_id", "")).strip()
                if role_id not in self.role_ids:
                    continue
                target_role = str(raw.get("target_role", "")).strip()
                if target_role not in self.role_ids:
                    target_role = ""
                action = _clean_text(raw.get("action", ""), 64) or "life_activity"
                description = _clean_text(raw.get("description", ""), 500)
                occurred = max(1, int(raw.get("occurred_at_unix") or timestamp))
                stat_changes = raw.get("stat_changes", {})
                if not isinstance(stat_changes, (dict, list)):
                    stat_changes = {}
                encoded_stats = _json(stat_changes)
                if len(encoded_stats) > 8_000:
                    encoded_stats = "{}"
                cursor = self._connection.execute(
                    """
                    INSERT INTO life_events (
                        event_id, save_id, role_id, target_role, action, description,
                        occurred_at_unix, stat_changes_json, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(event_id, save_id) DO NOTHING
                    """,
                    (
                        event_id,
                        save_id,
                        role_id,
                        target_role,
                        action,
                        description,
                        occurred,
                        encoded_stats,
                        timestamp,
                    ),
                )
                recorded += int(cursor.rowcount or 0)
        return {"recorded": recorded, "total": len(events)}

    def list_life_events(
        self,
        *,
        save_id: str,
        role_id: str = "",
        action: str = "",
        limit: int = 200,
        before_unix: int = 0,
    ) -> list[dict[str, Any]]:
        """Read-only life-event timeline for the Godot review page."""
        requested = max(1, min(500, int(limit)))
        clauses = ["save_id = ?"]
        params: list[Any] = [save_id]
        if role_id:
            if role_id not in self.role_ids:
                raise MemoryStoreError("role_id is invalid")
            clauses.append("role_id = ?")
            params.append(role_id)
        if action:
            clauses.append("action = ?")
            params.append(_clean_text(action, 64))
        if before_unix > 0:
            clauses.append("occurred_at_unix < ?")
            params.append(max(1, int(before_unix)))
        params.append(requested)
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT * FROM life_events
                WHERE {' AND '.join(clauses)}
                ORDER BY occurred_at_unix DESC
                LIMIT ?
                """,
                params,
            ).fetchall()
        return [self._life_event_row(row) for row in rows]

    def digest_completed(self, *, save_id: str, role_id: str, day_key: str) -> bool:
        """True if a digest for this save+role+day was already produced."""
        if role_id not in self.role_ids:
            raise MemoryStoreError("role_id is invalid")
        with self._lock:
            row = self._connection.execute(
                "SELECT 1 FROM digest_state WHERE save_id = ? AND role_id = ? AND day_key = ?",
                (save_id, role_id, day_key),
            ).fetchone()
        return row is not None

    def mark_digest_completed(
        self, *, save_id: str, role_id: str, day_key: str, memory_id: str = ""
    ) -> None:
        if role_id not in self.role_ids:
            raise MemoryStoreError("role_id is invalid")
        timestamp = max(1, int(time.time()))
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO digest_state(save_id, role_id, day_key, memory_id, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(save_id, role_id, day_key) DO NOTHING
                """,
                (save_id, role_id, _clean_text(day_key, 10), _clean_text(memory_id, 80), timestamp),
            )

    def digest_day_events(
        self,
        *,
        save_id: str,
        role_id: str,
        day_start_unix: int,
        day_end_unix: int,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        """Life events for one role within a local-calendar-day window (oldest first)."""
        requested = max(1, min(100, int(limit)))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM life_events
                WHERE save_id = ? AND role_id = ?
                  AND occurred_at_unix >= ? AND occurred_at_unix < ?
                ORDER BY occurred_at_unix ASC
                LIMIT ?
                """,
                (save_id, role_id, int(day_start_unix), int(day_end_unix), requested),
            ).fetchall()
        return [self._life_event_row(row) for row in rows]

    def digest_pending_saves(self, now: int | None = None) -> list[dict[str, str]]:
        """Saves that have life events older than 12h not yet digested (per role/day).

        #23 交界待定桩(#22/#23 联合评审):day_key 暂为现实日期,12h 冷却暂按
        现实时间(rate=1.0 下与 world_time 恒等);world_time 倍率启用(rate≠1)
        时需迁移为世界日键并回填 digest_state,详见 ADR-001。
        """
        timestamp = max(1, int(now or time.time()))
        cutoff = timestamp - 12 * 3600
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT le.save_id, le.role_id,
                       date(le.occurred_at_unix, 'unixepoch', 'localtime') AS day_key
                FROM life_events AS le
                GROUP BY le.save_id, le.role_id, day_key
                HAVING MAX(le.occurred_at_unix) < ?
                   AND NOT EXISTS (
                      SELECT 1 FROM digest_state AS ds
                      WHERE ds.save_id = le.save_id
                        AND ds.role_id = le.role_id
                        AND ds.day_key = date(le.occurred_at_unix, 'unixepoch', 'localtime')
                  )
                ORDER BY le.save_id, le.role_id, day_key
                LIMIT 16
                """,
                (cutoff,),
            ).fetchall()
        return [
            {
                "save_id": str(row["save_id"]),
                "role_id": str(row["role_id"]),
                "day_key": str(row["day_key"]),
            }
            for row in rows
        ]

    def life_save_ids(self) -> list[str]:
        """Distinct save ids that ever synced life state (milestone/weekly scope)."""
        with self._lock:
            rows = self._connection.execute(
                "SELECT DISTINCT save_id FROM life_state ORDER BY save_id"
            ).fetchall()
        return [str(row["save_id"]) for row in rows]

    def memory_count(self, save_id: str) -> int:
        """Total enabled memory entries for a save (milestone counting)."""
        with self._lock:
            row = self._connection.execute(
                "SELECT COUNT(*) FROM memory_entries WHERE save_id = ? AND enabled = 1",
                (save_id,),
            ).fetchone()
        return int(row[0]) if row else 0

    def unlocked_milestones(self, save_id: str) -> dict[str, int]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT milestone_id, unlocked_at FROM milestones WHERE save_id = ?",
                (save_id,),
            ).fetchall()
        return {str(row["milestone_id"]): int(row["unlocked_at"]) for row in rows}

    def mark_milestone(
        self, *, save_id: str, milestone_id: str, source_memory_id: str = ""
    ) -> bool:
        """Record an unlocked milestone; returns False when already present."""
        timestamp = max(1, int(time.time()))
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                INSERT INTO milestones(save_id, milestone_id, unlocked_at, source_memory_id)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(save_id, milestone_id) DO NOTHING
                """,
                (save_id, _clean_text(milestone_id, 64), timestamp, _clean_text(source_memory_id, 80)),
            )
            return int(cursor.rowcount or 0) > 0

    def recent_digest_memories(
        self, *, save_id: str, since_unix: int, limit: int = 40
    ) -> list[dict[str, Any]]:
        """Daily-digest memories newer than since_unix (weekly insight input)."""
        requested = max(1, min(100, int(limit)))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM memory_entries
                WHERE save_id = ? AND source = 'daily_digest' AND created_at >= ?
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (save_id, int(since_unix), requested),
            ).fetchall()
        return [self._memory_row(row) for row in rows]

    @staticmethod
    def _life_event_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "event_id": str(row["event_id"]),
            "save_id": str(row["save_id"]),
            "role_id": str(row["role_id"]),
            "target_role": str(row["target_role"]) if "target_role" in row.keys() else "",
            "action": str(row["action"]),
            "description": str(row["description"]),
            "occurred_at_unix": int(row["occurred_at_unix"]),
            "stat_changes": _json_object(row["stat_changes_json"]),
            "created_at": int(row["created_at"]),
        }


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
