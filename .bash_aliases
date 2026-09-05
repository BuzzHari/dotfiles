# Generic interactive Bash aliases and functions.

alias update-aliases='source "$HOME/.bash_aliases"'
alias glog='git log --pretty=format:"%h%x09%an%x09%ad%x09%s" --date=short'

# Bare-repository dotfiles management.
alias dotfiles='git --git-dir="$HOME/.dotfiles" --work-tree="$HOME"'
alias dotvim='GIT_DIR="$HOME/.dotfiles" GIT_WORK_TREE="$HOME" vim'

# Optional command replacements. Leave the system command untouched when the
# replacement is not installed.
if command -v batcat >/dev/null 2>&1; then
    alias cat='batcat --paging=never'
elif command -v bat >/dev/null 2>&1; then
    alias cat='bat --paging=never'
fi

if command -v eza >/dev/null 2>&1; then
    alias tree='eza --tree'
fi

if command -v rg >/dev/null 2>&1; then
    alias grep='rg --no-heading'
fi

if command -v fdfind >/dev/null 2>&1; then
    alias find='fdfind'
fi

# Open one or more files selected with fzf.
vimf() {
    local root="${1:-.}"
    local selection

    command -v fdfind >/dev/null 2>&1 || {
        echo "vimf: fdfind is not installed" >&2
        return 127
    }
    command -v fzf >/dev/null 2>&1 || {
        echo "vimf: fzf is not installed" >&2
        return 127
    }

    selection=$(fdfind --type f --hidden --exclude .git . "$root" | fzf) || return
    [[ -n "$selection" ]] && vim "$selection"
}

alias vf='vimf'

vimfm() {
    local root="${1:-.}"
    local -a files=()

    command -v fdfind >/dev/null 2>&1 || {
        echo "vimfm: fdfind is not installed" >&2
        return 127
    }
    command -v fzf >/dev/null 2>&1 || {
        echo "vimfm: fzf is not installed" >&2
        return 127
    }

    mapfile -t files < <(fdfind --type f --hidden --exclude .git . "$root" | fzf --multi)
    ((${#files[@]})) && vim "${files[@]}"
}

alias vfm='vimfm'

vim_modified() {
    local -a files=()

    command -v fzf >/dev/null 2>&1 || {
        echo "vim_modified: fzf is not installed" >&2
        return 127
    }

    mapfile -t files < <(git diff --name-only --diff-filter=ACMR | fzf --multi)
    ((${#files[@]})) && vim "${files[@]}"
}

# Show currently unused tmux prefix bindings.
free_tmux_bindings() {
    command -v tmux >/dev/null 2>&1 || {
        echo "free_tmux_bindings: tmux is not installed" >&2
        return 127
    }

    local c
    local free=""
    for c in {a..z} {A..Z}; do
        if ! tmux list-keys -T prefix 2>/dev/null | command grep -qE "prefix +$c "; then
            free+="$c "
        fi
    done
    printf 'Free: %s\n' "$free"
}

# Optional tmux session stash helpers.
if [[ -x "$HOME/.tmux/scripts/tmux-stash.sh" ]]; then
    alias astash='"$HOME/.tmux/scripts/tmux-stash.sh" isave'
    alias apop='"$HOME/.tmux/scripts/tmux-stash.sh" ipop'
fi
