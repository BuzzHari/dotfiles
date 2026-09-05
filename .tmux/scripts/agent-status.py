#!/usr/bin/env python3
"""Render the combined Copilot/Pi agent bar for tmux."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

HOME = Path.home()
COPILOT_STATE = HOME / ".copilot" / "session-state"
BROKER_ROOT = HOME / ".pi" / "agent" / "extensions" / "tmux-subagents" / "brokers"
CACHE_PATH = Path(os.environ.get("XDG_CACHE_HOME", str(HOME / ".cache"))) / "copilot-switch.json"
BAR_BG = "colour233"
SEP = "colour238"
LEFT_CAP = "\ue0b6"
RIGHT_CAP = "\ue0b4"
COPILOT_ICON = os.environ.get("TMUX_COPILOT_ICON", "\uec1e")
PI_ICON = os.environ.get("TMUX_PI_ICON", "π")
MAX_PINNED = 99
MAX_NONPINNED = 3
ACTIVE = {"work", "think", "wait"}


def tmux_panes() -> list[dict]:
    fields = [
        "pane_id", "session_id", "window_id", "session_name", "window_name",
        "window_index", "pane_index", "pane_pid", "pane_tty",
        "pane_current_command", "pane_title", "pane_current_path",
    ]
    try:
        output = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F", "\t".join(f"#{{{f}}}" for f in fields)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return []

    result: list[dict] = []
    for line in output.splitlines():
        values = line.split("\t")
        if len(values) != len(fields):
            continue
        pane = dict(zip(fields, values))
        pane["target"] = f'{pane["session_name"]}:{pane["window_index"]}.{pane["pane_index"]}'
        result.append(pane)
    return result


def process_snapshot() -> tuple[dict[str, str], dict[str, list[tuple[str, str, str]]]]:
    foreground: dict[str, str] = {}
    groups: dict[str, list[tuple[str, str, str]]] = {}
    try:
        output = subprocess.check_output(
            ["ps", "-eo", "pid=,pgid=,tty=,tpgid=,comm=,args="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return foreground, groups

    for line in output.splitlines():
        fields = line.strip().split(None, 5)
        if len(fields) < 5:
            continue
        pid, pgid, tty, tpgid, comm = fields[:5]
        args = fields[5] if len(fields) == 6 else ""
        if pgid.isdigit():
            groups.setdefault(pgid, []).append((pid, comm, args))
        if tty != "?" and tpgid.isdigit() and tpgid != "-1":
            foreground[tty] = tpgid
    return foreground, groups


def is_pi_record(comm: str, args: str) -> bool:
    argv0 = args.split(None, 1)[0] if args else comm
    return comm in {"pi", "pi.exe"} or Path(argv0).name in {"pi", "pi.exe"}


def foreground_pi_pid(pane: dict, snapshot: tuple[dict[str, str], dict[str, list[tuple[str, str, str]]]]) -> str | None:
    foreground, groups = snapshot
    tty = pane.get("pane_tty", "").removeprefix("/dev/")
    pgid = foreground.get(tty)
    if not pgid:
        return None
    for pid, comm, args in groups.get(pgid, []):
        if is_pi_record(comm, args):
            return pid
    return None


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


def is_copilot_pid(pid: str) -> bool:
    proc = Path("/proc") / pid
    try:
        comm = (proc / "comm").read_text(encoding="utf-8", errors="replace").strip()
        argv0 = (proc / "cmdline").read_bytes().split(b"\0", 1)[0].decode("utf-8", "replace")
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
        value = subprocess.check_output(
            ["ps", "-o", "tty=", "-p", pid], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""
    return "" if not value or value == "?" else f"/dev/{value}"


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def read_tail(path: Path, limit: int = 64 * 1024) -> str:
    try:
        with path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - limit))
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def event_to_status(event: str) -> str:
    if event in {
        "assistant.turn_end", "session.info", "session.start", "system.notification",
        "session.usage_checkpoint", "session.compaction_complete", "session.binary_asset",
        "session.plan_changed", "user.message", "",
    }:
        return "idle"
    if event in {"assistant.turn_start", "assistant.message"} or event.startswith("assistant.reasoning"):
        return "think"
    if event in {"tool.execution_start", "hook.start", "hook.end", "tool.execution_complete"}:
        return "work"
    if event in {"ask_user", "permission.requested"}:
        return "wait"
    return "idle"


def copilot_event_status(path: Path) -> str:
    tail = read_tail(path)
    lines = tail.splitlines()
    last_event = ""
    ask_pending = False
    permission_pending = False
    for line in lines:
        try:
            value = json.loads(line).get("type", "")
        except ValueError:
            value = ""
        if value:
            last_event = value
        if '"ask_user"' in line:
            ask_pending = True
        if '"tool.execution_complete"' in line and ask_pending:
            ask_pending = False
        if '"permission.requested"' in line:
            permission_pending = True
        if '"permission.completed"' in line and permission_pending:
            permission_pending = False
    if ask_pending:
        return "wait"
    if permission_pending:
        return "wait"
    return event_to_status(last_event)


def workspace_name(path: Path) -> str:
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("name:") or line.startswith("summary:"):
                return line.split(":", 1)[1].strip() or path.parent.name
    except OSError:
        pass
    return path.parent.name


def short(value: object, length: int = 13) -> str:
    text = " ".join(str(value or "").split())
    if len(text) <= length:
        return text
    return text[: max(1, length - 2)] + ".."


def load_cache() -> dict:
    value = read_json(CACHE_PATH)
    return value if value.get("version") == 2 else {"version": 2, "sessions": {}}


def save_cache(cache: dict) -> None:
    cache["version"] = 2
    try:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = CACHE_PATH.with_suffix(".status.tmp")
        tmp.write_text(json.dumps(cache, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")
        tmp.replace(CACHE_PATH)
    except OSError:
        pass


def update_unread(activity: dict, key: str, signature: str, active: bool, dirty: list[bool]) -> bool:
    previous = activity.get(key)
    if not isinstance(previous, dict) or "signature" not in previous:
        unread = False
    else:
        unread = bool(previous.get("unread"))
        if not active and previous.get("signature") != signature:
            unread = True
    next_value = {"signature": signature, "unread": unread}
    if previous != next_value:
        dirty[0] = True
    activity[key] = next_value
    return unread


def load_pinned() -> set[str]:
    try:
        value = subprocess.check_output(
            ["tmux", "show", "-gqv", "@copilot_pinned"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return set()
    return {item for item in value.split(",") if item}


def load_parent_states() -> dict[str, dict]:
    result: dict[str, dict] = {}
    for broker_file in BROKER_ROOT.glob("*/broker.json"):
        broker = read_json(broker_file)
        pane_id = broker.get("parentPaneId")
        if not pane_id:
            continue
        state = read_json(broker_file.with_name("parent-state.json"))
        if state.get("parentSessionId") != broker.get("parentSessionId"):
            continue
        if state.get("paneId") and state.get("paneId") != pane_id:
            continue
        previous = result.get(pane_id)
        state_rank = (
            int(state.get("updatedAt") or 0),
            1 if state.get("status") == "running" else 0,
        )
        previous_rank = (
            int(previous.get("updatedAt") or 0),
            1 if previous.get("status") == "running" else 0,
        ) if previous else (-1, -1)
        if previous is None or state_rank > previous_rank:
            result[pane_id] = state
    return result


def load_live_child(pane: dict, snapshot: tuple[dict[str, str], dict[str, list[tuple[str, str, str]]]]) -> dict | None:
    pid = foreground_pi_pid(pane, snapshot)
    if not pid:
        return None
    env = process_env(pid)
    if env.get("PI_TMUX_SUBAGENT_MODE") != "child":
        return None
    child_id = env.get("PI_TMUX_SUBAGENT_ID", "")
    broker_raw = env.get("PI_TMUX_SUBAGENT_BROKER_DIR", "")
    child_raw = env.get("PI_TMUX_SUBAGENT_CHILD_DIR", "")
    parent_session = env.get("PI_TMUX_SUBAGENT_PARENT_SESSION_ID", "")
    if not child_id or not broker_raw or not child_raw or not parent_session:
        return None

    broker_dir = Path(broker_raw).expanduser()
    child_dir = Path(child_raw).expanduser()
    try:
        if child_dir.resolve() != (broker_dir / "children" / child_id).resolve():
            return None
    except OSError:
        return None

    launch = read_json(child_dir / "launch.json")
    broker = read_json(broker_dir / "broker.json")
    if (
        launch.get("childId") != child_id
        or launch.get("paneId") != pane["pane_id"]
        or launch.get("parentSessionId") != parent_session
        or broker.get("parentSessionId") != parent_session
    ):
        return None
    state = read_json(child_dir / "state.json")
    if state.get("childId") not in {None, "", child_id}:
        state = {}
    return {
        "pid": pid,
        "child_id": child_id,
        "parent_session": parent_session,
        "parent_pane": broker.get("parentPaneId") or launch.get("parentPaneId"),
        "name": launch.get("name") or env.get("PI_TMUX_SUBAGENT_NAME") or child_id,
        "model": launch.get("model") or "?",
        "state": state,
    }


def target_for(row: dict) -> dict:
    return {
        "key": row["key"],
        "kind": row["kind"],
        "session_id": row["session_id"],
        "window_id": row["window_id"],
        "pane_id": row["pane_id"],
        "target": row["target"],
        "child_id": row.get("child_id"),
    }


def collect_rows() -> tuple[list[dict], dict, bool]:
    panes = tmux_panes()
    by_tty = {pane["pane_tty"]: pane for pane in panes if pane.get("pane_tty")}
    by_id = {pane["pane_id"]: pane for pane in panes}
    pi_panes = [pane for pane in panes if pane.get("pane_current_command") == "pi"]
    snapshot = process_snapshot()
    cache = load_cache()
    activity = cache.setdefault("agent_activity", {})
    dirty = [False]
    rows: list[dict] = []
    pinned = load_pinned()

    seen_pids: set[str] = set()
    for lock in COPILOT_STATE.glob("*/inuse.*.lock"):
        pid = lock.name.removeprefix("inuse.").removesuffix(".lock")
        if not pid.isdigit() or pid in seen_pids or not is_copilot_pid(pid):
            continue
        seen_pids.add(pid)
        tty = tty_for_pid(pid)
        pane = by_tty.get(tty)
        if not pane or pane.get("pane_current_command") not in {"copilot", "node"}:
            continue
        session_dir = lock.parent
        events = session_dir / "events.jsonl"
        if not events.exists():
            continue
        stat = events.stat()
        status = copilot_event_status(events)
        key = f"copilot:{session_dir.name}"
        signature = json.dumps(
            [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns],
            separators=(",", ":"),
            sort_keys=True,
        )
        unread = update_unread(activity, key, signature, status not in {"idle"}, dirty)
        rows.append({
            "key": key,
            "group": key,
            "kind": "copilot",
            "pin_id": session_dir.name,
            "label": f"{COPILOT_ICON} {short(workspace_name(session_dir / 'workspace.yaml'))}",
            "status": status,
            "unread": unread,
            "session_id": pane["session_id"],
            "window_id": pane["window_id"],
            "pane_id": pane["pane_id"],
            "target": pane["target"],
            "mtime": stat.st_mtime_ns,
            "child": False,
        })

    parent_states = load_parent_states()
    children: list[dict] = []
    child_pane_ids: set[str] = set()
    for pane in pi_panes:
        child = load_live_child(pane, snapshot)
        if child:
            child["pane"] = pane
            children.append(child)
            child_pane_ids.add(pane["pane_id"])

    for pane in pi_panes:
        if pane["pane_id"] in child_pane_ids:
            continue
        state = parent_states.get(pane["pane_id"])
        if state:
            raw = str(state.get("status") or "idle")
            status = "work" if state.get("busy") or raw == "running" else "dead" if raw == "stopped" else "idle"
            key = f"pi-parent:{state.get('parentSessionId', pane['pane_id'])}"
            signature = json.dumps(state, separators=(",", ":"), sort_keys=True)
            unread = update_unread(activity, key, signature, status == "work", dirty)
            label = pane.get("pane_title") or pane.get("window_name") or pane.get("pane_current_path")
            if label.startswith("π - "):
                label = label[4:]
            rows.append({
                "key": key,
                "group": key,
                "kind": "pi-parent",
                "pin_id": key,
                "label": f"{PI_ICON} {short(label)}",
                "status": status,
                "unread": unread,
                "session_id": pane["session_id"],
                "window_id": pane["window_id"],
                "pane_id": pane["pane_id"],
                "target": pane["target"],
                "model": state.get("model", "?"),
                "mtime": int(state.get("updatedAt") or 0),
                "child": False,
            })
        else:
            label = pane.get("pane_title") or pane.get("window_name") or pane.get("pane_current_path")
            if label.startswith("π - "):
                label = label[4:]
            key = f"pi-pane:{pane['pane_id']}"
            rows.append({
                "key": key,
                "group": key,
                "kind": "pi-pane",
                "pin_id": key,
                "label": f"{PI_ICON} {short(label)}",
                "status": "unknown",
                "unread": False,
                "session_id": pane["session_id"],
                "window_id": pane["window_id"],
                "pane_id": pane["pane_id"],
                "target": pane["target"],
                "mtime": 0,
                "child": False,
            })

    for child in children:
        pane = child["pane"]
        state = child["state"]
        raw = str(state.get("status") or "idle")
        status = "work" if state.get("busy") or raw == "running" else "dead" if raw in {"stopped", "error"} else "idle"
        key = f"pi-child:{child['child_id']}"
        signature = json.dumps(
            {
                "status": raw,
                "busy": bool(state.get("busy")),
                "updatedAt": state.get("updatedAt"),
                "lastTool": state.get("lastTool"),
                "lastReportAt": state.get("lastReportAt"),
                "lastAssistantText": state.get("lastAssistantText"),
            },
            separators=(",", ":"),
            sort_keys=True,
        )
        unread = update_unread(activity, key, signature, status == "work", dirty)
        group = f"pi-parent:{child['parent_session']}"
        rows.append({
            "key": key,
            "group": group,
            "kind": "pi-child",
            "pin_id": f"pi-child:{child['child_id']}",
            "label": f"{PI_ICON}↳ {short(child['name'], 11)}",
            "status": status,
            "unread": unread,
            "session_id": pane["session_id"],
            "window_id": pane["window_id"],
            "pane_id": pane["pane_id"],
            "target": pane["target"],
            "child_id": child["child_id"],
            "model": child["model"],
            "mtime": int(state.get("updatedAt") or 0),
            "child": True,
        })

    if dirty[0]:
        save_cache(cache)
    return rows, cache, dirty[0]


def activity_priority(rows: list[dict]) -> int:
    if any(row["status"] in ACTIVE for row in rows):
        return 0
    if any(row.get("unread") for row in rows):
        return 1
    return 3 if all(row["status"] == "unknown" for row in rows) else 2


def render(rows: list[dict]) -> str:
    groups: dict[str, list[dict]] = {}
    first: dict[str, int] = {}
    for index, row in enumerate(rows):
        groups.setdefault(row["group"], []).append(row)
        first.setdefault(row["group"], index)

    pinned = load_pinned()
    ordered_groups = sorted(
        groups.values(),
        key=lambda group: (
            0 if any(row["pin_id"] in pinned for row in group) else 1,
            activity_priority(group),
            -max(row.get("mtime", 0) for row in group),
            first[group[0]["group"]],
        ),
    )
    ordered = [row for group in ordered_groups for row in group]
    for row in ordered:
        row["pinned"] = row["pin_id"] in pinned

    visible: list[dict] = []
    overflow = 0
    nonpinned = 0
    for row in ordered:
        if row["pinned"]:
            visible.append(row)
        elif nonpinned < MAX_NONPINNED:
            visible.append(row)
            nonpinned += 1
        else:
            overflow += 1

    parts: list[str] = []
    for row in visible:
        token = "ag-" + hashlib.sha256(row["key"].encode()).hexdigest()[:12]
        target = target_for(row)
        subprocess.run(
            ["tmux", "set", "-g", f"@agent_target_{token}", json.dumps(target, separators=(",", ":"))],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        pin = "◉ " if row["pinned"] else ""
        label = f"{pin}{row['label']}"
        if row["status"] == "work":
            chunk = f"#[range=user|{token}]#[fg=colour28,bg={BAR_BG}]{LEFT_CAP}#[bg=colour28,fg=colour83,bold] {label} #[nobold,fg=colour28,bg={BAR_BG}]{RIGHT_CAP}#[norange]#[bg={BAR_BG}]"
        elif row["status"] == "think":
            chunk = f"#[range=user|{token}]#[fg=colour130,bg={BAR_BG}]{LEFT_CAP}#[bg=colour130,fg=colour220,bold] {label} #[nobold,fg=colour130,bg={BAR_BG}]{RIGHT_CAP}#[norange]#[bg={BAR_BG}]"
        elif row["status"] == "wait":
            chunk = f"#[range=user|{token}]#[fg=colour25,bg={BAR_BG}]{LEFT_CAP}#[bg=colour25,fg=colour81,bold,blink] {label} #[nobold,noblink,fg=colour25,bg={BAR_BG}]{RIGHT_CAP}#[norange]#[bg={BAR_BG}]"
        elif row.get("unread") and row["status"] == "idle":
            chunk = f"#[range=user|{token}]#[fg=colour255,bg={BAR_BG},bold] • {label} #[norange]#[bg={BAR_BG}]"
        elif row["status"] == "dead":
            chunk = f"#[range=user|{token}]#[fg=colour160,bg={BAR_BG}] × {label} #[norange]#[bg={BAR_BG}]"
        else:
            suffix = " ?" if row["status"] == "unknown" else ""
            chunk = f"#[range=user|{token}]#[fg=colour241,bg={BAR_BG}] {label}{suffix} #[norange]#[bg={BAR_BG}]"
        parts.append(chunk)

    out = f"#[fg=colour240,bg={BAR_BG},bold] agents #[nobold,fg={SEP}]│#[bg={BAR_BG}] "
    out += f"#[fg={SEP},bg={BAR_BG}] · #[bg={BAR_BG}]".join(parts)
    if overflow:
        out += f"#[fg={SEP},bg={BAR_BG}] · #[fg=colour241,bg={BAR_BG}] +{overflow} #[bg={BAR_BG}]"
    return out


def main() -> None:
    rows, _cache, _dirty = collect_rows()
    if not rows:
        value = f"#[fg=colour238,bg={BAR_BG}] no agents #[bg={BAR_BG}]"
    else:
        value = render(rows)
    subprocess.run(
        ["tmux", "set", "-g", "@copilot_agent_bar", value],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


if __name__ == "__main__":
    main()
