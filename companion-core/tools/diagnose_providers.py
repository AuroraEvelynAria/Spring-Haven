from __future__ import annotations

import argparse
import asyncio
import json
from dataclasses import replace
from pathlib import Path
from typing import Any

from spring_haven_core.config import CoreConfig
from spring_haven_core.provider import OpenAICompatibleProvider
from spring_haven_core.provider_settings import ProviderSettingsStore


class _ProfileOverrideSettings:
    def __init__(self, delegate: ProviderSettingsStore, capability: str, base_url: str):
        self._delegate = delegate
        self._capability = capability
        self._base_url = base_url

    def profile_snapshot(self, capability: str):
        snapshot = self._delegate.profile_snapshot(capability)
        return (
            replace(snapshot, base_url=self._base_url)
            if capability == self._capability
            else snapshot
        )

    def proxy_config(self):
        return self._delegate.proxy_config()

    def rag_config(self):
        return self._delegate.rag_config()


async def run(
    config_path: Path, capabilities: list[str], try_v1_fallback: bool
) -> dict[str, Any]:
    config = CoreConfig.load(config_path)
    settings = ProviderSettingsStore(
        config,
        config.provider_settings_path,
        config.provider_credential_path,
    )
    provider = OpenAICompatibleProvider(config, settings)
    results: dict[str, Any] = {}
    for capability in capabilities:
        try:
            results[capability] = await provider.diagnose(capability)
        except Exception as exc:
            failed: dict[str, Any] = {
                "capability": capability,
                "ok": False,
                "error_type": type(exc).__name__,
                "message": str(exc)[:500],
            }
            profile = settings.profile_snapshot(capability)
            if try_v1_fallback and not profile.base_url.rstrip("/").endswith("/v1"):
                fallback_provider = OpenAICompatibleProvider(
                    config,
                    _ProfileOverrideSettings(
                        settings,
                        capability,
                        profile.base_url.rstrip("/") + "/v1",
                    ),
                )
                try:
                    fallback = await fallback_provider.diagnose(capability)
                    fallback["temporary_base_url_suffix"] = "/v1"
                    failed["v1_fallback"] = fallback
                except Exception as fallback_exc:
                    failed["v1_fallback"] = {
                        "ok": False,
                        "error_type": type(fallback_exc).__name__,
                        "message": str(fallback_exc)[:500],
                    }
            results[capability] = failed
    return {
        "results": results,
        "privacy": "Credentials and provider response bodies were not emitted or persisted.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Run redacted live provider diagnostics.")
    parser.add_argument("--config", default="user_data/core_config.json")
    parser.add_argument(
        "--capabilities",
        nargs="+",
        default=["chat", "vision", "embedding", "rerank"],
    )
    parser.add_argument("--try-v1-fallback", action="store_true")
    args = parser.parse_args()
    print(
        json.dumps(
            asyncio.run(
                run(
                    Path(args.config).resolve(),
                    args.capabilities,
                    args.try_v1_fallback,
                )
            ),
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
