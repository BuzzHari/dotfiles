#!/bin/bash
# Manage pinned agents stored in tmux option @copilot_pinned (comma-separated UUIDs).
# Usage: copilot-pin.sh toggle <uuid>
#        copilot-pin.sh list

action="$1"
uuid="${2:-}"

get_pinned() {
    tmux show -gqv @copilot_pinned 2>/dev/null || true
}

case "$action" in
    toggle)
        [[ -z "$uuid" ]] && exit 1
        current=$(get_pinned)
        if echo ",$current," | grep -qF ",$uuid,"; then
            new=$(echo "$current" | tr ',' '\n' | grep -vxF "$uuid" | paste -sd',' - | sed 's/^,//;s/,$//')
        else
            new="${current:+$current,}$uuid"
        fi
        tmux set -g @copilot_pinned "$new"
        ;;
    list)
        get_pinned
        ;;
    *)
        echo "usage: copilot-pin.sh toggle <uuid> | list" >&2
        exit 1
        ;;
esac
