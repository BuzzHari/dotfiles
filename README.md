# Dotfiles

My personal dotfiles, managed using a bare git repository.

## How It Works

This setup uses a bare git repo to track dotfiles directly in the home directory without symlinks. The git database lives in `~/.dotfiles` while the actual files stay in their normal locations.

## Setup on a New Linux VM

Run the installer as the target login user, without `sudo`:

```bash
git clone --depth=1 https://github.com/BuzzHari/dotfiles.git ~/dotfiles-bootstrap
bash ~/dotfiles-bootstrap/install.sh
```

The installer supports Debian/Ubuntu, Fedora/RHEL-like, and Arch-like Linux
VMs. It will:

- install build dependencies with the VM's package manager;
- build the latest upstream Vim and tmux into `~/.local`;
- install the six Vim plugins below using Vim's native `pack/*/start/*`
  package directories (no external Vim plugin manager);
- install or update TPM for the tmux plugins declared in `.tmux.conf`;
- download and SHA-256-check the latest fzf, ripgrep (`rg`), and duf releases;
- install a user-local Node.js LTS copy when Pi needs Node.js 22.19 or newer;
- run the official Pi and OpenAI Codex CLI installers; and
- clone/update `~/.dotfiles` as a bare repository and check it out into `$HOME`.

When a tmux server is already running, the installer reloads the checked-out
`.tmux.conf`. Otherwise, tmux reads it automatically the next time it starts.
TPM itself is installed, but press `Ctrl-b I` inside tmux to fetch the plugins
declared in the configuration.

The script never needs root for the applications themselves. It uses `sudo`
only for build dependencies, so do not run `sudo bash install.sh`. If checkout
finds an existing conflicting home file, it moves that file to a unique
`~/.dotfiles-backup.*` directory before retrying.

The installer is safe to rerun, but it is not strictly missing-only: binaries
whose recorded version is current are skipped, while clean matching Vim/TPM
Git checkouts may be fast-forwarded to the latest revision. Dirty, non-Git, or
different-origin plugin directories are left unchanged. Pi is left in place
when already available; the Codex installer is invoked on each application
installation run. The bare dotfiles repository is fetched again so tracked
updates can be applied, with conflicting home files preserved in a backup.

Useful options:

```bash
bash install.sh --dry-run       # show the plan without changing anything
bash install.sh --skip-apps     # only configure the bare dotfiles repository
bash install.sh --skip-dotfiles # only install the applications
```

The installer is intentionally a latest-at-install-time bootstrap, not a
reproducible lockfile. Set `VIM_TAG` or `TMUX_TAG` when you need to pin those
source builds. Set `DOTFILES_REPO_URL` or `DOTFILES_DIR` for a different
repository or bare-repo location.

It does not modify SSH, UFW, users, or other firewall settings; apply those
server-specific security policies separately.

Pi is installed with the [official Pi installer](https://pi.dev/install.sh),
and Codex with the [official Codex CLI installer](https://chatgpt.com/codex/install.sh).
Those commands execute current remote installer code; review and pin release
artifacts instead if you need a high-assurance, fully reproducible bootstrap.

On the first `codex` run, sign in and use `/model` if you want to select
`gpt-5.6-sol`. The installer does not store credentials or change Codex's
model configuration.

### Manual bare-repository setup

The automated installer performs these steps. They are useful when you only
want the dotfiles and already have the applications installed:

```bash
git clone --bare https://github.com/BuzzHari/dotfiles.git ~/.dotfiles
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
dotfiles config --local status.showUntrackedFiles no
dotfiles checkout
```

If the checkout reports conflicts, copy the conflicting files somewhere safe,
then run `dotfiles checkout` again. The installer automates this backup without
parsing human-readable Git error output.

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

- `.tmux/scripts/copy-to-system-clipboard.sh`: Sends a tmux copy-mode selection to `pbcopy` on macOS, `wl-copy` on Wayland, or `xclip`/`xsel` on X11.
- `.tmux/scripts/copilot-switch.sh`: F11 FZF switcher for Copilot, Pi parents, and Pi children; displays live state, hierarchy, unread activity, provider icons, pins, and safely validated opaque tmux targets.
- `.tmux/scripts/session-switch.sh`: `Ctrl-b e` window switcher that carries opaque tmux session and window IDs through FZF.
- `.tmux/scripts/agent-status.py`: Collects and renders combined Copilot/Pi status entries for the tmux status line.
- `.tmux/scripts/copilot-status.sh`: Compatibility wrapper that launches `agent-status.py` for the existing status-right configuration.
- `.tmux/scripts/agent-jump.sh`: Validates generic `ag-*` status-bar tokens and focuses their current panes.
- `.tmux/scripts/copilot-pin.sh`: Toggles and lists pinned Copilot or Pi agent identifiers stored in tmux options.
- `.tmux/scripts/toggle-pane-collapse.py`: Folds panes to one line or one column, restores saved dimensions, and assigns remaining split space to an anchor pane.
- `.tmux/scripts/toggle-pane-collapse.sh`: Shell entry point used by the `F10` and `Ctrl-b Ctrl-z` bindings.
- `.tmux/scripts/copilot-jump.sh`: Legacy compatibility handler for older `ca-*` Copilot status tokens.

In vi copy mode, press `v` to begin selecting and `y` to copy. The selection is
kept in tmux's buffer. For local tmux sessions, the copy binding also invokes
`.tmux/scripts/copy-to-system-clipboard.sh`; on Debian/Ubuntu, install `xclip`
for an X11 session or `wl-clipboard` for Wayland if neither is already present:

```bash
sudo apt install xclip       # XFCE/X11
sudo apt install wl-clipboard # Wayland
```

If tmux is running on a remote VM over SSH, the binding does not invoke the
desktop clipboard helper. tmux sends the copied text through OSC 52 to the
local terminal instead. The configuration enables Kitty's `clipboard` and
`hyperlinks` terminal features only when the attached SSH client reports
`xterm-kitty`; other remote terminals receive tmux's native copy behavior but
must provide their own clipboard support.

The status line refreshes once per second and obtains Pi state from the tmux-subagent broker records under `~/.pi/agent/extensions/tmux-subagents/brokers/`. Existing Pi sessions may need to be reloaded after installing an updated Pi extension.

A tiled tmux layout must always fill the available window area. When all panes in a split are folded, one pane remains the space-consuming anchor; the other panes remain one-line folded panes.

## Vim Plugins

The installer installs these plugins using Vim's native package system. They
are placed below `~/.vim/pack/*/start/*`, so Vim loads them automatically at
startup. To install them manually, use:

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
