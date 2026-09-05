#!/bin/bash
file="$1"
line="$2"
start=$((line - 20))
[[ $start -lt 1 ]] && start=1
batcat --color=always --theme="Dracula"  --highlight-line $line --style=numbers --line-range "$start:+50" "$file"
