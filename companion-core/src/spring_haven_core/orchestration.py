from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from .roles import RoleRegistry
from .service import CompanionService, REQUEST_ID_PATTERN, RequestValidationError


DUAL_MARKERS = (
    "你们都回答",
    "你们两个都回答",
    "两个人都回答",
    "你们都说说",
    "一起回答",
    "both of you",
    "all of you",
)
DIRECTIVE_SUFFIXES = ("来回答", "回答一下", "回答", "说说", "告诉我")
DELEGATION_VERBS = ("去问", "去问问", "问问", "问一下", "去跟", "跟")


@dataclass(frozen=True)
class RouteDecision:
    roles: tuple[str, ...]
    reason: str
    audience_roles: tuple[str, ...]
    route: dict[str, Any] | None = None

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "roles": list(self.roles),
            "reason": self.reason,
            "audience_roles": list(self.audience_roles),
            "visibility": "shared_room",
        }
        if self.route:
            result["route"] = dict(self.route)
        return result


class ConversationOrchestrator:
    """Routes and serializes a shared turn without changing the selected role."""

    def __init__(self, roles: RoleRegistry, service: CompanionService):
        self.roles = roles
        self.service = service

    def resolve(
        self,
        text: str,
        selected_role_id: str,
        *,
        reply_mode: str = "auto",
        requested_roles: Any = None,
        conversational_role_id: str = "",
    ) -> RouteDecision:
        role_ids = self.roles.ids()
        if selected_role_id not in role_ids:
            raise RequestValidationError("selected_role_id is invalid")
        audience = tuple(role_ids)
        explicit = self._normalize_requested_roles(requested_roles)
        if explicit:
            return RouteDecision(tuple(explicit), "explicit_api", audience)
        if reply_mode not in {"auto", "selected", "both"}:
            raise RequestValidationError("reply_mode must be auto, selected or both")
        if reply_mode == "both":
            return RouteDecision(
                tuple([selected_role_id, *[item for item in role_ids if item != selected_role_id]]),
                "reply_mode_both",
                audience,
            )
        normalized = str(text).replace("\x00", " ").strip()
        lowered = normalized.lower()
        if reply_mode == "auto" and any(marker in lowered for marker in DUAL_MARKERS):
            return RouteDecision(
                tuple([selected_role_id, *[item for item in role_ids if item != selected_role_id]]),
                "explicit_dual",
                audience,
            )

        delegation = self._resolve_delegation(
            normalized, selected_role_id, conversational_role_id
        )
        if delegation:
            return delegation

        for role_id in role_ids:
            for alias in self._aliases(role_id):
                if f"@{alias}" in lowered or any(
                    f"{alias}{suffix}" in lowered for suffix in DIRECTIVE_SUFFIXES
                ):
                    return RouteDecision((role_id,), "explicit_directive", audience)
                if lowered.startswith(alias):
                    return RouteDecision((role_id,), "leading_name", audience)

        mentioned = [
            role_id
            for role_id in role_ids
            if any(alias in lowered for alias in self._aliases(role_id))
        ]
        if len(mentioned) == 1:
            return RouteDecision((mentioned[0],), "single_mention", audience)
        return RouteDecision((selected_role_id,), "selected", audience)

    async def orchestrate(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RequestValidationError("request body must be a JSON object")
        request_id = str(raw.get("request_id", "")).strip()
        if not REQUEST_ID_PATTERN.fullmatch(request_id):
            raise RequestValidationError("request_id is invalid")
        save_id = self.service.validate_save_id(raw.get("save_id"))
        text = str(raw.get("text", "")).replace("\x00", " ").strip()
        if not text or len(text) > 8_000:
            raise RequestValidationError("text must contain 1-8000 characters")
        selected_role_id = str(raw.get("selected_role_id", "")).strip()
        history = raw.get("history", [])
        if not isinstance(history, list) or len(history) > 64:
            raise RequestValidationError("history must be an array with at most 64 items")
        event_type = str(raw.get("event_type", "chat"))
        if event_type not in {"chat", "action"}:
            raise RequestValidationError("event_type must be chat or action")
        shared_state = raw.get("state", {})
        state_by_role = raw.get("state_by_role", {})
        if not isinstance(shared_state, dict) or not isinstance(state_by_role, dict):
            raise RequestValidationError("state and state_by_role must be JSON objects")

        decision = self.resolve(
            text,
            selected_role_id,
            reply_mode=str(raw.get("reply_mode", "auto")),
            requested_roles=raw.get("recipient_role_ids"),
            conversational_role_id=str(raw.get("conversational_role_id", "")),
        )
        source_message_id = str(raw.get("source_message_id", request_id)).strip()
        if not REQUEST_ID_PATTERN.fullmatch(source_message_id):
            source_message_id = request_id
        session = self.service.memory.update_session(
            save_id, selected_role_id, source_message_id
        )

        turn_history = [dict(item) for item in history if isinstance(item, dict)]
        replies: list[dict[str, Any]] = []
        for index, role_id in enumerate(decision.roles):
            role_state = dict(shared_state)
            role_specific = state_by_role.get(role_id, {})
            if isinstance(role_specific, dict):
                role_state.update(role_specific)
            role_state["source_message_id"] = source_message_id
            role_state["selected_role_id"] = selected_role_id
            role_state["conversation_visibility"] = {
                "protocol": "spring_haven.conversation_visibility.v1",
                "mode": "shared_room",
                "audience_roles": list(decision.audience_roles),
                "responder_role": role_id,
                "parenthetical_content_visible": True,
            }
            if decision.route:
                role_state["conversation_route"] = {
                    **decision.route,
                    "turn_role": role_id,
                    "turn_index": index,
                }
            child_request_id = _child_request_id(request_id, index, role_id)
            result = await self.service.chat(
                {
                    "request_id": child_request_id,
                    "role_id": role_id,
                    "save_id": save_id,
                    "text": text,
                    "history": turn_history,
                    "event_type": event_type,
                    "state": role_state,
                }
            )
            replies.append({"role_id": role_id, **result})
            turn_history.append(
                {
                    "id": f"{child_request_id}:ai",
                    "sender": "ai",
                    "role_id": role_id,
                    "text": result["reply"],
                    "event_type": event_type,
                }
            )

        return {
            "request_id": request_id,
            "save_id": save_id,
            "selected_role_id": selected_role_id,
            "selection_changed": False,
            "turn_index": int(session.get("turn_index", 0)),
            "route": decision.as_dict(),
            "replies": replies,
            "backend": "spring_haven_core",
            "memory_backend": "heartloom",
        }

    def _normalize_requested_roles(self, raw: Any) -> list[str]:
        if raw is None:
            return []
        if not isinstance(raw, list):
            raise RequestValidationError("recipient_role_ids must be an array")
        result: list[str] = []
        for item in raw:
            role_id = str(item)
            self.roles.get(role_id)
            if role_id not in result:
                result.append(role_id)
        return result

    def _resolve_delegation(
        self, text: str, selected_role_id: str, conversational_role_id: str
    ) -> RouteDecision | None:
        compact = text.lower()
        for separator in (" ", "\t", "\r", "\n", "，", ",", "。", "！", "!"):
            compact = compact.replace(separator, "")
        if any(marker in compact for marker in ("别去问", "不要去问", "不用去问")):
            return None
        role_ids = self.roles.ids()
        audience = tuple(role_ids)
        aliases = {role_id: self._aliases(role_id) for role_id in role_ids}
        for origin in role_ids:
            for target in role_ids:
                if origin == target:
                    continue
                for origin_alias in aliases[origin]:
                    for target_alias in aliases[target]:
                        if any(
                            f"{origin_alias}{verb}{target_alias}" in compact
                            for verb in DELEGATION_VERBS
                        ):
                            return RouteDecision(
                                (origin, target),
                                "named_delegation",
                                audience,
                                {
                                    "protocol": "spring_haven.conversation_route.v1",
                                    "kind": "delegate_question",
                                    "origin_role": origin,
                                    "target_role": target,
                                },
                            )
        for target in role_ids:
            if not any(
                f"你{verb}{alias}" in compact
                or f"帮我{verb.replace('去', '')}{alias}" in compact
                for alias in aliases[target]
                for verb in DELEGATION_VERBS
            ):
                continue
            origin = selected_role_id
            if target == origin:
                if conversational_role_id in role_ids and conversational_role_id != target:
                    origin = conversational_role_id
                else:
                    others = [item for item in role_ids if item != target]
                    if not others:
                        return None
                    origin = others[0]
            return RouteDecision(
                (origin, target),
                "selected_delegation",
                audience,
                {
                    "protocol": "spring_haven.conversation_route.v1",
                    "kind": "delegate_question",
                    "origin_role": origin,
                    "target_role": target,
                },
            )
        return None

    def _aliases(self, role_id: str) -> tuple[str, ...]:
        role = self.roles.get(role_id)
        values = [role.display_name, role.full_name, *role.aliases]
        return tuple(dict.fromkeys(value.lower().replace(" ", "") for value in values if value))


def _child_request_id(parent: str, index: int, role_id: str) -> str:
    suffix = f":{index}:{role_id}"
    if len(parent) + len(suffix) <= 128:
        return parent + suffix
    digest = hashlib.sha256(parent.encode("utf-8")).hexdigest()[:20]
    return f"orchestrated:{digest}:{index}:{role_id}"
