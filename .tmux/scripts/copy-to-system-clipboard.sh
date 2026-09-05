#!/usr/bin/env bash

# Receive a tmux copy-mode selection on stdin and put it in the desktop
# clipboard.  tmux still stores the same selection in its own buffer via
# copy-pipe-and-cancel.

set -Eeuo pipefail

case "$(uname -s)" in
    Darwin)
        if command -v pbcopy >/dev/null 2>&1; then
            exec pbcopy
        fi
        ;;
    Linux)
        # Prefer Wayland when this is a Wayland session, even if XWayland is
        # also providing DISPLAY.
        if [[ "${XDG_SESSION_TYPE:-}" == wayland || -n "${WAYLAND_DISPLAY:-}" ]] \
            && command -v wl-copy >/dev/null 2>&1; then
            exec wl-copy --type text/plain
        fi
        if [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
            exec xclip -selection clipboard -in
        fi
        if [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then
            exec xsel --clipboard --input
        fi
        ;;
esac

printf 'No usable desktop clipboard backend was found. ' >&2
printf 'Expected pbcopy on macOS, wl-copy on Wayland, or xclip/xsel on X11.\n' >&2
printf 'DISPLAY=%q WAYLAND_DISPLAY=%q XDG_SESSION_TYPE=%q\n' \
    "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" "${XDG_SESSION_TYPE:-}" >&2
exit 127
