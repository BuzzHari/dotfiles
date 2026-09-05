#!/usr/bin/env bash

# Bootstrap a Linux VM with the tools and dotfiles used in this repository.
# Run this as the target login user, not with sudo.  The script uses sudo only
# for system build dependencies; applications are installed under ~/.local.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
TARGET_HOME="${HOME:-}"
LOCAL_PREFIX="${LOCAL_PREFIX:-${TARGET_HOME}/.local}"
INSTALL_DIR="${LOCAL_PREFIX}/bin"
VERSION_DIR="${LOCAL_PREFIX}/share/dotfiles-installer/versions"
DOTFILES_DIR="${DOTFILES_DIR:-${TARGET_HOME}/.dotfiles}"
DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-https://github.com/BuzzHari/dotfiles.git}"
TPM_DIR="${TPM_DIR:-${TARGET_HOME}/.tmux/plugins/tpm}"
TPM_REPO_URL="${TPM_REPO_URL:-https://github.com/tmux-plugins/tpm}"
VIM_TAG="${VIM_TAG:-}"
TMUX_TAG="${TMUX_TAG:-}"
DEFAULT_BUILD_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
BUILD_JOBS="${BUILD_JOBS:-${DEFAULT_BUILD_JOBS}}"
DRY_RUN=0
INSTALL_APPS=1
SETUP_DOTFILES=1
PKG_MANAGER=""
KERNEL_ARCH="$(uname -m)"
TMP_ROOT=""

# Vim loads plugins placed below ~/.vim/pack/*/start/* automatically.  Keep
# these paths explicit so the installer uses Vim's native package mechanism
# rather than adding a third-party Vim plugin manager.
VIM_PLUGIN_SPECS=(
    "https://github.com/vim-airline/vim-airline.git|dist/start/vim-airline"
    "https://github.com/vim-airline/vim-airline-themes.git|dist/start/vim-airline-themes"
    "https://github.com/rakr/vim-one.git|rakr/start/vim-one"
    "https://github.com/tpope/vim-fugitive.git|tpope/start/fugitive"
    "https://github.com/fatih/vim-go.git|plugins/start/vim-go"
    "https://github.com/gcmt/taboo.vim.git|gcmt/start/taboo.vim"
)

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Install the latest upstream Vim, tmux, fzf, ripgrep, and duf, install the
configured Vim plugins, Pi, and OpenAI Codex CLI, then configure this
repository as a bare dotfiles repo.

Options:
  --skip-apps       Do not install or update applications.
  --skip-dotfiles   Do not clone or checkout the bare dotfiles repository.
  --dry-run         Print the plan without changing anything or using sudo.
  -h, --help        Show this help.

Environment overrides:
  DOTFILES_REPO_URL  Git URL (default: ${DOTFILES_REPO_URL})
  DOTFILES_DIR       Bare repo path (default: ${DOTFILES_DIR})
  TPM_REPO_URL       TPM Git URL (default: ${TPM_REPO_URL})
  TPM_DIR            TPM checkout path (default: ${TPM_DIR})
  LOCAL_PREFIX       User install prefix (default: ${LOCAL_PREFIX})
  VIM_TAG            Vim tag to build instead of the newest tag
  TMUX_TAG           tmux release tag to build instead of the newest release
  BUILD_JOBS         Parallel build jobs (default: ${BUILD_JOBS})

Example:
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} --skip-apps
EOF
}

log() {
    printf '[dotfiles-install] %s\n' "$*"
}

warn() {
    printf '[dotfiles-install] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[dotfiles-install] ERROR: %s\n' "$*" >&2
    exit 1
}

parse_args() {
    while (($#)); do
        case "$1" in
            --skip-apps)
                INSTALL_APPS=0
                ;;
            --skip-dotfiles)
                SETUP_DOTFILES=0
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

print_dry_run() {
    cat <<EOF
Dry run; no changes will be made.

Target user home: ${TARGET_HOME}
Install prefix:   ${LOCAL_PREFIX}
Dotfiles repo:    ${DOTFILES_DIR}
Dotfiles remote:  ${DOTFILES_REPO_URL}

The real run would:
EOF
    if ((INSTALL_APPS)); then
        cat <<EOF
  1. Install compiler and download dependencies with the VM's package manager.
  2. Build the latest upstream Vim and tmux under ${LOCAL_PREFIX}.
  3. Download and verify the latest fzf, ripgrep, and duf release archives.
  4. Install the configured Vim plugins under ~/.vim/pack/*/start/*.
  5. Install or update TPM under ${TPM_DIR}.
  6. Install Node.js LTS if Pi needs it, then run the official Pi installer.
  7. Run the official OpenAI Codex CLI installer.
EOF
    else
        printf '  (application installation skipped)\n'
    fi
    if ((SETUP_DOTFILES)); then
        cat <<EOF
  8. Clone or update ${DOTFILES_DIR}, back up checkout conflicts, and checkout
     the repository into ${TARGET_HOME}.
EOF
    else
        printf '  (dotfiles setup skipped)\n'
    fi
}

detect_package_manager() {
    [[ "$(uname -s)" == "Linux" ]] || die "This installer currently supports Linux VMs only."
    [[ -r /etc/os-release ]] || die "Cannot identify this Linux distribution (/etc/os-release is missing)."

    # shellcheck disable=SC1091
    . /etc/os-release
    local distro=" ${ID:-} ${ID_LIKE:-} "

    case "$distro" in
        *" debian "*|*" ubuntu "*)
            command -v apt-get >/dev/null 2>&1 || die "apt-get is required on Debian/Ubuntu systems."
            PKG_MANAGER=apt
            ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER=dnf
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER=yum
            else
                die "dnf or yum is required on Fedora/RHEL-like systems."
            fi
            ;;
        *" arch "*|*" manjaro "*)
            command -v pacman >/dev/null 2>&1 || die "pacman is required on Arch-like systems."
            PKG_MANAGER=pacman
            ;;
        *)
            die "Unsupported Linux distribution: ${ID:-unknown}. Supported families are Debian/Ubuntu, Fedora/RHEL, and Arch."
            ;;
    esac
}

require_sudo() {
    command -v sudo >/dev/null 2>&1 || die "sudo is required. Run this as your normal login user, not as root."
    sudo -v
}

install_system_packages() {
    log "Installing build and runtime dependencies with ${PKG_MANAGER}."

    case "$PKG_MANAGER" in
        apt)
            sudo apt-get update
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                ca-certificates curl git jq build-essential pkg-config \
                libevent-dev libncurses-dev bison autoconf automake libtool \
                python3 tar xz-utils gzip gettext
            ;;
        dnf|yum)
            sudo "$PKG_MANAGER" install -y \
                ca-certificates curl git jq gcc make pkgconf-pkg-config \
                libevent-devel ncurses-devel bison autoconf automake libtool \
                python3 tar xz gzip gettext
            ;;
        pacman)
            sudo pacman -Sy --needed --noconfirm \
                ca-certificates curl git jq base-devel pkgconf libevent ncurses \
                bison autoconf automake libtool python tar xz gzip gettext
            ;;
        *)
            die "Internal error: unknown package manager ${PKG_MANAGER}."
            ;;
    esac

    hash -r
}

init_workspace() {
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "HOME must point to an existing directory."
    [[ "$LOCAL_PREFIX" = /* ]] || die "LOCAL_PREFIX must be an absolute path."
    [[ "$DOTFILES_DIR" = /* ]] || die "DOTFILES_DIR must be an absolute path."
    [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be a positive integer."

    if ((INSTALL_APPS)); then
        mkdir -p "$INSTALL_DIR" "$VERSION_DIR"
        export PATH="${INSTALL_DIR}:${PATH}"
    fi
    TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-installer.XXXXXX")"
    trap 'if [[ -n "${TMP_ROOT:-}" ]]; then rm -rf -- "$TMP_ROOT"; fi' EXIT
}

curl_download() {
    curl --fail --location --retry 3 --retry-delay 1 \
        --connect-timeout 15 --proto '=https' --tlsv1.2 \
        --silent --show-error "$@"
}

fetch_release_json() {
    local repo="$1"
    local key="$2"
    local tag="${3:-}"
    local endpoint
    local output="${TMP_ROOT}/${key}.json"

    if [[ -n "$tag" ]]; then
        endpoint="https://api.github.com/repos/${repo}/releases/tags/${tag}"
    else
        endpoint="https://api.github.com/repos/${repo}/releases/latest"
    fi

    curl_download \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: BuzzHari-dotfiles-installer' \
        -o "$output" "$endpoint"

    [[ -n "$(jq -r '.tag_name // empty' "$output")" ]] || \
        die "GitHub did not return release metadata for ${repo}."
    printf '%s\n' "$output"
}

verify_sha256() {
    local expected="$1"
    local file="$2"

    [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] || \
        die "Invalid SHA-256 digest for ${file}."
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

download_verified_asset() {
    local json_path="$1"
    local asset_name="$2"
    local output="$3"
    local fallback_checksum_asset="${4:-}"
    local asset_url
    local expected
    local checksum_url
    local checksum_file

    asset_url="$(jq -r --arg name "$asset_name" \
        '.assets[]? | select(.name == $name) | .browser_download_url' "$json_path" | sed -n '1p')"
    [[ -n "$asset_url" && "$asset_url" != "null" ]] || \
        die "Release asset not found: ${asset_name}."
    [[ "$asset_url" == https://* ]] || die "Refusing a non-HTTPS download URL: ${asset_url}"

    log "Downloading ${asset_name}."
    curl_download -o "$output" "$asset_url"

    expected="$(jq -r --arg name "$asset_name" \
        '.assets[]? | select(.name == $name) | (.digest // empty)' "$json_path" | sed -n '1p')"
    expected="${expected#sha256:}"

    if [[ -z "$expected" && -n "$fallback_checksum_asset" ]]; then
        checksum_url="$(jq -r --arg name "$fallback_checksum_asset" \
            '.assets[]? | select(.name == $name) | .browser_download_url' "$json_path" | sed -n '1p')"
        [[ -n "$checksum_url" && "$checksum_url" != "null" ]] || \
            die "Neither an API digest nor checksum asset was found for ${asset_name}."
        checksum_file="${output}.checksums"
        curl_download -o "$checksum_file" "$checksum_url"

        # Verify the checksum file itself when GitHub exposes its digest.
        local checksum_digest
        checksum_digest="$(jq -r --arg name "$fallback_checksum_asset" \
            '.assets[]? | select(.name == $name) | (.digest // empty)' "$json_path" | sed -n '1p')"
        checksum_digest="${checksum_digest#sha256:}"
        [[ -n "$checksum_digest" ]] && verify_sha256 "$checksum_digest" "$checksum_file"

        expected="$(awk -v file="$asset_name" '$2 == file || $2 == "*" file { print $1; exit }' "$checksum_file")"
    fi

    [[ -n "$expected" ]] || die "No verifiable SHA-256 digest was published for ${asset_name}."
    verify_sha256 "$expected" "$output"
}

version_is_current() {
    local name="$1"
    local version="$2"
    local binary="$3"

    [[ -x "${INSTALL_DIR}/${binary}" && -f "${VERSION_DIR}/${name}" ]] || return 1
    [[ "$(<"${VERSION_DIR}/${name}")" == "$version" ]]
}

record_version() {
    local name="$1"
    local version="$2"
    local marker="${VERSION_DIR}/${name}"
    local temporary="${marker}.tmp.$$"

    printf '%s\n' "$version" > "$temporary"
    mv -f -- "$temporary" "$marker"
}

write_user_binary() {
    local source="$1"
    local destination="$2"

    [[ -f "$source" ]] || die "Expected executable was not found: ${source}"
    if [[ -L "$destination" ]]; then
        die "Refusing to overwrite symlink ${destination}; move it aside and rerun."
    fi
    [[ ! -d "$destination" ]] || die "Refusing to overwrite directory ${destination}."
    install -m 0755 -- "$source" "$destination"
}

extract_archive_binary() {
    local archive="$1"
    local binary="$2"
    local key="$3"
    local extract_dir="${TMP_ROOT}/extract-${key}"
    local candidate

    mkdir -p "$extract_dir"
    tar --no-same-owner -xzf "$archive" -C "$extract_dir"
    candidate="$(find "$extract_dir" -type f -name "$binary" -print -quit)"
    [[ -n "$candidate" ]] || die "Could not find ${binary} in ${archive}."
    write_user_binary "$candidate" "${INSTALL_DIR}/${binary}"
}

fzf_architecture() {
    case "$KERNEL_ARCH" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l) printf 'armv7' ;;
        armv6l) printf 'armv6' ;;
        armv5*) printf 'armv5' ;;
        riscv64) printf 'riscv64' ;;
        ppc64le) printf 'ppc64le' ;;
        s390x) printf 's390x' ;;
        loongarch64) printf 'loong64' ;;
        *) die "fzf has no configured Linux asset for architecture ${KERNEL_ARCH}." ;;
    esac
}

ripgrep_target() {
    case "$KERNEL_ARCH" in
        x86_64|amd64) printf 'x86_64-unknown-linux-musl' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-musl' ;;
        armv7l) printf 'armv7-unknown-linux-musleabihf' ;;
        s390x) printf 's390x-unknown-linux-gnu' ;;
        *) die "ripgrep has no configured Linux asset for architecture ${KERNEL_ARCH}." ;;
    esac
}

duf_architecture() {
    case "$KERNEL_ARCH" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l) printf 'armv7' ;;
        armv6l) printf 'armv6' ;;
        ppc64le) printf 'ppc64le' ;;
        i386|i686) printf '386' ;;
        *) die "duf has no configured Linux asset for architecture ${KERNEL_ARCH}." ;;
    esac
}

install_vim() {
    local tag
    local version
    local archive="${TMP_ROOT}/vim.tar.gz"
    local source_dir

    if [[ -n "$VIM_TAG" ]]; then
        tag="${VIM_TAG#refs/tags/}"
        [[ "$tag" == v* ]] || tag="v${tag}"
    else
        log "Looking up the newest Vim tag."
        tag="$(git ls-remote --tags --refs https://github.com/vim/vim.git 'refs/tags/v[0-9]*' \
            | awk -F/ '{print $3}' | sort -V | tail -n 1)"
        [[ -n "$tag" ]] || die "Could not determine the newest Vim tag."
    fi

    version="${tag#v}"
    if version_is_current vim "$tag" vim; then
        log "Vim ${version} is already installed in ${INSTALL_DIR}; skipping build."
        return
    fi

    log "Building Vim ${version} from the upstream source archive."
    curl_download -o "$archive" \
        "https://github.com/vim/vim/archive/refs/tags/${tag}.tar.gz"
    tar --no-same-owner -xzf "$archive" -C "$TMP_ROOT"
    source_dir="${TMP_ROOT}/vim-${version}"
    [[ -d "$source_dir" ]] || die "Unexpected Vim archive layout."

    (
        cd "$source_dir"
        ./configure \
            --prefix="$LOCAL_PREFIX" \
            --with-features=huge \
            --enable-multibyte \
            --enable-cscope \
            --disable-gui
        make -j "$BUILD_JOBS"
        make install
    )

    [[ -x "${INSTALL_DIR}/vim" ]] || die "Vim did not install to ${INSTALL_DIR}."
    record_version vim "$tag"
}

install_vim_plugin() {
    local repo="$1"
    local relative_dir="$2"
    local plugin_dir="${TARGET_HOME}/.vim/pack/${relative_dir}"
    local parent_dir
    local existing_origin

    if [[ -e "$plugin_dir" || -L "$plugin_dir" ]]; then
        if [[ -L "$plugin_dir" || ! -d "$plugin_dir" ]]; then
            warn "Vim plugin path exists but is not a directory; leaving it unchanged: ${plugin_dir}"
            return
        fi
        if ! git -C "$plugin_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            warn "Vim plugin directory is not a Git checkout; leaving it unchanged: ${plugin_dir}"
            return
        fi

        existing_origin="$(git -C "$plugin_dir" remote get-url origin 2>/dev/null || true)"
        if [[ "$existing_origin" != "$repo" ]]; then
            warn "Vim plugin has a different origin; leaving it unchanged: ${plugin_dir}"
            return
        fi
        if [[ -n "$(git -C "$plugin_dir" status --porcelain 2>/dev/null || true)" ]]; then
            warn "Vim plugin checkout has local changes; skipping update: ${plugin_dir}"
            return
        fi

        log "Updating Vim plugin ${repo}"
        if ! git -C "$plugin_dir" pull --ff-only --depth=1; then
            warn "Could not fast-forward Vim plugin; leaving it unchanged: ${plugin_dir}"
        fi
        return
    fi

    parent_dir="$(dirname -- "$plugin_dir")"
    mkdir -p "$parent_dir"
    log "Installing Vim plugin ${repo}"
    git clone --depth=1 "$repo" "$plugin_dir"
}

install_vim_plugins() {
    local spec
    local repo
    local relative_dir

    log "Installing Vim plugins with Vim's native package directories."
    for spec in "${VIM_PLUGIN_SPECS[@]}"; do
        IFS='|' read -r repo relative_dir <<< "$spec"
        install_vim_plugin "$repo" "$relative_dir"
    done
}

install_tmux() {
    local release_ref="${TMUX_TAG#v}"
    local json_path
    local version
    local asset
    local archive="${TMP_ROOT}/tmux.tar.gz"
    local source_dir

    json_path="$(fetch_release_json tmux/tmux tmux "$release_ref")"
    version="$(jq -r '.tag_name' "$json_path" | sed 's/^v//')"
    asset="tmux-${version}.tar.gz"

    if version_is_current tmux "$version" tmux; then
        log "tmux ${version} is already installed in ${INSTALL_DIR}; skipping build."
        return
    fi

    log "Building tmux ${version} from the upstream release archive."
    download_verified_asset "$json_path" "$asset" "$archive"
    tar --no-same-owner -xzf "$archive" -C "$TMP_ROOT"
    source_dir="${TMP_ROOT}/tmux-${version}"
    [[ -d "$source_dir" ]] || die "Unexpected tmux archive layout."

    (
        cd "$source_dir"
        ./configure --prefix="$LOCAL_PREFIX"
        make -j "$BUILD_JOBS"
        make install
    )

    [[ -x "${INSTALL_DIR}/tmux" ]] || die "tmux did not install to ${INSTALL_DIR}."
    record_version tmux "$version"
}

install_tpm() {
    local parent_dir
    local existing_origin

    if [[ -e "$TPM_DIR" || -L "$TPM_DIR" ]]; then
        if [[ -L "$TPM_DIR" || ! -d "$TPM_DIR" ]]; then
            warn "TPM path exists but is not a directory; leaving it unchanged: ${TPM_DIR}"
            return
        fi
        if ! git -C "$TPM_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            warn "TPM path is not a Git checkout; leaving it unchanged: ${TPM_DIR}"
            return
        fi

        existing_origin="$(git -C "$TPM_DIR" remote get-url origin 2>/dev/null || true)"
        if [[ "$existing_origin" != "$TPM_REPO_URL" ]]; then
            warn "TPM checkout has a different origin; leaving it unchanged: ${TPM_DIR}"
            return
        fi
        if [[ -n "$(git -C "$TPM_DIR" status --porcelain 2>/dev/null || true)" ]]; then
            warn "TPM checkout has local changes; skipping update: ${TPM_DIR}"
            return
        fi

        log "Updating TPM."
        if ! git -C "$TPM_DIR" pull --ff-only --depth=1; then
            warn "Could not fast-forward TPM; leaving it unchanged: ${TPM_DIR}"
        fi
        return
    fi

    parent_dir="$(dirname -- "$TPM_DIR")"
    mkdir -p "$parent_dir"
    log "Installing TPM."
    git clone --depth=1 "$TPM_REPO_URL" "$TPM_DIR"
}

reload_tmux_config() {
    local config_path="${TARGET_HOME}/.tmux.conf"

    command -v tmux >/dev/null 2>&1 || return 0
    [[ -f "$config_path" ]] || {
        log "No ${config_path} exists yet; tmux will read its configuration when started."
        return 0
    }

    if tmux list-sessions >/dev/null 2>&1; then
        log "Reloading ${config_path} in the running tmux server."
        if ! tmux source-file "$config_path"; then
            warn "Could not reload ${config_path}; start a new tmux server and inspect its configuration."
        fi
    else
        log "No running tmux server; ${config_path} will be read on the next tmux start."
    fi
}

install_fzf() {
    local json_path
    local version
    local architecture
    local asset
    local archive="${TMP_ROOT}/fzf.tar.gz"

    json_path="$(fetch_release_json junegunn/fzf fzf)"
    version="$(jq -r '.tag_name' "$json_path" | sed 's/^v//')"
    architecture="$(fzf_architecture)"
    asset="fzf-${version}-linux_${architecture}.tar.gz"

    if version_is_current fzf "$version" fzf; then
        log "fzf ${version} is already installed in ${INSTALL_DIR}; skipping download."
        return
    fi

    download_verified_asset "$json_path" "$asset" "$archive" \
        "fzf_${version}_checksums.txt"
    extract_archive_binary "$archive" fzf fzf
    "${INSTALL_DIR}/fzf" --version >/dev/null
    record_version fzf "$version"
}

install_ripgrep() {
    local json_path
    local version
    local target
    local asset
    local archive="${TMP_ROOT}/ripgrep.tar.gz"

    json_path="$(fetch_release_json BurntSushi/ripgrep ripgrep)"
    version="$(jq -r '.tag_name' "$json_path" | sed 's/^v//')"
    target="$(ripgrep_target)"
    asset="ripgrep-${version}-${target}.tar.gz"

    if version_is_current ripgrep "$version" rg; then
        log "ripgrep ${version} is already installed in ${INSTALL_DIR}; skipping download."
        return
    fi

    download_verified_asset "$json_path" "$asset" "$archive" "${asset}.sha256"
    extract_archive_binary "$archive" rg ripgrep
    "${INSTALL_DIR}/rg" --version >/dev/null
    record_version ripgrep "$version"
}

install_duf() {
    local json_path
    local version
    local architecture
    local asset
    local archive="${TMP_ROOT}/duf.tar.gz"

    json_path="$(fetch_release_json muesli/duf duf)"
    version="$(jq -r '.tag_name' "$json_path" | sed 's/^v//')"
    architecture="$(duf_architecture)"
    asset="duf_${version}_linux_${architecture}.tar.gz"

    if version_is_current duf "$version" duf; then
        log "duf ${version} is already installed in ${INSTALL_DIR}; skipping download."
        return
    fi

    download_verified_asset "$json_path" "$asset" "$archive" checksums.txt
    extract_archive_binary "$archive" duf duf
    "${INSTALL_DIR}/duf" --version >/dev/null
    record_version duf "$version"
}

version_at_least() {
    local minimum="$1"
    local actual="$2"
    [[ "$(printf '%s\n' "$minimum" "$actual" | sort -V | sed -n '1p')" == "$minimum" ]]
}

node_architecture() {
    case "$KERNEL_ARCH" in
        x86_64|amd64) printf 'x64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l) printf 'armv7l' ;;
        ppc64le) printf 'ppc64le' ;;
        s390x) printf 's390x' ;;
        *) die "Node.js has no configured Linux asset for architecture ${KERNEL_ARCH}." ;;
    esac
}

link_managed_binary() {
    local source="$1"
    local destination="$2"

    [[ -x "$source" ]] || die "Managed executable was not found: ${source}"
    if [[ -e "$destination" && ! -L "$destination" ]]; then
        die "Refusing to replace existing non-symlink ${destination}."
    fi
    ln -sfn "$source" "$destination"
}

install_node_if_needed() {
    local minimum="22.19.0"
    local current=""

    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        current="$(node --version 2>/dev/null | sed 's/^v//')"
        if [[ -n "$current" ]] && version_at_least "$minimum" "$current"; then
            log "Node.js ${current} and npm are already available for Pi."
            return
        fi
        warn "Existing Node.js ${current:-unknown} is older than Pi's required ${minimum}; installing a user-local LTS copy."
    else
        log "Pi requires Node.js ${minimum} or newer; installing a user-local LTS copy."
    fi

    local index="${TMP_ROOT}/node-index.json"
    local node_version
    local architecture
    local node_file
    local archive="${TMP_ROOT}/node.tar.xz"
    local sums="${TMP_ROOT}/node-SHASUMS256.txt"
    local expected
    local node_root
    local extracted

    curl_download -o "$index" https://nodejs.org/dist/index.json
    node_version="$(jq -r '[.[] | select(.lts != false)][0].version // empty' "$index")"
    [[ -n "$node_version" ]] || die "Could not determine the latest Node.js LTS release."
    version_at_least "$minimum" "${node_version#v}" || \
        die "Latest Node.js LTS ${node_version} is unexpectedly older than ${minimum}."

    architecture="$(node_architecture)"
    node_file="node-${node_version}-linux-${architecture}.tar.xz"
    node_root="${LOCAL_PREFIX}/lib/node/${node_version#v}-${architecture}"

    curl_download -o "$sums" "https://nodejs.org/dist/${node_version}/SHASUMS256.txt"
    expected="$(awk -v file="$node_file" '$2 == file { print $1; exit }' "$sums")"
    [[ -n "$expected" ]] || die "Node.js checksum not found for ${node_file}."
    curl_download -o "$archive" "https://nodejs.org/dist/${node_version}/${node_file}"
    verify_sha256 "$expected" "$archive"

    if [[ -e "$node_root" || -L "$node_root" ]]; then
        [[ -x "${node_root}/bin/node" ]] || die "Existing Node.js directory is incomplete: ${node_root}"
    else
        mkdir -p "${LOCAL_PREFIX}/lib/node"
        tar --no-same-owner -xJf "$archive" -C "$TMP_ROOT"
        extracted="${TMP_ROOT}/node-${node_version}-linux-${architecture}"
        [[ -x "${extracted}/bin/node" ]] || die "Unexpected Node.js archive layout."
        mv -- "$extracted" "$node_root"
    fi

    link_managed_binary "${node_root}/bin/node" "${INSTALL_DIR}/node"
    link_managed_binary "${node_root}/bin/npm" "${INSTALL_DIR}/npm"
    if [[ -e "${node_root}/bin/npx" || -L "${node_root}/bin/npx" ]]; then
        link_managed_binary "${node_root}/bin/npx" "${INSTALL_DIR}/npx"
    fi
    hash -r
    node --version
    npm --version
}

install_pi() {
    if command -v pi >/dev/null 2>&1; then
        log "Pi is already available at $(command -v pi); leaving the existing installation in place."
        return
    fi

    install_node_if_needed
    log "Installing Pi with the official pi.dev installer."
    # The installer is intentionally run as the target user.  The prefix keeps
    # npm's global package and launcher under the same user-local prefix.
    curl_download https://pi.dev/install.sh | NPM_CONFIG_PREFIX="$LOCAL_PREFIX" sh
    hash -r
    if [[ ! -x "${INSTALL_DIR}/pi" ]] && ! command -v pi >/dev/null 2>&1; then
        die "Pi installer completed without producing a pi executable on PATH."
    fi
}

install_codex() {
    case "$KERNEL_ARCH" in
        x86_64|amd64|aarch64|arm64) ;;
        *) die "The official Codex CLI Linux builds support x86_64 and arm64; this VM is ${KERNEL_ARCH}." ;;
    esac

    log "Installing or updating the OpenAI Codex CLI with the official installer."
    curl_download https://chatgpt.com/codex/install.sh | sh
    hash -r
    command -v codex >/dev/null 2>&1 || \
        warn "Codex installer finished, but codex is not currently on PATH. Start a new shell and check ${INSTALL_DIR}."
}

backup_dotfile_conflicts() {
    local backup_dir
    local relative_path
    local target
    local parent
    local backed_up=0

    backup_dir="$(mktemp -d "${TARGET_HOME}/.dotfiles-backup.XXXXXX")"
    while IFS= read -r -d '' relative_path; do
        target="${TARGET_HOME}/${relative_path}"
        if [[ -e "$target" || -L "$target" ]]; then
            # A symlink must be moved even when its contents happen to match;
            # checkout needs to replace it with the tracked file type.
            if [[ -L "$target" ]] || ! git --git-dir="$DOTFILES_DIR" show "HEAD:${relative_path}" | cmp -s - "$target"; then
                parent="$(dirname -- "$relative_path")"
                mkdir -p "${backup_dir}/${parent}"
                mv -- "$target" "${backup_dir}/${relative_path}"
                backed_up=$((backed_up + 1))
            fi
        fi
    done < <(git --git-dir="$DOTFILES_DIR" ls-tree -r -z --name-only HEAD)

    if ((backed_up)); then
        log "Backed up ${backed_up} conflicting home file(s) to ${backup_dir}."
    else
        # This directory is empty in this case; retain it so the user can see
        # that the installer checked for conflicts and recover it if desired.
        log "No conflicting dotfiles needed a backup; backup directory: ${backup_dir}."
    fi
}

setup_dotfiles() {
    local origin=""
    local checkout_log="${TMP_ROOT}/dotfiles-checkout.log"

    command -v git >/dev/null 2>&1 || die "git is required to configure the dotfiles repository."

    if [[ -e "$DOTFILES_DIR" || -L "$DOTFILES_DIR" ]]; then
        [[ -d "$DOTFILES_DIR" ]] || die "Dotfiles path exists but is not a directory: ${DOTFILES_DIR}"
        [[ "$(git --git-dir="$DOTFILES_DIR" rev-parse --is-bare-repository 2>/dev/null || true)" == true ]] || \
            die "Existing ${DOTFILES_DIR} is not a bare Git repository; refusing to replace it."

        origin="$(git --git-dir="$DOTFILES_DIR" remote get-url origin 2>/dev/null || true)"
        if [[ -z "$origin" ]]; then
            git --git-dir="$DOTFILES_DIR" remote add origin "$DOTFILES_REPO_URL"
            origin="$DOTFILES_REPO_URL"
        else
            log "Using existing dotfiles remote: ${origin}"
        fi
        git --git-dir="$DOTFILES_DIR" fetch --prune origin
    else
        log "Cloning ${DOTFILES_REPO_URL} as a bare repository into ${DOTFILES_DIR}."
        git clone --bare "$DOTFILES_REPO_URL" "$DOTFILES_DIR"
    fi

    git --git-dir="$DOTFILES_DIR" config status.showUntrackedFiles no

    if git --git-dir="$DOTFILES_DIR" --work-tree="$TARGET_HOME" checkout >"$checkout_log" 2>&1; then
        cat "$checkout_log"
    else
        cat "$checkout_log" >&2
        warn "Dotfiles checkout found existing files; preserving conflicts in a backup directory."
        backup_dotfile_conflicts
        git --git-dir="$DOTFILES_DIR" --work-tree="$TARGET_HOME" checkout
    fi

    log "Bare dotfiles repository is ready at ${DOTFILES_DIR}."
}

show_summary() {
    local command_name
    local path

    printf '\n'
    log "Setup finished."
    if ((INSTALL_APPS)); then
        printf 'Installed command paths:\n'
        for command_name in vim tmux fzf rg duf pi codex; do
            path="$(command -v "$command_name" 2>/dev/null || true)"
            if [[ -n "$path" ]]; then
                printf '  %-6s %s\n' "$command_name" "$path"
            else
                printf '  %-6s NOT FOUND\n' "$command_name"
            fi
        done
    fi
    if ((SETUP_DOTFILES)); then
        printf 'Dotfiles command: git --git-dir="$HOME/.dotfiles" --work-tree="$HOME"\n'
    fi
    printf '\nStart a new shell (or run: source "$HOME/.bashrc") to load the checked-out shell configuration.\n'
    printf 'Codex sign-in and model selection happen on first run: codex, then /model.\n'
}

main() {
    parse_args "$@"

    if ((DRY_RUN)); then
        print_dry_run
        return 0
    fi

    if (( !INSTALL_APPS && !SETUP_DOTFILES )); then
        log "Nothing to do; both applications and dotfiles setup were skipped."
        return 0
    fi

    [[ -n "$TARGET_HOME" ]] || die "HOME is not set."
    ((EUID != 0)) || die "Run this as the target login user, without sudo; it uses sudo only for dependencies."
    init_workspace

    if ((INSTALL_APPS)); then
        detect_package_manager
        require_sudo
        install_system_packages
        install_vim
        install_vim_plugins
        install_tmux
        install_tpm
        install_fzf
        install_ripgrep
        install_duf
        install_pi
        install_codex
    fi

    if ((SETUP_DOTFILES)); then
        setup_dotfiles
    fi

    if ((INSTALL_APPS)); then
        reload_tmux_config
    fi

    show_summary
}

main "$@"
