from __future__ import annotations

import base64
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from spring_haven_core.app import build_app
from spring_haven_core.config import CoreConfig
from spring_haven_core.provider import OpenAICompatibleProvider
from spring_haven_core.provider_settings import ProviderSettingsStore
from spring_haven_core.service import CompanionService

from test_contract import make_registry


class TtsProviderTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = patch.dict(
            os.environ,
            {
                "SPRING_HAVEN_LLM_API_KEY": "",
                "SPRING_HAVEN_TTS_API_KEY": "",
                "SPRING_HAVEN_TTS_BASE_URL": "",
                "SPRING_HAVEN_TTS_MODEL": "",
            },
        )
        self.environment.start()
        self.requests: list[dict[str, object]] = []
        upstream = web.Application()
        upstream.router.add_post("/v1/audio/speech", self.openai_tts)
        self.upstream = TestServer(upstream)
        await self.upstream.start_server()
        self.root_base_url = str(self.upstream.make_url("/")).rstrip("/")
        base_url = self.root_base_url + "/v1"
        self.config = CoreConfig(
            api_key="a" * 64,
            provider_base_url="http://127.0.0.1:1/v1",
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
        self.settings.update_profile(
            "tts",
            base_url=base_url,
            model="voicebox-qwen3-0.6b",
            api_key="sk-tts-test-not-a-real-key",
            persist=False,
            enabled=True,
            protocol="openai_speech",
            inherit_chat_key=False,
        )
        self.provider = OpenAICompatibleProvider(self.config, self.settings)

    async def asyncTearDown(self):
        await self.upstream.close()
        self.environment.stop()
        self.temp.cleanup()

    async def openai_tts(self, request: web.Request) -> web.Response:
        self.requests.append(await request.json())
        return web.Response(body=b"RIFFspring-haven-test-audio", content_type="audio/wav")

    async def test_openai_tts_payload_and_audio_are_preserved(self):
        reply = await self.provider.synthesize_speech(
            "你好，主人。",
            voice="ling",
            response_format="wav",
            speed=1.1,
        )
        self.assertEqual(reply.audio, b"RIFFspring-haven-test-audio")
        self.assertEqual(reply.mime_type, "audio/wav")
        self.assertEqual(self.requests[-1]["model"], "voicebox-qwen3-0.6b")
        self.assertEqual(self.requests[-1]["voice"], "ling")
        self.assertEqual(self.requests[-1]["response_format"], "wav")
        self.assertEqual(self.requests[-1]["speed"], 1.1)

    async def test_core_speech_endpoint_is_authenticated_and_base64_encodes_audio(self):
        roles_root = self.root / "roles"
        roles_root.mkdir()
        roles = make_registry(roles_root)
        service = CompanionService(roles, self.provider)
        client = TestClient(TestServer(build_app(self.config, roles, service)))
        await client.start_server()
        try:
            denied = await client.post("/audio/speech", json={"input": "你好"})
            self.assertEqual(denied.status, 401)
            response = await client.post(
                "/audio/speech",
                json={"input": "你好", "voice": "nai", "response_format": "wav"},
                headers={"X-API-Key": "a" * 64},
            )
            self.assertEqual(response.status, 200)
            body = await response.json()
            self.assertEqual(body["status"], "ok")
            audio = base64.b64decode(body["data"]["audio_base64"])
            self.assertEqual(audio, b"RIFFspring-haven-test-audio")
            self.assertEqual(body["data"]["mime_type"], "audio/wav")
        finally:
            await client.close()
            service.close()


if __name__ == "__main__":
    unittest.main()
