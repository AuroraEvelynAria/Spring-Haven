from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import time
from pathlib import Path
from typing import Any

from spring_haven_core.config import CoreConfig
from spring_haven_core.prompting import PromptComposer
from spring_haven_core.provider import OpenAICompatibleProvider, ProviderReply
from spring_haven_core.provider_settings import ProviderSettingsStore
from spring_haven_core.roles import RoleRegistry


def _sample_history() -> list[dict[str, Any]]:
    return [
        {"sender": "user", "text": "今天想在客厅安静待一会。", "created_at": 1},
        {"sender": "ai", "role_id": "ling", "text": "好，我陪你坐一会。", "created_at": 2},
        {"sender": "user", "text": "花盆里的土看起来有点干。", "created_at": 3},
        {"sender": "ai", "role_id": "ling", "text": "我等会去看看要不要浇水。", "created_at": 4},
        {"sender": "user", "text": "晚饭想吃清淡一点。", "created_at": 5},
        {"sender": "ai", "role_id": "nai", "text": "那就准备一份热汤吧。", "created_at": 6},
    ]


def _metrics(reply: ProviderReply, elapsed: float) -> dict[str, Any]:
    rate = reply.cached_tokens / reply.input_tokens if reply.input_tokens else 0.0
    return {
        "input_tokens": reply.input_tokens,
        "output_tokens": reply.output_tokens,
        "cached_tokens": reply.cached_tokens,
        "cache_miss_tokens": reply.cache_miss_tokens,
        "cache_hit_rate": round(rate, 4),
        "latency_ms": round(elapsed * 1000),
        "finish_reason": reply.finish_reason,
    }


async def _timed_complete(
    provider: OpenAICompatibleProvider,
    system_prompt: str,
    messages: list[dict[str, str]],
) -> tuple[ProviderReply, float]:
    started = time.perf_counter()
    reply = await provider.complete(system_prompt, messages)
    return reply, time.perf_counter() - started


async def run(args: argparse.Namespace) -> dict[str, Any]:
    config_path = Path(args.config).resolve()
    roles_path = Path(args.roles).resolve()
    config = CoreConfig.load(config_path)
    roles = RoleRegistry.load(roles_path)
    role = roles.get(args.role)
    settings = ProviderSettingsStore(
        config,
        config.provider_settings_path,
        config.provider_credential_path,
    )
    provider = OpenAICompatibleProvider(config, settings)
    composer = PromptComposer(roles)
    system_prompt = composer.system_prompt(role)
    state = {"conversation_visibility": {"audience_roles": roles.ids()}}
    history = _sample_history()
    fixed_messages = composer.messages(
        role,
        "你现在更想在客厅做什么？请简短回答。",
        history,
        state,
    )

    identical: list[dict[str, Any]] = []
    for _ in range(max(2, args.rounds)):
        reply, elapsed = await _timed_complete(provider, system_prompt, fixed_messages)
        identical.append(_metrics(reply, elapsed))

    first_messages = composer.messages(
        role,
        "你愿意陪我照看花吗？请简短回答。",
        history,
        state,
    )
    first_reply, first_elapsed = await _timed_complete(
        provider, system_prompt, first_messages
    )
    appended_history = [
        *history,
        {"sender": "user", "text": "你愿意陪我照看花吗？请简短回答。", "created_at": 7},
        {"sender": "ai", "role_id": role.role_id, "text": first_reply.text, "created_at": 8},
    ]
    appended_messages = composer.messages(
        role,
        "那我们先从哪一盆开始？请简短回答。",
        appended_history,
        state,
    )
    appended_reply, appended_elapsed = await _timed_complete(
        provider, system_prompt, appended_messages
    )
    appended = [
        _metrics(first_reply, first_elapsed),
        _metrics(appended_reply, appended_elapsed),
    ]

    measured = identical[1:] + appended[1:]
    return {
        "provider": {
            "base_url_host": settings.status()["base_url"].split("//", 1)[-1].split("/", 1)[0],
            "model": settings.status()["model"],
            "proxy_mode": settings.proxy_config()["mode"],
        },
        "role_id": role.role_id,
        "system_prompt_characters": len(system_prompt),
        "scenarios": {
            "identical_request": identical,
            "appended_conversation": appended,
        },
        "summary": {
            "measured_calls": len(measured),
            "mean_cache_hit_rate": round(
                statistics.fmean(item["cache_hit_rate"] for item in measured), 4
            ),
            "mean_latency_ms": round(
                statistics.fmean(item["latency_ms"] for item in measured)
            ),
        },
        "privacy": "Prompts, replies, and credentials were not emitted or persisted.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a redacted prompt-cache benchmark without touching memory databases."
    )
    parser.add_argument("--config", default="user_data/core_config.json")
    parser.add_argument("--roles", default="user_data/roles.json")
    parser.add_argument("--role", default="ling")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    print(json.dumps(asyncio.run(run(args)), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
