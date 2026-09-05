# Dotfiles

My personal dotfiles, managed using a bare git repository.

## How It Works

This setup uses a bare git repo to track dotfiles directly in the home directory without symlinks. The git database lives in `~/.dotfiles` while the actual files stay in their normal locations.

## Setup on a New Machine

```bash
# Clone the bare repo
git clone --bare git@github.com:USERNAME/dotfiles.git ~/.dotfiles

# Define the alias for this session
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'

# Hide untracked files
dotfiles config --local status.showUntrackedFiles no

# Checkout the files
dotfiles checkout
```

If you get errors about existing files, back them up first:

```bash
mkdir -p ~/.dotfiles-backup
dotfiles checkout 2>&1 | grep "^\s" | awk '{print $1}' | xargs -I{} mv {} ~/.dotfiles-backup/{}
dotfiles checkout
```

## Usage

Add this alias to your `.bashrc` or `.zshrc`:

```bash
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
```

Then use it like regular git:

```bash
dotfiles status
dotfiles add ~/.zshrc
dotfiles commit -m "Update zshrc"
dotfiles push
dotfiles pull
```

## tmux Scripts and Bindings

The tmux configuration integrates GitHub Copilot sessions, Pi parent agents, and Pi tmux subagents. The main configuration is in `.tmux.conf`; helper scripts are in `.tmux/scripts/`.

### Bindings

| Binding | Action |
|---|---|
| `F11` | Open the live Copilot/Pi agent switcher. |
| `Ctrl-b e` | Open the tmux window switcher using opaque session/window IDs, so names containing spaces work correctly. |
| `F10` | Fold or restore the focused pane, remembering its previous size. |
| `Ctrl-b Ctrl-z` | Prefix-based fallback for pane folding. |
| Click an agent in the status line | Validate and focus that agent's current pane. |

Active panes use a bright green border and an `▶ ACTIVE` marker. Pane borders show the pane index and title, including when a pane is folded to one line.

### Script overview

- `.tmux/scripts/copilot-switch.sh`: F11 FZF switcher for Copilot, Pi parents, and Pi children; displays live state, hierarchy, unread activity, provider icons, pins, and safely validated opaque tmux targets.
- `.tmux/scripts/session-switch.sh`: `Ctrl-b e` window switcher that carries opaque tmux session and window IDs through FZF.
- `.tmux/scripts/agent-status.py`: Collects and renders combined Copilot/Pi status entries for the tmux status line.
- `.tmux/scripts/copilot-status.sh`: Compatibility wrapper that launches `agent-status.py` for the existing status-right configuration.
- `.tmux/scripts/agent-jump.sh`: Validates generic `ag-*` status-bar tokens and focuses their current panes.
- `.tmux/scripts/copilot-pin.sh`: Toggles and lists pinned Copilot or Pi agent identifiers stored in tmux options.
- `.tmux/scripts/toggle-pane-collapse.py`: Folds panes to one line or one column, restores saved dimensions, and assigns remaining split space to an anchor pane.
- `.tmux/scripts/toggle-pane-collapse.sh`: Shell entry point used by the `F10` and `Ctrl-b Ctrl-z` bindings.
- `.tmux/scripts/copilot-jump.sh`: Legacy compatibility handler for older `ca-*` Copilot status tokens.

The status line refreshes once per second and obtains Pi state from the tmux-subagent broker records under `~/.pi/agent/extensions/tmux-subagents/brokers/`. Existing Pi sessions may need to be reloaded after installing an updated Pi extension.

A tiled tmux layout must always fill the available window area. When all panes in a split are folded, one pane remains the space-consuming anchor; the other panes remain one-line folded panes.

## Vim Plugins

Install these plugins using Vim's native package system:

```bash
# vim-airline - statusline
git clone https://github.com/vim-airline/vim-airline.git ~/.vim/pack/dist/start/vim-airline

# vim-airline-themes - themes for airline
git clone https://github.com/vim-airline/vim-airline-themes.git ~/.vim/pack/dist/start/vim-airline-themes

# vim-one - colorscheme
git clone https://github.com/rakr/vim-one.git ~/.vim/pack/rakr/start/vim-one

# vim-fugitive - git integration
git clone https://github.com/tpope/vim-fugitive.git ~/.vim/pack/tpope/start/fugitive

# vim-go - go development
git clone https://github.com/fatih/vim-go.git ~/.vim/pack/plugins/start/vim-go

# taboo.vim - tab naming
git clone https://github.com/gcmt/taboo.vim.git ~/.vim/pack/gcmt/start/taboo.vim
```

### Plugin Links

- [vim-airline](https://github.com/vim-airline/vim-airline)
- [vim-airline-themes](https://github.com/vim-airline/vim-airline-themes)
- [vim-one](https://github.com/rakr/vim-one)
- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- [vim-go](https://github.com/fatih/vim-go)
- [taboo.vim](https://github.com/gcmt/taboo.vim)
