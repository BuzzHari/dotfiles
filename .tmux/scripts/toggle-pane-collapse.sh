#!/bin/sh
set -eu

exec python3 "$HOME/.tmux/scripts/toggle-pane-collapse.py" "$@"
