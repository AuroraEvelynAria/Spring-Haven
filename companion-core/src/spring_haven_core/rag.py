from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Iterable

from .provider import OpenAICompatibleProvider, ProviderError


DOCUMENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
ASCII_TERM = re.compile(r"[a-z0-9][a-z0-9_-]{1,63}")
HAN_SEQUENCE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]{2,}")
MARKDOWN_HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$")


class RagStoreError(RuntimeError):
    """The local knowledge store could not complete an operation."""


class KnowledgeRagStore:
    """Local SQLite document/chunk store with optional embedding and rerank."""

    def __init__(
        self,
        path: str | Path,
        provider: OpenAICompatibleProvider,
        role_ids: Iterable[str],
    ):
        raw_path = str(path)
        self.path = raw_path if raw_path == ":memory:" else str(Path(path).resolve())
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.provider = provider
        self.role_ids = tuple(dict.fromkeys(str(item) for item in role_ids))
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(
            self.path, timeout=5.0, check_same_thread=False
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
                raise RagStoreError(f"RAG backup integrity check failed: {result}")
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
        CREATE TABLE IF NOT EXISTS rag_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rag_documents (
            document_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT '*',
            source_uri TEXT NOT NULL DEFAULT '',
            metadata_json TEXT NOT NULL DEFAULT '{}',
            content TEXT NOT NULL DEFAULT '',
            content_hash TEXT NOT NULL,
            character_count INTEGER NOT NULL,
            chunk_count INTEGER NOT NULL,
            embedding_state TEXT NOT NULL DEFAULT 'none',
            embedding_error TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_rag_documents_updated
            ON rag_documents(updated_at DESC);
        CREATE TABLE IF NOT EXISTS rag_chunks (
            chunk_id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES rag_documents(document_id)
                ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            section_path TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL,
            embedding_json TEXT,
            created_at INTEGER NOT NULL,
            UNIQUE(document_id, ordinal)
        );
        CREATE INDEX IF NOT EXISTS idx_rag_chunks_document
            ON rag_chunks(document_id, ordinal);
        """
        with self._lock, self._connection:
            self._connection.executescript(schema)
            columns = {
                str(row["name"])
                for row in self._connection.execute(
                    "PRAGMA table_info(rag_documents)"
                ).fetchall()
            }
            if "content" not in columns:
                self._connection.execute(
                    "ALTER TABLE rag_documents ADD COLUMN content TEXT NOT NULL DEFAULT ''"
                )
                legacy_documents = self._connection.execute(
                    "SELECT document_id FROM rag_documents ORDER BY created_at, document_id"
                ).fetchall()
                for document in legacy_documents:
                    chunks = self._connection.execute(
                        """
                        SELECT content FROM rag_chunks
                        WHERE document_id = ? ORDER BY ordinal
                        """,
                        (document["document_id"],),
                    ).fetchall()
                    reconstructed = self._merge_legacy_chunks(
                        [str(chunk["content"]) for chunk in chunks]
                    )
                    self._connection.execute(
                        """
                        UPDATE rag_documents
                        SET content = ?, content_hash = ?, character_count = ?
                        WHERE document_id = ?
                        """,
                        (
                            reconstructed,
                            hashlib.sha256(reconstructed.encode("utf-8")).hexdigest(),
                            len(reconstructed),
                            document["document_id"],
                        ),
                    )
            chunk_columns = {
                str(row["name"])
                for row in self._connection.execute(
                    "PRAGMA table_info(rag_chunks)"
                ).fetchall()
            }
            if "section_path" not in chunk_columns:
                self._connection.execute(
                    "ALTER TABLE rag_chunks ADD COLUMN section_path TEXT NOT NULL DEFAULT ''"
                )
            self._connection.execute(
                "INSERT OR REPLACE INTO rag_meta(key, value) VALUES('schema_version', '2')"
            )

    async def put_document(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RagStoreError("document must be a JSON object")
        title = self._clean_text(raw.get("title", ""), 200)
        text = str(raw.get("text", "")).replace("\x00", " ").strip()
        if not title:
            raise RagStoreError("document title is required")
        if not text or len(text) > 1_000_000:
            raise RagStoreError("document text must contain 1-1000000 characters")
        requested_document_id = str(raw.get("document_id", "")).strip()
        if requested_document_id and not DOCUMENT_ID_PATTERN.fullmatch(requested_document_id):
            raise RagStoreError("document_id is invalid")
        scope = str(raw.get("scope", "*")).strip() or "*"
        if scope != "*" and scope not in self.role_ids:
            raise RagStoreError("document scope must be * or a known role_id")
        source_uri = self._clean_text(raw.get("source_uri", ""), 2_048)
        metadata = raw.get("metadata", {})
        if not isinstance(metadata, dict):
            raise RagStoreError("document metadata must be a JSON object")
        metadata_json = json.dumps(metadata, ensure_ascii=False, separators=(",", ":"))
        if len(metadata_json) > 16_000:
            raise RagStoreError("document metadata is too large")

        content_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        document_id = requested_document_id
        if not document_id:
            with self._lock:
                existing = None
                if source_uri:
                    existing = self._connection.execute(
                        """
                        SELECT document_id FROM rag_documents
                        WHERE source_uri = ? AND scope = ?
                        ORDER BY updated_at DESC LIMIT 1
                        """,
                        (source_uri, scope),
                    ).fetchone()
                if existing is None:
                    existing = self._connection.execute(
                        """
                        SELECT document_id FROM rag_documents
                        WHERE content_hash = ? AND scope = ?
                        ORDER BY updated_at DESC LIMIT 1
                        """,
                        (content_hash, scope),
                    ).fetchone()
            document_id = (
                str(existing["document_id"])
                if existing is not None
                else f"doc-{uuid.uuid4().hex}"
            )

        settings = self.provider.settings.rag_config()
        chunks = self._chunk_text(
            text,
            int(settings["chunk_size"]),
            int(settings["chunk_overlap"]),
        )
        chunk_contents = [str(chunk["content"]) for chunk in chunks]
        embeddings: list[list[float]] = []
        embedding_state = "disabled"
        embedding_error = ""
        embedding_profile = self.provider.settings.profile_snapshot("embedding")
        if bool(settings["use_embeddings"]) and embedding_profile.enabled:
            try:
                for start in range(0, len(chunks), 32):
                    embeddings.extend(
                        await self.provider.embed(chunk_contents[start : start + 32])
                    )
                embedding_state = "ready"
            except ProviderError as exc:
                embeddings = []
                embedding_state = "error"
                embedding_error = str(exc)[:500]

        now = int(time.time())
        with self._lock, self._connection:
            existing = self._connection.execute(
                "SELECT created_at FROM rag_documents WHERE document_id = ?",
                (document_id,),
            ).fetchone()
            created_at = int(existing["created_at"]) if existing else now
            self._connection.execute(
                """
                INSERT INTO rag_documents(
                    document_id, title, scope, source_uri, metadata_json, content,
                    content_hash, character_count, chunk_count, embedding_state,
                    embedding_error, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id) DO UPDATE SET
                    title=excluded.title,
                    scope=excluded.scope,
                    source_uri=excluded.source_uri,
                    metadata_json=excluded.metadata_json,
                    content=excluded.content,
                    content_hash=excluded.content_hash,
                    character_count=excluded.character_count,
                    chunk_count=excluded.chunk_count,
                    embedding_state=excluded.embedding_state,
                    embedding_error=excluded.embedding_error,
                    updated_at=excluded.updated_at
                """,
                (
                    document_id,
                    title,
                    scope,
                    source_uri,
                    metadata_json,
                    text,
                    content_hash,
                    len(text),
                    len(chunks),
                    embedding_state,
                    embedding_error,
                    created_at,
                    now,
                ),
            )
            self._connection.execute(
                "DELETE FROM rag_chunks WHERE document_id = ?", (document_id,)
            )
            self._connection.executemany(
                """
                INSERT INTO rag_chunks(
                    chunk_id, document_id, ordinal, section_path, content,
                    embedding_json, created_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        f"{document_id}:{index}",
                        document_id,
                        index,
                        str(chunk.get("section_path", "")),
                        str(chunk["content"]),
                        (
                            json.dumps(embeddings[index], separators=(",", ":"))
                            if index < len(embeddings)
                            else None
                        ),
                        now,
                    )
                    for index, chunk in enumerate(chunks)
                ],
            )
        return self.get_document(document_id, include_content=False)

    def get_document(
        self, document_id: str, *, include_content: bool = True
    ) -> dict[str, Any]:
        normalized = self._document_id(document_id)
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM rag_documents WHERE document_id = ?", (normalized,)
            ).fetchone()
        if row is None:
            raise RagStoreError("document not found")
        return self._document_row(row, include_content=include_content)

    def list_documents(self, limit: int = 100) -> list[dict[str, Any]]:
        bounded = max(1, min(500, int(limit)))
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM rag_documents ORDER BY updated_at DESC LIMIT ?",
                (bounded,),
            ).fetchall()
        return [self._document_row(row, include_content=False) for row in rows]

    def delete_document(self, document_id: str) -> bool:
        normalized = self._document_id(document_id)
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "DELETE FROM rag_documents WHERE document_id = ?", (normalized,)
            )
        return cursor.rowcount > 0

    async def batch_documents(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RagStoreError("batch request must be a JSON object")
        action = str(raw.get("action", "")).strip().lower()
        raw_ids = raw.get("document_ids", [])
        if not isinstance(raw_ids, list):
            raise RagStoreError("document_ids must be an array")
        document_ids = list(
            dict.fromkeys(self._document_id(item) for item in raw_ids)
        )
        if not 1 <= len(document_ids) <= 500:
            raise RagStoreError("batch request must contain 1-500 document_ids")

        placeholders = ",".join("?" for _item in document_ids)
        with self._lock:
            rows = self._connection.execute(
                f"SELECT * FROM rag_documents WHERE document_id IN ({placeholders})",
                document_ids,
            ).fetchall()
        if len(rows) != len(document_ids):
            found = {str(row["document_id"]) for row in rows}
            missing = next(item for item in document_ids if item not in found)
            raise RagStoreError(f"document not found: {missing}")

        if action == "delete":
            with self._lock, self._connection:
                cursor = self._connection.execute(
                    f"DELETE FROM rag_documents WHERE document_id IN ({placeholders})",
                    document_ids,
                )
            return {"action": action, "affected_documents": cursor.rowcount}

        scope_value = raw.get("scope")
        scope = None if scope_value is None else str(scope_value).strip()
        if scope is not None and scope != "*" and scope not in self.role_ids:
            raise RagStoreError("document scope must be * or a known role_id")
        if action == "update_scope":
            if scope is None:
                raise RagStoreError("scope is required for update_scope")
            with self._lock, self._connection:
                cursor = self._connection.execute(
                    f"""
                    UPDATE rag_documents SET scope = ?, updated_at = ?
                    WHERE document_id IN ({placeholders})
                    """,
                    [scope, int(time.time()), *document_ids],
                )
            return {
                "action": action,
                "affected_documents": cursor.rowcount,
                "scope": scope,
            }

        if action != "rechunk":
            raise RagStoreError("batch action must be update_scope, rechunk or delete")
        by_id = {str(row["document_id"]): row for row in rows}
        updated = 0
        for document_id in document_ids:
            row = by_id[document_id]
            await self.put_document(
                {
                    "document_id": document_id,
                    "title": str(row["title"]),
                    "text": str(row["content"]),
                    "scope": scope if scope is not None else str(row["scope"]),
                    "source_uri": str(row["source_uri"]),
                    "metadata": json.loads(str(row["metadata_json"])),
                }
            )
            updated += 1
        return {"action": action, "affected_documents": updated, "scope": scope}

    async def search(
        self,
        query: str,
        *,
        role_id: str = "",
        limit: int | None = None,
    ) -> list[dict[str, Any]]:
        normalized_query = str(query).replace("\x00", " ").strip()
        if not normalized_query or len(normalized_query) > 8_000:
            raise RagStoreError("RAG query must contain 1-8000 characters")
        if role_id and role_id not in self.role_ids:
            raise RagStoreError("unknown RAG role_id")
        settings = self.provider.settings.rag_config()
        if not bool(settings["enabled"]):
            return []
        top_k = max(1, min(20, int(limit or settings["top_k"])))
        candidate_limit = max(top_k, int(settings["candidate_limit"]))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT c.chunk_id, c.document_id, c.ordinal, c.section_path, c.content,
                       c.embedding_json, d.title, d.scope, d.source_uri,
                       d.metadata_json, d.updated_at
                FROM rag_chunks c
                JOIN rag_documents d ON d.document_id = c.document_id
                WHERE d.scope = '*' OR d.scope = ?
                ORDER BY d.updated_at DESC, c.ordinal ASC
                LIMIT 5000
                """,
                (role_id,),
            ).fetchall()
        if not rows:
            return []

        query_terms = self._terms(normalized_query)
        scored: dict[int, dict[str, Any]] = {}
        for index, row in enumerate(rows):
            lexical = self._lexical_score(normalized_query, query_terms, row["content"])
            if lexical > 0:
                scored[index] = {"lexical": lexical, "vector": None}

        embedding_profile = self.provider.settings.profile_snapshot("embedding")
        if bool(settings["use_embeddings"]) and embedding_profile.enabled:
            try:
                query_vector = (await self.provider.embed([normalized_query]))[0]
                for index, row in enumerate(rows):
                    if not row["embedding_json"]:
                        continue
                    try:
                        vector = [float(item) for item in json.loads(row["embedding_json"])]
                    except (TypeError, ValueError, json.JSONDecodeError):
                        continue
                    cosine = self._cosine(query_vector, vector)
                    if cosine is None:
                        continue
                    item = scored.setdefault(index, {"lexical": 0.0, "vector": None})
                    item["vector"] = (cosine + 1.0) / 2.0
            except ProviderError:
                pass

        candidates: list[tuple[float, int]] = []
        for index, components in scored.items():
            lexical = min(1.0, float(components["lexical"]))
            vector = components["vector"]
            combined = lexical if vector is None else lexical * 0.35 + float(vector) * 0.65
            candidates.append((combined, index))
        candidates.sort(reverse=True)
        candidates = candidates[:candidate_limit]
        if not candidates:
            return []

        rerank_profile = self.provider.settings.profile_snapshot("rerank")
        reranked = False
        if bool(settings["use_rerank"]) and rerank_profile.enabled:
            try:
                ranking = await self.provider.rerank(
                    normalized_query,
                    [str(rows[index]["content"]) for _score, index in candidates],
                    top_k,
                )
                candidates = [
                    (float(item["score"]), candidates[int(item["index"])][1])
                    for item in ranking
                    if 0 <= int(item["index"]) < len(candidates)
                ]
                reranked = True
            except ProviderError:
                pass

        results: list[dict[str, Any]] = []
        for score, index in candidates[:top_k]:
            row = rows[index]
            results.append(
                {
                    "chunk_id": str(row["chunk_id"]),
                    "document_id": str(row["document_id"]),
                    "title": str(row["title"]),
                    "section_path": str(row["section_path"]),
                    "content": str(row["content"]),
                    "source_uri": str(row["source_uri"]),
                    "scope": str(row["scope"]),
                    "score": round(float(score), 6),
                    "reranked": reranked,
                    "updated_at": int(row["updated_at"]),
                }
            )
        return results

    async def reindex_embeddings(self) -> dict[str, Any]:
        profile = self.provider.settings.profile_snapshot("embedding")
        if not profile.enabled:
            raise RagStoreError("embedding provider is disabled")
        with self._lock:
            rows = self._connection.execute(
                "SELECT chunk_id, document_id, content FROM rag_chunks ORDER BY document_id, ordinal"
            ).fetchall()
        updated = 0
        affected_documents: set[str] = set()
        for start in range(0, len(rows), 32):
            batch = rows[start : start + 32]
            try:
                vectors = await self.provider.embed([str(row["content"]) for row in batch])
            except ProviderError as exc:
                raise RagStoreError(str(exc)) from exc
            with self._lock, self._connection:
                for row, vector in zip(batch, vectors, strict=True):
                    self._connection.execute(
                        "UPDATE rag_chunks SET embedding_json = ? WHERE chunk_id = ?",
                        (json.dumps(vector, separators=(",", ":")), row["chunk_id"]),
                    )
                    affected_documents.add(str(row["document_id"]))
                    updated += 1
        with self._lock, self._connection:
            for document_id in affected_documents:
                self._connection.execute(
                    """
                    UPDATE rag_documents
                    SET embedding_state = 'ready', embedding_error = '', updated_at = ?
                    WHERE document_id = ?
                    """,
                    (int(time.time()), document_id),
                )
        return {"updated_chunks": updated, "documents": len(affected_documents)}

    def status(self) -> dict[str, Any]:
        with self._lock:
            document_count = int(
                self._connection.execute("SELECT COUNT(*) FROM rag_documents").fetchone()[0]
            )
            chunk_count = int(
                self._connection.execute("SELECT COUNT(*) FROM rag_chunks").fetchone()[0]
            )
            embedded_count = int(
                self._connection.execute(
                    "SELECT COUNT(*) FROM rag_chunks WHERE embedding_json IS NOT NULL"
                ).fetchone()[0]
            )
        return {
            "backend": "spring_haven_rag",
            "database": "sqlite",
            "document_count": document_count,
            "chunk_count": chunk_count,
            "embedded_chunk_count": embedded_count,
            "settings": self.provider.settings.rag_config(),
            "chunking_strategy": "markdown_sections_v2",
        }

    @classmethod
    def _chunk_text(cls, text: str, size: int, overlap: int) -> list[dict[str, str]]:
        normalized = text.replace("\r\n", "\n").replace("\r", "\n").strip()
        if not normalized:
            return []
        overlap = min(max(0, overlap), max(0, size // 2))
        sections: list[tuple[str, list[str]]] = []
        heading_path: list[str] = []
        current_lines: list[str] = []
        current_path = ""
        for line in normalized.split("\n"):
            match = MARKDOWN_HEADING.match(line)
            if match:
                if current_lines:
                    sections.append((current_path, current_lines))
                level = len(match.group(1))
                title = match.group(2).strip()
                heading_path = heading_path[: level - 1]
                heading_path.append(title)
                current_path = " > ".join(heading_path)
                current_lines = [line]
            else:
                current_lines.append(line)
        if current_lines:
            sections.append((current_path, current_lines))

        chunks: list[dict[str, str]] = []
        for section_path, lines in sections:
            section_text = "\n".join(lines).strip()
            if not section_text:
                continue
            if section_path and len(lines) == 1 and MARKDOWN_HEADING.match(lines[0]):
                continue
            prefix = f"[章节: {section_path}]" if section_path else ""
            budget = max(80, size - len(prefix) - (1 if prefix else 0))
            pieces = cls._plain_chunks(section_text, budget, overlap)
            for piece in pieces:
                content = f"{prefix}\n{piece}" if prefix else piece
                chunks.append({"section_path": section_path, "content": content})
        return chunks

    @staticmethod
    def _plain_chunks(text: str, size: int, overlap: int) -> list[str]:
        chunks: list[str] = []
        start = 0
        while start < len(text):
            hard_end = min(len(text), start + size)
            end = hard_end
            if hard_end < len(text):
                search_from = start + int(size * 0.6)
                boundaries = [
                    text.rfind(marker, search_from, hard_end)
                    for marker in ("\n\n", "\n", "。", "！", "？", ". ")
                ]
                best = max(boundaries)
                if best > start:
                    end = best + 1
            chunk = text[start:end].strip()
            if chunk:
                chunks.append(chunk)
            if end >= len(text):
                break
            start = max(start + 1, end - overlap)
        return chunks

    @staticmethod
    def _merge_legacy_chunks(chunks: list[str]) -> str:
        """Best-effort source reconstruction for pre-source-storage databases."""
        if not chunks:
            return ""
        merged = chunks[0].strip()
        for raw_chunk in chunks[1:]:
            chunk = raw_chunk.strip()
            if not chunk:
                continue
            overlap_limit = min(len(merged), len(chunk), 4_000)
            overlap = 0
            for width in range(overlap_limit, 0, -1):
                if merged.endswith(chunk[:width]):
                    overlap = width
                    break
            if overlap:
                merged += chunk[overlap:]
            else:
                merged += "\n\n" + chunk
        return merged.strip()

    @staticmethod
    def _terms(text: str) -> set[str]:
        normalized = text.lower()
        terms = set(ASCII_TERM.findall(normalized))
        for sequence in HAN_SEQUENCE.findall(normalized):
            terms.add(sequence)
            terms.update(sequence[index : index + 2] for index in range(len(sequence) - 1))
        return {term for term in terms if len(term) >= 2}

    @classmethod
    def _lexical_score(cls, query: str, query_terms: set[str], content: str) -> float:
        normalized_content = content.lower()
        if query.lower() in normalized_content:
            return 1.0
        if not query_terms:
            return 0.0
        matched = sum(1 for term in query_terms if term in normalized_content)
        return matched / len(query_terms)

    @staticmethod
    def _cosine(first: list[float], second: list[float]) -> float | None:
        if not first or len(first) != len(second):
            return None
        dot = sum(a * b for a, b in zip(first, second, strict=True))
        first_norm = math.sqrt(sum(value * value for value in first))
        second_norm = math.sqrt(sum(value * value for value in second))
        if first_norm <= 0.0 or second_norm <= 0.0:
            return None
        return max(-1.0, min(1.0, dot / (first_norm * second_norm)))

    @staticmethod
    def _clean_text(value: Any, limit: int) -> str:
        return str(value).replace("\x00", " ").strip()[:limit]

    @staticmethod
    def _document_id(value: Any) -> str:
        normalized = str(value).strip()
        if not DOCUMENT_ID_PATTERN.fullmatch(normalized):
            raise RagStoreError("document_id is invalid")
        return normalized

    @staticmethod
    def _document_row(
        row: sqlite3.Row, *, include_content: bool = False
    ) -> dict[str, Any]:
        try:
            metadata = json.loads(row["metadata_json"])
        except (TypeError, ValueError):
            metadata = {}
        result = {
            "document_id": str(row["document_id"]),
            "title": str(row["title"]),
            "scope": str(row["scope"]),
            "source_uri": str(row["source_uri"]),
            "metadata": metadata if isinstance(metadata, dict) else {},
            "content_hash": str(row["content_hash"]),
            "character_count": int(row["character_count"]),
            "chunk_count": int(row["chunk_count"]),
            "embedding_state": str(row["embedding_state"]),
            "embedding_error": str(row["embedding_error"]),
            "created_at": int(row["created_at"]),
            "updated_at": int(row["updated_at"]),
        }
        if include_content:
            result["text"] = str(row["content"])
        return result
