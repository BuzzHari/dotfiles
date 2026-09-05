#!/usr/bin/env python3
"""Collapse a tmux pane to a line and restore its previous size."""
from __future__ import annotations

import json
import os
import subprocess
import sys


COLLAPSED_SIZE = max(1, int(os.environ.get("TMUX_COLLAPSED_PANE_SIZE", "1")))


def tmux(*args: str, check: bool = True) -> str:
    return subprocess.check_output(
        ["tmux", *args], text=True, stderr=subprocess.DEVNULL
    ).strip()


def tmux_run(*args: str) -> None:
    subprocess.run(["tmux", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def pane_options(pane_id: str) -> tuple[str, str, str]:
    def get(name: str) -> str:
        try:
            return tmux("show-options", "-p", "-qv", "-t", pane_id, name)
        except subprocess.CalledProcessError:
            return ""

    return get("@tmux_collapse_state"), get("@tmux_collapse_saved"), get("@tmux_collapse_axis")


def panes_in_window(pane_id: str) -> list[dict[str, int | str]]:
    fmt = "\t".join(
        ["#{pane_id}", "#{pane_width}", "#{pane_height}", "#{pane_left}",
         "#{pane_top}", "#{pane_right}", "#{pane_bottom}"]
    )
    output = tmux("list-panes", "-t", pane_id, "-F", fmt)
    panes: list[dict[str, int | str]] = []
    for line in output.splitlines():
        values = line.split("\t")
        if len(values) != 7:
            continue
        try:
            panes.append({
                "id": values[0],
                "width": int(values[1]),
                "height": int(values[2]),
                "left": int(values[3]),
                "top": int(values[4]),
                "right": int(values[5]),
                "bottom": int(values[6]),
            })
        except ValueError:
            continue
    return panes


def choose_axis(target: dict, panes: list[dict]) -> str | None:
    siblings = [pane for pane in panes if pane["id"] != target["id"]]
    vertical_stack = any(
        pane["left"] == target["left"] and pane["right"] == target["right"]
        and pane["top"] != target["top"]
        for pane in siblings
    )
    horizontal_stack = any(
        pane["top"] == target["top"] and pane["bottom"] == target["bottom"]
        and pane["left"] != target["left"]
        for pane in siblings
    )
    if vertical_stack and not horizontal_stack:
        return "y"
    if horizontal_stack and not vertical_stack:
        return "x"
    if vertical_stack:
        return "y"
    if horizontal_stack:
        return "x"
    return None


def resize(pane_id: str, axis: str, size: int) -> None:
    flag = "-y" if axis == "y" else "-x"
    tmux_run("resize-pane", "-t", pane_id, flag, str(max(1, size)))


def pane_size(pane: dict, axis: str) -> int:
    return int(pane["height"] if axis == "y" else pane["width"])


def pane_stack(target: dict, panes: list[dict], axis: str) -> list[dict]:
    if axis == "y":
        stack = [
            pane for pane in panes
            if pane["left"] == target["left"] and pane["right"] == target["right"]
        ]
        return sorted(stack, key=lambda pane: int(pane["top"]))
    stack = [
        pane for pane in panes
        if pane["top"] == target["top"] and pane["bottom"] == target["bottom"]
    ]
    return sorted(stack, key=lambda pane: int(pane["left"]))


def clear_collapse_state(pane_id: str) -> None:
    tmux_run("set-option", "-p", "-t", pane_id, "-u", "@tmux_collapse_state")


def parse_saved(raw: str) -> dict:
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def make_anchor_fill(pane_id: str, axis: str) -> str | None:
    """Give all remaining rows/columns to the one still-open pane in a stack."""
    try:
        panes = panes_in_window(pane_id)
    except (OSError, subprocess.CalledProcessError):
        return None
    target = next((pane for pane in panes if pane["id"] == pane_id), None)
    if target is None:
        return None
    stack = pane_stack(target, panes, axis)
    if len(stack) < 2:
        return None

    states: dict[str, str] = {}
    for pane in stack:
        pane_key = str(pane["id"])
        state, saved_raw, _axis = pane_options(pane_key)
        # Keep the collapse marker while choosing the anchor. A collapsed
        # sibling may be temporarily large because tmux has not yet been
        # told which pane should receive the freed rows.
        if state != "collapsed" and pane_size(pane, axis) <= COLLAPSED_SIZE:
            saved = parse_saved(saved_raw)
            if isinstance(saved.get(axis), int) and saved[axis] > COLLAPSED_SIZE:
                state = "collapsed"
                tmux_run("set-option", "-p", "-t", pane_key, "@tmux_collapse_state", "collapsed")
        states[pane_key] = state

    open_panes = [pane for pane in stack if states.get(str(pane["id"])) != "collapsed"]
    if len(open_panes) > 1:
        return None
    if open_panes:
        anchor = open_panes[0]
    else:
        # A tiled tmux layout must have one pane that owns the remaining
        # space. Prefer the first pane in the stack when every pane is folded.
        anchor = stack[0]
        clear_collapse_state(str(anchor["id"]))
        states[str(anchor["id"])] = ""

    # First make every folded sibling small. The final anchor resize below
    # then takes the space tmux would otherwise give to an arbitrary sibling.
    for pane in stack:
        pane_key = str(pane["id"])
        if pane_key != str(anchor["id"]) and states.get(pane_key) == "collapsed":
            resize(pane_key, axis, COLLAPSED_SIZE)

    try:
        panes = panes_in_window(pane_id)
    except (OSError, subprocess.CalledProcessError):
        return str(anchor["id"])
    target = next((pane for pane in panes if pane["id"] == pane_id), None)
    if target is None:
        return str(anchor["id"])
    stack = pane_stack(target, panes, axis)
    anchor = next((pane for pane in stack if pane["id"] == anchor["id"]), anchor)

    start = min(int(pane["top"] if axis == "y" else pane["left"]) for pane in stack)
    end = max(int(pane["bottom"] if axis == "y" else pane["right"]) for pane in stack)
    span = end - start + 1
    folded = [pane for pane in stack if pane["id"] != anchor["id"]]
    desired = span - (len(stack) - 1) - len(folded) * COLLAPSED_SIZE
    resize(str(anchor["id"]), axis, max(COLLAPSED_SIZE, desired))
    return str(anchor["id"])


def main() -> int:
    pane_id = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("TMUX_PANE", "")
    requested_axis = sys.argv[2] if len(sys.argv) > 2 else "auto"
    if not pane_id:
        return 0

    try:
        panes = panes_in_window(pane_id)
    except (OSError, subprocess.CalledProcessError):
        return 0
    target = next((pane for pane in panes if pane["id"] == pane_id), None)
    if target is None:
        return 0

    state, saved_raw, saved_axis = pane_options(pane_id)
    axis = requested_axis if requested_axis in {"x", "y"} else choose_axis(target, panes)
    if axis is None:
        axis = saved_axis if saved_axis in {"x", "y"} else "y"

    current_size = pane_size(target, axis)
    saved = parse_saved(saved_raw)
    if (
        state != "collapsed"
        and current_size <= COLLAPSED_SIZE
        and isinstance(saved.get(axis), int)
        and saved[axis] > COLLAPSED_SIZE
    ):
        state = "collapsed"
        tmux_run("set-option", "-p", "-t", pane_id, "@tmux_collapse_state", "collapsed")
    if state == "collapsed" and current_size <= COLLAPSED_SIZE:
        size = saved.get(axis) if isinstance(saved, dict) else None
        if not isinstance(size, int) or size < 1:
            size = saved.get("size") if isinstance(saved, dict) else None
        if not isinstance(size, int) or size < 1:
            size = 8
        resize(pane_id, axis, size)
        clear_collapse_state(pane_id)
        tmux_run("display-message", f"Restored pane {pane_id} to {size}{axis}")
        return 0

    # If tmux previously expanded a folded pane to absorb space, its state is
    # stale. Preserve its saved size, but treat the visible pane as open now.
    if state == "collapsed" and current_size > COLLAPSED_SIZE:
        clear_collapse_state(pane_id)
        state = ""

    if requested_axis not in {"x", "y"} and choose_axis(target, panes) is None:
        tmux_run("display-message", f"Pane {pane_id} has no sibling split to collapse")
        return 0

    existing_saved = parse_saved(saved_raw)
    if not isinstance(existing_saved, dict) or not existing_saved:
        existing_saved = {
            "x": int(target["width"]),
            "y": int(target["height"]),
            "size": current_size,
        }
        tmux_run(
            "set-option", "-p", "-t", pane_id, "@tmux_collapse_saved",
            json.dumps(existing_saved, separators=(",", ":")),
        )
    tmux_run("set-option", "-p", "-t", pane_id, "@tmux_collapse_axis", axis)
    tmux_run("set-option", "-p", "-t", pane_id, "@tmux_collapse_state", "collapsed")
    resize(pane_id, axis, COLLAPSED_SIZE)
    anchor = make_anchor_fill(pane_id, axis)
    if anchor:
        tmux_run(
            "display-message",
            f"Collapsed {pane_id}; remaining {axis}-space assigned to {anchor}",
        )
    else:
        tmux_run("display-message", f"Collapsed pane {pane_id} to {COLLAPSED_SIZE}{axis}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
