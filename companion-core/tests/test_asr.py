from __future__ import annotations

import json
import os
import struct
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


def pcm_wav(sample_rate: int = 16_000, frames: int = 3_200) -> bytes:
    pcm = b"\x00\x00" * frames
    return (
        b"RIFF"
        + struct.pack("<I", 36 + len(pcm))
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16)
        + b"data"
        + struct.pack("<I", len(pcm))
        + pcm
    )


class AsrProviderTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = patch.dict(
            os.environ,
            {
                "SPRING_HAVEN_LLM_API_KEY": "",
                "SPRING_HAVEN_ASR_API_KEY": "",
                "SPRING_HAVEN_ASR_BASE_URL": "",
                "SPRING_HAVEN_ASR_MODEL": "",
                "SPRING_HAVEN_PROXY_MODE": "",
                "SPRING_HAVEN_PROXY_URL": "",
            },
        )
        self.environment.start()
        self.requests: list[dict[str, object]] = []
        upstream = web.Application()
        upstream.router.add_post("/v1/audio/transcriptions", self.openai_asr)
        upstream.router.add_post("/asr", self.open_llm_vtuber_asr)
        self.upstream = TestServer(upstream)
        await self.upstream.start_server()
        self.base_url = str(self.upstream.make_url("/")).rstrip("/")
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
        self.provider = OpenAICompatibleProvider(self.config, self.settings)

    async def asyncTearDown(self):
        await self.upstream.close()
        self.environment.stop()
        self.temp.cleanup()

    async def _multipart_fields(self, request: web.Request) -> dict[str, object]:
        fields: dict[str, object] = {
            "authorization": request.headers.get("Authorization", "")
        }
        reader = await request.multipart()
        while True:
            part = await reader.next()
            if part is None:
                break
            if part.name == "file":
                fields["filename"] = part.filename
                fields["mime_type"] = part.headers.get("Content-Type", "")
                fields["audio"] = await part.read()
            else:
                fields[str(part.name)] = await part.text()
        return fields

    async def openai_asr(self, request: web.Request) -> web.Response:
        fields = await self._multipart_fields(request)
        self.requests.append(fields)
        return web.json_response({"text": "我把温水递给小玲", "language": "zh"})

    async def open_llm_vtuber_asr(self, request: web.Request) -> web.Response:
        fields = await self._multipart_fields(request)
        self.requests.append(fields)
        return web.json_response({"text": "小奈过来我这里"})

    async def test_openai_compatible_transcription_uses_multipart_and_key(self):
        self.settings.update_profile(
            "asr",
            base_url=self.base_url + "/v1",
            model="whisper-large-v3-turbo",
            api_key="sk-asr-test-not-a-real-key",
            persist=False,
            enabled=True,
            protocol="openai_transcriptions",
            inherit_chat_key=False,
        )
        reply = await self.provider.transcribe_audio(pcm_wav(), language="zh")
        self.assertEqual(reply.text, "我把温水递给小玲")
        request = self.requests[-1]
        self.assertEqual(request["model"], "whisper-large-v3-turbo")
        self.assertEqual(request["language"], "zh")
        self.assertEqual(request["authorization"], "Bearer sk-asr-test-not-a-real-key")
        self.assertEqual(request["mime_type"], "audio/wav")
        self.assertTrue(bytes(request["audio"]).startswith(b"RIFF"))

    async def test_open_llm_vtuber_protocol_omits_openai_only_fields(self):
        self.settings.update_profile(
            "asr",
            base_url=self.base_url,
            model="sense-voice",
            enabled=True,
            protocol="open_llm_vtuber_asr",
            inherit_chat_key=False,
        )
        reply = await self.provider.transcribe_audio(pcm_wav())
        self.assertEqual(reply.text, "小奈过来我这里")
        request = self.requests[-1]
        self.assertNotIn("model", request)
        self.assertNotIn("language", request)

    async def test_core_audio_endpoint_is_authenticated_and_returns_envelope(self):
        self.settings.update_profile(
            "asr",
            base_url=self.base_url + "/v1",
            model="whisper-large-v3-turbo",
            enabled=True,
            protocol="openai_transcriptions",
            inherit_chat_key=False,
        )
        roles_root = self.root / "roles"
        roles_root.mkdir()
        roles = make_registry(roles_root)
        service = CompanionService(roles, self.provider)
        client = TestClient(TestServer(build_app(self.config, roles, service)))
        await client.start_server()
        try:
            unauthenticated = await client.post(
                "/audio/transcribe", data=pcm_wav(), headers={"Content-Type": "audio/wav"}
            )
            self.assertEqual(unauthenticated.status, 401)
            response = await client.post(
                "/audio/transcribe?language=zh",
                data=pcm_wav(),
                headers={"X-API-Key": "a" * 64, "Content-Type": "audio/wav"},
            )
            self.assertEqual(response.status, 200)
            body = await response.json()
            self.assertEqual(body["data"]["text"], "我把温水递给小玲")
            self.assertEqual(body["data"]["provider"], "companion_core")
        finally:
            await client.close()
            service.close()

    async def test_core_audio_endpoint_rejects_non_wav_without_upstream_call(self):
        roles_root = self.root / "invalid-roles"
        roles_root.mkdir()
        roles = make_registry(roles_root)
        service = CompanionService(roles, self.provider)
        client = TestClient(TestServer(build_app(self.config, roles, service)))
        await client.start_server()
        try:
            response = await client.post(
                "/audio/transcribe",
                data=b"not a wav" * 10,
                headers={"X-API-Key": "a" * 64, "Content-Type": "audio/wav"},
            )
            self.assertEqual(response.status, 400)
            body = json.loads(await response.text())
            self.assertIn("PCM WAV", body["message"])
            self.assertEqual(self.requests, [])
        finally:
            await client.close()
            service.close()


if __name__ == "__main__":
    unittest.main()
