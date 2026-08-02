from __future__ import annotations

import os
import platform
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from aiohttp.test_utils import TestClient, TestServer

from spring_haven_core.app import build_app
from spring_haven_core.config import CoreConfig
from spring_haven_core.provider import ProviderReply
from spring_haven_core.provider_settings import (
    ProviderConfigurationError,
    ProviderSettingsStore,
)
from spring_haven_core.service import CompanionService

from test_contract import make_registry


class ProviderSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = patch.dict(
            os.environ,
            {
                "SPRING_HAVEN_LLM_API_KEY": "",
                "SPRING_HAVEN_LLM_BASE_URL": "",
                "SPRING_HAVEN_LLM_MODEL": "",
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
        self.config = CoreConfig(
            api_key="c" * 64,
            provider_base_url="https://api.deepseek.com/v1",
            provider_model="deepseek-chat",
            provider_settings_path=str(self.root / "provider.json"),
            provider_credential_path=str(self.root / "provider.dpapi"),
        )

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def make_store(self) -> ProviderSettingsStore:
        return ProviderSettingsStore(
            self.config,
            self.config.provider_settings_path,
            self.config.provider_credential_path,
        )

    def test_remote_http_provider_is_rejected(self):
        store = self.make_store()
        with self.assertRaises(ProviderConfigurationError):
            store.update(
                base_url="http://api.openai.com/v1",
                model="gpt-4.1-mini",
            )

    def test_private_ip_http_provider_is_allowed_without_override(self):
        store = self.make_store()
        profile = store.update_profile(
            "vision",
            base_url="http://192.168.1.25:8080/v1",
            model="gpt-4.1-mini",
            enabled=True,
            protocol="openai_chat_vision",
            inherit_chat_key=True,
        )
        self.assertEqual(profile["base_url"], "http://192.168.1.25:8080/v1")
        self.assertFalse(profile["allow_insecure_http"])
        self.assertEqual(profile["transport_security"], "plaintext_http")

    def test_public_ip_http_provider_requires_explicit_persisted_override(self):
        store = self.make_store()
        profile = store.update_profile(
            "vision",
            base_url="http://8.8.8.8:8080/v1",
            model="gpt-4.1-mini",
            enabled=True,
            protocol="openai_chat_vision",
            inherit_chat_key=True,
            allow_insecure_http=True,
        )
        self.assertTrue(profile["allow_insecure_http"])
        rebuilt = self.make_store()
        snapshot = rebuilt.profile_snapshot("vision")
        self.assertEqual(snapshot.base_url, "http://8.8.8.8:8080/v1")
        self.assertTrue(snapshot.allow_insecure_http)

    def test_capability_profiles_and_rag_settings_are_versioned(self):
        store = self.make_store()
        profile = store.update_profile(
            "vision",
            base_url="https://api.openai.com/v1",
            model="gpt-4.1-mini",
            enabled=True,
            protocol="openai_chat_vision",
            inherit_chat_key=True,
        )
        rag = store.update_rag(
            {
                "enabled": True,
                "use_embeddings": True,
                "use_rerank": False,
                "top_k": 8,
                "candidate_limit": 6,
                "chunk_size": 700,
                "chunk_overlap": 100,
            }
        )
        self.assertTrue(profile["enabled"])
        self.assertEqual(profile["protocol"], "openai_chat_vision")
        self.assertEqual(rag["candidate_limit"], 8)
        saved = __import__("json").loads(
            Path(self.config.provider_settings_path).read_text(encoding="utf-8")
        )
        self.assertEqual(saved["version"], 7)
        self.assertIn("vision", saved["profiles"])
        self.assertIn("asr", saved["profiles"])
        self.assertIn("tts", saved["profiles"])
        self.assertIn("fallbacks", saved)
        self.assertNotIn("api_key", repr(saved))

    def test_fallback_candidates_are_ordered_redacted_and_reloadable(self):
        store = self.make_store()
        candidates = store.update_fallbacks(
            "chat",
            [
                {
                    "id": "local_backup",
                    "label": "本地备用",
                    "base_url": "http://127.0.0.1:1234/v1",
                    "model": "local-chat",
                    "enabled": True,
                    "protocol": "openai_chat",
                    "inherit_chat_key": False,
                }
            ],
        )
        self.assertEqual(candidates[0]["id"], "local_backup")
        self.assertNotIn("api_key'", repr(candidates))
        snapshots = self.make_store().candidate_snapshots("chat")
        self.assertEqual([item.candidate_id for item in snapshots], ["primary", "local_backup"])

    def test_fallback_candidates_reject_duplicate_ids(self):
        store = self.make_store()
        raw = {
            "id": "duplicate",
            "label": "备用",
            "base_url": "http://127.0.0.1:1234/v1",
            "model": "local-chat",
            "enabled": True,
            "protocol": "openai_chat",
            "inherit_chat_key": False,
        }
        with self.assertRaises(ProviderConfigurationError):
            store.update_fallbacks("chat", [raw, dict(raw)])

    def test_network_proxy_is_validated_persisted_and_reloadable(self):
        store = self.make_store()
        configured = store.update_network_proxy(
            {"mode": "custom", "url": "http://127.0.0.1:7890/"}
        )
        self.assertEqual(
            configured, {"mode": "custom", "url": "http://127.0.0.1:7890"}
        )
        self.assertEqual(self.make_store().proxy_config(), configured)
        system = store.update_network_proxy({"mode": "system", "url": "ignored"})
        self.assertEqual(system, {"mode": "system", "url": ""})

    def test_network_proxy_rejects_credentials_and_unsupported_schemes(self):
        store = self.make_store()
        with self.assertRaises(ProviderConfigurationError):
            store.update_network_proxy(
                {"mode": "custom", "url": "http://user:secret@127.0.0.1:7890"}
            )
        with self.assertRaises(ProviderConfigurationError):
            store.update_network_proxy(
                {"mode": "custom", "url": "socks5://127.0.0.1:1080"}
            )

    def test_invalid_capability_protocol_and_rag_overlap_are_rejected(self):
        store = self.make_store()
        with self.assertRaises(ProviderConfigurationError):
            store.update_profile(
                "embedding",
                base_url="https://api.openai.com/v1",
                model="text-embedding-3-small",
                enabled=True,
                protocol="openai_chat",
                inherit_chat_key=True,
            )
        with self.assertRaises(ProviderConfigurationError):
            store.update_rag({"chunk_size": 500, "chunk_overlap": 500})

    @unittest.skipUnless(platform.system() == "Windows", "Windows DPAPI required")
    def test_multiple_capability_keys_share_one_redacted_encrypted_bundle(self):
        chat_key = "sk-test-chat-not-a-real-credential"
        vision_key = "sk-test-vision-not-a-real-credential"
        store = self.make_store()
        store.update(
            base_url="https://api.openai.com/v1",
            model="gpt-4.1-mini",
            api_key=chat_key,
        )
        store.update_profile(
            "vision",
            base_url="https://api.openai.com/v1",
            model="gpt-4.1-mini",
            api_key=vision_key,
            enabled=True,
            protocol="openai_chat_vision",
            inherit_chat_key=False,
        )
        ciphertext = Path(self.config.provider_credential_path).read_bytes()
        self.assertNotIn(chat_key.encode(), ciphertext)
        self.assertNotIn(vision_key.encode(), ciphertext)
        rebuilt = self.make_store()
        self.assertEqual(rebuilt.profile_snapshot("chat").api_key, chat_key)
        self.assertEqual(rebuilt.profile_snapshot("vision").api_key, vision_key)
        rendered = repr(rebuilt.status())
        self.assertNotIn(chat_key, rendered)
        self.assertNotIn(vision_key, rendered)

    @unittest.skipUnless(platform.system() == "Windows", "Windows DPAPI required")
    def test_fallback_key_is_encrypted_and_bound_to_stable_candidate_id(self):
        secret = "sk-test-fallback-not-a-real-credential"
        store = self.make_store()
        store.update_fallbacks(
            "vision",
            [{
                "id": "vision_backup",
                "label": "视觉备用",
                "base_url": "https://api.openai.com/v1",
                "model": "gpt-4.1-mini",
                "enabled": True,
                "protocol": "openai_chat_vision",
                "inherit_chat_key": False,
                "api_key": secret,
            }],
        )
        ciphertext = Path(self.config.provider_credential_path).read_bytes()
        self.assertNotIn(secret.encode("utf-8"), ciphertext)
        rebuilt = self.make_store()
        self.assertEqual(rebuilt.candidate_snapshots("vision")[1].api_key, secret)
        self.assertNotIn(secret, repr(rebuilt.status()))

    @unittest.skipUnless(platform.system() == "Windows", "Windows DPAPI required")
    def test_dpapi_round_trip_never_exposes_key_in_status_or_ciphertext(self):
        secret = "sk-test-this-is-not-a-real-credential"
        store = self.make_store()
        status = store.update(
            base_url="https://api.openai.com/v1",
            model="gpt-4.1-mini",
            api_key=secret,
        )
        self.assertNotIn(secret, repr(status))
        self.assertTrue(status["api_key_configured"])
        ciphertext = Path(self.config.provider_credential_path).read_bytes()
        self.assertNotIn(secret.encode("utf-8"), ciphertext)
        rebuilt = self.make_store()
        self.assertEqual(rebuilt.snapshot().api_key, secret)
        rebuilt.update(
            base_url="https://api.openai.com/v1",
            model="gpt-4.1-mini",
            clear_api_key=True,
        )
        self.assertFalse(Path(self.config.provider_credential_path).exists())

    @unittest.skipUnless(platform.system() == "Windows", "Windows DPAPI required")
    def test_failed_credential_stage_preserves_previous_files_and_runtime(self):
        store = self.make_store()
        store.update(
            base_url="https://api.deepseek.com/v1",
            model="deepseek-chat",
        )
        settings_path = Path(self.config.provider_settings_path)
        old_settings = settings_path.read_bytes()
        old_snapshot = store.snapshot()
        original_writer = store._atomic_write_bytes

        def fail_credential_stage(path: Path, value: bytes) -> None:
            if path.name.endswith(".dpapi.pending"):
                raise OSError("simulated credential write failure")
            original_writer(path, value)

        with patch.object(store, "_atomic_write_bytes", fail_credential_stage):
            with self.assertRaises(ProviderConfigurationError):
                store.update(
                    base_url="https://api.openai.com/v1",
                    model="gpt-4.1-mini",
                    api_key="sk-test-this-is-not-a-real-credential",
                )
        self.assertEqual(settings_path.read_bytes(), old_settings)
        self.assertEqual(store.snapshot(), old_snapshot)
        self.assertFalse(Path(self.config.provider_credential_path).exists())

    @unittest.skipUnless(platform.system() == "Windows", "Windows DPAPI required")
    def test_failed_second_commit_rolls_back_credential_and_settings(self):
        first_key = "sk-test-first-not-a-real-credential"
        second_key = "sk-test-second-not-a-real-credential"
        store = self.make_store()
        store.update(
            base_url="https://api.deepseek.com/v1",
            model="deepseek-chat",
            api_key=first_key,
        )
        settings_path = Path(self.config.provider_settings_path)
        credential_path = Path(self.config.provider_credential_path)
        old_settings = settings_path.read_bytes()
        old_credential = credential_path.read_bytes()
        old_snapshot = store.snapshot()
        original_replace = os.replace

        def fail_settings_commit(source, destination):
            source_path = Path(source)
            destination_path = Path(destination)
            if (
                source_path.name == settings_path.name + ".pending"
                and destination_path.name == settings_path.name
            ):
                raise OSError("simulated settings commit failure")
            original_replace(source, destination)

        with patch(
            "spring_haven_core.provider_settings.os.replace",
            side_effect=fail_settings_commit,
        ):
            with self.assertRaises(ProviderConfigurationError):
                store.update(
                    base_url="https://api.openai.com/v1",
                    model="gpt-4.1-mini",
                    api_key=second_key,
                )
        self.assertEqual(settings_path.read_bytes(), old_settings)
        self.assertEqual(credential_path.read_bytes(), old_credential)
        self.assertEqual(store.snapshot(), old_snapshot)

    @unittest.skipUnless(platform.system() == "Windows", "Windows DPAPI required")
    def test_clearing_saved_key_falls_back_to_environment_key(self):
        environment_key = "sk-test-environment-not-a-real-credential"
        with patch.dict(
            os.environ,
            {"SPRING_HAVEN_LLM_API_KEY": environment_key},
        ):
            store = self.make_store()
            store.update(
                base_url="https://api.openai.com/v1",
                model="gpt-4.1-mini",
                api_key="sk-test-saved-not-a-real-credential",
            )
            status = store.update(
                base_url="https://api.openai.com/v1",
                model="gpt-4.1-mini",
                clear_api_key=True,
            )
        self.assertEqual(store.snapshot().api_key, environment_key)
        self.assertEqual(status["credential_source"], "environment")
        self.assertFalse(status["saved_api_key_configured"])


class _ProviderWithSettings:
    def __init__(self, settings: ProviderSettingsStore):
        self.settings = settings

    async def complete(self, system_prompt, messages):
        return ProviderReply(text="unused")


class ProviderSettingsHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = patch.dict(
            os.environ,
            {
                "SPRING_HAVEN_LLM_API_KEY": "",
                "SPRING_HAVEN_LLM_BASE_URL": "",
                "SPRING_HAVEN_LLM_MODEL": "",
                "SPRING_HAVEN_TTS_API_KEY": "",
                "SPRING_HAVEN_TTS_BASE_URL": "",
                "SPRING_HAVEN_TTS_MODEL": "",
                "SPRING_HAVEN_PROXY_MODE": "",
                "SPRING_HAVEN_PROXY_URL": "",
            },
        )
        self.environment.start()
        self.config = CoreConfig(
            api_key="h" * 64,
            provider_base_url="http://127.0.0.1:1234/v1",
            provider_model="local-model",
            provider_settings_path=str(self.root / "provider.json"),
            provider_credential_path=str(self.root / "provider.dpapi"),
        )
        self.roles = make_registry(self.root)
        self.settings = ProviderSettingsStore(
            self.config,
            self.config.provider_settings_path,
            self.config.provider_credential_path,
        )
        self.service = CompanionService(
            self.roles, _ProviderWithSettings(self.settings)
        )
        self.client = TestClient(
            TestServer(build_app(self.config, self.roles, self.service))
        )
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.service.close()
        self.environment.stop()
        self.temp.cleanup()

    def headers(self) -> dict[str, str]:
        return {"X-API-Key": "h" * 64}

    async def test_status_and_update_are_authenticated_and_redacted(self):
        unauthorized = await self.client.get("/provider/status")
        self.assertEqual(unauthorized.status, 401)

        response = await self.client.post(
            "/provider/config",
            headers=self.headers(),
            json={
                "base_url": "https://api.openai.com/v1",
                "model": "gpt-4.1-mini",
                "api_key": "sk-test-this-is-not-a-real-credential",
                "persist": True,
            },
        )
        self.assertEqual(response.status, 200)
        body = await response.json()
        rendered = repr(body)
        self.assertNotIn("sk-test-this-is-not-a-real-credential", rendered)
        self.assertTrue(body["data"]["api_key_configured"])
        self.assertEqual(body["data"]["model"], "gpt-4.1-mini")

    async def test_clear_requires_an_explicit_boolean(self):
        response = await self.client.post(
            "/provider/config",
            headers=self.headers(),
            json={
                "base_url": "http://127.0.0.1:1234/v1",
                "model": "local-model",
                "clear_api_key": "yes",
            },
        )
        self.assertEqual(response.status, 400)

    async def test_advanced_profile_endpoint_is_redacted(self):
        response = await self.client.post(
            "/providers/config",
            headers=self.headers(),
            json={
                "capability": "embedding",
                "base_url": "https://api.openai.com/v1",
                "model": "text-embedding-3-small",
                "api_key": "sk-test-embedding-not-a-real-credential",
                "enabled": True,
                "protocol": "openai_embeddings",
                "inherit_chat_key": False,
                "persist": True,
            },
        )
        self.assertEqual(response.status, 200)
        body = await response.json()
        self.assertNotIn("sk-test-embedding-not-a-real-credential", repr(body))
        self.assertEqual(body["data"]["capability"], "embedding")
        status = await self.client.get("/providers/status", headers=self.headers())
        status_body = await status.json()
        self.assertTrue(status_body["data"]["profiles"]["embedding"]["enabled"])

    async def test_visual_profile_accepts_explicit_public_http_relay(self):
        response = await self.client.post(
            "/providers/config",
            headers=self.headers(),
            json={
                "capability": "vision",
                "base_url": "http://8.8.8.8:8080/v1",
                "model": "gpt-4.1-mini",
                "enabled": True,
                "protocol": "openai_chat_vision",
                "inherit_chat_key": True,
                "allow_insecure_http": True,
                "persist": True,
            },
        )
        self.assertEqual(response.status, 200)
        body = await response.json()
        self.assertTrue(body["data"]["allow_insecure_http"])
        self.assertEqual(body["data"]["transport_security"], "plaintext_http")

    async def test_network_proxy_endpoint_updates_redacted_provider_status(self):
        response = await self.client.post(
            "/network/proxy",
            headers=self.headers(),
            json={"mode": "custom", "url": "http://127.0.0.1:7890"},
        )
        self.assertEqual(response.status, 200)
        body = await response.json()
        self.assertEqual(
            body["data"]["network_proxy"],
            {"mode": "custom", "url": "http://127.0.0.1:7890"},
        )
        status = await self.client.get("/providers/status", headers=self.headers())
        status_body = await status.json()
        self.assertEqual(
            status_body["data"]["network_proxy"]["mode"], "custom"
        )

    async def test_fallback_endpoint_is_authenticated_ordered_and_redacted(self):
        secret = "sk-test-fallback-http-not-a-real-credential"
        response = await self.client.post(
            "/providers/fallbacks",
            headers=self.headers(),
            json={
                "capability": "chat",
                "candidates": [{
                    "id": "backup",
                    "label": "备用聊天",
                    "base_url": "http://127.0.0.1:1234/v1",
                    "model": "backup-model",
                    "enabled": True,
                    "protocol": "openai_chat",
                    "inherit_chat_key": False,
                    "api_key": secret,
                }],
            },
        )
        self.assertEqual(response.status, 200)
        body = await response.json()
        self.assertNotIn(secret, repr(body))
        self.assertEqual(body["data"]["candidates"][0]["id"], "backup")
        status = await self.client.get("/providers/status", headers=self.headers())
        status_body = await status.json()
        self.assertEqual(status_body["data"]["fallbacks"]["chat"][0]["model"], "backup-model")


if __name__ == "__main__":
    unittest.main()
