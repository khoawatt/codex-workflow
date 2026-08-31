#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
START='<!-- codex-work:project-workflow:start -->'
END='<!-- codex-work:project-workflow:end -->'

die() { printf 'install-project.sh: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 && -d "$TARGET" ]] || die 'usage: bash install-project.sh <repo-path>'
TARGET="$(cd -- "$TARGET" && pwd)"

install_if_absent() {
    local source="$1" destination="$2" mode="$3"
    if [[ -e "$destination" ]]; then
        printf 'Kept existing file: %s\n' "$destination"
        return
    fi
    install -d "$(dirname -- "$destination")"
    install -m "$mode" "$source" "$destination"
    printf 'Installed: %s\n' "$destination"
}

install_if_absent "$REPO_ROOT/templates/merge-approved-pr.sh" \
    "$TARGET/.codex/scripts/merge-approved-pr.sh" 0755

agents="$TARGET/AGENTS.md"
has_start=0; has_end=0
[[ -s "$agents" ]] && grep -Fq "$START" "$agents" && has_start=1
[[ -s "$agents" ]] && grep -Fq "$END" "$agents" && has_end=1
[[ "$has_start" == "$has_end" ]] || die "incomplete managed workflow block in $agents"
if [[ "$has_start" == 1 ]]; then
    printf 'Kept existing project workflow block: %s\n' "$agents"
else
    [[ -e "$agents" ]] && { backup="$agents.backup.$(date +%Y%m%d%H%M%S)"; cp -p -- "$agents" "$backup"; printf 'Backup: %s\n' "$backup"; }
    { [[ -s "$agents" ]] && printf '\n'; cat "$REPO_ROOT/templates/AGENTS.workflow.md"; } >> "$agents"
    printf 'Installed project workflow block: %s\n' "$agents"
fi

printf 'Restart Codex sessions for %s so the new AGENTS.md instructions are loaded.\n' "$TARGET"
