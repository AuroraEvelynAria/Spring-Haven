"""Real-weather service using the free Open-Meteo API (no key, no cost).

Fetches current weather for a configured location, caches it briefly, and maps
WMO weather codes to the Spring Haven weather vocabulary used by WeatherSystem.gd.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

from aiohttp import ClientSession, ClientTimeout

from .provider_settings import ProviderSettingsStore

LOGGER = logging.getLogger("spring_haven_core.weather")

OPEN_METEO_CURRENT_URL = "https://api.open-meteo.com/v1/forecast"
OPEN_METEO_GEO_URL = "https://geocoding-api.open-meteo.com/v1/search"

# WMO weather code -> Spring Haven weather code
WMO_TO_CODE: dict[int, str] = {
    0: "sunny", 1: "sunny", 2: "cloudy", 3: "cloudy",
    45: "cloudy", 48: "cloudy",
    51: "rain", 53: "rain", 55: "rain", 56: "rain", 57: "rain",
    61: "rain", 63: "rain", 65: "rain", 66: "rain", 67: "rain",
    71: "snow", 73: "snow", 75: "snow", 77: "snow",
    80: "rain", 81: "rain", 82: "rain",
    85: "snow", 86: "snow",
    95: "rain", 96: "rain", 99: "rain",
}

CACHE_SECONDS = 30 * 60  # 30 分钟缓存


class WeatherService:
    """Fetches real weather for a location; degrades to empty on any failure."""

    def __init__(
        self,
        location: str = "",
        *,
        settings: ProviderSettingsStore | None = None,
        timeout_seconds: int = 12,
    ) -> None:
        self.location = str(location).strip()
        self.settings = settings
        self.timeout_seconds = max(3, timeout_seconds)
        self._cache: dict[str, Any] = {}
        self._lock = asyncio.Lock()

    async def current(self, now: int | None = None) -> dict[str, Any]:
        """Return the cached/fresh real weather, or {} when unavailable.

        Result: {source: "real", code, temperature, description, day_key, captured_at}
        """
        timestamp = max(1, int(now or time.time()))
        cache_age = timestamp - int(self._cache.get("captured_at", 0))
        if self._cache and 0 <= cache_age < CACHE_SECONDS:
            return dict(self._cache)
        if not self.location:
            return {}
        async with self._lock:
            cache_age = timestamp - int(self._cache.get("captured_at", 0))
            if self._cache and 0 <= cache_age < CACHE_SECONDS:
                return dict(self._cache)
            try:
                result = await self._fetch_fresh(timestamp)
            except Exception as exc:
                LOGGER.warning("real weather fetch failed: %s", type(exc).__name__)
                return {}
            if result:
                self._cache = result
            return dict(result)

    async def _fetch_fresh(self, now: int) -> dict[str, Any]:
        lat, lon = await self._resolve_location()
        if lat is None or lon is None:
            return {}
        params = {
            "latitude": f"{lat:.4f}",
            "longitude": f"{lon:.4f}",
            "current": "temperature_2m,weather_code",
            "timezone": "auto",
        }
        timeout = ClientTimeout(total=self.timeout_seconds)
        proxy = self._proxy_url()
        body: dict[str, Any] = {}
        async with ClientSession(timeout=timeout, trust_env=proxy is None) as session:
            try:
                async with session.get(
                    OPEN_METEO_CURRENT_URL, params=params, proxy=proxy
                ) as response:
                    if response.status != 200:
                        LOGGER.warning("open-meteo HTTP %s", response.status)
                        return {}
                    body = json.loads(await response.text())
            except Exception:
                # 代理不可达时回退直连（用户代理可能时开时关）
                if proxy is None:
                    raise
                LOGGER.warning("weather via proxy failed; retrying direct")
                async with session.get(
                    OPEN_METEO_CURRENT_URL, params=params, proxy=None
                ) as response:
                    if response.status != 200:
                        LOGGER.warning("open-meteo direct HTTP %s", response.status)
                        return {}
                    body = json.loads(await response.text())
        current = body.get("current", {}) if isinstance(body, dict) else {}
        code = int(current.get("weather_code", 0) or 0)
        temperature = float(current.get("temperature_2m", 0.0) or 0.0)
        weather_code = WMO_TO_CODE.get(code, "cloudy")
        local_time = str(current.get("time", ""))
        day_key = str(local_time)[:10] if local_time else time.strftime(
            "%Y-%m-%d", time.localtime(now)
        )
        return {
            "source": "real",
            "code": weather_code,
            "temperature": int(round(temperature)),
            "description": f"实时天气·{_describe(weather_code)}",
            "day_key": day_key,
            "captured_at": now,
        }

    async def _resolve_location(self) -> tuple[float | None, float | None]:
        """Accept 'lat,lon' or a city name (geocoding via Open-Meteo)."""
        location = self.location.strip()
        if not location:
            return None, None
        if "," in location:
            parts = [p.strip() for p in location.split(",")]
            if len(parts) == 2:
                try:
                    return float(parts[0]), float(parts[1])
                except ValueError:
                    pass
        proxy = self._proxy_url()
        timeout = ClientTimeout(total=self.timeout_seconds)
        try:
            async with ClientSession(timeout=timeout, trust_env=proxy is None) as session:
                try:
                    async with session.get(
                        OPEN_METEO_GEO_URL,
                        params={"name": location, "count": 1, "language": "zh"},
                        proxy=proxy,
                    ) as response:
                        if response.status != 200:
                            return None, None
                        body = json.loads(await response.text())
                except Exception:
                    if proxy is None:
                        raise
                    async with session.get(
                        OPEN_METEO_GEO_URL,
                        params={"name": location, "count": 1, "language": "zh"},
                        proxy=None,
                    ) as response:
                        if response.status != 200:
                            return None, None
                        body = json.loads(await response.text())
            results = body.get("results", []) if isinstance(body, dict) else []
            if not results:
                return None, None
            first = results[0]
            return float(first.get("latitude", 0.0)), float(first.get("longitude", 0.0))
        except Exception as exc:
            LOGGER.warning("weather geocoding failed: %s", type(exc).__name__)
            return None, None

    def _proxy_url(self) -> str | None:
        if self.settings is None:
            return None
        try:
            proxy = self.settings.proxy_config()
        except Exception:
            return None
        mode = str(proxy.get("mode", "direct"))
        if mode == "custom":
            return str(proxy.get("url", "")) or None
        return None


def _describe(code: str) -> str:
    return {
        "sunny": "晴天",
        "cloudy": "多云",
        "rain": "有雨",
        "snow": "下雪",
        "windy": "大风",
    }.get(code, code)
