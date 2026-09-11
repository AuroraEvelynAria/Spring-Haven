from __future__ import annotations

import ctypes
import ipaddress
import json
import os
import platform
import re
import threading
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .config import CoreConfig


class ProviderConfigurationError(ValueError):
    """A provider setting or credential could not be validated or persisted."""


@dataclass(frozen=True)
class ProviderSnapshot:
    base_url: str
    model: str
    api_key: str


@dataclass(frozen=True)
class CapabilitySnapshot:
    capability: str
    base_url: str
    model: str
    api_key: str
    enabled: bool
    protocol: str
    inherit_chat_key: bool
    allow_insecure_http: bool
    candidate_id: str = "primary"
    label: str = "Primary"
    is_fallback: bool = False


CAPABILITIES = ("chat", "vision", "embedding", "rerank", "asr", "tts")
CAPABILITY_PROTOCOLS = {
    "chat": {"openai_chat"},
    "vision": {"openai_chat_vision"},
    "embedding": {"openai_embeddings"},
    "rerank": {"jina_v1", "cohere_v2"},
    "asr": {"openai_transcriptions"},
    "tts": {"openai_speech", "gpt_sovits_get"},
}
# 已移除的旧协议（Open-LLM-VTuber）：旧存档加载时静默回退到默认协议，避免阻断启动。
REMOVED_PROTOCOL_FALLBACKS = {
    "open_llm_vtuber_asr": "openai_transcriptions",
    "open_llm_vtuber_tts_ws": "openai_speech",
}

CAPABILITY_ENV_PREFIX = {
    "chat": "SPRING_HAVEN_LLM",
    "vision": "SPRING_HAVEN_VISION",
    "embedding": "SPRING_HAVEN_EMBEDDING",
    "rerank": "SPRING_HAVEN_RERANK",
    "asr": "SPRING_HAVEN_ASR",
    "tts": "SPRING_HAVEN_TTS",
}
DEFAULT_PROFILES = {
    "vision": {
        "base_url": "https://api.openai.com/v1",
        "model": "gpt-4.1-mini",
        "enabled": False,
        "protocol": "openai_chat_vision",
        "inherit_chat_key": True,
        "allow_insecure_http": False,
    },
    "embedding": {
        "base_url": "https://api.openai.com/v1",
        "model": "text-embedding-3-small",
        "enabled": False,
        "protocol": "openai_embeddings",
        "inherit_chat_key": True,
        "allow_insecure_http": False,
    },
    "rerank": {
        "base_url": "https://api.jina.ai/v1",
        "model": "jina-reranker-v2-base-multilingual",
        "enabled": False,
        "protocol": "jina_v1",
        "inherit_chat_key": False,
        "allow_insecure_http": False,
    },
    "asr": {
        "base_url": "http://127.0.0.1:12393",
        "model": "whisper-1",
        "enabled": False,
        "protocol": "openai_transcriptions",
        "inherit_chat_key": False,
        "allow_insecure_http": False,
    },
    "tts": {
        "base_url": "http://127.0.0.1:8880/v1",
        "model": "kokoro",
        "enabled": False,
        "protocol": "openai_speech",
        "inherit_chat_key": False,
        "allow_insecure_http": False,
    },
}
DEFAULT_RAG = {
    "enabled": False,
    "use_embeddings": True,
    "use_rerank": False,
    "top_k": 6,
    "candidate_limit": 24,
    "chunk_size": 900,
    "chunk_overlap": 120,
}
DEFAULT_NETWORK_PROXY = {
    "mode": "direct",
    "url": "",
}
MAX_FALLBACK_CANDIDATES = 6
FALLBACK_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$")


class ProviderSettingsStore:
    """Multi-capability provider registry with a DPAPI-protected key bundle."""

    def __init__(
        self,
        config: CoreConfig,
        settings_path: str | Path,
        credential_path: str | Path,
    ):
        self.settings_path = Path(settings_path).resolve()
        self.credential_path = Path(credential_path).resolve()
        self.settings_path.parent.mkdir(parents=True, exist_ok=True)
        self.credential_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        saved = self._load_settings()
        saved_profiles = saved.get("profiles", {})
        if not isinstance(saved_profiles, dict):
            saved_profiles = {}
        legacy_chat = {
            "base_url": saved.get("base_url", config.provider_base_url),
            "model": saved.get("model", config.provider_model),
            "enabled": True,
            "protocol": "openai_chat",
            "inherit_chat_key": False,
            "allow_insecure_http": False,
        }
        self._profiles: dict[str, dict[str, Any]] = {}
        self._keys: dict[str, str] = {capability: "" for capability in CAPABILITIES}
        self._persisted_keys: dict[str, str] = {}
        self._credential_sources: dict[str, str] = {
            capability: "none" for capability in CAPABILITIES
        }
        self._fallback_keys: dict[str, str] = {
            capability: "" for capability in CAPABILITIES
        }
        self._fallback_sources: dict[str, str] = {
            capability: "none" for capability in CAPABILITIES
        }
        self._fallback_profiles: dict[str, list[dict[str, Any]]] = {
            capability: [] for capability in CAPABILITIES
        }
        self._candidate_keys: dict[str, dict[str, str]] = {
            capability: {} for capability in CAPABILITIES
        }
        self._persisted_candidate_keys: dict[str, dict[str, str]] = {
            capability: {} for capability in CAPABILITIES
        }
        self._candidate_credential_sources: dict[str, dict[str, str]] = {
            capability: {} for capability in CAPABILITIES
        }

        for capability in CAPABILITIES:
            defaults = legacy_chat if capability == "chat" else DEFAULT_PROFILES[capability]
            raw_profile = saved_profiles.get(capability, defaults)
            if not isinstance(raw_profile, dict):
                raw_profile = defaults
            prefix = CAPABILITY_ENV_PREFIX[capability]
            environment_base = os.getenv(prefix + "_BASE_URL", "").strip()
            environment_model = os.getenv(prefix + "_MODEL", "").strip()
            environment_key = os.getenv(prefix + "_API_KEY", "").strip()
            environment_allow_http = os.getenv(
                prefix + "_ALLOW_INSECURE_HTTP", ""
            ).strip()
            enabled_value: Any = raw_profile.get("enabled", defaults["enabled"])
            environment_enabled = os.getenv(prefix + "_ENABLED", "").strip()
            if environment_enabled:
                enabled_value = self._validate_bool(environment_enabled, "enabled")
            elif capability != "chat" and (
                environment_base or environment_model or environment_key
            ):
                enabled_value = True
            self._profiles[capability] = self._validated_profile(
                capability,
                base_url=environment_base
                or raw_profile.get("base_url", defaults["base_url"]),
                model=environment_model or raw_profile.get("model", defaults["model"]),
                enabled=True if capability == "chat" else enabled_value,
                protocol=REMOVED_PROTOCOL_FALLBACKS.get(
                    str(raw_profile.get("protocol", defaults["protocol"])),
                    str(raw_profile.get("protocol", defaults["protocol"])),
                ),
                inherit_chat_key=False
                if capability == "chat"
                else raw_profile.get(
                    "inherit_chat_key", defaults["inherit_chat_key"]
                ),
                allow_insecure_http=(
                    self._validate_bool(
                        environment_allow_http, "allow_insecure_http"
                    )
                    if environment_allow_http
                    else raw_profile.get(
                        "allow_insecure_http",
                        defaults.get("allow_insecure_http", False),
                    )
                ),
            )
            if environment_key:
                validated_environment_key = self._validate_key(environment_key)
                self._fallback_keys[capability] = validated_environment_key
                self._fallback_sources[capability] = "environment"

        saved_fallbacks = saved.get("fallbacks", {})
        if not isinstance(saved_fallbacks, dict):
            saved_fallbacks = {}
        for capability in CAPABILITIES:
            raw_candidates = saved_fallbacks.get(capability, [])
            if not isinstance(raw_candidates, list):
                raw_candidates = []
            self._fallback_profiles[capability] = self._validated_fallbacks(
                capability, raw_candidates
            )

        config_key = str(config.provider_api_key).strip()
        if not self._fallback_keys["chat"] and config_key:
            self._fallback_keys["chat"] = self._validate_key(config_key)
            self._fallback_sources["chat"] = "config"

        if self.credential_path.is_file() and self.persistence_supported:
            try:
                plaintext = _dpapi_unprotect(self.credential_path.read_bytes()).decode(
                    "utf-8"
                )
                credential_bundle = self._decode_credential_bundle(plaintext)
                self._persisted_keys = credential_bundle["keys"]
                self._persisted_candidate_keys = credential_bundle["fallback_keys"]
            except Exception as exc:
                raise ProviderConfigurationError(
                    "saved provider credential could not be decrypted"
                ) from exc

        for capability in CAPABILITIES:
            if self._fallback_sources[capability] == "environment":
                self._keys[capability] = self._fallback_keys[capability]
                self._credential_sources[capability] = "environment"
            elif capability in self._persisted_keys:
                self._keys[capability] = self._persisted_keys[capability]
                self._credential_sources[capability] = "encrypted_store"
            elif self._fallback_keys[capability]:
                self._keys[capability] = self._fallback_keys[capability]
                self._credential_sources[capability] = self._fallback_sources[capability]
            valid_candidate_ids = {
                str(item["id"]) for item in self._fallback_profiles[capability]
            }
            for candidate_id, key in self._persisted_candidate_keys.get(
                capability, {}
            ).items():
                if candidate_id in valid_candidate_ids:
                    self._candidate_keys[capability][candidate_id] = key
                    self._candidate_credential_sources[capability][candidate_id] = (
                        "encrypted_store"
                    )

        raw_rag = saved.get("rag", {})
        self._rag = self._validated_rag(raw_rag if isinstance(raw_rag, dict) else {})
        raw_proxy = saved.get("network_proxy", {})
        if not isinstance(raw_proxy, dict):
            raw_proxy = {}
        environment_mode = os.getenv("SPRING_HAVEN_PROXY_MODE", "").strip()
        environment_url = os.getenv("SPRING_HAVEN_PROXY_URL", "").strip()
        if environment_mode or environment_url:
            raw_proxy = {
                "mode": environment_mode or ("custom" if environment_url else "direct"),
                "url": environment_url,
            }
        self._network_proxy = self._validated_network_proxy(raw_proxy)
        self._sync_chat_aliases()

    @property
    def persistence_supported(self) -> bool:
        return platform.system() == "Windows"

    def snapshot(self) -> ProviderSnapshot:
        with self._lock:
            chat = self.profile_snapshot("chat")
            return ProviderSnapshot(chat.base_url, chat.model, chat.api_key)

    def profile_snapshot(self, capability: str) -> CapabilitySnapshot:
        normalized = self._validate_capability(capability)
        with self._lock:
            profile = self._profiles[normalized]
            api_key = self._keys[normalized]
            if (
                not api_key
                and normalized != "chat"
                and bool(profile["inherit_chat_key"])
            ):
                api_key = self._keys["chat"]
            return CapabilitySnapshot(
                capability=normalized,
                base_url=str(profile["base_url"]),
                model=str(profile["model"]),
                api_key=api_key,
                enabled=bool(profile["enabled"]),
                protocol=str(profile["protocol"]),
                inherit_chat_key=bool(profile["inherit_chat_key"]),
                allow_insecure_http=bool(profile.get("allow_insecure_http", False)),
            )

    def candidate_snapshots(self, capability: str) -> list[CapabilitySnapshot]:
        normalized = self._validate_capability(capability)
        with self._lock:
            result = [self.profile_snapshot(normalized)]
            for candidate in self._fallback_profiles[normalized]:
                if not bool(candidate["enabled"]):
                    continue
                candidate_id = str(candidate["id"])
                api_key = (
                    result[0].api_key
                    if bool(candidate["inherit_chat_key"])
                    else self._candidate_keys[normalized].get(candidate_id, "")
                )
                result.append(
                    CapabilitySnapshot(
                        capability=normalized,
                        base_url=str(candidate["base_url"]),
                        model=str(candidate["model"]),
                        api_key=api_key,
                        enabled=True,
                        protocol=str(candidate["protocol"]),
                        inherit_chat_key=bool(candidate["inherit_chat_key"]),
                        allow_insecure_http=bool(
                            candidate.get("allow_insecure_http", False)
                        ),
                        candidate_id=candidate_id,
                        label=str(candidate["label"]),
                        is_fallback=True,
                    )
                )
            return result

    def rag_config(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._rag)

    def proxy_config(self) -> dict[str, str]:
        with self._lock:
            return dict(self._network_proxy)

    def status(self) -> dict[str, Any]:
        with self._lock:
            profiles = {
                capability: self._profile_status(capability)
                for capability in CAPABILITIES
            }
            chat = profiles["chat"]
            return {
                "base_url": chat["base_url"],
                "model": chat["model"],
                "api_key_configured": chat["api_key_configured"],
                "saved_api_key_configured": chat["saved_api_key_configured"],
                "credential_source": chat["credential_source"],
                "credential_persistence": (
                    "windows_dpapi" if self.persistence_supported else "memory_only"
                ),
                "provider_host": chat["provider_host"],
                "requires_restart": False,
                "profiles": profiles,
                "fallbacks": {
                    capability: self._fallback_status(capability)
                    for capability in CAPABILITIES
                },
                "rag": dict(self._rag),
                "network_proxy": dict(self._network_proxy),
            }

    def update_fallbacks(self, capability: str, raw: Any) -> list[dict[str, Any]]:
        normalized = self._validate_capability(capability)
        if not isinstance(raw, list):
            raise ProviderConfigurationError("provider fallbacks must be an array")
        new_profiles = self._validated_fallbacks(normalized, raw)
        submitted_keys: dict[str, str] = {}
        clear_ids: set[str] = set()
        for index, item in enumerate(raw):
            if not isinstance(item, dict):
                continue
            candidate_id = str(item.get("id", f"fallback_{index + 1}")).strip()
            clear_value = item.get("clear_api_key", False)
            if not isinstance(clear_value, bool):
                raise ProviderConfigurationError("fallback clear_api_key must be boolean")
            if clear_value:
                clear_ids.add(candidate_id)
            raw_key = item.get("api_key")
            if raw_key is not None and str(raw_key).strip():
                if clear_value:
                    raise ProviderConfigurationError(
                        "fallback api_key and clear_api_key cannot be used together"
                    )
                submitted_keys[candidate_id] = self._validate_key(raw_key)
        if submitted_keys and not self.persistence_supported:
            raise ProviderConfigurationError(
                "secure credential persistence is unavailable on this platform"
            )
        with self._lock:
            previous_profiles = [dict(item) for item in self._fallback_profiles[normalized]]
            previous_keys = {
                key: dict(value) for key, value in self._candidate_keys.items()
            }
            previous_persisted = {
                key: dict(value)
                for key, value in self._persisted_candidate_keys.items()
            }
            previous_sources = {
                key: dict(value)
                for key, value in self._candidate_credential_sources.items()
            }
            valid_ids = {str(item["id"]) for item in new_profiles}
            self._fallback_profiles[normalized] = new_profiles
            self._candidate_keys[normalized] = {
                key: value
                for key, value in self._candidate_keys[normalized].items()
                if key in valid_ids and key not in clear_ids
            }
            self._persisted_candidate_keys[normalized] = {
                key: value
                for key, value in self._persisted_candidate_keys[normalized].items()
                if key in valid_ids and key not in clear_ids
            }
            self._candidate_credential_sources[normalized] = {
                key: value
                for key, value in self._candidate_credential_sources[normalized].items()
                if key in valid_ids and key not in clear_ids
            }
            for candidate_id, key in submitted_keys.items():
                if candidate_id not in valid_ids:
                    raise ProviderConfigurationError("fallback API key has no candidate")
                self._candidate_keys[normalized][candidate_id] = key
                self._persisted_candidate_keys[normalized][candidate_id] = key
                self._candidate_credential_sources[normalized][candidate_id] = (
                    "encrypted_store"
                )
            try:
                self._persist_update(
                    self._settings_document(),
                    persisted_credentials=self._credential_document(),
                )
            except Exception as exc:
                self._fallback_profiles[normalized] = previous_profiles
                self._candidate_keys = previous_keys
                self._persisted_candidate_keys = previous_persisted
                self._candidate_credential_sources = previous_sources
                raise ProviderConfigurationError(
                    "provider fallbacks could not be saved"
                ) from exc
            return self._fallback_status(normalized)

    def update(
        self,
        *,
        base_url: Any,
        model: Any,
        api_key: Any = None,
        clear_api_key: bool = False,
        persist: bool = True,
        allow_insecure_http: Any = False,
    ) -> dict[str, Any]:
        self.update_profile(
            "chat",
            base_url=base_url,
            model=model,
            api_key=api_key,
            clear_api_key=clear_api_key,
            persist=persist,
            enabled=True,
            protocol="openai_chat",
            inherit_chat_key=False,
            allow_insecure_http=allow_insecure_http,
        )
        return self.status()

    def update_profile(
        self,
        capability: str,
        *,
        base_url: Any,
        model: Any,
        api_key: Any = None,
        clear_api_key: bool = False,
        persist: bool = True,
        enabled: Any = True,
        protocol: Any = "",
        inherit_chat_key: Any = False,
        allow_insecure_http: Any = None,
    ) -> dict[str, Any]:
        normalized_capability = self._validate_capability(capability)
        previous_profile = self._profiles[normalized_capability]
        normalized_profile = self._validated_profile(
            normalized_capability,
            base_url=base_url,
            model=model,
            enabled=True if normalized_capability == "chat" else enabled,
            protocol=protocol or previous_profile["protocol"],
            inherit_chat_key=False
            if normalized_capability == "chat"
            else inherit_chat_key,
            allow_insecure_http=(
                previous_profile.get("allow_insecure_http", False)
                if allow_insecure_http is None
                else allow_insecure_http
            ),
        )
        if clear_api_key and api_key not in {None, ""}:
            raise ProviderConfigurationError(
                "api_key and clear_api_key cannot be used together"
            )
        new_key: str | None = None
        if api_key is not None and str(api_key).strip():
            new_key = self._validate_key(str(api_key).strip())
        if persist and new_key is not None and not self.persistence_supported:
            raise ProviderConfigurationError(
                "secure credential persistence is unavailable on this platform"
            )

        with self._lock:
            previous_profiles = {
                key: dict(value) for key, value in self._profiles.items()
            }
            previous_keys = dict(self._keys)
            previous_persisted = dict(self._persisted_keys)
            previous_sources = dict(self._credential_sources)
            self._profiles[normalized_capability] = normalized_profile
            if clear_api_key:
                self._persisted_keys.pop(normalized_capability, None)
                self._keys[normalized_capability] = self._fallback_keys[
                    normalized_capability
                ]
                self._credential_sources[normalized_capability] = self._fallback_sources[
                    normalized_capability
                ]
            elif new_key is not None:
                self._keys[normalized_capability] = new_key
                self._credential_sources[normalized_capability] = (
                    "encrypted_store" if persist else "runtime"
                )
                if persist:
                    self._persisted_keys[normalized_capability] = new_key
            try:
                self._persist_update(
                    self._settings_document(),
                    persisted_credentials=(
                        self._credential_document()
                        if clear_api_key or (new_key is not None and persist)
                        else None
                    ),
                )
            except Exception as exc:
                self._profiles = previous_profiles
                self._keys = previous_keys
                self._persisted_keys = previous_persisted
                self._credential_sources = previous_sources
                self._sync_chat_aliases()
                raise ProviderConfigurationError(
                    "provider settings could not be saved"
                ) from exc
            self._sync_chat_aliases()
            return self._profile_status(normalized_capability)

    def update_rag(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise ProviderConfigurationError("rag settings must be a JSON object")
        normalized = self._validated_rag(raw)
        with self._lock:
            previous = dict(self._rag)
            self._rag = normalized
            try:
                self._persist_update(
                    self._settings_document(), persisted_credentials=None
                )
            except Exception as exc:
                self._rag = previous
                raise ProviderConfigurationError("RAG settings could not be saved") from exc
            return dict(self._rag)

    def update_network_proxy(self, raw: Any) -> dict[str, str]:
        if not isinstance(raw, dict):
            raise ProviderConfigurationError("network proxy must be a JSON object")
        normalized = self._validated_network_proxy(raw)
        with self._lock:
            previous = dict(self._network_proxy)
            self._network_proxy = normalized
            try:
                self._persist_update(
                    self._settings_document(), persisted_credentials=None
                )
            except Exception as exc:
                self._network_proxy = previous
                raise ProviderConfigurationError(
                    "network proxy settings could not be saved"
                ) from exc
            return dict(self._network_proxy)

    def _persist_update(
        self,
        settings: dict[str, Any],
        *,
        persisted_credentials: dict[str, Any] | None,
    ) -> None:
        """Stage every changed file before committing and roll back partial commits."""
        settings_stage = self.settings_path.with_name(
            self.settings_path.name + ".pending"
        )
        credential_stage = self.credential_path.with_name(
            self.credential_path.name + ".pending"
        )
        old_settings = self._read_optional_bytes(self.settings_path)
        old_credential = self._read_optional_bytes(self.credential_path)
        credential_changed = persisted_credentials is not None
        try:
            self._atomic_write_json(settings_stage, settings)
            if persisted_credentials:
                self._atomic_write_bytes(
                    credential_stage,
                    _dpapi_protect(
                        self._encode_credential_bundle(persisted_credentials).encode(
                            "utf-8"
                        )
                    ),
                )

            # Commit the credential first. If the following settings replace fails,
            # both files are restored from their in-memory snapshots.
            if persisted_credentials == {} or (
                persisted_credentials is not None
                and not persisted_credentials.get("keys")
                and not any(
                    persisted_credentials.get("fallback_keys", {}).get(capability)
                    for capability in CAPABILITIES
                )
            ):
                self.credential_path.unlink(missing_ok=True)
            elif persisted_credentials is not None:
                os.replace(credential_stage, self.credential_path)
            os.replace(settings_stage, self.settings_path)
        except Exception:
            if credential_changed:
                self._restore_optional_bytes(self.credential_path, old_credential)
            self._restore_optional_bytes(self.settings_path, old_settings)
            raise
        finally:
            for staged in (settings_stage, credential_stage):
                staged.unlink(missing_ok=True)
                staged.with_suffix(staged.suffix + ".tmp").unlink(missing_ok=True)

    def _load_settings(self) -> dict[str, Any]:
        if not self.settings_path.is_file():
            return {}
        try:
            parsed = json.loads(self.settings_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ProviderConfigurationError("provider settings file is invalid") from exc
        if not isinstance(parsed, dict):
            raise ProviderConfigurationError("provider settings must be a JSON object")
        return parsed

    def _settings_document(self) -> dict[str, Any]:
        return {
            "version": 7,
            "profiles": {
                capability: dict(self._profiles[capability])
                for capability in CAPABILITIES
            },
            "rag": dict(self._rag),
            "network_proxy": dict(self._network_proxy),
            "fallbacks": {
                capability: [dict(item) for item in self._fallback_profiles[capability]]
                for capability in CAPABILITIES
            },
        }

    def _credential_document(self) -> dict[str, Any]:
        return {
            "keys": dict(self._persisted_keys),
            "fallback_keys": {
                capability: dict(self._persisted_candidate_keys[capability])
                for capability in CAPABILITIES
            },
        }

    def _profile_status(self, capability: str) -> dict[str, Any]:
        snapshot = self.profile_snapshot(capability)
        parsed = urlparse(snapshot.base_url)
        source = self._credential_sources[capability]
        inherited = False
        if not snapshot.api_key:
            source = "none"
        elif not self._keys[capability] and snapshot.inherit_chat_key:
            source = "inherited_chat"
            inherited = True
        return {
            "capability": capability,
            "base_url": snapshot.base_url,
            "model": snapshot.model,
            "enabled": snapshot.enabled,
            "protocol": snapshot.protocol,
            "inherit_chat_key": snapshot.inherit_chat_key,
            "allow_insecure_http": snapshot.allow_insecure_http,
            "transport_security": (
                "plaintext_http"
                if urlparse(snapshot.base_url).scheme == "http"
                else "https"
            ),
            "api_key_configured": bool(snapshot.api_key),
            "saved_api_key_configured": capability in self._persisted_keys,
            "credential_source": source,
            "credential_inherited": inherited,
            "provider_host": parsed.hostname or "",
            "request_ready": bool(snapshot.enabled and snapshot.base_url and snapshot.model),
        }

    def _fallback_status(self, capability: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for priority, candidate in enumerate(self._fallback_profiles[capability], 1):
            candidate_id = str(candidate["id"])
            source = self._candidate_credential_sources[capability].get(
                candidate_id, "none"
            )
            inherited = False
            configured = bool(self._candidate_keys[capability].get(candidate_id, ""))
            if bool(candidate["inherit_chat_key"]):
                configured = bool(self.profile_snapshot(capability).api_key)
                source = "inherited_primary" if configured else "none"
                inherited = configured
            parsed = urlparse(str(candidate["base_url"]))
            result.append(
                {
                    **dict(candidate),
                    "capability": capability,
                    "priority": priority,
                    "api_key_configured": configured,
                    "saved_api_key_configured": candidate_id
                    in self._persisted_candidate_keys[capability],
                    "credential_source": source,
                    "credential_inherited": inherited,
                    "provider_host": parsed.hostname or "",
                    "transport_security": (
                        "plaintext_http" if parsed.scheme == "http" else "https"
                    ),
                    "request_ready": bool(
                        candidate["enabled"]
                        and candidate["base_url"]
                        and candidate["model"]
                    ),
                }
            )
        return result

    def _sync_chat_aliases(self) -> None:
        chat = self._profiles["chat"]
        self._base_url = str(chat["base_url"])
        self._model = str(chat["model"])
        self._api_key = self._keys["chat"]
        self._credential_source = self._credential_sources["chat"]
        self._fallback_api_key = self._fallback_keys["chat"]
        self._fallback_credential_source = self._fallback_sources["chat"]

    @staticmethod
    def _decode_credential_bundle(plaintext: str) -> dict[str, Any]:
        try:
            parsed = json.loads(plaintext)
        except ValueError:
            return {
                "keys": {"chat": ProviderSettingsStore._validate_key(plaintext)},
                "fallback_keys": {capability: {} for capability in CAPABILITIES},
            }
        if not isinstance(parsed, dict) or not isinstance(parsed.get("keys"), dict):
            return {
                "keys": {"chat": ProviderSettingsStore._validate_key(plaintext)},
                "fallback_keys": {capability: {} for capability in CAPABILITIES},
            }
        result: dict[str, str] = {}
        for capability, value in parsed["keys"].items():
            if str(capability) in CAPABILITIES and str(value).strip():
                result[str(capability)] = ProviderSettingsStore._validate_key(value)
        fallback_result: dict[str, dict[str, str]] = {
            capability: {} for capability in CAPABILITIES
        }
        raw_fallbacks = parsed.get("fallback_keys", {})
        if isinstance(raw_fallbacks, dict):
            for capability, values in raw_fallbacks.items():
                if capability not in CAPABILITIES or not isinstance(values, dict):
                    continue
                for candidate_id, value in values.items():
                    normalized_id = str(candidate_id).strip()
                    if FALLBACK_ID_PATTERN.fullmatch(normalized_id) and str(value).strip():
                        fallback_result[capability][normalized_id] = (
                            ProviderSettingsStore._validate_key(value)
                        )
        return {"keys": result, "fallback_keys": fallback_result}

    @staticmethod
    def _encode_credential_bundle(credentials: dict[str, Any]) -> str:
        keys = credentials.get("keys", {})
        fallback_keys = credentials.get("fallback_keys", {})
        return json.dumps(
            {
                "version": 3,
                "keys": {
                    capability: keys[capability]
                    for capability in CAPABILITIES
                    if capability in keys and keys[capability]
                },
                "fallback_keys": {
                    capability: {
                        candidate_id: value
                        for candidate_id, value in fallback_keys.get(capability, {}).items()
                        if FALLBACK_ID_PATTERN.fullmatch(str(candidate_id)) and value
                    }
                    for capability in CAPABILITIES
                },
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )

    @classmethod
    def _validated_fallbacks(
        cls, capability: str, raw: list[Any]
    ) -> list[dict[str, Any]]:
        if len(raw) > MAX_FALLBACK_CANDIDATES:
            raise ProviderConfigurationError("too many provider fallback candidates")
        result: list[dict[str, Any]] = []
        seen: set[str] = set()
        default_protocol = next(iter(CAPABILITY_PROTOCOLS[capability]))
        for index, item in enumerate(raw):
            if not isinstance(item, dict):
                raise ProviderConfigurationError("fallback candidate must be an object")
            candidate_id = str(item.get("id", f"fallback_{index + 1}")).strip()
            if not FALLBACK_ID_PATTERN.fullmatch(candidate_id) or candidate_id in seen:
                raise ProviderConfigurationError("fallback candidate id is invalid or duplicated")
            seen.add(candidate_id)
            profile = cls._validated_profile(
                capability,
                base_url=item.get("base_url", ""),
                model=item.get("model", ""),
                enabled=item.get("enabled", True),
                protocol=REMOVED_PROTOCOL_FALLBACKS.get(
                    str(item.get("protocol", default_protocol)),
                    str(item.get("protocol", default_protocol)),
                ),
                inherit_chat_key=item.get("inherit_chat_key", True),
                allow_insecure_http=item.get("allow_insecure_http", False),
            )
            label = str(item.get("label", f"备用 {index + 1}")).replace("\x00", " ").strip()
            if not label or len(label) > 80:
                raise ProviderConfigurationError("fallback candidate label is invalid")
            result.append({"id": candidate_id, "label": label, **profile})
        return result

    @staticmethod
    def _validate_capability(value: Any) -> str:
        normalized = str(value).strip().lower()
        if normalized not in CAPABILITIES:
            raise ProviderConfigurationError("unknown provider capability")
        return normalized

    @classmethod
    def _validated_profile(
        cls,
        capability: str,
        *,
        base_url: Any,
        model: Any,
        enabled: Any,
        protocol: Any,
        inherit_chat_key: Any,
        allow_insecure_http: Any,
    ) -> dict[str, Any]:
        normalized_protocol = str(protocol).strip()
        if normalized_protocol not in CAPABILITY_PROTOCOLS[capability]:
            raise ProviderConfigurationError(
                f"unsupported protocol for {capability} provider"
            )
        normalized_allow_http = cls._validate_bool(
            allow_insecure_http, "allow_insecure_http"
        )
        return {
            "base_url": cls._validate_base_url(
                base_url, allow_insecure_http=normalized_allow_http
            ),
            "model": cls._validate_model(model),
            "enabled": cls._validate_bool(enabled, "enabled"),
            "protocol": normalized_protocol,
            "inherit_chat_key": cls._validate_bool(
                inherit_chat_key, "inherit_chat_key"
            ),
            "allow_insecure_http": normalized_allow_http,
        }

    @classmethod
    def _validated_rag(cls, raw: dict[str, Any]) -> dict[str, Any]:
        merged = {**DEFAULT_RAG, **raw}
        result = {
            "enabled": cls._validate_bool(merged["enabled"], "rag enabled"),
            "use_embeddings": cls._validate_bool(
                merged["use_embeddings"], "rag use_embeddings"
            ),
            "use_rerank": cls._validate_bool(
                merged["use_rerank"], "rag use_rerank"
            ),
            "top_k": cls._bounded_int(merged["top_k"], 1, 20, "rag top_k"),
            "candidate_limit": cls._bounded_int(
                merged["candidate_limit"], 4, 100, "rag candidate_limit"
            ),
            "chunk_size": cls._bounded_int(
                merged["chunk_size"], 200, 4_000, "rag chunk_size"
            ),
            "chunk_overlap": cls._bounded_int(
                merged["chunk_overlap"], 0, 1_000, "rag chunk_overlap"
            ),
        }
        if result["chunk_overlap"] >= result["chunk_size"]:
            raise ProviderConfigurationError(
                "rag chunk_overlap must be smaller than chunk_size"
            )
        if result["candidate_limit"] < result["top_k"]:
            result["candidate_limit"] = result["top_k"]
        return result

    @staticmethod
    def _validated_network_proxy(raw: dict[str, Any]) -> dict[str, str]:
        merged = {**DEFAULT_NETWORK_PROXY, **raw}
        mode = str(merged.get("mode", "direct")).strip().lower()
        if mode not in {"direct", "system", "custom"}:
            raise ProviderConfigurationError(
                "network proxy mode must be direct, system or custom"
            )
        proxy_url = str(merged.get("url", "")).strip()
        if mode != "custom":
            return {"mode": mode, "url": ""}
        if not proxy_url or len(proxy_url) > 2_048:
            raise ProviderConfigurationError(
                "custom network proxy URL is required"
            )
        parsed = urlparse(proxy_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ProviderConfigurationError(
                "custom network proxy must use http or https"
            )
        if parsed.username or parsed.password:
            raise ProviderConfigurationError(
                "proxy credentials cannot be stored in the proxy URL"
            )
        if parsed.query or parsed.fragment:
            raise ProviderConfigurationError(
                "custom network proxy URL cannot contain query or fragment"
            )
        return {"mode": mode, "url": proxy_url.rstrip("/")}

    @staticmethod
    def _validate_bool(value: Any, field: str) -> bool:
        if isinstance(value, bool):
            return value
        normalized = str(value).strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
        raise ProviderConfigurationError(f"{field} must be boolean")

    @staticmethod
    def _bounded_int(value: Any, minimum: int, maximum: int, field: str) -> int:
        try:
            parsed = int(value)
        except (TypeError, ValueError) as exc:
            raise ProviderConfigurationError(f"{field} must be an integer") from exc
        if not minimum <= parsed <= maximum:
            raise ProviderConfigurationError(
                f"{field} must be between {minimum} and {maximum}"
            )
        return parsed

    @staticmethod
    def _read_optional_bytes(path: Path) -> bytes | None:
        return path.read_bytes() if path.is_file() else None

    @staticmethod
    def _restore_optional_bytes(path: Path, value: bytes | None) -> None:
        if value is None:
            path.unlink(missing_ok=True)
        else:
            ProviderSettingsStore._atomic_write_bytes(path, value)

    @staticmethod
    def _validate_base_url(
        value: Any, *, allow_insecure_http: bool = False
    ) -> str:
        normalized = str(value).strip().rstrip("/")
        if not normalized or len(normalized) > 2_048:
            raise ProviderConfigurationError("provider base URL is invalid")
        parsed = urlparse(normalized)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ProviderConfigurationError("provider base URL must use http or https")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ProviderConfigurationError(
                "provider base URL cannot contain credentials, query, or fragment"
            )
        if (
            parsed.scheme == "http"
            and not ProviderSettingsStore._is_local_or_private_host(parsed.hostname)
            and not allow_insecure_http
        ):
            raise ProviderConfigurationError(
                "remote HTTP provider requires allow_insecure_http; API keys and image data will be sent without TLS"
            )
        return normalized

    @staticmethod
    def _is_local_or_private_host(hostname: str | None) -> bool:
        normalized = str(hostname or "").strip().lower()
        if normalized in {"localhost", "localhost.localdomain"}:
            return True
        try:
            address = ipaddress.ip_address(normalized)
        except ValueError:
            return False
        return bool(address.is_loopback or address.is_private or address.is_link_local)

    @staticmethod
    def _validate_model(value: Any) -> str:
        normalized = str(value).replace("\x00", "").strip()
        if not normalized or len(normalized) > 200 or any(
            character in normalized for character in "\r\n\t"
        ):
            raise ProviderConfigurationError("provider model is invalid")
        return normalized

    @staticmethod
    def _validate_key(value: Any) -> str:
        normalized = str(value).strip()
        if len(normalized) < 8 or len(normalized) > 4_096 or any(
            character in normalized for character in "\r\n\x00"
        ):
            raise ProviderConfigurationError("provider API key is invalid")
        return normalized

    @staticmethod
    def _atomic_write_json(path: Path, value: dict[str, Any]) -> None:
        ProviderSettingsStore._atomic_write_bytes(
            path,
            (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
        )

    @staticmethod
    def _atomic_write_bytes(path: Path, value: bytes) -> None:
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_bytes(value)
        os.replace(temp, path)


class _DataBlob(ctypes.Structure):
    _fields_ = [
        ("cbData", wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_ubyte)),
    ]


def _blob(value: bytes) -> tuple[_DataBlob, Any]:
    buffer = ctypes.create_string_buffer(value)
    blob = _DataBlob(
        len(value), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte))
    )
    return blob, buffer


def _dpapi_protect(value: bytes) -> bytes:
    if platform.system() != "Windows":
        raise ProviderConfigurationError("DPAPI is only available on Windows")
    input_blob, input_buffer = _blob(value)
    entropy_blob, entropy_buffer = _blob(b"Spring-Haven-Core/provider-key/v1")
    output_blob = _DataBlob()
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(_DataBlob),
        wintypes.LPCWSTR,
        ctypes.POINTER(_DataBlob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_DataBlob),
    ]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    success = crypt32.CryptProtectData(
        ctypes.byref(input_blob),
        "Spring Haven Provider API Key",
        ctypes.byref(entropy_blob),
        None,
        None,
        0x1,
        ctypes.byref(output_blob),
    )
    _ = (input_buffer, entropy_buffer)
    if not success:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(output_blob.pbData, output_blob.cbData)
    finally:
        kernel32.LocalFree(ctypes.cast(output_blob.pbData, wintypes.HLOCAL))


def _dpapi_unprotect(value: bytes) -> bytes:
    if platform.system() != "Windows":
        raise ProviderConfigurationError("DPAPI is only available on Windows")
    input_blob, input_buffer = _blob(value)
    entropy_blob, entropy_buffer = _blob(b"Spring-Haven-Core/provider-key/v1")
    output_blob = _DataBlob()
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(_DataBlob),
        ctypes.POINTER(wintypes.LPWSTR),
        ctypes.POINTER(_DataBlob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_DataBlob),
    ]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    success = crypt32.CryptUnprotectData(
        ctypes.byref(input_blob),
        None,
        ctypes.byref(entropy_blob),
        None,
        None,
        0x1,
        ctypes.byref(output_blob),
    )
    _ = (input_buffer, entropy_buffer)
    if not success:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(output_blob.pbData, output_blob.cbData)
    finally:
        kernel32.LocalFree(ctypes.cast(output_blob.pbData, wintypes.HLOCAL))
