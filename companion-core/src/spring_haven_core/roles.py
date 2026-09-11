from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROLE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class RoleConfigurationError(ValueError):
    """Raised when a role registry cannot safely be loaded."""


@dataclass(frozen=True)
class RoleDefinition:
    role_id: str
    display_name: str
    full_name: str
    aliases: tuple[str, ...]
    persona_prompt: str
    memory_prompt: str = ""
    age: int | None = None


class RoleRegistry:
    def __init__(
        self,
        roles: dict[str, RoleDefinition],
        source_path: Path | None = None,
    ):
        if not roles:
            raise RoleConfigurationError("at least one role is required")
        self._roles = dict(roles)
        self._source_path = source_path

    @classmethod
    def load(cls, path: str | Path) -> "RoleRegistry":
        source = Path(path)
        parsed = json.loads(source.read_text(encoding="utf-8-sig"))
        raw_roles = parsed.get("roles") if isinstance(parsed, dict) else None
        if not isinstance(raw_roles, list):
            raise RoleConfigurationError("roles.json must contain a roles array")

        roles: dict[str, RoleDefinition] = {}
        for raw in raw_roles:
            role = _parse_role(raw, source.parent)
            if role.role_id in roles:
                raise RoleConfigurationError(f"duplicate role_id: {role.role_id}")
            roles[role.role_id] = role
        return cls(roles, source)

    def get(self, role_id: str) -> RoleDefinition:
        try:
            return self._roles[role_id]
        except KeyError as exc:
            raise RoleConfigurationError(f"unknown role_id: {role_id}") from exc

    def ids(self) -> list[str]:
        return list(self._roles)

    def others(self, role_id: str) -> list[RoleDefinition]:
        return [role for key, role in self._roles.items() if key != role_id]


def _parse_role(raw: Any, root: Path) -> RoleDefinition:
    if not isinstance(raw, dict):
        raise RoleConfigurationError("each role must be a JSON object")
    role_id = str(raw.get("role_id", "")).strip().lower()
    if not ROLE_ID_PATTERN.fullmatch(role_id):
        raise RoleConfigurationError(f"invalid role_id: {role_id!r}")
    display_name = str(raw.get("display_name", "")).strip()
    full_name = str(raw.get("full_name", display_name)).strip()
    if not display_name or len(display_name) > 80 or len(full_name) > 120:
        raise RoleConfigurationError(f"invalid display name for {role_id}")

    aliases_raw = raw.get("aliases", [])
    if not isinstance(aliases_raw, list):
        raise RoleConfigurationError(f"aliases must be an array for {role_id}")
    aliases = tuple(
        dict.fromkeys(
            item.strip()
            for item in map(str, aliases_raw)
            if item.strip() and len(item.strip()) <= 80
        )
    )

    prompt_file = str(raw.get("prompt_file", "")).strip()
    inline_prompt = str(raw.get("persona_prompt", "")).strip()
    if prompt_file:
        prompt_path = (root / prompt_file).resolve()
        if root.resolve() not in prompt_path.parents:
            raise RoleConfigurationError(f"prompt path escapes registry directory: {role_id}")
        if not prompt_path.is_file():
            raise RoleConfigurationError(f"prompt file is missing for {role_id}")
        inline_prompt = prompt_path.read_text(encoding="utf-8").strip()
    if not inline_prompt or len(inline_prompt) > 100_000:
        raise RoleConfigurationError(f"persona prompt is missing or too large: {role_id}")

    memory_prompt_file = str(raw.get("memory_prompt_file", "")).strip()
    memory_prompt = str(raw.get("memory_prompt", "")).strip()
    if memory_prompt_file:
        memory_prompt_path = (root / memory_prompt_file).resolve()
        if root.resolve() not in memory_prompt_path.parents:
            raise RoleConfigurationError(
                f"memory prompt path escapes registry directory: {role_id}"
            )
        if not memory_prompt_path.is_file():
            raise RoleConfigurationError(f"memory prompt file is missing for {role_id}")
        memory_prompt = memory_prompt_path.read_text(encoding="utf-8").strip()
    if not memory_prompt:
        memory_prompt = (
            f"你是{display_name}的专属记忆整理者。只从她的视角整理可靠事实、"
            "重要共同经历、关系变化、主人偏好和会影响未来行为的日常习惯。"
        )
    if len(memory_prompt) > 30_000:
        raise RoleConfigurationError(f"memory prompt is too large: {role_id}")

    raw_age = raw.get("age")
    age: int | None = None
    if raw_age is not None:
        if isinstance(raw_age, bool) or not isinstance(raw_age, int):
            raise RoleConfigurationError(f"age must be an integer for {role_id}")
        if not 1 <= raw_age <= 200:
            raise RoleConfigurationError(f"age is out of range for {role_id}")
        age = raw_age

    return RoleDefinition(
        role_id=role_id,
        display_name=display_name,
        full_name=full_name or display_name,
        aliases=aliases,
        persona_prompt=inline_prompt,
        memory_prompt=memory_prompt,
        age=age,
    )
