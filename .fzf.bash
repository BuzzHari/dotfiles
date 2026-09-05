# fzf key bindings and completion for Bash.
# Works with recent fzf releases that provide `fzf --bash`.
if command -v fzf >/dev/null 2>&1; then
    eval "$(fzf --bash 2>/dev/null)"
fi
