#!/bin/bash
set -euo pipefail

export COPILOT_SWITCH_SCRIPT="${BASH_SOURCE[0]}"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import glob
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import re
from pathlib import Path

FZF = os.environ.get("FZF") or shutil.which("fzf") or "fzf"
SCRIPT_PATH = os.environ.get("COPILOT_SWITCH_SCRIPT", os.path.expanduser("~/.tmux/scripts/copilot-switch.sh"))
PIN_SCRIPT = os.path.expanduser("~/.tmux/scripts/copilot-pin.sh")
ACTIVE_STATUSES = {"work", "think", "input"}
COPILOT_ICON = os.environ.get(
    "TMUX_COPILOT_ICON",
    "\uec1e",  # Codicon `copilot`; requires a Nerd Font/Codicons-capable font.
)
PI_ICON = os.environ.get("TMUX_PI_ICON", "π")
STATUS_FORMAT = {
    "work": ("●", "working"),
    "think": ("◐", "thinking"),
    "input": ("!", "input"),
    "idle": ("·", "idle"),
    "dead": ("×", "dead"),
}
STATE_DIR = Path(os.path.expanduser("~/.copilot/session-state"))
SUBAGENT_BROKER_ROOT = Path(os.path.expanduser("~/.pi/agent/extensions/tmux-subagents/brokers"))
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")))
CACHE_PATH = CACHE_DIR / "copilot-switch.json"
CACHE_VERSION = 2
TAIL_BYTES = 64 * 1024
MODEL_SCAN_BYTES = 256 * 1024
USER_MSG = b'"user.message"'

TMUX_PANES_CACHE: list[dict] | None = None
PINNED_CACHE: list[str] | None = None
PROCESS_SNAPSHOT_CACHE: tuple[dict[str, str], dict[str, list[tuple[str, str, str]]]] | None = None
PARENT_STATES_CACHE: dict[str, dict] | None = None
SWITCH_CACHE: dict | None = None


def recursive_model(value):
    if isinstance(value, dict):
        model = value.get("model")
        if isinstance(model, str) and model:
            return model
        for child in value.values():
            found = recursive_model(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = recursive_model(child)
            if found:
                return found
    return None


def load_default_model() -> str:
    settings = Path(os.path.expanduser("~/.copilot/settings.json"))
    try:
        with settings.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return "?"
    return recursive_model(data) or "?"


def short_model(model: str) -> str:
    if "/" in model:
        model = model.rsplit("/", 1)[-1]
    if model.startswith("claude-"):
        model = model[len("claude-") :]
    elif model.startswith("gpt-"):
        model = "gpt-" + model[len("gpt-") :]
    return model


def event_to_status(event: str) -> str:
    if event in {
        "assistant.turn_end",
        "session.info",
        "session.start",
        "system.notification",
        "session.usage_checkpoint",
        "session.compaction_complete",
        "session.binary_asset",
        "session.plan_changed",
        "user.message",
        "",
    }:
        return "idle"
    if event in {"assistant.turn_start", "assistant.message"} or event.startswith("assistant.reasoning"):
        return "think"
    if event == "ask_user":
        return "input"
    if event in {"tool.execution_start", "hook.start", "hook.end", "tool.execution_complete"}:
        return "work"
    if event == "permission.requested":
        return "input"
    return "idle"


def load_cache() -> dict:
    global SWITCH_CACHE
    if SWITCH_CACHE is not None:
        return SWITCH_CACHE
    try:
        with CACHE_PATH.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict) and data.get("version") == CACHE_VERSION:
            SWITCH_CACHE = data
            return SWITCH_CACHE
    except Exception:
        pass
    SWITCH_CACHE = {"version": CACHE_VERSION, "sessions": {}}
    return SWITCH_CACHE


def save_cache(cache: dict) -> None:
    global SWITCH_CACHE
    SWITCH_CACHE = cache
    cache["version"] = CACHE_VERSION
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_PATH.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(cache, fh, separators=(",", ":"), ensure_ascii=False)
    tmp.replace(CACHE_PATH)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def tail_text(path: Path, limit: int = TAIL_BYTES) -> str:
    with path.open("rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - limit), os.SEEK_SET)
        return fh.read().decode("utf-8", errors="replace")


def parse_last_json_type(text: str) -> str:
    for line in reversed(text.splitlines()):
        if '"type"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        value = obj.get("type")
        if isinstance(value, str) and value:
            return value
    return ""


def detect_special_state(tail: str, last_event: str) -> str:
    """Return 'ask_user' or 'permission.requested' if one is pending.

    Uses a position-aware check: finds the LAST occurrence of the trigger
    string and verifies no completion event appears after it. This handles
    long sessions where the tail contains previous tool.execution_complete
    events from unrelated earlier tool calls.
    """
    ask_pos = tail.rfind('"ask_user"')
    if ask_pos >= 0 and '"tool.execution_complete"' not in tail[ask_pos:]:
        return "ask_user"
    perm_pos = tail.rfind('"permission.requested"')
    if perm_pos >= 0 and '"permission.completed"' not in tail[perm_pos:]:
        return "permission.requested"
    return last_event


def parse_last_model(text: str) -> str:
    for line in reversed(text.splitlines()):
        if "model_change" not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        model = obj.get("data", {}).get("newModel")
        if isinstance(model, str) and model:
            return model
    return ""


def model_from_json_line(raw: bytes) -> str:
    if b"model_change" not in raw:
        return ""
    try:
        obj = json.loads(raw)
    except Exception:
        return ""
    model = obj.get("data", {}).get("newModel")
    return model if isinstance(model, str) and model else ""


def scan_last_model(path: Path) -> str:
    """Scan backwards without repeatedly rebuilding the entire file buffer."""
    try:
        size = path.stat().st_size
    except OSError:
        return ""

    with path.open("rb") as fh:
        pos = size
        carry = b""
        while pos > 0:
            step = min(MODEL_SCAN_BYTES, pos)
            pos -= step
            fh.seek(pos)
            data = fh.read(step) + carry
            lines = data.split(b"\n")

            for line in reversed(lines[1:]):
                model = model_from_json_line(line)
                if model:
                    return model
            carry = lines[0]

        return model_from_json_line(carry)


def parse_workspace_name(path: Path) -> str:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("name:") or line.startswith("summary:"):
                    return line.split(":", 1)[1].strip() or "—"
    except Exception:
        pass
    return "—"


def read_rss_mb(pid: str) -> tuple[int, str]:
    status = Path("/proc") / pid / "status"
    try:
        with status.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    kb = int(line.split()[1])
                    mb = kb // 1024
                    if mb >= 1024:
                        val = f"{(mb * 10) // 1024}"
                        return kb, f"{val[:-1]}.{val[-1]}G"
                    return kb, f"{mb}M"
    except Exception:
        pass
    return 0, "0M"


def count_user_messages(path: Path) -> int:
    total = 0
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            total += chunk.count(USER_MSG)
    return total


def update_events_meta(sdir: Path, cache_entry: dict | None) -> dict:
    events = sdir / "events.jsonl"
    if not events.exists():
        return {
            "stat": None,
            "last_event": "",
            "status": "idle",
            "model": default_model,
            "turns": 0,
        }
    st = events.stat()
    stat_key = [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns]

    # Fast path: file unchanged
    if cache_entry and cache_entry.get("stat") == stat_key:
        if cache_entry.get("model_scanned"):
            return cache_entry
        # One-time migration: scan for real model once, then mark done
        cached_model = cache_entry.get("model", "")
        tail = tail_text(events)
        model = parse_last_model(tail)
        if not model and not (cached_model and cached_model != default_model):
            model = scan_last_model(events)
        if not model:
            model = cached_model or default_model
        cache_entry["model"] = short_model(model)
        cache_entry["model_scanned"] = True
        return cache_entry

    # File changed — read only the delta (new bytes since last cached offset)
    cached_model = cache_entry.get("model", "") if cache_entry else ""
    cached_turns = int(cache_entry.get("turns", 0)) if cache_entry else 0
    same_inode = (cache_entry and cache_entry.get("stat") and
                  cache_entry["stat"][0:2] == stat_key[0:2])
    old_size = int(cache_entry["stat"][2]) if same_inode else 0

    if same_inode and st.st_size >= old_size:
        # Read delta only
        with events.open("rb") as fh:
            if old_size:
                fh.seek(old_size)
            delta_bytes = fh.read()
        delta = delta_bytes.decode("utf-8", errors="replace")
        turns = cached_turns + delta_bytes.count(USER_MSG)

        # Status: check last 64KB of file for last event type
        tail = tail_text(events)
        last_event = parse_last_json_type(tail)

        # Model: only rescan if delta contains a model change; otherwise keep cached
        if b"model_change" in delta_bytes:
            model = parse_last_model(delta) or parse_last_model(tail) or cached_model
        else:
            model = cached_model

        # ask_user / permission detection from tail
        last_event = detect_special_state(tail, last_event)
    else:
        # New file or shrunk (rotation): full scan
        tail = tail_text(events)
        last_event = parse_last_json_type(tail)
        model = parse_last_model(tail) or scan_last_model(events)
        turns = count_user_messages(events)
        last_event = detect_special_state(tail, last_event)

    if not model:
        model = cached_model or default_model

    return {
        "stat": stat_key,
        "last_event": last_event,
        "status": event_to_status(last_event),
        "model": short_model(model),
        "turns": turns,
        "model_scanned": True,
    }


def update_workspace_meta(sdir: Path, cache_entry: dict | None) -> dict:
    ws = sdir / "workspace.yaml"
    try:
        st = ws.stat()
        stat_key = [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns]
    except Exception:
        return {"stat": None, "summary": sdir.name}

    if cache_entry and cache_entry.get("stat") == stat_key:
        return cache_entry

    summary = parse_workspace_name(ws)
    if not summary or summary == "—":
        summary = sdir.name
    if len(summary) > 30:
        summary = summary[:28] + ".."
    return {"stat": stat_key, "summary": summary}


def load_pinned(refresh: bool = False) -> list[str]:
    global PINNED_CACHE
    if PINNED_CACHE is not None and not refresh:
        return PINNED_CACHE
    try:
        out = subprocess.check_output(
            ["tmux", "show", "-gqv", "@copilot_pinned"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
        PINNED_CACHE = [u for u in out.split(",") if u]
    except (subprocess.CalledProcessError, FileNotFoundError):
        PINNED_CACHE = []
    return PINNED_CACHE


def tmux_panes(refresh: bool = False) -> list[dict]:
    global TMUX_PANES_CACHE
    if TMUX_PANES_CACHE is not None and not refresh:
        return TMUX_PANES_CACHE

    fields = [
        "pane_id",
        "session_id",
        "window_id",
        "session_name",
        "window_name",
        "window_index",
        "pane_index",
        "pane_pid",
        "pane_tty",
        "pane_current_command",
        "pane_title",
        "pane_current_path",
    ]
    try:
        out = subprocess.check_output(
            [
                "tmux",
                "list-panes",
                "-a",
                "-F",
                "\t".join(f"#{{{field}}}" for field in fields),
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        TMUX_PANES_CACHE = []
        return TMUX_PANES_CACHE

    panes: list[dict] = []
    for line in out.splitlines():
        values = line.split("\t")
        if len(values) != len(fields):
            continue
        pane = dict(zip(fields, values))
        pane["target"] = f'{pane["session_name"]}:{pane["window_index"]}.{pane["pane_index"]}'
        panes.append(pane)
    TMUX_PANES_CACHE = panes
    return TMUX_PANES_CACHE


def tmux_pane_map() -> dict[str, dict]:
    return {
        pane["pane_tty"]: pane
        for pane in tmux_panes()
        if pane.get("pane_tty")
    }


def process_snapshot(
    refresh: bool = False,
) -> tuple[dict[str, str], dict[str, list[tuple[str, str, str]]]]:
    """Snapshot tty foreground groups and their processes once per invocation."""
    global PROCESS_SNAPSHOT_CACHE
    if PROCESS_SNAPSHOT_CACHE is not None and not refresh:
        return PROCESS_SNAPSHOT_CACHE

    foreground_by_tty: dict[str, str] = {}
    processes_by_group: dict[str, list[tuple[str, str, str]]] = {}
    try:
        output = subprocess.check_output(
            ["ps", "-eo", "pid=,pgid=,tty=,tpgid=,comm=,args="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        PROCESS_SNAPSHOT_CACHE = ({}, {})
        return PROCESS_SNAPSHOT_CACHE

    for line in output.splitlines():
        fields = line.strip().split(None, 5)
        if len(fields) < 5:
            continue
        pid, pgid, tty, tpgid, comm = fields[:5]
        args = fields[5] if len(fields) == 6 else ""
        if pgid.isdigit():
            processes_by_group.setdefault(pgid, []).append((pid, comm, args))
        if tty != "?" and tpgid.isdigit() and tpgid != "-1":
            foreground_by_tty[tty] = tpgid

    PROCESS_SNAPSHOT_CACHE = (foreground_by_tty, processes_by_group)
    return PROCESS_SNAPSHOT_CACHE


def is_pi_process_record(comm: str, args: str) -> bool:
    argv0 = args.split(None, 1)[0] if args else comm
    return comm in {"pi", "pi.exe"} or Path(argv0).name in {"pi", "pi.exe"}


def find_foreground_pi_process(pane: dict, refresh: bool = False) -> str | None:
    """Find Pi only in the pane's foreground process group."""
    foreground_by_tty, processes_by_group = process_snapshot(refresh)
    tty = pane.get("pane_tty", "").removeprefix("/dev/")
    pgid = foreground_by_tty.get(tty)
    if not pgid:
        return None

    for pid, comm, args in processes_by_group.get(pgid, []):
        if is_pi_process_record(comm, args):
            return pid
    return None


def process_environment(pid: str) -> dict[str, str]:
    try:
        raw = (Path("/proc") / pid / "environ").read_bytes()
    except OSError:
        return {}

    env: dict[str, str] = {}
    for item in raw.split(b"\0"):
        if b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        env[key.decode("utf-8", errors="replace")] = value.decode("utf-8", errors="replace")
    return env


def read_json_file(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def load_parent_states(refresh: bool = False) -> dict[str, dict]:
    global PARENT_STATES_CACHE
    if PARENT_STATES_CACHE is not None and not refresh:
        return PARENT_STATES_CACHE

    states: dict[str, dict] = {}
    for broker_file in SUBAGENT_BROKER_ROOT.glob("*/broker.json"):
        broker = read_json_file(broker_file)
        broker_pane_id = broker.get("parentPaneId")
        if not broker_pane_id:
            continue
        state = read_json_file(broker_file.with_name("parent-state.json"))
        if not state or state.get("parentSessionId") != broker.get("parentSessionId"):
            continue
        state_pane_id = state.get("paneId")
        if state_pane_id and state_pane_id != broker_pane_id:
            continue
        previous = states.get(broker_pane_id)
        state_rank = (
            int(state.get("updatedAt") or 0),
            1 if state.get("status") == "running" else 0,
        )
        previous_rank = (
            int(previous.get("updatedAt") or 0),
            1 if previous.get("status") == "running" else 0,
        ) if previous else (-1, -1)
        if previous is None or state_rank > previous_rank:
            states[broker_pane_id] = state

    PARENT_STATES_CACHE = states
    return PARENT_STATES_CACHE


def load_live_subagent(pane: dict, refresh_process: bool = False) -> dict | None:
    """Return validated broker metadata for a live child Pi pane."""
    pi_pid = find_foreground_pi_process(pane, refresh_process)
    if not pi_pid:
        return None

    env = process_environment(pi_pid)
    if env.get("PI_TMUX_SUBAGENT_MODE") != "child":
        return None

    child_id = env.get("PI_TMUX_SUBAGENT_ID", "")
    broker_raw = env.get("PI_TMUX_SUBAGENT_BROKER_DIR", "")
    child_raw = env.get("PI_TMUX_SUBAGENT_CHILD_DIR", "")
    parent_session_id = env.get("PI_TMUX_SUBAGENT_PARENT_SESSION_ID", "")
    if not child_id or not broker_raw or not child_raw or not parent_session_id:
        return None

    broker_dir = Path(broker_raw).expanduser()
    child_dir = Path(child_raw).expanduser()
    try:
        expected_child_dir = (broker_dir / "children" / child_id).resolve()
        if child_dir.resolve() != expected_child_dir:
            return None
    except OSError:
        return None

    launch = read_json_file(child_dir / "launch.json")
    broker = read_json_file(broker_dir / "broker.json")
    if (
        launch.get("childId") != child_id
        or launch.get("paneId") != pane.get("pane_id")
        or launch.get("parentSessionId") != parent_session_id
        or broker.get("parentSessionId") != parent_session_id
    ):
        return None

    state = read_json_file(child_dir / "state.json")
    if state.get("childId") not in {None, "", child_id}:
        state = {}

    return {
        "pi_pid": pi_pid,
        "child_id": child_id,
        "parent_session_id": parent_session_id,
        # broker.json is the current parent location; launch.json is the
        # spawn-time fallback for older brokers or before a parent refresh.
        "parent_pane_id": broker.get("parentPaneId") or launch.get("parentPaneId"),
        "parent_window_id": broker.get("parentWindowId") or launch.get("parentWindowId"),
        "parent_tmux_session_id": broker.get("parentTmuxSessionId") or launch.get("parentTmuxSessionId"),
        "launch": launch,
        "state": state,
        "name": launch.get("name") or env.get("PI_TMUX_SUBAGENT_NAME") or child_id,
    }


def active_locks() -> list[Path]:
    return [Path(p) for p in glob.glob(str(STATE_DIR / "*" / "inuse.*.lock"))]


def pid_from_lock(lock: Path) -> str:
    name = lock.name
    if not name.startswith("inuse.") or not name.endswith(".lock"):
        return ""
    return name[len("inuse.") : -len(".lock")]


def is_copilot_process(pid: str) -> bool:
    proc = Path("/proc") / pid
    try:
        comm = (proc / "comm").read_text(encoding="utf-8", errors="replace").strip()
        argv0 = (proc / "cmdline").read_bytes().split(b"\0", 1)[0].decode("utf-8", errors="replace")
    except OSError:
        return False
    return comm in {"copilot", "copilot.exe"} or Path(argv0).name in {"copilot", "copilot.exe"}


def tty_for_pid(pid: str) -> str:
    proc = Path("/proc") / pid / "fd"
    for fd in ("0", "1", "2"):
        try:
            target = os.readlink(proc / fd)
        except OSError:
            continue
        if target.startswith("/dev/"):
            return target
    try:
        out = subprocess.check_output(["ps", "-o", "tty=", "-p", pid], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return ""
    tty = out.strip()
    if not tty or tty == "?":
        return ""
    return f"/dev/{tty}"


def format_mem(kb: int) -> str:
    mb = kb // 1024
    if mb >= 1024:
        val = (mb * 10) // 1024
        return f"{val // 10}.{val % 10}G"
    return f"{mb}M"


def build_rows() -> list[dict]:
    panes = tmux_pane_map()
    cache = load_cache()
    sessions_cache = cache.setdefault("sessions", {})
    activity_cache = cache.setdefault("agent_activity", {})
    rows: list[dict] = []
    seen_pids: set[str] = set()

    for lock in active_locks():
        pid = pid_from_lock(lock)
        if not pid or pid in seen_pids or not Path("/proc", pid).exists():
            continue
        seen_pids.add(pid)
        if not is_copilot_process(pid):
            continue

        tty = tty_for_pid(pid)
        if not tty:
            continue

        pane_info = panes.get(tty)
        if not pane_info or pane_info.get("pane_current_command") not in {"copilot", "node"}:
            continue
        pane = pane_info["target"]
        wname = pane_info["window_name"]

        sdir = lock.parent
        key = str(sdir)
        session_cache = sessions_cache.get(key, {})

        if not (sdir / "events.jsonl").exists():
            continue

        events_cache = session_cache.get("events")
        ws_cache = session_cache.get("workspace")

        events_meta = update_events_meta(sdir, events_cache)
        ws_meta = update_workspace_meta(sdir, ws_cache)
        activity_key = f"copilot:{sdir.name}"
        activity_signature = json.dumps(events_meta.get("stat"), separators=(",", ":"), sort_keys=True)
        unread = update_unread(
            activity_cache,
            activity_key,
            activity_signature,
            events_meta["status"] in ACTIVE_STATUSES,
        )

        rss_kb, mem = read_rss_mb(pid)
        rows.append(
            {
                "kind": "copilot",
                "group_id": f"copilot:{sdir.name}",
                "pane": pane,
                "wname": wname,
                "display": f"{COPILOT_ICON}  {pane} [{wname}]",
                "session_id": pane_info["session_id"],
                "window_id": pane_info["window_id"],
                "pane_id": pane_info["pane_id"],
                "status": events_meta["status"],
                "status_text": events_meta["status"],
                "unread": unread,
                "color_status": "unread" if unread and events_meta["status"] == "idle" else events_meta["status"],
                "read_key": activity_key,
                "activity_signature": activity_signature,
                "mem_kb": rss_kb,
                "mem": mem,
                "turns": str(events_meta["turns"]),
                "model": events_meta["model"],
                "summary": ws_meta["summary"],
                "uuid": sdir.name,
                "pin_id": sdir.name,
                "mtime_ns": events_meta["stat"][3] if events_meta.get("stat") else 0,
                "events_cache": events_meta,
                "ws_cache": ws_meta,
            }
        )

        sessions_cache[key] = {"events": events_meta, "workspace": ws_meta}

    cache["sessions"] = sessions_cache
    save_cache(cache)

    pinned_list = load_pinned()
    pinned_order = {uuid: i for i, uuid in enumerate(pinned_list)}
    for r in rows:
        r["pinned"] = r["uuid"] in pinned_order
    rows.sort(key=lambda r: (
        0 if r["pinned"] else 1,
        pinned_order.get(r["uuid"], 0),
        0 if r["status"] in ACTIVE_STATUSES else 1 if r.get("unread") else 2,
        -r["mtime_ns"],
        -r["mem_kb"],
    ))
    return rows


def shorten_display(value: object, limit: int = 42) -> str:
    text = " ".join(str(value or "").split())
    if not text:
        return "—"
    return text if len(text) <= limit else f"{text[:limit - 2]}.."


def update_unread(activity_cache: dict, key: str, signature: str, active: bool) -> bool:
    if not signature:
        return False
    previous = activity_cache.get(key)
    if not isinstance(previous, dict) or "signature" not in previous:
        unread = False
    else:
        unread = bool(previous.get("unread"))
        if not active and previous.get("signature") != signature:
            unread = True
    activity_cache[key] = {"signature": signature, "unread": unread}
    return unread


def pi_pin_id(pane: dict, child: dict | None) -> str:
    if child:
        return f"pi-child:{child['child_id']}"

    identity = "\x1f".join(
        [
            pane.get("session_name", ""),
            pane.get("window_name", ""),
            pane.get("pane_current_path", ""),
            pane.get("pane_title", ""),
            pane.get("pane_id", ""),
            pane.get("pi_pid", ""),
        ]
    )
    digest = hashlib.sha256(identity.encode("utf-8", errors="replace")).hexdigest()[:16]
    return f"pi-root:{digest}"


def make_pi_row(
    pane: dict,
    child: dict | None,
    tree_prefix: str = "",
    tree_branch: str = "",
    orphan: bool = False,
) -> dict:
    if child:
        state = child["state"]
        raw_state = str(state.get("status") or "idle")
        if state.get("busy") or raw_state == "running":
            status = "work"
            status_text = "running"
        elif raw_state in {"stopped", "error"}:
            status = "dead"
            status_text = raw_state
        else:
            status = "idle"
            status_text = raw_state

        name = shorten_display(child["name"], 42)
        if orphan:
            name = f"{name} [orphan]"
        display = f"{PI_ICON}  {tree_prefix}{tree_branch}{name} [{pane['target']}]"
        launch = child["launch"]
        model = launch.get("model") or "?"
        summary = (
            f"tool: {state['lastTool']}"
            if state.get("lastTool")
            else state.get("lastReportSummary")
            or launch.get("task")
            or pane.get("pane_current_path")
        )
        pin_id = pi_pin_id(pane, child)
        row_id = child["child_id"]
    else:
        title = pane.get("pane_title") or pane.get("window_name") or pane.get("pane_current_path")
        if title.startswith("π - "):
            title = title[4:]
        display = f"{PI_ICON}  {shorten_display(title, 52)} [{pane['target']}]"
        parent_state = pane.get("parent_state") or {}
        raw_state = str(parent_state.get("status") or "idle")
        if raw_state == "running" or parent_state.get("busy"):
            status = "work"
            status_text = "running"
        elif raw_state == "stopped":
            status = "dead"
            status_text = "stopped"
        elif parent_state:
            status = "idle"
            status_text = "idle"
        else:
            status = "idle"
            status_text = "—"
        model = parent_state.get("model") or "?"
        summary = parent_state.get("sessionFile") or pane.get("pane_current_path") or "—"
        pin_id = pi_pin_id(pane, None)
        row_id = pane["pane_id"]

    pi_pid = child["pi_pid"] if child else pane.get("pi_pid")
    rss_kb, mem = read_rss_mb(pi_pid) if pi_pid else (0, "0M")
    return {
        "kind": "pi-child" if child else "pi",
        "pane": pane["target"],
        "wname": pane["window_name"],
        "display": display,
        "session_id": pane["session_id"],
        "window_id": pane["window_id"],
        "pane_id": pane["pane_id"],
        "status": status,
        "status_text": status_text,
        "unread": bool(pane.get("pi_unread")),
        "color_status": "unread" if pane.get("pi_unread") and status == "idle" else status,
        "read_key": (
            f"pi-child:{child['child_id']}"
            if child
            else f"pi-parent:{pane['parent_state']['parentSessionId']}"
            if pane.get("parent_state")
            else f"pi-pane:{pane['pane_id']}"
        ),
        "activity_signature": pane.get("pi_activity_signature", ""),
        "mem_kb": rss_kb,
        "mem": mem,
        "turns": "—",
        "model": short_model(str(model)),
        "summary": shorten_display(summary),
        "uuid": row_id,
        "pin_id": pin_id,
        "pinned": False,
        "mtime_ns": int(child["launch"].get("createdAt") or 0) if child else 0,
    }


def build_pi_rows() -> list[dict]:
    panes = [pane for pane in tmux_panes() if pane.get("pane_current_command") == "pi"]
    if not panes:
        return []

    cache = load_cache()
    activity_cache = cache.setdefault("agent_activity", {})
    parent_states = load_parent_states()
    for pane in panes:
        child = load_live_subagent(pane)
        pane["subagent"] = child
        pane["parent_state"] = parent_states.get(pane["pane_id"]) if not child else None
        pane["pi_pid"] = child["pi_pid"] if child else find_foreground_pi_process(pane)
        pane["pi_unread"] = False
        pane["pi_activity_signature"] = ""
        if child:
            state = child["state"]
            raw_state = str(state.get("status") or "idle")
            active = bool(state.get("busy")) or raw_state == "running"
            signature = json.dumps(
                {
                    "status": raw_state,
                    "busy": bool(state.get("busy")),
                    "updatedAt": state.get("updatedAt"),
                    "lastTool": state.get("lastTool"),
                    "lastReportAt": state.get("lastReportAt"),
                    "lastAssistantText": state.get("lastAssistantText"),
                },
                separators=(",", ":"),
                sort_keys=True,
            )
            activity_key = f"pi-child:{child['child_id']}"
            pane["pi_unread"] = update_unread(activity_cache, activity_key, signature, active)
            pane["pi_activity_signature"] = signature
        elif pane["parent_state"]:
            parent_state = pane["parent_state"]
            raw_state = str(parent_state.get("status") or "idle")
            active = bool(parent_state.get("busy")) or raw_state == "running"
            signature = json.dumps(parent_state, separators=(",", ":"), sort_keys=True)
            activity_key = f"pi-parent:{parent_state.get('parentSessionId', pane['pane_id'])}"
            pane["pi_unread"] = update_unread(activity_cache, activity_key, signature, active)
            pane["pi_activity_signature"] = signature

    by_id = {pane["pane_id"]: pane for pane in panes}
    pinned = set(load_pinned())
    children_by_parent: dict[str, list[dict]] = {}
    roots: list[tuple[dict, bool]] = []

    for pane in panes:
        child = pane.get("subagent")
        parent_id = child.get("parent_pane_id") if child else None
        parent = by_id.get(parent_id) if parent_id else None
        # Pane IDs survive tmux moves; window/session IDs do not. The current
        # broker parentPaneId is therefore the only location authority here.
        if child and parent and parent_id != pane["pane_id"]:
            children_by_parent.setdefault(parent_id, []).append(pane)
        else:
            roots.append((pane, bool(child)))

    for children in children_by_parent.values():
        children.sort(key=lambda item: (
            0 if pi_pin_id(item, item["subagent"]) in pinned else 1,
            int(item["subagent"]["launch"].get("createdAt") or 0),
            item["subagent"]["name"].lower(),
        ))

    roots.sort(key=lambda item: (
        0 if pi_pin_id(item[0], item[0].get("subagent")) in pinned else 1,
        item[0]["target"],
    ))

    rows: list[dict] = []
    visited: set[str] = set()

    def append_tree(
        pane: dict,
        tree_prefix: str = "",
        tree_branch: str = "",
        depth: int = 0,
        orphan: bool = False,
        group_id: str | None = None,
    ) -> None:
        pane_id = pane["pane_id"]
        if pane_id in visited:
            return
        visited.add(pane_id)
        group_id = group_id or pane_id
        row = make_pi_row(pane, pane.get("subagent"), tree_prefix, tree_branch, orphan)
        row["group_id"] = f"pi:{group_id}"
        rows.append(row)

        children = children_by_parent.get(pane_id, [])
        child_prefix = tree_prefix
        if tree_branch:
            child_prefix += "   " if tree_branch == "└─ " else "│  "
        for index, child_pane in enumerate(children):
            last = index == len(children) - 1
            append_tree(
                child_pane,
                child_prefix,
                "└─ " if last else "├─ ",
                depth + 1,
                group_id=group_id,
            )

    for pane, orphan in roots:
        append_tree(pane, orphan=orphan, tree_branch="└─ " if orphan else "")

    # A broker/layout cycle or an unexpected stale relationship must not hide a live pane.
    for pane in panes:
        if pane["pane_id"] not in visited:
            append_tree(pane, tree_branch="└─ ", orphan=bool(pane.get("subagent")))

    for row in rows:
        row["pinned"] = row["pin_id"] in pinned
    save_cache(cache)
    return rows


def format_status(row: dict) -> str:
    symbol, default_label = STATUS_FORMAT.get(row.get("status", "idle"), ("·", "unknown"))
    raw_label = str(row.get("status_text") or "").strip()
    if row.get("status") == "idle" and raw_label in {"", "—"}:
        label = "unknown"
    elif row.get("status") == "idle" and raw_label != "idle":
        label = raw_label
    elif row.get("status") == "dead" and raw_label:
        label = raw_label
    else:
        label = default_label
    return f"{symbol} {label}"


def pad_lines(rows: list[dict]) -> tuple[str, list[tuple[str, str]], dict[str, int]]:
    header = ["PANE", "STATUS", "RAM", "TURNS", "MODEL", "SUMMARY"]
    data: list[tuple[str, list[str]]] = []
    widths = [len(h) for h in header]
    for row in rows:
        pane = row.get("display") or f'{row["pane"]} [{row["wname"]}]'
        status = format_status(row)
        cols = [pane, status, row["mem"], row["turns"], row["model"], row["summary"]]
        data.append((row["pane"], cols))
        for i, col in enumerate(cols):
            widths[i] = max(widths[i], len(col))

    header_line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(header))
    lines = [
        "  ".join(
            [
                cols[0].ljust(widths[0]),
                cols[1].ljust(widths[1]),
                cols[2].rjust(widths[2]),
                cols[3].rjust(widths[3]),
                cols[4].ljust(widths[4]),
                cols[5].ljust(widths[5]),
            ]
        )
        for _, cols in data
    ]
    return header_line, lines, {k: widths[i] for i, k in enumerate(header)}


def order_agent_rows(rows: list[dict]) -> list[dict]:
    groups: dict[str, list[dict]] = {}
    first_index: dict[str, int] = {}
    for index, row in enumerate(rows):
        group_id = row.get("group_id", f"row:{index}")
        groups.setdefault(group_id, []).append(row)
        first_index.setdefault(group_id, index)

    def activity_priority(group_rows: list[dict]) -> int:
        if any(row.get("status") in ACTIVE_STATUSES for row in group_rows):
            return 0
        if any(row.get("unread") for row in group_rows):
            return 1
        return 2

    ordered_groups = sorted(
        groups.values(),
        key=lambda group_rows: (
            0 if any(row.get("pinned") for row in group_rows) else 1,
            activity_priority(group_rows),
            first_index[group_rows[0].get("group_id", "")],
        ),
    )
    return [row for group_rows in ordered_groups for row in group_rows]


default_model = load_default_model()
rows = order_agent_rows(build_rows() + build_pi_rows())

if not rows:
    subprocess.run(["tmux", "display-message", "No Copilot or Pi sessions found"], check=False)
    raise SystemExit(0)

header, lines, _ = pad_lines(rows)
ansi_re = re.compile(r"\x1b\[[0-9;]*m")

colors = {
    "work": "\033[1;92m",
    "think": "\033[1;93m",
    "input": "\033[1;96m",
    "idle": "\033[90m",
    "unread": "\033[97m",
    "dead": "\033[1;91m",
}
reset = "\033[0m"

if "--list" in sys.argv[1:]:
    print(header)
    for row, line in zip(rows, lines):
        pin_mark = "◉ " if row.get("pinned") else "  "
        color_status = row.get("color_status", row["status"])
        print(f"{colors.get(color_status, '')}{pin_mark}{line}{reset}")
    raise SystemExit(0)


def make_fzf_lines() -> list[str]:
    result = []
    for row, line in zip(rows, lines):
        pin_mark = "◉ " if row.get("pinned") else "  "
        color_status = row.get("color_status", row["status"])
        colored = f"{colors.get(color_status, '')}{pin_mark}{line}{reset}"
        # Keep tmux IDs opaque and hidden; the visible text is the final field.
        result.append(
            f"{row.get('kind', 'copilot')}\t{row.get('pin_id', row['uuid'])}\t"
            f"{row['session_id']}\t{row['window_id']}\t{row['pane_id']}\t"
            f"{row['pane']}\t{colored}"
        )
    return result


if "--fzf-input" in sys.argv[1:]:
    print("\n".join(make_fzf_lines()))
    raise SystemExit(0)

def fzf_reload_loop(socket_path: str, stop_event: threading.Event) -> None:
    """Refresh the popup through fzf's local Unix-socket API."""
    action = f"reload({SCRIPT_PATH} --fzf-input)".encode("utf-8")
    request = (
        b"POST / HTTP/1.1\r\n"
        b"Host: localhost\r\n"
        + f"Content-Length: {len(action)}\r\n".encode("ascii")
        + b"Connection: close\r\n\r\n"
        + action
    )
    while not stop_event.wait(1.0):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.25)
                client.connect(socket_path)
                client.sendall(request)
        except OSError:
            # fzf may not have created the socket yet or may have exited.
            continue


payload = "\n".join(make_fzf_lines())
listen_path = f"/tmp/copilot-switch-{os.getpid()}.sock"
try:
    Path(listen_path).unlink()
except FileNotFoundError:
    pass

stop_refresh = threading.Event()
refresh_thread = threading.Thread(
    target=fzf_reload_loop,
    args=(listen_path, stop_refresh),
    daemon=True,
)
refresh_thread.start()
try:
    fzf = subprocess.run(
        [
            FZF,
            "--tmux",
            "80%,50%",
            "--reverse",
            "--ansi",
            "--delimiter",
            "\t",
            "--with-nth",
            "7..",
            f"--header=  {header}",
            "--prompt=agent> ",
            f"--listen={listen_path}",
            f"--bind=ctrl-p:execute-silent({PIN_SCRIPT} toggle {{2}})+reload({SCRIPT_PATH} --fzf-input)",
            "--bind=ctrl-p:+change-header(  ◉ pin toggled — reloading...)",
        ],
        input=payload,
        text=True,
        capture_output=True,
    )
finally:
    stop_refresh.set()
    refresh_thread.join(timeout=1.0)
    try:
        Path(listen_path).unlink()
    except FileNotFoundError:
        pass

if fzf.returncode != 0:
    raise SystemExit(0)


def mark_row_read(pin_id: str) -> None:
    row = next((item for item in rows if item.get("pin_id") == pin_id), None)
    if not row or not row.get("read_key") or not row.get("activity_signature"):
        return
    cache = load_cache()
    cache.setdefault("agent_activity", {})[row["read_key"]] = {
        "signature": row["activity_signature"],
        "unread": False,
    }
    save_cache(cache)


def validate_selection(
    kind: str,
    pin_id: str,
    session_id: str,
    window_id: str,
    pane_id: str,
    target: str,
) -> bool:
    try:
        current = subprocess.check_output(
            [
                "tmux",
                "display-message",
                "-p",
                "-t",
                pane_id,
                "#{pane_id}\t#{session_id}\t#{window_id}\t"
                "#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip().split("\t")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

    if len(current) != 5 or current[:4] != [pane_id, session_id, window_id, target]:
        return False

    command = current[4]
    if kind.startswith("pi"):
        if command != "pi":
            return False
        if kind == "pi-child":
            pane = next((item for item in tmux_panes(refresh=True) if item.get("pane_id") == pane_id), None)
            child = load_live_subagent(pane, refresh_process=True) if pane else None
            return bool(child and pin_id == f"pi-child:{child['child_id']}")
        return True

    # Copilot panes normally report `copilot`; allow a direct node wrapper too.
    return kind == "copilot" and command in {"copilot", "node"}


selected = fzf.stdout.strip()
if not selected:
    raise SystemExit(0)

fields = ansi_re.sub("", selected).split("\t")
if len(fields) < 6:
    raise SystemExit(0)

kind = fields[0]
pin_id = fields[1]
session_id = fields[2]
window_id = fields[3]
pane_id = fields[4]
target = fields[5]
if not session_id or not window_id or not pane_id or not target:
    raise SystemExit(0)

if not validate_selection(kind, pin_id, session_id, window_id, pane_id, target):
    subprocess.run(["tmux", "display-message", "Agent disappeared before selection"], check=False)
    raise SystemExit(0)

mark_row_read(pin_id)
subprocess.run(["tmux", "switch-client", "-t", session_id], check=False)
subprocess.run(["tmux", "select-window", "-t", window_id], check=False)
subprocess.run(["tmux", "select-pane", "-t", pane_id], check=False)
PY
