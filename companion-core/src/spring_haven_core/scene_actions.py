from __future__ import annotations

import json
import re
from typing import Any


ACTION_PATTERN = re.compile(
    r"<scene_action>\s*(\{.*?\})\s*</scene_action>",
    flags=re.IGNORECASE | re.DOTALL,
)


def extract_scene_actions(text: str, state: dict[str, Any], role_id: str) -> tuple[str, list[dict[str, Any]]]:
    """Remove model-only action tags and return one strictly validated action."""

    visible = ACTION_PATTERN.sub("", text).strip()
    matches = ACTION_PATTERN.findall(text)
    if not matches:
        return text.strip(), []
    context = state.get("scene_context", {}) if isinstance(state, dict) else {}
    if not _valid_context(context, role_id) or len(matches) != 1:
        return visible or "我明白了。", []
    try:
        raw = json.loads(matches[0])
    except (TypeError, ValueError):
        return visible or "我明白了。", []
    action = _validate_action(raw, context)
    return visible or "我明白了，马上行动。", [action] if action else []


def _valid_context(raw: Any, role_id: str) -> bool:
    return (
        isinstance(raw, dict)
        and raw.get("protocol") == "spring_heaven.scene_actions.v1"
        and type(raw.get("schema_version")) in {int, float}
        and float(raw.get("schema_version")) == 1.0
        and raw.get("actor_role_id") == role_id
        and raw.get("vision_available") is False
        and isinstance(raw.get("available_actions"), list)
    )


def _validate_action(raw: Any, context: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(raw, dict) or type(raw.get("schema_version")) is not int:
        return {}
    if raw.get("schema_version") != 1 or not isinstance(raw.get("action"), str):
        return {}
    action_name = raw["action"]
    available: dict[str, set[str]] = {}
    for item in context.get("available_actions", [])[:16]:
        if not isinstance(item, dict) or not isinstance(item.get("action"), str):
            continue
        targets = item.get("allowed_target_ids", [])
        available[item["action"]] = {
            str(target) for target in targets[:32]
        } if isinstance(targets, list) else set()
    if action_name not in available:
        return {}
    if action_name == "move_to":
        if set(raw) != {"schema_version", "action", "target_id"}:
            return {}
        target_id = raw.get("target_id")
        if not isinstance(target_id, str) or target_id not in available[action_name]:
            return {}
        entity_ids = {
            str(item.get("id"))
            for item in context.get("entities", [])[:32]
            if isinstance(item, dict)
        }
        if entity_ids and target_id not in entity_ids:
            return {}
        return {"schema_version": 1, "action": "move_to", "target_id": target_id}
    if action_name in {"follow_player", "stop"}:
        if set(raw) != {"schema_version", "action"}:
            return {}
        return {"schema_version": 1, "action": action_name}
    return {}
