#!/usr/bin/env python3
"""Focus a status-bar agent token after validating its current tmux target."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

CACHE_PATH = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "copilot-switch.json"


def tmux(*args: str) -> str:
    return subprocess.check_output(["tmux", *args], text=True, stderr=subprocess.DEVNULL).strip()


def process_env(pid: str) -> dict[str, str]:
    try:
        raw = (Path("/proc") / pid / "environ").read_bytes()
    except OSError:
        return {}
    result: dict[str, str] = {}
    for item in raw.split(b"\0"):
        if b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        result[key.decode("utf-8", "replace")] = value.decode("utf-8", "replace")
    return result


def clear_unread(key: str) -> None:
    try:
        data = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    activity = data.get("agent_activity")
    if not isinstance(activity, dict) or key not in activity:
        return
    entry = activity.get(key)
    if not isinstance(entry, dict):
        return
    entry["unread"] = False
    try:
        tmp = CACHE_PATH.with_suffix(".jump.tmp")
        tmp.write_text(json.dumps(data, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")
        tmp.replace(CACHE_PATH)
    except OSError:
        pass


def main() -> None:
    if len(sys.argv) < 2:
        return
    token = sys.argv[1]
    if not token.startswith("ag-"):
        if token.startswith("ca-"):
            subprocess.run([str(Path.home() / ".tmux/scripts/copilot-jump.sh"), token], check=False)
        return

    try:
        raw = tmux("show-option", "-gqv", f"@agent_target_{token}")
        target = json.loads(raw)
    except (OSError, ValueError, subprocess.CalledProcessError):
        return

    session_id = str(target.get("session_id", ""))
    window_id = str(target.get("window_id", ""))
    pane_id = str(target.get("pane_id", ""))
    kind = str(target.get("kind", ""))
    key = str(target.get("key", ""))
    expected_target = str(target.get("target", ""))
    if not session_id or not window_id or not pane_id or not kind or not key:
        return

    try:
        current = tmux(
            "display-message", "-p", "-t", pane_id,
            "#{pane_id}\t#{session_id}\t#{window_id}\t"
            "#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_pid}",
        ).split("\t")
    except (OSError, subprocess.CalledProcessError):
        return

    if len(current) != 6 or current[:3] != [pane_id, session_id, window_id]:
        return
    if expected_target and current[3] != expected_target:
        return
    if kind.startswith("pi") and current[4] != "pi":
        return
    if kind == "copilot" and current[4] not in {"copilot", "node"}:
        return

    if kind == "pi-child":
        env = process_env(current[5])
        if env.get("PI_TMUX_SUBAGENT_MODE") != "child":
            return
        if env.get("PI_TMUX_SUBAGENT_ID") not in {target.get("child_id"), key.rsplit(":", 1)[-1]}:
            return

    clear_unread(key)
    subprocess.run(["tmux", "switch-client", "-t", session_id], check=False)
    subprocess.run(["tmux", "select-window", "-t", window_id], check=False)
    subprocess.run(["tmux", "select-pane", "-t", pane_id], check=False)


if __name__ == "__main__":
    main()
