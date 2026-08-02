from __future__ import annotations

import base64
import binascii
import asyncio
import hmac
import json
import logging
from typing import Any
from urllib.parse import urlparse

from aiohttp import ClientSession, ClientTimeout, web

from .config import CoreConfig
from .document_import import DocumentImportError, extract_document, extract_web_document
from .memory import HeartloomStore, MemoryStoreError
from .orchestration import ConversationOrchestrator
from .provider import OpenAICompatibleProvider, ProviderError
from .provider_settings import ProviderConfigurationError, ProviderSettingsStore
from .roles import RoleConfigurationError, RoleRegistry
from .rag import KnowledgeRagStore, RagStoreError
from .service import CompanionService, RequestValidationError


LOGGER = logging.getLogger("spring_haven_core")
PROTOCOL_VERSION = 2
CONFIG_KEY = web.AppKey("config", CoreConfig)
ROLES_KEY = web.AppKey("roles", RoleRegistry)
SERVICE_KEY = web.AppKey("service", CompanionService)
ORCHESTRATOR_KEY = web.AppKey("orchestrator", ConversationOrchestrator)
PROVIDER_SETTINGS_KEY = web.AppKey("provider_settings", ProviderSettingsStore)
MAINTENANCE_TASK_KEY = web.AppKey("maintenance_task", asyncio.Task)
LIFE_TASK_KEY = web.AppKey("life_task", asyncio.Task)


def build_app(
    config: CoreConfig,
    roles: RoleRegistry,
    service: CompanionService | None = None,
) -> web.Application:
    owns_runtime = service is None
    if service is None:
        provider_settings = ProviderSettingsStore(
            config,
            config.provider_settings_path,
            config.provider_credential_path,
        )
        provider = OpenAICompatibleProvider(config, provider_settings)
        runtime = CompanionService(
            roles,
            provider,
            HeartloomStore(config.memory_db_path, roles.ids()),
            KnowledgeRagStore(config.rag_db_path, provider, roles.ids()),
            memory_recall_limit=config.memory_recall_limit,
            memory_recent_messages=config.memory_recent_messages,
            memory_organizer_enabled=config.memory_organizer_enabled,
            memory_organizer_max_entries=config.memory_organizer_max_entries,
        )
    else:
        runtime = service
        provider_settings = getattr(runtime.provider, "settings", None)
    orchestrator = ConversationOrchestrator(roles, runtime)

    @web.middleware
    async def security(request: web.Request, handler):
        supplied = request.headers.get("X-API-Key", "")
        if not hmac.compare_digest(supplied, config.api_key):
            return _error(401, "authentication failed", retryable=False)
        response: web.StreamResponse = await handler(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    app = web.Application(client_max_size=28_000_000, middlewares=[security])
    app[CONFIG_KEY] = config
    app[ROLES_KEY] = roles
    app[SERVICE_KEY] = runtime
    app[ORCHESTRATOR_KEY] = orchestrator
    if isinstance(provider_settings, ProviderSettingsStore):
        app[PROVIDER_SETTINGS_KEY] = provider_settings
    app.router.add_get("/health", _health)
    app.router.add_post("/chat", _chat)
    app.router.add_post("/orchestrate", _orchestrate)
    app.router.add_get("/conversation/policy", _conversation_policy_status)
    app.router.add_post("/conversation/policy", _conversation_policy_config)
    app.router.add_get("/provider/status", _provider_status)
    app.router.add_post("/provider/config", _provider_config)
    app.router.add_get("/providers/status", _provider_status)
    app.router.add_post("/providers/config", _provider_profile_config)
    app.router.add_post("/providers/fallbacks", _provider_fallback_config)
    app.router.add_post("/providers/diagnose", _provider_diagnose)
    app.router.add_get("/network/proxy", _network_proxy_status)
    app.router.add_post("/network/proxy", _network_proxy_config)
    app.router.add_post("/vision/analyze", _vision_analyze)
    app.router.add_post("/audio/transcribe", _audio_transcribe)
    app.router.add_post("/audio/speech", _audio_speech)
    app.router.add_get("/rag/status", _rag_status)
    app.router.add_post("/rag/config", _rag_config)
    app.router.add_get("/rag/documents", _rag_documents)
    app.router.add_post("/rag/documents", _rag_put_document)
    app.router.add_post("/rag/documents/batch", _rag_batch_documents)
    app.router.add_get("/rag/documents/{document_id}", _rag_get_document)
    app.router.add_delete("/rag/documents/{document_id}", _rag_delete_document)
    app.router.add_post("/rag/import", _rag_import_document)
    app.router.add_post("/rag/import-url", _rag_import_url)
    app.router.add_post("/rag/search", _rag_search)
    app.router.add_post("/rag/reindex", _rag_reindex)
    app.router.add_get("/memory/status", _memory_status)
    app.router.add_get("/memory/entries", _memory_entries)
    app.router.add_get("/memory/graph", _memory_graph)
    app.router.add_post("/memory/entries", _memory_put)
    app.router.add_delete("/memory/entries/{memory_id}", _memory_delete)
    app.router.add_post("/memory/recall", _memory_recall)
    app.router.add_post("/session/reset", _session_reset)
    app.router.add_post("/life/sync", _life_sync)
    app.router.add_get("/life/status", _life_status)
    app.router.add_get("/life/outbox", _life_outbox)
    app.router.add_post("/life/outbox/ack", _life_outbox_ack)
    app.router.add_get("/maintenance/status", _maintenance_status)
    app.router.add_post("/maintenance/run", _maintenance_run)
    app.router.add_get("/maintenance/backups", _maintenance_backups)
    app.router.add_post("/maintenance/backups/{name}/verify", _maintenance_backup_verify)
    if owns_runtime:
        app.on_startup.append(_start_maintenance)
        app.on_startup.append(_start_life_scheduler)
        app.on_cleanup.append(_close_runtime)
    return app


async def _health(request: web.Request) -> web.Response:
    config = request.app[CONFIG_KEY]
    roles = request.app[ROLES_KEY]
    provider_status = (
        request.app[PROVIDER_SETTINGS_KEY].status()
        if PROVIDER_SETTINGS_KEY in request.app
        else {
            "base_url": config.provider_base_url,
            "model": config.provider_model,
            "api_key_configured": bool(config.provider_api_key),
        }
    )
    return _ok(
        {
            "protocol_version": PROTOCOL_VERSION,
            "backend": "spring_haven_core",
            "host": config.host,
            "port": config.port,
            "roles": roles.ids(),
            "provider_configured": bool(
                provider_status.get("base_url") and provider_status.get("model")
            ),
            "provider": provider_status,
            "provider_runtime": request.app[SERVICE_KEY].provider_runtime_status(),
            "memory_backend": "heartloom",
            "memory_organizer_enabled": config.memory_organizer_enabled,
            "memory": request.app[SERVICE_KEY].memory_status(),
            "rag": (
                request.app[SERVICE_KEY].rag_status()
                if request.app[SERVICE_KEY].rag is not None
                else {"backend": "unavailable"}
            ),
            "maintenance": request.app[SERVICE_KEY].storage_maintenance_status(),
            "life": request.app[SERVICE_KEY].life_status(),
        }
    )


async def _provider_status(request: web.Request) -> web.Response:
    if PROVIDER_SETTINGS_KEY not in request.app:
        return _error(503, "runtime provider settings are unavailable", retryable=False)
    status = request.app[PROVIDER_SETTINGS_KEY].status()
    status["runtime"] = request.app[SERVICE_KEY].provider_runtime_status()
    return _ok(status)


async def _conversation_policy_status(request: web.Request) -> web.Response:
    return _ok(request.app[ROLES_KEY].conversation_policy_status())


async def _conversation_policy_config(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise RoleConfigurationError("request body must be a JSON object")
        user_is_adult = payload.get("user_is_adult")
        allow_adult = payload.get("allow_consensual_adult_content")
        if not isinstance(user_is_adult, bool) or not isinstance(allow_adult, bool):
            raise RoleConfigurationError("conversation policy flags must be boolean")
        return _ok(
            request.app[ROLES_KEY].update_conversation_policy(
                user_is_adult=user_is_adult,
                allow_consensual_adult_content=allow_adult,
                persist=True,
            )
        )
    except (RoleConfigurationError, OSError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _provider_config(request: web.Request) -> web.Response:
    if PROVIDER_SETTINGS_KEY not in request.app:
        return _error(503, "runtime provider settings are unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise ProviderConfigurationError("request body must be a JSON object")
        persist = payload.get("persist", True)
        clear_api_key = payload.get("clear_api_key", False)
        allow_insecure_http = payload.get("allow_insecure_http", False)
        if not all(
            isinstance(value, bool)
            for value in (persist, clear_api_key, allow_insecure_http)
        ):
            raise ProviderConfigurationError(
                "persist, clear_api_key and allow_insecure_http must be boolean"
            )
        status = request.app[PROVIDER_SETTINGS_KEY].update(
            base_url=payload.get("base_url", ""),
            model=payload.get("model", ""),
            api_key=payload.get("api_key"),
            clear_api_key=clear_api_key,
            persist=persist,
            allow_insecure_http=allow_insecure_http,
        )
        return _ok(status)
    except (ProviderConfigurationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _provider_profile_config(request: web.Request) -> web.Response:
    if PROVIDER_SETTINGS_KEY not in request.app:
        return _error(503, "runtime provider settings are unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise ProviderConfigurationError("request body must be a JSON object")
        persist = payload.get("persist", True)
        clear_api_key = payload.get("clear_api_key", False)
        enabled = payload.get("enabled", True)
        inherit_chat_key = payload.get("inherit_chat_key", False)
        allow_insecure_http = payload.get("allow_insecure_http", None)
        if not all(
            isinstance(value, bool)
            for value in (persist, clear_api_key, enabled, inherit_chat_key)
        ) or (
            allow_insecure_http is not None
            and not isinstance(allow_insecure_http, bool)
        ):
            raise ProviderConfigurationError(
                "persist, clear_api_key, enabled, inherit_chat_key and allow_insecure_http must be boolean"
            )
        status = request.app[PROVIDER_SETTINGS_KEY].update_profile(
            str(payload.get("capability", "")),
            base_url=payload.get("base_url", ""),
            model=payload.get("model", ""),
            api_key=payload.get("api_key"),
            clear_api_key=clear_api_key,
            persist=persist,
            enabled=enabled,
            protocol=payload.get("protocol", ""),
            inherit_chat_key=inherit_chat_key,
            allow_insecure_http=allow_insecure_http,
        )
        return _ok(status)
    except (ProviderConfigurationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _provider_diagnose(request: web.Request) -> web.Response:
    provider = request.app[SERVICE_KEY].provider
    if not isinstance(provider, OpenAICompatibleProvider):
        return _error(503, "runtime provider diagnostics are unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise ProviderConfigurationError("request body must be a JSON object")
        return _ok(await provider.diagnose(str(payload.get("capability", ""))))
    except ProviderConfigurationError as exc:
        return _error(400, str(exc), retryable=False)
    except ProviderError as exc:
        LOGGER.warning("provider diagnostic failure: %s", exc)
        return _error(502, str(exc), retryable=True)


async def _provider_fallback_config(request: web.Request) -> web.Response:
    if PROVIDER_SETTINGS_KEY not in request.app:
        return _error(503, "runtime provider settings are unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise ProviderConfigurationError("request body must be a JSON object")
        candidates = request.app[PROVIDER_SETTINGS_KEY].update_fallbacks(
            str(payload.get("capability", "")), payload.get("candidates", [])
        )
        return _ok(
            {
                "capability": str(payload.get("capability", "")),
                "candidates": candidates,
            }
        )
    except (ProviderConfigurationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _network_proxy_status(request: web.Request) -> web.Response:
    if PROVIDER_SETTINGS_KEY not in request.app:
        return _error(503, "runtime provider settings are unavailable", retryable=False)
    return _ok({"network_proxy": request.app[PROVIDER_SETTINGS_KEY].proxy_config()})


async def _network_proxy_config(request: web.Request) -> web.Response:
    if PROVIDER_SETTINGS_KEY not in request.app:
        return _error(503, "runtime provider settings are unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        network_proxy = request.app[PROVIDER_SETTINGS_KEY].update_network_proxy(
            payload
        )
        return _ok({"network_proxy": network_proxy})
    except (ProviderConfigurationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _vision_analyze(request: web.Request) -> web.Response:
    provider = request.app[SERVICE_KEY].provider
    if not isinstance(provider, OpenAICompatibleProvider):
        return _error(503, "vision runtime is unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise RequestValidationError("request body must be a JSON object")
        image_base64 = str(payload.get("image_base64", "")).strip()
        mime_type = str(payload.get("mime_type", "")).strip().lower()
        if mime_type not in {"image/jpeg", "image/png", "image/webp"}:
            raise RequestValidationError("unsupported image MIME type")
        try:
            image_bytes = base64.b64decode(image_base64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise RequestValidationError("image_base64 is invalid") from exc
        if not 1 <= len(image_bytes) <= 6_000_000:
            raise RequestValidationError("image must contain 1-6000000 bytes")
        symbolic_context = payload.get("symbolic_context", {})
        if not isinstance(symbolic_context, dict):
            raise RequestValidationError("symbolic_context must be a JSON object")
        if len(json.dumps(symbolic_context, ensure_ascii=False)) > 32_000:
            raise RequestValidationError("symbolic_context is too large")
        reply = await provider.describe_image(
            image_base64=image_base64,
            mime_type=mime_type,
            question=str(payload.get("question", "")),
            symbolic_context=symbolic_context,
        )
        if reply.finish_reason == "length":
            raise ProviderError("vision provider output exceeded its token limit")
        return _ok(
            {
                "text": reply.text,
                "structured": reply.structured,
                "finish_reason": reply.finish_reason,
                "provider": "companion_core",
            }
        )
    except RequestValidationError as exc:
        return _error(400, str(exc), retryable=False)
    except ProviderError as exc:
        LOGGER.warning("vision provider failure: %s", exc)
        return _error(502, str(exc), retryable=True)


async def _audio_transcribe(request: web.Request) -> web.Response:
    provider = request.app[SERVICE_KEY].provider
    if not isinstance(provider, OpenAICompatibleProvider):
        return _error(503, "speech recognition runtime is unavailable", retryable=False)
    try:
        mime_type = request.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if mime_type not in {"audio/wav", "audio/x-wav", "application/octet-stream"}:
            raise RequestValidationError("audio body must use WAV content type")
        audio_bytes = await request.read()
        if not 44 <= len(audio_bytes) <= 8_000_000:
            raise RequestValidationError("audio body must contain 44-8000000 bytes")
        if audio_bytes[:4] != b"RIFF" or audio_bytes[8:12] != b"WAVE":
            raise RequestValidationError("audio body must be a PCM WAV file")
        reply = await provider.transcribe_audio(
            audio_bytes,
            filename="spring-haven-voice-input.wav",
            mime_type="audio/wav",
            language=request.query.get("language", "zh"),
        )
        return _ok(
            {
                "text": reply.text,
                "language": reply.language,
                "provider": "companion_core",
            }
        )
    except RequestValidationError as exc:
        return _error(400, str(exc), retryable=False)
    except ProviderError as exc:
        LOGGER.warning("speech recognition provider failure: %s", exc)
        return _error(502, str(exc), retryable=exc.failover_allowed)


async def _audio_speech(request: web.Request) -> web.Response:
    provider = request.app[SERVICE_KEY].provider
    if not isinstance(provider, OpenAICompatibleProvider):
        return _error(503, "speech synthesis runtime is unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise RequestValidationError("request body must be a JSON object")
        text = str(payload.get("input", payload.get("text", ""))).replace("\x00", " ").strip()
        if not text:
            raise RequestValidationError("speech input text is empty")
        if len(text) > 4_000:
            raise RequestValidationError("speech input text exceeded 4000 characters")
        response_format = str(payload.get("response_format", "wav")).strip().lower()
        speed = payload.get("speed", 1.0)
        voice = str(payload.get("voice", "")).strip()
        reply = await provider.synthesize_speech(
            text,
            voice=voice,
            response_format=response_format,
            speed=speed,
        )
        return _ok(
            {
                "audio_base64": base64.b64encode(reply.audio).decode("ascii"),
                "mime_type": reply.mime_type,
                "provider": "companion_core",
            }
        )
    except RequestValidationError as exc:
        return _error(400, str(exc), retryable=False)
    except ProviderError as exc:
        LOGGER.warning("speech synthesis provider failure: %s", exc)
        return _error(502, str(exc), retryable=exc.failover_allowed)


async def _rag_status(request: web.Request) -> web.Response:
    try:
        return _ok(request.app[SERVICE_KEY].rag_status())
    except (RequestValidationError, RagStoreError, ValueError) as exc:
        return _error(503, str(exc), retryable=False)


async def _rag_config(request: web.Request) -> web.Response:
    if PROVIDER_SETTINGS_KEY not in request.app:
        return _error(503, "runtime provider settings are unavailable", retryable=False)
    try:
        payload: Any = await request.json()
        settings = request.app[PROVIDER_SETTINGS_KEY].update_rag(payload)
        return _ok({"settings": settings, "status": request.app[SERVICE_KEY].rag_status()})
    except (ProviderConfigurationError, RequestValidationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _rag_documents(request: web.Request) -> web.Response:
    try:
        entries = request.app[SERVICE_KEY].list_rag_documents(
            request.query.get("limit", 100)
        )
        return _ok({"documents": entries, "count": len(entries)})
    except (RequestValidationError, RagStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _rag_put_document(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        document = await request.app[SERVICE_KEY].put_rag_document(payload)
        return _ok({"document": document})
    except (RequestValidationError, RagStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _rag_batch_documents(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        result = await request.app[SERVICE_KEY].batch_rag_documents(payload)
        return _ok(result)
    except (RequestValidationError, RagStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _rag_get_document(request: web.Request) -> web.Response:
    try:
        document = request.app[SERVICE_KEY].get_rag_document(
            request.match_info["document_id"]
        )
        return _ok({"document": document})
    except (RequestValidationError, RagStoreError, ValueError) as exc:
        return _error(404, str(exc), retryable=False)


async def _rag_import_document(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise RequestValidationError("request body must be a JSON object")
        encoded = str(payload.get("content_base64", "")).strip()
        try:
            content = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise RequestValidationError("content_base64 is invalid") from exc
        extracted = extract_document(str(payload.get("filename", "")), content)
        metadata = payload.get("metadata", {})
        if not isinstance(metadata, dict):
            raise RequestValidationError("metadata must be a JSON object")
        metadata = {
            **metadata,
            "import_filename": extracted["filename"],
            "import_extension": extracted["extension"],
        }
        document_payload = {
            "document_id": payload.get("document_id", ""),
            "title": str(payload.get("title", "")).strip() or extracted["title"],
            "text": extracted["text"],
            "scope": payload.get("scope", "*"),
            "source_uri": payload.get("source_uri", ""),
            "metadata": metadata,
        }
        document = await request.app[SERVICE_KEY].put_rag_document(document_payload)
        return _ok({"document": document, "import": extracted})
    except (RequestValidationError, RagStoreError, DocumentImportError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _rag_import_url(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise RequestValidationError("request body must be a JSON object")
        url = _validated_import_url(payload.get("url", ""))
        timeout = ClientTimeout(total=20)
        proxy_settings = (
            request.app[PROVIDER_SETTINGS_KEY].proxy_config()
            if PROVIDER_SETTINGS_KEY in request.app
            else {"mode": "direct", "url": ""}
        )
        proxy_mode = str(proxy_settings.get("mode", "direct"))
        proxy_url = (
            str(proxy_settings.get("url", ""))
            if proxy_mode == "custom"
            else None
        )
        async with ClientSession(
            timeout=timeout,
            trust_env=proxy_mode == "system",
        ) as session:
            async with session.get(
                url,
                allow_redirects=False,
                headers={"User-Agent": "Spring-Haven-Core/0.1 knowledge-import"},
                proxy=proxy_url,
            ) as response:
                if response.status < 200 or response.status >= 300:
                    raise RequestValidationError(
                        f"web import returned HTTP {response.status}"
                    )
                content = await response.content.read(20_000_001)
                if len(content) > 20_000_000:
                    raise RequestValidationError("web document is too large")
                extracted = extract_web_document(
                    url, response.headers.get("Content-Type", "text/plain"), content
                )
        metadata = payload.get("metadata", {})
        if not isinstance(metadata, dict):
            raise RequestValidationError("metadata must be a JSON object")
        document = await request.app[SERVICE_KEY].put_rag_document(
            {
                "document_id": payload.get("document_id", ""),
                "title": str(payload.get("title", "")).strip() or extracted["title"],
                "text": extracted["text"],
                "scope": payload.get("scope", "*"),
                "source_uri": url,
                "metadata": {**metadata, "import_type": "web"},
            }
        )
        return _ok({"document": document, "import": extracted})
    except (RequestValidationError, RagStoreError, DocumentImportError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)
    except Exception as exc:
        LOGGER.warning("web knowledge import failed: %s", type(exc).__name__)
        return _error(502, "web document could not be downloaded", retryable=True)


async def _rag_delete_document(request: web.Request) -> web.Response:
    try:
        deleted = request.app[SERVICE_KEY].delete_rag_document(
            request.match_info["document_id"]
        )
        return _ok({"deleted": deleted})
    except (RequestValidationError, RagStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _rag_search(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        entries = await request.app[SERVICE_KEY].search_rag(payload)
        return _ok({"entries": entries, "count": len(entries)})
    except (RequestValidationError, RoleConfigurationError, RagStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _rag_reindex(request: web.Request) -> web.Response:
    try:
        return _ok(await request.app[SERVICE_KEY].reindex_rag())
    except (RequestValidationError, RagStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _chat(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        payload: Any = await request.json()
        return _ok(await service.chat(payload))
    except (RequestValidationError, RoleConfigurationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)
    except ProviderError as exc:
        LOGGER.warning("provider failure: %s", exc)
        return _error(502, str(exc), retryable=True)
    except Exception:
        LOGGER.exception("unexpected chat failure")
        return _error(500, "companion core failed", retryable=True)


async def _orchestrate(request: web.Request) -> web.Response:
    orchestrator = request.app[ORCHESTRATOR_KEY]
    try:
        payload: Any = await request.json()
        return _ok(await orchestrator.orchestrate(payload))
    except (RequestValidationError, RoleConfigurationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)
    except ProviderError as exc:
        LOGGER.warning("provider failure during orchestration: %s", exc)
        return _error(502, str(exc), retryable=True)
    except Exception:
        LOGGER.exception("unexpected orchestration failure")
        return _error(500, "companion orchestration failed", retryable=True)


async def _memory_status(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        return _ok(
            service.memory_status(
                request.query.get("save_id", ""),
                request.query.get("role_id", ""),
            )
        )
    except (RequestValidationError, RoleConfigurationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _maintenance_status(request: web.Request) -> web.Response:
    return _ok(request.app[SERVICE_KEY].storage_maintenance_status())


async def _maintenance_run(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        if not isinstance(payload, dict):
            raise RequestValidationError("request body must be a JSON object")
        force_backup = payload.get("force_backup", False)
        if not isinstance(force_backup, bool):
            raise RequestValidationError("force_backup must be boolean")
        result = await asyncio.to_thread(
            request.app[SERVICE_KEY].run_storage_maintenance,
            force_backup=force_backup,
        )
        return _ok(result)
    except (RequestValidationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _maintenance_backups(request: web.Request) -> web.Response:
    backups = request.app[SERVICE_KEY].list_storage_backups()
    return _ok({"backups": backups, "count": len(backups)})


async def _maintenance_backup_verify(request: web.Request) -> web.Response:
    try:
        return _ok(
            request.app[SERVICE_KEY].verify_storage_backup(request.match_info["name"])
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return _error(400, str(exc), retryable=False)


async def _memory_entries(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        entries = service.list_memories(
            request.query.get("save_id"),
            request.query.get("role_id", ""),
            request.query.get("query", ""),
            request.query.get("limit", 100),
        )
        return _ok({"entries": entries, "count": len(entries), "backend": "heartloom"})
    except (RequestValidationError, RoleConfigurationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _memory_graph(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        return _ok(
            service.memory_graph(
                request.query.get("save_id"),
                request.query.get("scope", ""),
                request.query.get("query", ""),
                request.query.get("limit", 120),
            )
        )
    except (RequestValidationError, RoleConfigurationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _memory_put(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        payload: Any = await request.json()
        return _ok({"entry": service.put_memory(payload), "backend": "heartloom"})
    except (RequestValidationError, RoleConfigurationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _memory_recall(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        payload: Any = await request.json()
        entries = service.recall_memories(payload)
        return _ok({"entries": entries, "count": len(entries), "backend": "heartloom"})
    except (RequestValidationError, RoleConfigurationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _memory_delete(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        deleted = service.delete_memory(
            request.query.get("save_id"), request.match_info["memory_id"]
        )
        return _ok({"deleted": deleted, "backend": "heartloom"})
    except (RequestValidationError, RoleConfigurationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _session_reset(request: web.Request) -> web.Response:
    service = request.app[SERVICE_KEY]
    try:
        payload = await request.json()
        if not isinstance(payload, dict):
            raise RequestValidationError("request body must be a JSON object")
        return _ok(service.reset_session(payload.get("save_id")))
    except (RequestValidationError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _life_sync(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        return _ok(request.app[SERVICE_KEY].sync_life_state(payload))
    except (RequestValidationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _life_status(request: web.Request) -> web.Response:
    try:
        return _ok(
            request.app[SERVICE_KEY].life_status(request.query.get("save_id", ""))
        )
    except (RequestValidationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _life_outbox(request: web.Request) -> web.Response:
    try:
        deliveries = request.app[SERVICE_KEY].poll_life_outbox(
            request.query.get("save_id"), request.query.get("limit", 16)
        )
        return _ok({"deliveries": deliveries, "count": len(deliveries)})
    except (RequestValidationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


async def _life_outbox_ack(request: web.Request) -> web.Response:
    try:
        payload: Any = await request.json()
        return _ok(request.app[SERVICE_KEY].ack_life_outbox(payload))
    except (RequestValidationError, MemoryStoreError, ValueError) as exc:
        return _error(400, str(exc), retryable=False)


def _validated_import_url(value: Any) -> str:
    normalized = str(value).strip()
    if not normalized or len(normalized) > 2_048:
        raise RequestValidationError("web import URL is invalid")
    parsed = urlparse(normalized)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise RequestValidationError("web import URL must use http or https")
    if parsed.username or parsed.password:
        raise RequestValidationError("web import URL cannot contain credentials")
    if parsed.scheme == "http" and parsed.hostname not in {
        "127.0.0.1",
        "localhost",
        "::1",
    }:
        raise RequestValidationError("remote web imports must use HTTPS")
    return normalized


def _ok(data: dict[str, Any]) -> web.Response:
    return web.json_response({"status": "ok", "data": data})


def _error(status: int, message: str, retryable: bool) -> web.Response:
    return web.json_response(
        {"status": "error", "message": message, "retryable": retryable},
        status=status,
    )


async def _close_runtime(app: web.Application) -> None:
    tasks = [app.get(MAINTENANCE_TASK_KEY), app.get(LIFE_TASK_KEY)]
    active_tasks = [task for task in tasks if isinstance(task, asyncio.Task)]
    for task in active_tasks:
        task.cancel()
    if active_tasks:
        await asyncio.gather(*active_tasks, return_exceptions=True)
    await app[SERVICE_KEY].aclose()


async def _start_maintenance(app: web.Application) -> None:
    app[MAINTENANCE_TASK_KEY] = asyncio.create_task(_maintenance_loop(app))


async def _start_life_scheduler(app: web.Application) -> None:
    app[LIFE_TASK_KEY] = asyncio.create_task(_life_scheduler_loop(app))


async def _maintenance_loop(app: web.Application) -> None:
    await asyncio.sleep(2.0)
    while True:
        try:
            result = await asyncio.to_thread(
                app[SERVICE_KEY].run_storage_maintenance, force_backup=False
            )
            if result.get("state") == "error":
                LOGGER.error("storage maintenance failed: %s", result.get("error", ""))
        except asyncio.CancelledError:
            raise
        except Exception:
            LOGGER.exception("unexpected storage maintenance failure")
        await asyncio.sleep(6 * 60 * 60)


async def _life_scheduler_loop(app: web.Application) -> None:
    await asyncio.sleep(5.0)
    while True:
        try:
            result = await app[SERVICE_KEY].run_due_life_events()
            if int(result.get("failed", 0)) > 0:
                LOGGER.warning("offline life scheduler failures: %s", result)
        except asyncio.CancelledError:
            raise
        except Exception:
            LOGGER.exception("unexpected offline life scheduler failure")
        await asyncio.sleep(60.0)
