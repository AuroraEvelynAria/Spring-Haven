from __future__ import annotations

import argparse
import logging
from pathlib import Path

from aiohttp import web

from spring_haven_core.app import build_app
from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.provider import ProviderReply
from spring_haven_core.roles import RoleDefinition, RoleRegistry
from spring_haven_core.service import CompanionService


class ScriptedProvider:
    async def complete(self, system_prompt, messages):
        shared = "\n".join(str(item.get("content", "")) for item in messages)
        if "当前回复者是 小玲" in system_prompt:
            text = (
                "小奈，主人想问你这一餐想吃什么。"
                if "conversation_route" in shared
                else "樱灯"
            )
        elif "樱灯" in shared:
            text = "我看见小玲刚才说了樱灯。月铃。"
        else:
            text = "月铃"
        return ProviderReply(text=text, finish_reason="stop")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--port", type=int, default=18340)
    args = parser.parse_args()
    roles = RoleRegistry(
        {
            "ling": RoleDefinition(
                "ling", "小玲", "春日 铃音", ("小玲", "铃音"), "你是小玲。"
            ),
            "nai": RoleDefinition(
                "nai", "小奈", "白濑 雪奈", ("小奈", "雪奈"), "你是小奈。"
            ),
        }
    )
    config = CoreConfig(
        port=args.port,
        api_key=args.api_key,
        provider_base_url="http://127.0.0.1:1/v1",
        provider_model="scripted-test-provider",
        memory_db_path=str(args.database),
        memory_organizer_enabled=False,
    )
    service = CompanionService(
        roles,
        ScriptedProvider(),
        HeartloomStore(args.database, roles.ids()),
    )
    app = build_app(config, roles, service)

    async def close_service(_app):
        service.close()

    app.on_cleanup.append(close_service)
    logging.basicConfig(level=logging.WARNING)
    web.run_app(
        app,
        host="127.0.0.1",
        port=args.port,
        access_log=None,
        print=None,
    )


if __name__ == "__main__":
    main()
