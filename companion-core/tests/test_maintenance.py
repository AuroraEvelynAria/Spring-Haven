from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from spring_haven_core.maintenance import StorageMaintenance
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.rag import KnowledgeRagStore


class _Settings:
    def rag_config(self):
        return {
            "enabled": True,
            "use_embeddings": False,
            "use_rerank": False,
            "top_k": 4,
            "candidate_limit": 12,
            "chunk_size": 240,
            "chunk_overlap": 30,
        }

    def profile_snapshot(self, capability):
        return SimpleNamespace(enabled=False, capability=capability)


class _Provider:
    def __init__(self):
        self.settings = _Settings()


class StorageMaintenanceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.memory = HeartloomStore(self.root / "heartloom.sqlite3", ["ling", "nai"])
        self.rag = KnowledgeRagStore(
            self.root / "knowledge.sqlite3", _Provider(), ["ling", "nai"]
        )
        await self.rag.put_document(
            {"title": "备份测试", "text": "# 日常\n窗边的花今天浇过水。", "scope": "ling"}
        )

    async def asyncTearDown(self):
        self.memory.close()
        self.rag.close()
        self.temp.cleanup()

    async def test_online_backup_is_consistent_throttled_and_rotated(self):
        maintenance = StorageMaintenance(
            self.memory,
            self.rag,
            backup_interval_seconds=3_600,
            retention_count=2,
        )
        first = maintenance.run(force_backup=True)
        self.assertEqual(first["state"], "ready")
        self.assertEqual(first["integrity"], {"heartloom": "ok", "knowledge": "ok"})
        first_name = first["last_backup_name"]
        backup = self.root / "backups" / first_name
        self.assertTrue((backup / "heartloom.sqlite3").is_file())
        self.assertTrue((backup / "knowledge.sqlite3").is_file())
        manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], "spring_haven.storage_backup.v1")
        self.assertEqual(set(manifest["sha256"]), {"heartloom.sqlite3", "knowledge.sqlite3"})
        for filename in ["heartloom.sqlite3", "knowledge.sqlite3"]:
            connection = sqlite3.connect(backup / filename)
            try:
                self.assertEqual(connection.execute("PRAGMA quick_check").fetchone()[0], "ok")
            finally:
                connection.close()

        listed = maintenance.list_backups()
        self.assertEqual(listed[0]["name"], first_name)
        self.assertTrue(listed[0]["manifest_valid"])
        verification = maintenance.verify_backup(first_name)
        self.assertTrue(verification["ok"])
        self.assertTrue(verification["files"]["heartloom.sqlite3"]["sha256_matches"])
        self.assertEqual(verification["files"]["knowledge.sqlite3"]["quick_check"], "ok")
        with self.assertRaises(ValueError):
            maintenance.verify_backup("../outside")

        throttled = maintenance.run(force_backup=False)
        self.assertEqual(throttled["last_backup_name"], first_name)
        maintenance.run(force_backup=True)
        maintenance.run(force_backup=True)
        backup_directories = [
            path for path in (self.root / "backups").iterdir() if path.is_dir()
        ]
        self.assertEqual(len(backup_directories), 2)


if __name__ == "__main__":
    unittest.main()
