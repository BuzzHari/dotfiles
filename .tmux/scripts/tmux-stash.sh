#!/usr/bin/env bash
# tmux-stash — save and restore individual tmux sessions
# Usage: astash (interactive stash), apop (interactive restore)
#        or: tmux-stash save|pop|list|peek|drop|scrollback [args]
set -euo pipefail

STASH_DIR="${TMUX_STASH_DIR:-$HOME/.tmux/stash}"
FZF="${FZF:-$(command -v fzf || true)}"
[[ -x "$FZF" ]] || { echo "tmux-stash: fzf is not installed" >&2; exit 127; }

die()  { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }
info() { printf "\033[32m•\033[0m %s\n" "$*"; }
warn() { printf "\033[33m!\033[0m %s\n" "$*"; }

# Sanitize session name for filesystem
fs_safe() { echo "$1" | tr '/:.' '___'; }

# ── save ─────────────────────────────────────────────────────────────
cmd_save() {
    local session="${1:?Usage: tmux-stash save <session>}"

    tmux has-session -t "=$session" 2>/dev/null \
        || die "Session '$session' not found"

    # Don't stash the current session if it's the only one
    local current
    current=$(tmux display-message -p '#S' 2>/dev/null || true)
    local session_count
    session_count=$(tmux list-sessions 2>/dev/null | wc -l)
    if [[ "$session" == "$current" && "$session_count" -le 1 ]]; then
        die "Can't stash the only active session. Switch to another first."
    fi

    local safe_name
    safe_name=$(fs_safe "$session")
    local stash_path="$STASH_DIR/$safe_name"

    # Overwrite existing stash silently (interactive flow already confirmed)
    [[ -d "$stash_path" ]] && command rm -rf "$stash_path"
    mkdir -p "$stash_path/scrollback" "$stash_path/vim"

    # Metadata
    printf "session=%s\nstashed=%s\ntmux=%s\n" \
        "$session" "$(date -Iseconds)" "$(tmux -V | awk '{print $2}')" \
        > "$stash_path/metadata"

    # Window/pane layout (TSV)
    tmux list-panes -t "=$session" -s -F \
        '#{window_index}	#{window_name}	#{window_active}	#{window_flags}	#{window_layout}	#{pane_index}	#{pane_active}	#{pane_current_path}	#{pane_current_command}' \
        > "$stash_path/layout.tsv"

    local vim_saved=0 pane_count=0

    while IFS=$'\t' read -r wi wn wa wf wl pi pa pp pc; do
        pane_count=$((pane_count + 1))
        local pane_target="=$session:${wi}.${pi}"

        # Scrollback
        tmux capture-pane -t "$pane_target" -p -S -32768 \
            > "$stash_path/scrollback/${wi}_${pi}.txt" 2>/dev/null || true

        # Vim/nvim session
        if [[ "$pc" == *vim* || "$pc" == *nvim* ]]; then
            local vim_file="$stash_path/vim/${wi}_${pi}.vim"
            tmux send-keys -t "$pane_target" Escape
            tmux send-keys -t "$pane_target" ":mksession! $vim_file" Enter
            vim_saved=$((vim_saved + 1))
        fi
    done < "$stash_path/layout.tsv"

    # Give vim time to write
    [[ $vim_saved -gt 0 ]] && sleep 1

    local win_count
    win_count=$(awk -F'\t' '{print $1}' "$stash_path/layout.tsv" | sort -u | wc -l)

    # If stashing the current session, switch away first
    if [[ "$session" == "$current" ]]; then
        tmux switch-client -n 2>/dev/null || true
    fi

    tmux kill-session -t "=$session"

    info "Stashed: $session  (${win_count}w ${pane_count}p${vim_saved:+, ${vim_saved} vim})"
}

# ── pop (restore) ───────────────────────────────────────────────────
cmd_pop() {
    local name="${1:?Usage: tmux-stash pop <session>}"
    local safe_name
    safe_name=$(fs_safe "$name")
    local stash_path="$STASH_DIR/$safe_name"

    [[ -d "$stash_path" ]] || die "No stash found: '$name'"
    [[ -f "$stash_path/layout.tsv" ]] || die "Corrupt stash: missing layout.tsv"

    local session
    session=$(grep '^session=' "$stash_path/metadata" | cut -d= -f2-)

    tmux has-session -t "=$session" 2>/dev/null \
        && die "Session '$session' already exists"

    # Collect unique window indices
    local -a win_indices
    mapfile -t win_indices < <(awk -F'\t' '{print $1}' "$stash_path/layout.tsv" | sort -nu)

    local first_win="${win_indices[0]}"
    local first_path
    first_path=$(awk -F'\t' -v w="$first_win" '$1==w && $6=="0" {print $8}' "$stash_path/layout.tsv")

    # Create session
    tmux new-session -d -s "$session" -c "${first_path:-.}" -x 200 -y 50

    # Move auto-created window to correct index
    local base_idx
    base_idx=$(tmux show-option -gqv base-index 2>/dev/null)
    base_idx="${base_idx:-0}"
    if [[ "$base_idx" != "$first_win" ]]; then
        tmux move-window -s "=$session:${base_idx}" -t "=$session:${first_win}" 2>/dev/null || true
    fi

    # Setup panes for a given window
    _setup_window() {
        local win_idx="$1" stash_path="$2" session="$3"
        local target_base="=$session:${win_idx}"

        local layout
        layout=$(awk -F'\t' -v w="$win_idx" '$1==w {print $5; exit}' "$stash_path/layout.tsv")

        local num_panes
        num_panes=$(awk -F'\t' -v w="$win_idx" '$1==w' "$stash_path/layout.tsv" | wc -l)

        # Create additional panes
        for ((p=1; p<num_panes; p++)); do
            local p_path
            p_path=$(awk -F'\t' -v w="$win_idx" -v p="$p" '$1==w && $6==p {print $8}' "$stash_path/layout.tsv")
            tmux split-window -t "$target_base" -c "${p_path:-.}"
        done

        # Apply saved layout
        tmux select-layout -t "$target_base" "$layout" 2>/dev/null || true

        # Restore vim sessions and active pane
        while IFS=$'\t' read -r wi wn wa wf wl pi pa pp pc; do
            [[ "$wi" == "$win_idx" ]] || continue
            local target="=$session:${wi}.${pi}"

            local vim_file="$stash_path/vim/${wi}_${pi}.vim"
            if [[ -f "$vim_file" ]]; then
                local vim_cmd="vim"
                [[ "$pc" == *nvim* ]] && vim_cmd="nvim"
                tmux send-keys -t "$target" "$vim_cmd -S '${vim_file}'" Enter
            fi

            [[ "$pa" == "1" ]] && tmux select-pane -t "$target"
        done < "$stash_path/layout.tsv"
    }

    # First window (already created)
    local win_name
    win_name=$(awk -F'\t' -v w="$first_win" '$1==w {print $2; exit}' "$stash_path/layout.tsv")
    tmux rename-window -t "=$session:${first_win}" "$win_name"
    _setup_window "$first_win" "$stash_path" "$session"

    # Remaining windows
    for win_idx in "${win_indices[@]:1}"; do
        local w_name w_path
        w_name=$(awk -F'\t' -v w="$win_idx" '$1==w {print $2; exit}' "$stash_path/layout.tsv")
        w_path=$(awk -F'\t' -v w="$win_idx" '$1==w && $6=="0" {print $8}' "$stash_path/layout.tsv")
        tmux new-window -t "=$session:${win_idx}" -n "$w_name" -c "${w_path:-.}"
        _setup_window "$win_idx" "$stash_path" "$session"
    done

    # Select the window that was active when stashed
    while IFS=$'\t' read -r wi wn wa wf wl pi pa pp pc; do
        if [[ "$wa" == "1" && "$pi" == "0" ]]; then
            tmux select-window -t "=$session:${wi}"
            break
        fi
    done < "$stash_path/layout.tsv"

    local win_count=${#win_indices[@]}
    local pane_count
    pane_count=$(wc -l < "$stash_path/layout.tsv")

    # Clean up stash
    command rm -rf "$stash_path"

    info "Restored: $session  (${win_count}w ${pane_count}p)"

    # Switch to the restored session if inside tmux
    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "=$session"
    fi
}

# ── interactive save (astash) ───────────────────────────────────────
cmd_interactive_save() {
    local current
    current=$(tmux display-message -p '#S' 2>/dev/null || true)

    local pick
    pick=$(tmux list-sessions -F '#{session_name}  #{session_windows}w #{session_attached}a' \
        | "$FZF" --tmux 60%,40% --reverse \
                 --prompt="Stash session: " \
                 --header="Select a session to stash (save + kill)" \
                 --preview 'tmux list-windows -t "=$(echo {} | awk "{print \$1}")" -F "  #{window_index}: #{window_name} (#{window_panes} panes) #{window_active}" 2>/dev/null' \
        | awk '{print $1}')

    [[ -z "$pick" ]] && return 0
    cmd_save "$pick"
}

# ── interactive restore (apop) ──────────────────────────────────────
cmd_interactive_pop() {
    [[ -d "$STASH_DIR" ]] || die "No stashes found"

    local entries=""
    for dir in "$STASH_DIR"/*/; do
        [[ -f "$dir/metadata" ]] || continue
        local session stashed wins panes
        session=$(grep '^session=' "$dir/metadata" | cut -d= -f2-)
        stashed=$(grep '^stashed=' "$dir/metadata" | cut -d= -f2- | cut -dT -f1)
        wins=$(awk -F'\t' '{print $1}' "$dir/layout.tsv" | sort -u | wc -l)
        panes=$(wc -l < "$dir/layout.tsv")
        entries+="${session}  ${wins}w ${panes}p  stashed:${stashed}"$'\n'
    done

    [[ -z "$entries" ]] && die "No stashes found"

    local pick
    pick=$(echo "$entries" \
        | "$FZF" --tmux 60%,40% --reverse \
                 --prompt="Restore session: " \
                 --header="Select a stashed session to restore" \
                 --preview "cat '$STASH_DIR'/\$(echo {} | awk '{print \$1}' | tr '/:.' '___')/layout.tsv 2>/dev/null \
                     | awk -F'\t' '{printf \"  win:%s %-15s pane:%s  %s  [%s]\n\", \$1, \$2, \$6, \$8, \$9}'" \
        | awk '{print $1}')

    [[ -z "$pick" ]] && return 0
    cmd_pop "$pick"
}

# ── list ─────────────────────────────────────────────────────────────
cmd_list() {
    [[ -d "$STASH_DIR" ]] || { echo "No stashes."; return 0; }

    local count=0
    printf "\033[1m%-40s  %-12s  %s\033[0m\n" "SESSION" "STASHED" "SIZE"
    for dir in "$STASH_DIR"/*/; do
        [[ -f "$dir/metadata" ]] || continue
        count=$((count + 1))
        local session stashed wins panes
        session=$(grep '^session=' "$dir/metadata" | cut -d= -f2-)
        stashed=$(grep '^stashed=' "$dir/metadata" | cut -d= -f2- | cut -dT -f1)
        wins=$(awk -F'\t' '{print $1}' "$dir/layout.tsv" | sort -u | wc -l)
        panes=$(wc -l < "$dir/layout.tsv")
        printf "%-40s  %-12s  %sw %sp\n" "$session" "$stashed" "$wins" "$panes"
    done
    [[ $count -eq 0 ]] && echo "No stashes."
}

# ── peek ─────────────────────────────────────────────────────────────
cmd_peek() {
    local name="${1:?Usage: tmux-stash peek <session>}"
    local safe_name
    safe_name=$(fs_safe "$name")
    local stash_path="$STASH_DIR/$safe_name"

    [[ -d "$stash_path" ]] || die "No stash: '$name'"

    echo "=== $name ==="
    cat "$stash_path/metadata"
    echo ""
    printf "%-4s %-20s %-4s %-35s %s\n" "WIN" "NAME" "PANE" "PATH" "CMD"
    while IFS=$'\t' read -r wi wn wa wf wl pi pa pp pc; do
        local mark=""
        [[ "$wa" == "1" && "$pa" == "1" ]] && mark=" ◀"
        printf "%-4s %-20s %-4s %-35s %s%s\n" "$wi" "$wn" "$pi" "${pp##*/}" "$pc" "$mark"
    done < "$stash_path/layout.tsv"

    local vim_count
    vim_count=$(find "$stash_path/vim" -name '*.vim' 2>/dev/null | wc -l)
    local scroll_size
    scroll_size=$(du -sh "$stash_path/scrollback" 2>/dev/null | awk '{print $1}')
    echo ""
    echo "Vim sessions: $vim_count  |  Scrollback: ${scroll_size:-0}"
}

# ── drop ─────────────────────────────────────────────────────────────
cmd_drop() {
    local name="${1:?Usage: tmux-stash drop <session>}"
    local safe_name
    safe_name=$(fs_safe "$name")
    local stash_path="$STASH_DIR/$safe_name"

    [[ -d "$stash_path" ]] || die "No stash: '$name'"
    command rm -rf "$stash_path"
    info "Dropped: $name"
}

# ── scrollback ───────────────────────────────────────────────────────
cmd_scrollback() {
    local name="${1:?Usage: tmux-stash scrollback <session> [window] [pane]}"
    local win="${2:-}" pane="${3:-0}"
    local safe_name
    safe_name=$(fs_safe "$name")
    local stash_path="$STASH_DIR/$safe_name"

    [[ -d "$stash_path" ]] || die "No stash: '$name'"

    if [[ -z "$win" ]]; then
        echo "Scrollback files:"
        ls -lh "$stash_path/scrollback/"
        return
    fi

    local file="$stash_path/scrollback/${win}_${pane}.txt"
    [[ -f "$file" ]] || die "No scrollback for window $win, pane $pane"
    ${PAGER:-less} "$file"
}

# ── main dispatch ────────────────────────────────────────────────────
case "${1:-help}" in
    save)       shift; cmd_save "$@" ;;
    pop)        shift; cmd_pop "$@" ;;
    isave)      cmd_interactive_save ;;
    ipop)       cmd_interactive_pop ;;
    list|ls)    cmd_list ;;
    peek|show)  shift; cmd_peek "$@" ;;
    drop|rm)    shift; cmd_drop "$@" ;;
    scrollback) shift; cmd_scrollback "$@" ;;
    help|-h|--help)
        cat <<'USAGE'
tmux-stash — save and restore individual tmux sessions

Interactive (fzf):
    astash              Fuzzy-pick a session to stash
    apop                Fuzzy-pick a stash to restore

Direct:
    tmux-stash save <session>           Stash a session (save + kill)
    tmux-stash pop  <session>           Restore a stash (restore + delete)
    tmux-stash list                     List all stashes
    tmux-stash peek <session>           Show stash details
    tmux-stash drop <session>           Delete a stash
    tmux-stash scrollback <s> [w] [p]   View saved scrollback

Saved to: ~/.tmux/stash/    (override: TMUX_STASH_DIR)
USAGE
        ;;
    *)  die "Unknown command: $1  (try: tmux-stash help)" ;;
esac
