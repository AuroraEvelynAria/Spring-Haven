from __future__ import annotations

import asyncio
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from aiohttp import web
from aiohttp.test_utils import TestServer

from spring_haven_core.config import CoreConfig
from spring_haven_core.provider import OpenAICompatibleProvider, ProviderError, _usage_snapshot
from spring_haven_core.provider_settings import ProviderSettingsStore


class ProviderCapabilityProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = patch.dict(
            os.environ,
            {
                "SPRING_HAVEN_LLM_API_KEY": "",
                "SPRING_HAVEN_LLM_BASE_URL": "",
                "SPRING_HAVEN_LLM_MODEL": "",
                "SPRING_HAVEN_VISION_API_KEY": "",
                "SPRING_HAVEN_EMBEDDING_API_KEY": "",
                "SPRING_HAVEN_RERANK_API_KEY": "",
                "SPRING_HAVEN_ASR_API_KEY": "",
                "SPRING_HAVEN_ASR_BASE_URL": "",
                "SPRING_HAVEN_ASR_MODEL": "",
                "SPRING_HAVEN_TTS_API_KEY": "",
                "SPRING_HAVEN_TTS_BASE_URL": "",
                "SPRING_HAVEN_TTS_MODEL": "",
                "SPRING_HAVEN_PROXY_MODE": "",
                "SPRING_HAVEN_PROXY_URL": "",
            },
        )
        self.environment.start()
        self.authorizations = []
        self.failure_calls = 0
        self.empty_reply_calls = 0
        self.empty_reply_payloads = []
        self.invalid_json_calls = 0
        self.invalid_embedding_calls = 0
        app = web.Application()
        app.router.add_post("/v1/chat/completions", self.chat)
        app.router.add_post("/v1/embeddings", self.embeddings)
        app.router.add_post("/v1/rerank", self.rerank)
        app.router.add_post("/v1/fail", self.fail)
        app.router.add_post("/v1/client-fail", self.client_fail)
        app.router.add_post("/v1/nul-json", self.nul_json)
        app.router.add_post("/v1/sse-json", self.sse_json)
        app.router.add_post("/v1/html-ok", self.html_ok)
        app.router.add_post("/v1/chunked-json", self.chunked_json)
        self.server = TestServer(app)
        await self.server.start_server()
        base_url = str(self.server.make_url("/v1")).rstrip("/")
        self.config = CoreConfig(
            api_key="p" * 64,
            provider_base_url=base_url,
            provider_model="chat-model",
            provider_settings_path=str(self.root / "providers.json"),
            provider_credential_path=str(self.root / "providers.dpapi"),
            request_timeout_seconds=5,
        )
        self.settings = ProviderSettingsStore(
            self.config,
            self.config.provider_settings_path,
            self.config.provider_credential_path,
        )
        self.settings.update(
            base_url=base_url,
            model="chat-model",
            api_key="sk-test-shared-not-a-real-credential",
            persist=False,
        )
        for capability, model, protocol in [
            ("vision", "vision-model", "openai_chat_vision"),
            ("embedding", "embedding-model", "openai_embeddings"),
            ("rerank", "rerank-model", "jina_v1"),
        ]:
            self.settings.update_profile(
                capability,
                base_url=base_url,
                model=model,
                enabled=True,
                protocol=protocol,
                inherit_chat_key=True,
            )
        self.provider = OpenAICompatibleProvider(self.config, self.settings)

    async def asyncTearDown(self):
        await self.server.close()
        self.environment.stop()
        self.temp.cleanup()

    async def chat(self, request):
        self.authorizations.append(request.headers.get("Authorization", ""))
        payload = await request.json()
        if payload.get("model") == "primary-503":
            self.failure_calls += 1
            return web.json_response(
                {"error": {"message": "temporary failure"}}, status=503
            )
        if payload.get("model") == "auth-401":
            return web.json_response(
                {"error": {"message": "invalid key"}}, status=401
            )
        if payload.get("model") == "empty-once":
            self.empty_reply_calls += 1
            self.empty_reply_payloads.append(payload)
            if self.empty_reply_calls == 1:
                return web.json_response(
                    {
                        "choices": [{
                            "message": {
                                "content": "",
                                "reasoning_content": "internal reasoning must stay hidden",
                            },
                            "finish_reason": "length",
                        }]
                    }
                )
            return web.json_response(
                {"choices": [{"message": {"content": "最终回复"}, "finish_reason": "stop"}]}
            )
        if payload.get("model") == "empty-primary":
            return web.json_response(
                {
                    "choices": [{
                        "message": {"content": "", "reasoning_content": "hidden"},
                        "finish_reason": "length",
                    }]
                }
            )
        if payload.get("model") == "invalid-json-once":
            self.invalid_json_calls += 1
            if self.invalid_json_calls == 1:
                return web.Response(
                    body=b'{"choices":[{"message":',
                    content_type="application/json",
                )
            return web.json_response(
                {"choices": [{"message": {"content": "recovered json"}, "finish_reason": "stop"}]}
            )
        content = payload["messages"][-1]["content"]
        if isinstance(content, list):
            reply = '{"observations":["窗边有花"],"entities":[],"changes":[],"confidence":0.9}'
        else:
            reply = "chat reply"
        return web.json_response(
            {"choices": [{"message": {"content": reply}, "finish_reason": "stop"}]}
        )

    async def embeddings(self, request):
        self.authorizations.append(request.headers.get("Authorization", ""))
        payload = await request.json()
        if payload.get("input") == ["invalid-json-once"]:
            self.invalid_embedding_calls += 1
            if self.invalid_embedding_calls == 1:
                return web.Response(
                    body=b'{"data":[{"index":0,"embedding":',
                    content_type="application/json",
                )
        return web.json_response(
            {
                "data": [
                    {"index": index, "embedding": [float(index + 1), 0.5]}
                    for index, _text in enumerate(payload["input"])
                ]
            }
        )

    async def rerank(self, request):
        self.authorizations.append(request.headers.get("Authorization", ""))
        payload = await request.json()
        return web.json_response(
            {
                "results": [
                    {"index": index, "relevance_score": 0.9 - index * 0.1}
                    for index in range(min(payload["top_n"], len(payload["documents"])))
                ]
            }
        )

    async def fail(self, _request):
        self.failure_calls += 1
        return web.json_response({"error": {"message": "temporary failure"}}, status=503)

    async def client_fail(self, _request):
        return web.json_response({"error": {"message": "invalid key"}}, status=401)

    async def nul_json(self, _request):
        return web.Response(
            body=(
                b'{"choices":[{"message":{"content":"nul-safe"},'
                b'"finish_reason":"stop"}]}\x00\x00'
            ),
            content_type="application/json",
        )

    async def sse_json(self, _request):
        return web.Response(
            text=(
                'data: {"id":"chat-sse","model":"proxy-model","choices":'
                '[{"delta":{"role":"assistant"},"finish_reason":null}]}\n\n'
                'data: {"id":"chat-sse","model":"proxy-model","choices":'
                '[{"delta":{"content":"团子"},"finish_reason":null}]}\n\n'
                'data: {"id":"chat-sse","model":"proxy-model","choices":'
                '[{"delta":{"content":"回复"},"finish_reason":"stop"}],'
                '"usage":{"prompt_tokens":12,"completion_tokens":3}}\n\n'
                'data: [DONE]\n\n'
            ),
            content_type="text/event-stream",
        )

    async def html_ok(self, _request):
        return web.Response(text="<html>upstream proxy error</html>", content_type="text/html")

    async def chunked_json(self, request):
        response = web.StreamResponse(
            status=200, headers={"Content-Type": "application/json"}
        )
        await response.prepare(request)
        body = (
            b'{"choices":[{"message":{"content":"complete chunked reply"},'
            b'"finish_reason":"stop"}]}'
        )
        await response.write(body[:23])
        await asyncio.sleep(0.02)
        await response.write(body[23:])
        await response.write_eof()
        return response

    async def test_openai_compatible_vision_embedding_and_rerank(self):
        vision = await self.provider.describe_image(
            image_base64="aW1hZ2U=",
            mime_type="image/png",
            question="看到了什么？",
        )
        vectors = await self.provider.embed(["一", "二"])
        ranking = await self.provider.rerank("问题", ["甲", "乙"], 2)
        self.assertEqual(vision.structured["confidence"], 0.9)
        self.assertEqual(vectors, [[1.0, 0.5], [2.0, 0.5]])
        self.assertEqual(ranking[0]["index"], 0)
        self.assertEqual(
            self.authorizations,
            ["Bearer sk-test-shared-not-a-real-credential"] * 3,
        )

    async def test_custom_http_proxy_is_used_for_provider_requests(self):
        proxy_calls = []

        async def proxy_response(request):
            proxy_calls.append(request.raw_path)
            payload = await request.json()
            return web.json_response(
                {
                    "data": [
                        {"index": index, "embedding": [0.25, float(index + 1)]}
                        for index, _text in enumerate(payload["input"])
                    ]
                }
            )

        proxy_app = web.Application()
        proxy_app.router.add_route("*", "/{tail:.*}", proxy_response)
        proxy_server = TestServer(proxy_app)
        await proxy_server.start_server()
        try:
            self.settings.update_network_proxy(
                {
                    "mode": "custom",
                    "url": str(proxy_server.make_url("/")).rstrip("/"),
                }
            )
            vectors = await self.provider.embed(["代理测试"])
            self.assertEqual(vectors, [[0.25, 1.0]])
            self.assertEqual(len(proxy_calls), 1)
            self.assertIn("/v1/embeddings", proxy_calls[0])
        finally:
            await proxy_server.close()

    async def test_non_json_provider_error_is_safe_and_actionable(self):
        profile = self.settings.profile_snapshot("chat")
        with self.assertRaisesRegex(
            ProviderError, r"HTTP 404 returned non-JSON content.*needs a /v1 suffix"
        ):
            await self.provider._post_json(
                SimpleNamespace(
                    base_url=str(self.server.make_url("/")).rstrip("/"),
                    api_key=profile.api_key,
                    capability="chat",
                ),
                "/missing",
                {"diagnostic": True},
            )

    async def test_json_with_nul_suffix_is_accepted(self):
        profile = self.settings.profile_snapshot("chat")
        data = await self.provider._post_json(profile, "/nul-json", {}, "chat")
        self.assertEqual(data["choices"][0]["message"]["content"], "nul-safe")

    async def test_sse_returned_for_non_stream_request_is_reassembled(self):
        profile = self.settings.profile_snapshot("chat")
        data = await self.provider._post_json(profile, "/sse-json", {}, "chat")
        self.assertEqual(data["choices"][0]["message"]["content"], "团子回复")
        self.assertEqual(data["choices"][0]["finish_reason"], "stop")
        self.assertEqual(data["usage"]["prompt_tokens"], 12)

    async def test_chunked_json_response_is_read_to_eof(self):
        profile = self.settings.profile_snapshot("chat")
        data = await self.provider._post_json(
            profile, "/chunked-json", {}, "chat"
        )
        self.assertEqual(
            data["choices"][0]["message"]["content"], "complete chunked reply"
        )

    async def test_html_with_http_200_remains_invalid_and_can_fail_over(self):
        profile = self.settings.profile_snapshot("chat")
        with self.assertRaises(ProviderError) as captured:
            await self.provider._post_json(profile, "/html-ok", {}, "chat")
        self.assertTrue(captured.exception.failover_allowed)
        self.assertEqual(captured.exception.status_code, 200)

    async def test_repeated_failures_open_a_bounded_circuit(self):
        profile = self.settings.profile_snapshot("chat")
        for _index in range(3):
            with self.assertRaisesRegex(ProviderError, "HTTP 503"):
                await self.provider._post_json(profile, "/fail", {}, "chat")
        with self.assertRaisesRegex(ProviderError, "temporarily paused"):
            await self.provider._post_json(profile, "/fail", {}, "chat")
        self.assertEqual(self.failure_calls, 3)
        status = self.provider.circuit_status()["chat"]
        self.assertEqual(status["state"], "open")
        self.assertEqual(status["consecutive_failures"], 3)
        self.assertGreater(status["retry_after_seconds"], 0)

    async def test_503_switches_to_fallback_and_reports_active_candidate(self):
        fallback_app = web.Application()

        async def fallback_chat(_request):
            return web.json_response(
                {"choices": [{"message": {"content": "fallback reply"}, "finish_reason": "stop"}]}
            )

        fallback_app.router.add_post("/v1/chat/completions", fallback_chat)
        fallback_server = TestServer(fallback_app)
        await fallback_server.start_server()
        try:
            self.settings.update(
                base_url=str(self.server.make_url("/v1")).rstrip("/"),
                model="primary-503",
            )
            self.settings.update_fallbacks(
                "chat",
                [{
                    "id": "backup",
                    "label": "Backup",
                    "base_url": str(fallback_server.make_url("/v1")).rstrip("/"),
                    "model": "fallback-model",
                    "enabled": True,
                    "protocol": "openai_chat",
                    "inherit_chat_key": False,
                }],
            )
            reply = await self.provider.complete("system", [{"role": "user", "content": "hi"}])
            self.assertEqual(reply.text, "fallback reply")
            status = self.provider.circuit_status()["chat"]
            self.assertEqual(status["active_candidate_id"], "backup")
            self.assertGreaterEqual(status["switch_count"], 1)
        finally:
            await fallback_server.close()

    async def test_empty_chat_reply_gets_one_bounded_final_answer_retry(self):
        self.settings.update(
            base_url=str(self.server.make_url("/v1")).rstrip("/"),
            model="empty-once",
        )
        reply = await self.provider.complete(
            "system", [{"role": "user", "content": "hi"}]
        )
        self.assertEqual(reply.text, "最终回复")
        self.assertNotIn("internal reasoning", reply.text)
        self.assertEqual(self.empty_reply_calls, 2)
        retry = self.empty_reply_payloads[1]
        self.assertEqual(retry["max_tokens"], self.config.max_output_tokens * 2)
        self.assertLessEqual(retry["temperature"], 0.6)
        self.assertIn("不要展示推理过程", retry["messages"][-1]["content"])

    async def test_empty_chat_reply_switches_to_fallback_before_retry(self):
        fallback_calls = []
        fallback_app = web.Application()

        async def fallback_chat(request):
            fallback_calls.append(await request.json())
            return web.json_response(
                {"choices": [{"message": {"content": "backup reply"}, "finish_reason": "stop"}]}
            )

        fallback_app.router.add_post("/v1/chat/completions", fallback_chat)
        fallback_server = TestServer(fallback_app)
        await fallback_server.start_server()
        try:
            self.settings.update(
                base_url=str(self.server.make_url("/v1")).rstrip("/"),
                model="empty-primary",
            )
            self.settings.update_fallbacks(
                "chat",
                [{
                    "id": "backup-empty",
                    "label": "Backup Empty",
                    "base_url": str(fallback_server.make_url("/v1")).rstrip("/"),
                    "model": "fallback-model",
                    "enabled": True,
                    "protocol": "openai_chat",
                    "inherit_chat_key": False,
                }],
            )
            reply = await self.provider.complete(
                "system", [{"role": "user", "content": "hi"}]
            )
            self.assertEqual(reply.text, "backup reply")
            self.assertEqual(len(fallback_calls), 1)
            self.assertEqual(
                self.provider.circuit_status()["chat"]["active_candidate_id"],
                "backup-empty",
            )
        finally:
            await fallback_server.close()

    async def test_malformed_http_200_json_gets_one_same_prompt_retry(self):
        self.settings.update(
            base_url=str(self.server.make_url("/v1")).rstrip("/"),
            model="invalid-json-once",
        )
        reply = await self.provider.complete(
            "system", [{"role": "user", "content": "hi"}]
        )
        self.assertEqual(reply.text, "recovered json")
        self.assertEqual(self.invalid_json_calls, 2)

    async def test_embedding_malformed_http_200_json_gets_one_retry(self):
        vectors = await self.provider.embed(["invalid-json-once"])
        self.assertEqual(vectors, [[1.0, 0.5]])
        self.assertEqual(self.invalid_embedding_calls, 2)

    async def test_authentication_failure_does_not_switch_to_fallback(self):
        self.settings.update(
            base_url=str(self.server.make_url("/v1")).rstrip("/"),
            model="auth-401",
        )
        self.settings.update_fallbacks(
            "chat",
            [{
                "id": "backup",
                "label": "Backup",
                "base_url": str(self.server.make_url("/v1")).rstrip("/"),
                "model": "fallback-model",
                "enabled": True,
                "protocol": "openai_chat",
                "inherit_chat_key": False,
            }],
        )
        for _index in range(4):
            with self.assertRaisesRegex(ProviderError, "HTTP 401"):
                await self.provider.complete("system", [{"role": "user", "content": "hi"}])
        status = self.provider.circuit_status()["chat"]
        self.assertEqual(status["active_candidate_id"], "primary")
        self.assertEqual(status["state"], "closed")

    async def test_each_capability_has_a_redacted_live_diagnostic(self):
        for capability in ["chat", "vision", "embedding", "rerank"]:
            result = await self.provider.diagnose(capability)
            self.assertTrue(result["ok"])
            self.assertEqual(result["capability"], capability)
            self.assertNotIn("api_key", repr(result))
            self.assertGreaterEqual(result["latency_ms"], 0)
        self.assertEqual(
            self.authorizations,
            ["Bearer sk-test-shared-not-a-real-credential"] * 4,
        )

    def test_cache_usage_is_normalized_across_compatible_schemas(self):
        self.assertEqual(
            _usage_snapshot(
                {
                    "prompt_tokens": 1200,
                    "completion_tokens": 80,
                    "prompt_tokens_details": {"cached_tokens": 960},
                }
            ),
            (1200, 80, 960, 240),
        )
        self.assertEqual(
            _usage_snapshot(
                {
                    "prompt_tokens": 1500,
                    "completion_tokens": 90,
                    "prompt_cache_hit_tokens": 1024,
                    "prompt_cache_miss_tokens": 476,
                }
            ),
            (1500, 90, 1024, 476),
        )
        self.assertEqual(
            _usage_snapshot(
                {
                    "input_tokens": 800,
                    "output_tokens": 40,
                    "cache_read_input_tokens": 640,
                }
            ),
            (800, 40, 640, 160),
        )


if __name__ == "__main__":
    unittest.main()
