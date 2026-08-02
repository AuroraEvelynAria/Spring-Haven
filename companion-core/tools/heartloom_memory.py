from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from spring_haven_core.config import CoreConfig
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.roles import RoleRegistry


def main() -> None:
    parser = argparse.ArgumentParser(description="Heartloom Memory local administration")
    parser.add_argument("--config", default="user_data/core_config.json")
    parser.add_argument("--roles", default="user_data/roles.json")
    commands = parser.add_subparsers(dest="command", required=True)

    status = commands.add_parser("status")
    _filters(status, role_optional=True)

    listing = commands.add_parser("list")
    _filters(listing, role_optional=True)
    listing.add_argument("--query", default="")
    listing.add_argument("--limit", type=int, default=100)

    recall = commands.add_parser("recall")
    _filters(recall, role_optional=False)
    recall.add_argument("--query", required=True)
    recall.add_argument("--limit", type=int, default=8)

    importing = commands.add_parser("import")
    importing.add_argument("--file", type=Path, required=True)
    importing.add_argument("--save-id", default="")

    exporting = commands.add_parser("export")
    _filters(exporting, role_optional=True)
    exporting.add_argument("--file", type=Path, required=True)
    exporting.add_argument("--limit", type=int, default=500)

    deleting = commands.add_parser("delete")
    deleting.add_argument("--save-id", required=True)
    deleting.add_argument("--memory-id", required=True)

    args = parser.parse_args()
    config = CoreConfig.load(args.config)
    roles = RoleRegistry.load(args.roles)
    store = HeartloomStore(config.memory_db_path, roles.ids())
    try:
        result = _execute(store, args)
        if result is not None:
            print(json.dumps(result, ensure_ascii=False, indent=2))
    finally:
        store.close()


def _execute(store: HeartloomStore, args: argparse.Namespace) -> Any:
    if args.command == "status":
        return store.status(args.save_id, args.role_id)
    if args.command == "list":
        return {
            "entries": store.list_memories(
                save_id=args.save_id,
                role_id=args.role_id,
                query=args.query,
                limit=args.limit,
            )
        }
    if args.command == "recall":
        return {
            "entries": store.recall(
                save_id=args.save_id,
                role_id=args.role_id,
                query=args.query,
                limit=args.limit,
                record_access=False,
            )
        }
    if args.command == "import":
        parsed = json.loads(args.file.read_text(encoding="utf-8"))
        entries = parsed.get("entries", parsed) if isinstance(parsed, dict) else parsed
        if not isinstance(entries, list):
            raise SystemExit("Import file must contain an array or an entries array")
        imported = []
        for item in entries:
            if not isinstance(item, dict):
                continue
            payload = dict(item)
            if args.save_id:
                payload["save_id"] = args.save_id
            imported.append(store.put_memory(payload, source="manual"))
        return {"imported": len(imported), "entries": imported}
    if args.command == "export":
        entries = store.list_memories(
            save_id=args.save_id,
            role_id=args.role_id,
            limit=args.limit,
        )
        document = {"format": "spring_haven.heartloom.v1", "entries": entries}
        args.file.parent.mkdir(parents=True, exist_ok=True)
        args.file.write_text(
            json.dumps(document, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        return {"exported": len(entries), "file": str(args.file.resolve())}
    if args.command == "delete":
        return {"deleted": store.delete_memory(args.save_id, args.memory_id)}
    raise SystemExit("Unknown command")


def _filters(parser: argparse.ArgumentParser, *, role_optional: bool) -> None:
    parser.add_argument("--save-id", required=True)
    parser.add_argument("--role-id", required=not role_optional, default="")


if __name__ == "__main__":
    main()
