#!/usr/bin/env python3
"""ADR-016 修订1:导演注入 CLI(演示排期/作者推剧情用)。

用法:
  python tools/plot_direct.py --save my-save --plot first-thunder \\
      --action enter --beat storm-night \\
      --observation "初雷之夜,客厅的灯只剩她那一盏"

  python tools/plot_direct.py --save my-save --plot first-thunder \\
      --action resolve --choice stay \\
      --observation "主人推门进了客厅"

observation 必填:导演只能通过「她能感知到的东西」改变世界;没有 observation
的注入在入口就被拒绝。密钥用 --key 或环境变量 SPRING_HAVEN_CORE_KEY。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser(description="Spring Haven 导演注入(节拍级)")
    parser.add_argument("--base-url", default="http://127.0.0.1:18340")
    parser.add_argument("--key", default=os.getenv("SPRING_HAVEN_CORE_KEY", ""))
    parser.add_argument("--save", required=True, help="存档 id")
    parser.add_argument("--plot", required=True, help="剧本 plot_id")
    parser.add_argument("--action", required=True, choices=["enter", "resolve"])
    parser.add_argument("--beat", default="", help="enter: 目标节拍 id")
    parser.add_argument("--choice", default="", help="resolve: 选项 id")
    parser.add_argument("--observation", required=True,
                        help="她能第一人称感知到的文本(必填)")
    args = parser.parse_args()

    if not args.key:
        print("缺少 --key 或环境变量 SPRING_HAVEN_CORE_KEY", file=sys.stderr)
        return 2
    payload: dict[str, str] = {
        "save_id": args.save,
        "plot_id": args.plot,
        "action": args.action,
        "observation": args.observation,
    }
    if args.beat:
        payload["beat_id"] = args.beat
    if args.choice:
        payload["choice_id"] = args.choice

    request = urllib.request.Request(
        f"{args.base_url.rstrip('/')}/plot/direct",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-API-Key": args.key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')}", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"连接失败: {exc.reason}", file=sys.stderr)
        return 1
    if body.get("status") != "ok":
        print(f"core error: {body}", file=sys.stderr)
        return 1
    data = body.get("data", {})
    print(f"entry_id: {data.get('entry_id', '')}")
    print(json.dumps(data.get("status", {}), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
