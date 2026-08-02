from __future__ import annotations

import argparse
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

from aiohttp import web

from .app import build_app
from .config import CoreConfig
from .roles import RoleRegistry


def main() -> None:
    parser = argparse.ArgumentParser(description="Spring Haven Companion Core")
    parser.add_argument("--config", default="user_data/core_config.json")
    parser.add_argument("--roles", default="user_data/roles.json")
    parser.add_argument("--log-level", default="INFO")
    parser.add_argument("--log-file", default="")
    args = parser.parse_args()

    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if str(args.log_file).strip():
        log_path = Path(args.log_file).resolve()
        log_path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(
            RotatingFileHandler(
                log_path,
                maxBytes=5 * 1024 * 1024,
                backupCount=3,
                encoding="utf-8",
            )
        )
    logging.basicConfig(
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        handlers=handlers,
    )
    config = CoreConfig.load(args.config)
    roles = RoleRegistry.load(args.roles)
    web.run_app(
        build_app(config, roles),
        host=config.host,
        port=config.port,
        access_log=None,
        print=lambda message: logging.getLogger("spring_haven_core").info(message),
    )


if __name__ == "__main__":
    main()
