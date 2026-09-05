#!/bin/bash
# Jump to the tmux pane running a given copilot session.
# Called by tmux mouse binding when clicking an agent in the status bar.
# Usage: copilot-jump.sh <token-or-uuid>
# Token format: ca-<12hex>  (stored in @copilot_agent_<token> tmux option)

TOKEN_OR_UUID="$1"
[[ -z "$TOKEN_OR_UUID" ]] && exit 0

# Resolve token → UUID if needed
if [[ "$TOKEN_OR_UUID" == ca-* ]]; then
    SESSION_UUID=$(tmux show-option -gqv "@copilot_agent_${TOKEN_OR_UUID}" 2>/dev/null)
else
    SESSION_UUID="$TOKEN_OR_UUID"
fi
[[ -z "$SESSION_UUID" ]] && exit 0

SDIR=~/.copilot/session-state/"$SESSION_UUID"
[[ -d "$SDIR" ]] || exit 0

# Get an active PID from lock files (prefer the freshest)
PID=$(find "$SDIR" -maxdepth 1 -name 'inuse.*.lock' -printf '%T@ %f\n' 2>/dev/null \
    | sort -rn | head -1 | sed 's/.*inuse\.\([0-9]*\)\.lock/\1/')
[[ -z "$PID" ]] && exit 0

# Confirm the process is still alive
[[ -d "/proc/$PID" ]] || exit 0

# Resolve TTY for this PID
TTY=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
[[ -z "$TTY" || "$TTY" == "?" ]] && exit 0

# Find the tmux pane whose tty matches
PANE=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_tty}' 2>/dev/null \
    | awk -v tty="/dev/$TTY" '$2 == tty { print $1 }' | head -1)
[[ -z "$PANE" ]] && exit 0

tmux switch-client -t "${PANE%.*}"
tmux select-pane -t "$PANE"
