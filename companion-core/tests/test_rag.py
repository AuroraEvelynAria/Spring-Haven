from __future__ import annotations

import base64
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from aiohttp.test_utils import TestClient, TestServer

from spring_haven_core.app import build_app
from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.provider import OpenAICompatibleProvider, ProviderReply
from spring_haven_core.provider_settings import ProviderSettingsStore
from spring_haven_core.rag import KnowledgeRagStore
from spring_haven_core.service import CompanionService

from test_contract import make_registry, valid_payload


class FakeRagSettings:
    def __init__(self, *, embeddings: bool = False, rerank: bool = False):
        self.embeddings = embeddings
        self.rerank_enabled = rerank

    def rag_config(self):
        return {
            "enabled": True,
            "use_embeddings": self.embeddings,
            "use_rerank": self.rerank_enabled,
            "top_k": 4,
            "candidate_limit": 12,
            "chunk_size": 240,
            "chunk_overlap": 30,
        }

    def profile_snapshot(self, capability):
        return SimpleNamespace(
            enabled=(self.embeddings if capability == "embedding" else self.rerank_enabled),
            capability=capability,
        )


class FakeRagProvider:
    def __init__(self, *, embeddings: bool = False, rerank: bool = False):
        self.settings = FakeRagSettings(embeddings=embeddings, rerank=rerank)
        self.calls = []
        self.embed_calls = 0
        self.rerank_calls = 0

    async def complete(self, system_prompt, messages):
        self.calls.append((system_prompt, messages))
        return ProviderReply(text="我记得资料里提到了窗边的薄荷。")

    async def embed(self, texts):
        self.embed_calls += 1
        return [
            [1.0, 0.0] if "薄荷" in text or "花" in text else [0.0, 1.0]
            for text in texts
        ]

    async def rerank(self, query, documents, top_n):
        self.rerank_calls += 1
        ranked = sorted(
            range(len(documents)),
            key=lambda index: ("薄荷" in documents[index], -index),
            reverse=True,
        )
        return [
            {"index": index, "score": 1.0 - order * 0.05}
            for order, index in enumerate(ranked[:top_n])
        ]


class RagStoreTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    async def asyncTearDown(self):
        self.temp.cleanup()

    async def test_local_lexical_rag_is_scoped_by_role(self):
        provider = FakeRagProvider()
        store = KnowledgeRagStore(self.root / "rag.sqlite3", provider, ["ling", "nai"])
        try:
            shared = await store.put_document(
                {
                    "title": "植物照料",
                    "text": "窗边的薄荷需要保持土壤湿润，但不要让花盆积水。",
                    "scope": "*",
                }
            )
            await store.put_document(
                {
                    "title": "小玲私有笔记",
                    "text": "小玲把蓝色钥匙放在自己的抽屉里。",
                    "scope": "ling",
                }
            )
            results = await store.search("薄荷怎么照料", role_id="nai")
            private_results = await store.search("蓝色钥匙", role_id="nai")
            self.assertEqual(results[0]["document_id"], shared["document_id"])
            self.assertEqual(private_results, [])
            self.assertEqual(store.status()["document_count"], 2)
        finally:
            store.close()

    async def test_existing_database_is_migrated_to_store_editable_source(self):
        # Version 1 databases created before source editing did not have `content`.
        path = self.root / "legacy-rag.sqlite3"
        connection = sqlite3.connect(path)
        connection.executescript(
            """
            CREATE TABLE rag_documents (
                document_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                scope TEXT NOT NULL DEFAULT '*',
                source_uri TEXT NOT NULL DEFAULT '',
                metadata_json TEXT NOT NULL DEFAULT '{}',
                content_hash TEXT NOT NULL,
                character_count INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL,
                embedding_state TEXT NOT NULL DEFAULT 'none',
                embedding_error TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE rag_chunks (
                chunk_id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL REFERENCES rag_documents(document_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                content TEXT NOT NULL,
                embedding_json TEXT,
                created_at INTEGER NOT NULL,
                UNIQUE(document_id, ordinal)
            );
            """
        )
        connection.execute(
            """
            INSERT INTO rag_documents(
                document_id, title, content_hash, character_count, chunk_count,
                created_at, updated_at
            ) VALUES('legacy', '旧文档', 'old-hash', 12, 2, 1, 1)
            """
        )
        connection.executemany(
            """
            INSERT INTO rag_chunks(
                chunk_id, document_id, ordinal, content, created_at
            ) VALUES(?, 'legacy', ?, ?, 1)
            """,
            [
                ("legacy:0", 0, "窗边的薄荷需要散射光。每天观察土壤。"),
                ("legacy:1", 1, "每天观察土壤。干燥时再少量浇水。"),
            ],
        )
        connection.commit()
        connection.close()
        provider = FakeRagProvider()
        store = KnowledgeRagStore(path, provider, ["ling", "nai"])
        try:
            migrated = store.get_document("legacy")
            self.assertEqual(
                migrated["text"],
                "窗边的薄荷需要散射光。每天观察土壤。干燥时再少量浇水。",
            )
            self.assertEqual(migrated["character_count"], len(migrated["text"]))
            created = await store.put_document(
                {"title": "迁移后文档", "text": "原文现在可以重新编辑。"}
            )
            fetched = store.get_document(created["document_id"])
            self.assertEqual(fetched["text"], "原文现在可以重新编辑。")
        finally:
            store.close()

    async def test_embedding_and_rerank_pipeline_is_optional(self):
        provider = FakeRagProvider(embeddings=True, rerank=True)
        store = KnowledgeRagStore(self.root / "rag.sqlite3", provider, ["ling", "nai"])
        try:
            await store.put_document(
                {
                    "title": "植物",
                    "text": "薄荷喜欢明亮散射光。\n\n餐桌需要每天擦拭。",
                }
            )
            results = await store.search("薄荷", role_id="ling")
            self.assertTrue(results)
            self.assertTrue(results[0]["reranked"])
            self.assertGreaterEqual(provider.embed_calls, 2)
            self.assertEqual(provider.rerank_calls, 1)
            self.assertGreater(store.status()["embedded_chunk_count"], 0)
        finally:
            store.close()

    async def test_chat_injects_rag_as_dynamic_read_only_context(self):
        roles = make_registry(self.root)
        provider = FakeRagProvider()
        rag = KnowledgeRagStore(self.root / "rag.sqlite3", provider, roles.ids())
        memory = HeartloomStore(self.root / "heartloom.sqlite3", roles.ids())
        service = CompanionService(roles, provider, memory, rag)
        try:
            await rag.put_document(
                {"title": "植物照料", "text": "窗边的薄荷需要保持土壤微湿。"}
            )
            payload = valid_payload()
            payload["text"] = "窗边的薄荷怎么照顾？"
            result = await service.chat(payload)
            system_prompt, messages = provider.calls[0]
            rendered_messages = repr(messages)
            self.assertNotIn("窗边的薄荷需要保持土壤微湿", system_prompt)
            self.assertIn("spring_haven_knowledge_context", rendered_messages)
            self.assertIn("窗边的薄荷需要保持土壤微湿", rendered_messages)
            self.assertEqual(result["rag"]["recalled_count"], 1)
        finally:
            await service.aclose()

    async def test_markdown_headings_keep_sections_separate_and_searchable(self):
        provider = FakeRagProvider()
        store = KnowledgeRagStore(self.root / "rag.sqlite3", provider, ["ling", "nai"])
        try:
            document = await store.put_document(
                {
                    "title": "生活设定",
                    "scope": "ling",
                    "text": (
                        "# 情绪调节\n压力大时会先去窗边安静坐一会。\n\n"
                        "## 我的充电方式\n整理花叶和听熟悉的音乐会让心情变好。\n\n"
                        "# 饮食偏好\n晚餐更喜欢清淡的热汤。"
                    ),
                }
            )
            with store._lock:
                rows = store._connection.execute(
                    """
                    SELECT section_path, content FROM rag_chunks
                    WHERE document_id = ? ORDER BY ordinal
                    """,
                    (document["document_id"],),
                ).fetchall()
            self.assertEqual(
                [str(row["section_path"]) for row in rows],
                ["情绪调节", "情绪调节 > 我的充电方式", "饮食偏好"],
            )
            self.assertNotIn("饮食偏好", str(rows[0]["content"]))
            results = await store.search("怎么让心情变好", role_id="ling")
            self.assertTrue(results)
            self.assertEqual(results[0]["section_path"], "情绪调节 > 我的充电方式")
        finally:
            store.close()

    async def test_source_deduplication_and_batch_document_operations(self):
        provider = FakeRagProvider()
        store = KnowledgeRagStore(self.root / "rag.sqlite3", provider, ["ling", "nai"])
        try:
            first = await store.put_document(
                {
                    "title": "小玲设定",
                    "text": "# 情绪\n旧内容。",
                    "scope": "*",
                    "source_uri": "C:/knowledge/ling.md",
                }
            )
            updated = await store.put_document(
                {
                    "title": "小玲设定",
                    "text": "# 情绪\n更新后的内容。",
                    "scope": "*",
                    "source_uri": "C:/knowledge/ling.md",
                }
            )
            second = await store.put_document(
                {"title": "另一份", "text": "# 日常\n另一份内容。", "scope": "*"}
            )
            self.assertEqual(first["document_id"], updated["document_id"])
            self.assertEqual(store.status()["document_count"], 2)

            scoped = await store.batch_documents(
                {
                    "action": "update_scope",
                    "document_ids": [first["document_id"], second["document_id"]],
                    "scope": "ling",
                }
            )
            self.assertEqual(scoped["affected_documents"], 2)
            self.assertTrue(
                all(item["scope"] == "ling" for item in store.list_documents())
            )
            rechunked = await store.batch_documents(
                {"action": "rechunk", "document_ids": [first["document_id"]]}
            )
            self.assertEqual(rechunked["affected_documents"], 1)
            deleted = await store.batch_documents(
                {"action": "delete", "document_ids": [second["document_id"]]}
            )
            self.assertEqual(deleted["affected_documents"], 1)
            self.assertEqual(store.status()["document_count"], 1)
        finally:
            store.close()


class RagHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roles = make_registry(self.root)
        self.config = CoreConfig(
            api_key="r" * 64,
            provider_base_url="http://127.0.0.1:1/v1",
            provider_model="unused",
            provider_settings_path=str(self.root / "providers.json"),
            provider_credential_path=str(self.root / "providers.dpapi"),
            rag_db_path=str(self.root / "rag.sqlite3"),
        )
        self.settings = ProviderSettingsStore(
            self.config,
            self.config.provider_settings_path,
            self.config.provider_credential_path,
        )
        self.settings.update_rag(
            {
                "enabled": True,
                "use_embeddings": False,
                "use_rerank": False,
                "top_k": 4,
                "candidate_limit": 12,
                "chunk_size": 300,
                "chunk_overlap": 30,
            }
        )
        self.provider = OpenAICompatibleProvider(self.config, self.settings)
        self.rag = KnowledgeRagStore(
            self.config.rag_db_path, self.provider, self.roles.ids()
        )
        self.memory = HeartloomStore(self.root / "heartloom.sqlite3", self.roles.ids())
        self.service = CompanionService(
            self.roles, self.provider, self.memory, self.rag
        )
        self.client = TestClient(
            TestServer(build_app(self.config, self.roles, self.service))
        )
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.service.aclose()
        self.temp.cleanup()

    def headers(self):
        return {"X-API-Key": "r" * 64}

    async def test_document_crud_and_search_http_contract(self):
        created = await self.client.post(
            "/rag/documents",
            headers=self.headers(),
            json={"title": "餐桌说明", "text": "餐桌右侧抽屉里放着浅色餐垫。"},
        )
        self.assertEqual(created.status, 200)
        created_body = await created.json()
        document_id = created_body["data"]["document"]["document_id"]

        fetched = await self.client.get(
            f"/rag/documents/{document_id}", headers=self.headers()
        )
        fetched_document = (await fetched.json())["data"]["document"]
        self.assertEqual(fetched_document["text"], "餐桌右侧抽屉里放着浅色餐垫。")

        updated = await self.client.post(
            "/rag/documents",
            headers=self.headers(),
            json={
                "document_id": document_id,
                "title": "餐桌说明（更新）",
                "text": "餐垫已经移动到餐桌左侧柜子。",
                "scope": "nai",
            },
        )
        self.assertEqual(updated.status, 200)
        updated_document = (await updated.json())["data"]["document"]
        self.assertEqual(updated_document["document_id"], document_id)
        self.assertEqual(updated_document["scope"], "nai")
        self.assertNotEqual(
            updated_document["content_hash"], fetched_document["content_hash"]
        )

        search = await self.client.post(
            "/rag/search",
            headers=self.headers(),
            json={"query": "餐垫在哪里", "role_id": "nai", "limit": 3},
        )
        search_body = await search.json()
        self.assertEqual(search_body["data"]["count"], 1)
        self.assertEqual(
            search_body["data"]["entries"][0]["document_id"], document_id
        )

        status = await self.client.get("/rag/status", headers=self.headers())
        self.assertEqual((await status.json())["data"]["document_count"], 1)
        deleted = await self.client.delete(
            f"/rag/documents/{document_id}", headers=self.headers()
        )
        self.assertTrue((await deleted.json())["data"]["deleted"])
        missing = await self.client.get(
            f"/rag/documents/{document_id}", headers=self.headers()
        )
        self.assertEqual(missing.status, 404)

    async def test_base64_document_and_local_web_import(self):
        imported = await self.client.post(
            "/rag/import",
            headers=self.headers(),
            json={
                "filename": "daily.md",
                "content_base64": base64.b64encode(
                    "花盆今天浇过水。".encode("utf-8")
                ).decode("ascii"),
                "scope": "ling",
            },
        )
        self.assertEqual(imported.status, 200)
        imported_body = await imported.json()
        self.assertEqual(imported_body["data"]["document"]["title"], "daily")
        self.assertEqual(imported_body["data"]["import"]["extension"], ".md")

        async def web_page(_request):
            from aiohttp import web

            return web.Response(
                text="<html><head><title>室内植物</title></head><body>绿萝需要散射光。</body></html>",
                content_type="text/html",
            )

        from aiohttp import web

        source_app = web.Application()
        source_app.router.add_get("/knowledge", web_page)
        source_server = TestServer(source_app)
        await source_server.start_server()
        try:
            web_import = await self.client.post(
                "/rag/import-url",
                headers=self.headers(),
                json={"url": str(source_server.make_url("/knowledge")), "scope": "*"},
            )
            self.assertEqual(web_import.status, 200)
            web_body = await web_import.json()
            self.assertEqual(
                web_body["data"]["document"]["title"], "室内植物"
            )
            self.assertEqual(
                web_body["data"]["document"]["source_uri"],
                str(source_server.make_url("/knowledge")),
            )
        finally:
            await source_server.close()

    async def test_import_validation_rejects_bad_payloads_and_remote_http(self):
        invalid_base64 = await self.client.post(
            "/rag/import",
            headers=self.headers(),
            json={"filename": "bad.txt", "content_base64": "%%%"},
        )
        self.assertEqual(invalid_base64.status, 400)
        remote_http = await self.client.post(
            "/rag/import-url",
            headers=self.headers(),
            json={"url": "http://example.com/knowledge"},
        )
        self.assertEqual(remote_http.status, 400)

    async def test_batch_document_http_contract(self):
        document_ids = []
        for title in ["第一份", "第二份"]:
            response = await self.client.post(
                "/rag/documents",
                headers=self.headers(),
                json={"title": title, "text": f"# {title}\n用于批量接口测试。", "scope": "*"},
            )
            document_ids.append((await response.json())["data"]["document"]["document_id"])
        scoped = await self.client.post(
            "/rag/documents/batch",
            headers=self.headers(),
            json={"action": "update_scope", "document_ids": document_ids, "scope": "ling"},
        )
        self.assertEqual(scoped.status, 200)
        self.assertEqual((await scoped.json())["data"]["affected_documents"], 2)
        listed = await self.client.get("/rag/documents", headers=self.headers())
        self.assertTrue(
            all(item["scope"] == "ling" for item in (await listed.json())["data"]["documents"])
        )
        deleted = await self.client.post(
            "/rag/documents/batch",
            headers=self.headers(),
            json={"action": "delete", "document_ids": document_ids},
        )
        self.assertEqual((await deleted.json())["data"]["affected_documents"], 2)


if __name__ == "__main__":
    unittest.main()
