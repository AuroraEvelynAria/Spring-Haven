from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from .memory import HeartloomStore
from .rag import KnowledgeRagStore


class StorageMaintenance:
    """Online SQLite checks and atomic, bounded local backups."""

    def __init__(
        self,
        memory: HeartloomStore,
        rag: KnowledgeRagStore | None,
        *,
        backup_interval_seconds: int = 86_400,
        retention_count: int = 14,
    ):
        self.memory = memory
        self.rag = rag
        self.backup_interval_seconds = max(3_600, int(backup_interval_seconds))
        self.retention_count = max(2, int(retention_count))
        self._lock = threading.Lock()
        self._status: dict[str, Any] = {
            "state": "idle",
            "last_run_at": 0,
            "last_success_at": 0,
            "last_backup_at": 0,
            "last_backup_name": "",
            "integrity": {},
            "checkpoints": {},
            "error": "",
        }

    def status(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._status)

    def run(self, *, force_backup: bool = False) -> dict[str, Any]:
        if not self._lock.acquire(blocking=False):
            return {**self.status(), "state": "busy"}
        try:
            now = int(time.time())
            self._status = {**self._status, "state": "running", "last_run_at": now, "error": ""}
            integrity = {"heartloom": self.memory.integrity_check()}
            checkpoints = {"heartloom": self.memory.checkpoint()}
            if self.rag is not None:
                integrity["knowledge"] = self.rag.integrity_check()
                checkpoints["knowledge"] = self.rag.checkpoint()
            if any(result != "ok" for result in integrity.values()):
                raise RuntimeError("SQLite integrity check failed")

            backup_name = str(self._status.get("last_backup_name", ""))
            last_backup_at = self._latest_backup_timestamp()
            should_backup = (
                force_backup
                or last_backup_at <= 0
                or now - last_backup_at >= self.backup_interval_seconds
            )
            if should_backup and self.memory.path != ":memory:":
                backup_name = self._create_backup(now, integrity)
                last_backup_at = now
                self._rotate_backups()
            self._status = {
                "state": "ready",
                "last_run_at": now,
                "last_success_at": now,
                "last_backup_at": last_backup_at,
                "last_backup_name": backup_name,
                "integrity": integrity,
                "checkpoints": checkpoints,
                "error": "",
            }
        except Exception as exc:
            self._status = {
                **self._status,
                "state": "error",
                "error": f"{type(exc).__name__}: {str(exc)[:500]}",
            }
        finally:
            self._lock.release()
        return self.status()

    @property
    def backup_root(self) -> Path | None:
        if self.memory.path == ":memory:":
            return None
        return Path(self.memory.path).resolve().parent / "backups"

    def list_backups(self) -> list[dict[str, Any]]:
        root = self.backup_root
        if root is None or not root.is_dir():
            return []
        backups: list[dict[str, Any]] = []
        for path in sorted(
            (item for item in root.iterdir() if item.is_dir() and not item.name.startswith(".")),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        ):
            manifest_path = path / "manifest.json"
            manifest: dict[str, Any] = {}
            manifest_error = ""
            try:
                parsed = json.loads(manifest_path.read_text(encoding="utf-8"))
                if not isinstance(parsed, dict):
                    raise ValueError("manifest is not an object")
                manifest = parsed
            except Exception as exc:
                manifest_error = f"{type(exc).__name__}: {str(exc)[:200]}"
            files = manifest.get("sha256", {}) if isinstance(manifest, dict) else {}
            total_bytes = sum(
                (path / str(filename)).stat().st_size
                for filename in files
                if isinstance(filename, str) and (path / filename).is_file()
            ) if isinstance(files, dict) else 0
            backups.append(
                {
                    "name": path.name,
                    "created_at": int(manifest.get("created_at", path.stat().st_mtime)),
                    "schema": str(manifest.get("schema", "")),
                    "file_count": len(files) if isinstance(files, dict) else 0,
                    "total_bytes": total_bytes,
                    "manifest_valid": (
                        not manifest_error
                        and manifest.get("schema") == "spring_haven.storage_backup.v1"
                        and isinstance(files, dict)
                        and bool(files)
                    ),
                    "manifest_error": manifest_error,
                }
            )
        return backups

    def verify_backup(self, name: str) -> dict[str, Any]:
        root = self.backup_root
        normalized = str(name).strip()
        if root is None or not re.fullmatch(r"[0-9]{8}-[0-9]{6}(?:-[a-f0-9]{8})?", normalized):
            raise ValueError("backup name is invalid")
        root = root.resolve()
        backup = (root / normalized).resolve()
        if backup.parent != root or not backup.is_dir():
            raise ValueError("backup does not exist")
        manifest_path = backup / "manifest.json"
        parsed = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(parsed, dict) or parsed.get("schema") != "spring_haven.storage_backup.v1":
            raise ValueError("backup manifest is invalid")
        expected = parsed.get("sha256", {})
        if not isinstance(expected, dict) or not expected:
            raise ValueError("backup manifest has no file hashes")
        files: dict[str, Any] = {}
        all_valid = True
        allowed_files = {"heartloom.sqlite3", "knowledge.sqlite3"}
        for filename, expected_hash in expected.items():
            safe_name = str(filename)
            if safe_name not in allowed_files:
                files[safe_name] = {"ok": False, "error": "unexpected backup file"}
                all_valid = False
                continue
            source = (backup / safe_name).resolve()
            if source.parent != backup or not source.is_file():
                files[safe_name] = {"ok": False, "error": "file is missing"}
                all_valid = False
                continue
            actual_hash = self._sha256(source)
            quick_check = ""
            try:
                connection = sqlite3.connect(f"file:{source.as_posix()}?mode=ro", uri=True)
                try:
                    quick_check = str(connection.execute("PRAGMA quick_check").fetchone()[0])
                finally:
                    connection.close()
            except sqlite3.Error as exc:
                quick_check = f"sqlite error: {str(exc)[:200]}"
            valid = actual_hash == str(expected_hash) and quick_check == "ok"
            files[safe_name] = {
                "ok": valid,
                "bytes": source.stat().st_size,
                "sha256_matches": actual_hash == str(expected_hash),
                "quick_check": quick_check,
            }
            all_valid = all_valid and valid
        return {
            "name": normalized,
            "ok": all_valid,
            "created_at": int(parsed.get("created_at", 0)),
            "files": files,
        }

    def _latest_backup_timestamp(self) -> int:
        root = self.backup_root
        if root is None or not root.is_dir():
            return 0
        timestamps = [
            int(path.stat().st_mtime)
            for path in root.iterdir()
            if path.is_dir() and not path.name.startswith(".")
        ]
        return max(timestamps, default=0)

    def _create_backup(self, now: int, integrity: dict[str, str]) -> str:
        root = self.backup_root
        if root is None:
            return ""
        root.mkdir(parents=True, exist_ok=True)
        name = time.strftime("%Y%m%d-%H%M%S", time.localtime(now))
        final = root / name
        if final.exists():
            name += f"-{uuid.uuid4().hex[:8]}"
            final = root / name
        pending = root / f".{name}.pending-{uuid.uuid4().hex[:8]}"
        pending.mkdir(parents=False, exist_ok=False)
        try:
            memory_file = pending / "heartloom.sqlite3"
            self.memory.backup_to(memory_file)
            files = {"heartloom.sqlite3": self._sha256(memory_file)}
            if self.rag is not None and self.rag.path != ":memory:":
                knowledge_file = pending / "knowledge.sqlite3"
                self.rag.backup_to(knowledge_file)
                files["knowledge.sqlite3"] = self._sha256(knowledge_file)
            manifest = {
                "schema": "spring_haven.storage_backup.v1",
                "created_at": now,
                "integrity": integrity,
                "sha256": files,
            }
            (pending / "manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            os.replace(pending, final)
        except Exception:
            if pending.exists() and pending.parent == root:
                shutil.rmtree(pending)
            raise
        return name

    def _rotate_backups(self) -> None:
        root = self.backup_root
        if root is None or not root.is_dir():
            return
        backups = sorted(
            (path for path in root.iterdir() if path.is_dir() and not path.name.startswith(".")),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        for path in backups[self.retention_count :]:
            if path.parent == root:
                shutil.rmtree(path)

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()
