"""ADR-011:记忆召回跨编码器重排测试。

覆盖:重排生效/降级回落/开关关闭/recall_pool 无副作用/commit 定稿副作用。
"""

from __future__ import annotations

import asyncio
import unittest

from spring_haven_core.memory import HeartloomStore
from spring_haven_core.roles import RoleDefinition, RoleRegistry
from spring_haven_core.service import CompanionService


class _FakeProfile:
    def __init__(self, enabled: bool):
        self.enabled = enabled


class _FakeSettings:
    def __init__(self, enabled: bool = True):
        self.enabled = enabled

    def profile_snapshot(self, capability: str) -> "_FakeProfile":
        return _FakeProfile(self.enabled)


class _FakeProvider:
    """可编程 rerank 桩:按文档内容关键词返回分数;可注入异常。"""

    def __init__(self, raise_error: bool = False):
        self.settings = _FakeSettings()
        self.rerank_calls: list[tuple[str, list[str]]] = []
        self.raise_error = raise_error

    async def complete(self, system_prompt, messages):  # pragma: no cover
        raise AssertionError("chat completion 不应被本测试触发")

    async def rerank(self, query, documents, top_n):
        self.rerank_calls.append((query, list(documents)))
        if self.raise_error:
            raise RuntimeError("rerank upstream down")
        scores = []
        for index, doc in enumerate(documents):
            scores.append({"index": index, "score": 0.9 if "稀土" in doc else 0.1})
        return scores[:top_n]


def _roles() -> RoleRegistry:
    return RoleRegistry(
        {"ling": RoleDefinition("ling", "小玲", "春日 铃音", ("小玲",), "你是小玲。")}
    )


def _seed(store: HeartloomStore) -> list[str]:
    ids = []
    for tag, content, terms in (
        ("a", "主人在后院种了一畦青菜", ["青菜"]),
        ("b", "主人聊起稀土出口的新闻", ["稀土"]),
        ("c", "小玲晒了一下午太阳", ["太阳"]),
        ("d", "主人修好了院子里的篱笆", ["篱笆"]),
    ):
        ids.append(
            str(
                store.put_memory(
                    {
                        "save_id": "s",
                        "scope_role_id": "ling",
                        "kind": "episodic",
                        "title": f"记忆{tag}",
                        "content": content,
                        "trigger_terms": terms,
                        "source_event_id": f"seed-{tag}",
                    },
                    source="organizer_ling",
                )["memory_id"]
            )
        )
    return ids


class RecallRerankTests(unittest.TestCase):
    def setUp(self):
        self.store = HeartloomStore(":memory:", ["ling"])

    def tearDown(self):
        self.store.close()

    def _service(self, provider, *, rerank_enabled: bool = True) -> CompanionService:
        return CompanionService(
            _roles(),
            provider,
            self.store,
            memory_organizer_enabled=False,
            memory_recall_limit=2,
            memory_rerank_enabled=rerank_enabled,
        )

    def _run(self, coro):
        return asyncio.run(coro)

    def test_rerank_reorders_final_selection(self):
        provider = _FakeProvider()
        service = self._service(provider)
        _seed(self.store)
        memories = self._run(
            service._recall_with_rerank(
                save_id="s",
                role_id="ling",
                query="主人院子里的青菜和稀土新闻",
                query_vector=None,
                embedding_model="",
            )
        )
        self.assertEqual(len(provider.rerank_calls), 1)
        titles = [item["title"] for item in memories]
        # rerank 给「稀土」0.9 分:即使混合序不同,最终前 2 必含稀土条目且排前
        self.assertIn("记忆b", titles[:2])
        self.assertLessEqual(titles.index("记忆b"), 1)

    def test_rerank_failure_degrades_to_hybrid_order(self):
        provider = _FakeProvider(raise_error=True)
        service = self._service(provider)
        _seed(self.store)
        memories = self._run(
            service._recall_with_rerank(
                save_id="s",
                role_id="ling",
                query="主人院子里发生了什么",
                query_vector=None,
                embedding_model="",
            )
        )
        self.assertEqual(len(provider.rerank_calls), 1)
        self.assertTrue(memories)
        # 降级即纯混合序:与 recall_pool 截断一致
        pool = self.store.recall_pool(
            save_id="s", role_id="ling", query="主人院子里发生了什么"
        )
        self.assertEqual(
            [item["memory_id"] for item in memories],
            [item["memory_id"] for item in pool[: len(memories)]],
        )

    def test_disabled_flag_never_calls_rerank(self):
        provider = _FakeProvider()
        service = self._service(provider, rerank_enabled=False)
        _seed(self.store)
        memories = self._run(
            service._recall_with_rerank(
                save_id="s",
                role_id="ling",
                query="主人院子里发生了什么",
                query_vector=None,
                embedding_model="",
            )
        )
        self.assertEqual(provider.rerank_calls, [])
        self.assertTrue(memories)

    def test_rerank_profile_disabled_degrades(self):
        provider = _FakeProvider()
        provider.settings = _FakeSettings(enabled=False)
        service = self._service(provider)
        _seed(self.store)
        memories = self._run(
            service._recall_with_rerank(
                save_id="s",
                role_id="ling",
                query="主人院子里发生了什么",
                query_vector=None,
                embedding_model="",
            )
        )
        self.assertEqual(provider.rerank_calls, [])
        self.assertTrue(memories)

    def test_recall_pool_has_no_side_effects_and_commit_finalizes(self):
        memory_id = _seed(self.store)[1]  # 记忆b(稀土)
        # 模拟该记忆已休眠
        self.store.set_memory_lifecycle(memory_id, "dormant")
        before = self.store.recall_pool(
            save_id="s", role_id="ling", query="稀土新闻"
        )
        self.assertTrue(before)
        # 池阶段:零副作用——dormant 未被唤醒、无唤醒奖励
        row = self.store._connection.execute(
            "SELECT lifecycle, intrinsic, recall_count FROM memory_entries WHERE memory_id = ?",
            (memory_id,),
        ).fetchone()
        self.assertEqual(str(row["lifecycle"]), "dormant")
        self.assertEqual(int(row["recall_count"]), 0)
        # 定稿:唤醒 + 奖励只落在传入的 id 上
        self.store.commit_recall_access(
            save_id="s",
            role_id="ling",
            memory_ids=[memory_id],
            record_access=True,
        )
        row = self.store._connection.execute(
            "SELECT lifecycle, intrinsic, recall_count FROM memory_entries WHERE memory_id = ?",
            (memory_id,),
        ).fetchone()
        self.assertEqual(str(row["lifecycle"]), "active")
        self.assertEqual(int(row["recall_count"]), 1)
        self.assertGreater(float(row["intrinsic"]), 1.0)  # ADR-014:1.0 → ×1.5
        # 未入选的记忆不受影响
        others = self.store._connection.execute(
            "SELECT COUNT(*) FROM memory_entries WHERE recall_count > 0"
        ).fetchone()[0]
        self.assertEqual(int(others), 1)

    def test_recall_wrapper_matches_legacy_behavior(self):
        ids = _seed(self.store)
        legacy = self.store.recall(
            save_id="s", role_id="ling", query="稀土新闻", limit=2
        )
        self.assertEqual(len(legacy), 1)
        self.assertEqual(str(legacy[0]["memory_id"]), ids[1])
        self.assertIn("recall_score", legacy[0])


if __name__ == "__main__":
    unittest.main()
