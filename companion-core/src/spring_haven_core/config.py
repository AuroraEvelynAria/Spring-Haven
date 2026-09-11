from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class ConfigurationError(ValueError):
    """Raised when local runtime configuration is unsafe or incomplete."""


@dataclass(frozen=True)
class CoreConfig:
    host: str = "127.0.0.1"
    port: int = 18340
    api_key: str = ""
    provider_base_url: str = "https://api.deepseek.com/v1"
    provider_model: str = "deepseek-chat"
    provider_api_key: str = ""
    provider_settings_path: str = "user_data/provider_settings.json"
    provider_credential_path: str = "user_data/provider_key.dpapi"
    request_timeout_seconds: int = 90
    max_output_tokens: int = 1200
    temperature: float = 0.8
    memory_db_path: str = "user_data/heartloom.sqlite3"
    rag_db_path: str = "user_data/knowledge.sqlite3"
    memory_recall_limit: int = 8
    memory_recent_messages: int = 24
    memory_organizer_enabled: bool = True
    memory_organizer_max_entries: int = 3
    weather_location: str = ""  # 城市名或 "lat,lon"；空则不用真实天气
    rag_import_allow_private: bool = False  # 允许 web 导入指向私网/环回地址

    @classmethod
    def load(cls, path: str | Path) -> "CoreConfig":
        source = Path(path)
        raw: dict[str, Any] = {}
        if source.exists():
            try:
                parsed = json.loads(source.read_text(encoding="utf-8-sig"))
            except json.JSONDecodeError as exc:
                raise ConfigurationError(f"core config is not valid JSON: {exc}") from exc
            if not isinstance(parsed, dict):
                raise ConfigurationError("core config must be a JSON object")
            raw = parsed

        memory_path_value = os.getenv(
            "SPRING_HAVEN_MEMORY_DB",
            str(raw.get("memory_db_path", "heartloom.sqlite3")),
        ).strip()
        memory_path = Path(memory_path_value)
        if not memory_path.is_absolute():
            memory_path = source.parent / memory_path
        rag_path_value = os.getenv(
            "SPRING_HAVEN_RAG_DB",
            str(raw.get("rag_db_path", "knowledge.sqlite3")),
        ).strip()
        rag_path = Path(rag_path_value)
        if not rag_path.is_absolute():
            rag_path = source.parent / rag_path

        config = cls(
            host="127.0.0.1",
            port=_bounded_int(raw.get("port", 18340), 1024, 65535, "port"),
            api_key=os.getenv(
                "SPRING_HAVEN_CORE_KEY", str(raw.get("api_key", ""))
            ).strip(),
            provider_base_url=os.getenv(
                "SPRING_HAVEN_LLM_BASE_URL",
                str(raw.get("provider_base_url", cls.provider_base_url)),
            ).strip().rstrip("/"),
            provider_model=os.getenv(
                "SPRING_HAVEN_LLM_MODEL",
                str(raw.get("provider_model", cls.provider_model)),
            ).strip(),
            provider_api_key=os.getenv(
                "SPRING_HAVEN_LLM_API_KEY",
                str(raw.get("provider_api_key", "")),
            ).strip(),
            provider_settings_path=str((source.parent / "provider_settings.json").resolve()),
            provider_credential_path=str((source.parent / "provider_key.dpapi").resolve()),
            request_timeout_seconds=_bounded_int(
                raw.get("request_timeout_seconds", 90), 5, 180, "request timeout"
            ),
            max_output_tokens=_bounded_int(
                raw.get("max_output_tokens", 1200), 64, 8192, "max output tokens"
            ),
            temperature=_bounded_float(
                raw.get("temperature", 0.8), 0.0, 2.0, "temperature"
            ),
            memory_db_path=str(memory_path.resolve()),
            rag_db_path=str(rag_path.resolve()),
            memory_recall_limit=_bounded_int(
                raw.get("memory_recall_limit", 8), 1, 24, "memory recall limit"
            ),
            memory_recent_messages=_bounded_int(
                raw.get("memory_recent_messages", 24), 4, 128, "recent message limit"
            ),
            memory_organizer_enabled=_as_bool(
                os.getenv(
                    "SPRING_HAVEN_MEMORY_ORGANIZER",
                    raw.get("memory_organizer_enabled", True),
                ),
                "memory organizer enabled",
            ),
            memory_organizer_max_entries=_bounded_int(
                raw.get("memory_organizer_max_entries", 3),
                1,
                5,
                "memory organizer max entries",
            ),
            weather_location=str(raw.get("weather_location", "")).strip()[:120],
            rag_import_allow_private=bool(
                raw.get("rag_import_allow_private", False)
            ),
        )
        if len(config.api_key) < 32:
            raise ConfigurationError(
                "api_key must contain at least 32 characters; run the bootstrap tool"
            )
        if not config.provider_base_url.startswith(("http://", "https://")):
            raise ConfigurationError("provider_base_url must use http or https")
        if not config.provider_model:
            raise ConfigurationError("provider_model is required")
        return config

    @property
    def provider_configured(self) -> bool:
        return bool(self.provider_base_url and self.provider_model)


def _bounded_int(value: Any, minimum: int, maximum: int, field: str) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ConfigurationError(f"{field} must be an integer") from exc
    if not minimum <= parsed <= maximum:
        raise ConfigurationError(f"{field} must be between {minimum} and {maximum}")
    return parsed


def _bounded_float(value: Any, minimum: float, maximum: float, field: str) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise ConfigurationError(f"{field} must be numeric") from exc
    if not minimum <= parsed <= maximum:
        raise ConfigurationError(f"{field} must be between {minimum} and {maximum}")
    return parsed


def _as_bool(value: Any, field: str) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ConfigurationError(f"{field} must be boolean")
