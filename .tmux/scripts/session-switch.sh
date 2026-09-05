#!/bin/bash
set -euo pipefail

FZF="${FZF:-$(command -v fzf || true)}"
[[ -x "$FZF" ]] || { echo "session-switch: fzf is not installed" >&2; exit 127; }

selected=$(
    tmux list-windows -a -F $'#{session_id}\t#{window_id}\t▌ #{session_name}:#{window_index}\t#{window_name}' \
        | "$FZF" --tmux 50%,50% --reverse --delimiter=$'\t' --with-nth=3,4
) || exit 0

IFS=$'\t' read -r session_id window_id _ <<< "$selected"
if [[ -z "$session_id" || -z "$window_id" ]]; then
    exit 0
fi

tmux switch-client -t "$session_id"
tmux select-window -t "$window_id"
