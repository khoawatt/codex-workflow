#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CODEX_WORK_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${CODEX_WORK_CONFIG_DIR:-$HOME/.config/codex-work}"
CONFIG_FILE="$CONFIG_DIR/projects.conf"
CLONE_PROJECTS=1

die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: bash install.sh [--no-clone]

Installs codex-work and its default project config. Missing projects are cloned
by default. Existing config and project directories are never overwritten.
EOF
}

case "${1:-}" in
    '') ;;
    --no-clone) CLONE_PROJECTS=0 ;;
    --help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
esac
[[ $# -le 1 ]] || die "Too many arguments."

command -v git >/dev/null 2>&1 || die "git is required."

install -d "$BIN_DIR" "$CONFIG_DIR"
install -m 0755 "$REPO_ROOT/bin/codex-work" "$BIN_DIR/codex-work"

if [[ -e "$CONFIG_FILE" ]]; then
    printf 'Kept existing config: %s\n' "$CONFIG_FILE"
else
    install -m 0644 "$REPO_ROOT/config/projects.conf" "$CONFIG_FILE"
    printf 'Installed default config: %s\n' "$CONFIG_FILE"
fi

expand_path() {
    case "$1" in
        '~') printf '%s\n' "$HOME" ;;
        '~/'*) printf '%s/%s\n' "$HOME" "${1:2}" ;;
        /*) printf '%s\n' "$1" ;;
        *) die "Checkout path must be absolute or start with ~/: $1" ;;
    esac
}

if [[ "$CLONE_PROJECTS" == "1" ]]; then
    while IFS='|' read -r name url checkout_path extra || [[ -n "${name}${url}${checkout_path}${extra}" ]]; do
        [[ -z "${name//[[:space:]]/}" || "$name" == \#* ]] && continue
        [[ -n "$name" && -n "$url" && -n "$checkout_path" && -z "${extra:-}" ]] ||
            die "Invalid entry in $CONFIG_FILE."

        target="$(expand_path "$checkout_path")"
        if [[ -e "$target" ]]; then
            printf 'Kept existing project: %s (%s)\n' "$name" "$target"
            continue
        fi

        install -d "$(dirname -- "$target")"
        printf 'Cloning %s into %s\n' "$name" "$target"
        git clone "$url" "$target"
    done < "$CONFIG_FILE"
fi

printf '\nInstalled launcher: %s/codex-work\n' "$BIN_DIR"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    printf 'Add this directory to PATH, then restart your shell:\n'
    printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
fi

for dependency in tmux codex; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'Warning: %s is not installed or not in PATH. See docs/SETUP.md.\n' "$dependency" >&2
    fi
done

printf 'Next: codex-work --status, then codex-work\n'
