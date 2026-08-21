#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

bash -n "$REPO_ROOT/bin/codex-work" "$REPO_ROOT/install.sh"

mkdir -p "$TEST_ROOT/fake-bin"
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "has-session" ]]; then exit 1; fi
exit 0
EOF
cat > "$TEST_ROOT/fake-bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux" "$TEST_ROOT/fake-bin/codex"

HOME="$TEST_ROOT/home" \
PATH="$TEST_ROOT/fake-bin:$PATH" \
CODEX_WORK_BIN_DIR="$TEST_ROOT/home/.local/bin" \
CODEX_WORK_CONFIG_DIR="$TEST_ROOT/home/.config/codex-work" \
    bash "$REPO_ROOT/install.sh" --no-clone >/dev/null

[[ -x "$TEST_ROOT/home/.local/bin/codex-work" ]] || fail "launcher was not installed"
[[ -f "$TEST_ROOT/home/.config/codex-work/projects.conf" ]] || fail "config was not installed"

printf '# preserved\nsolo|https://example.invalid/solo.git|~/work/solo\n' \
    > "$TEST_ROOT/home/.config/codex-work/projects.conf"

HOME="$TEST_ROOT/home" \
PATH="$TEST_ROOT/fake-bin:$PATH" \
CODEX_WORK_BIN_DIR="$TEST_ROOT/home/.local/bin" \
CODEX_WORK_CONFIG_DIR="$TEST_ROOT/home/.config/codex-work" \
    bash "$REPO_ROOT/install.sh" --no-clone >/dev/null

grep -Fxq '# preserved' "$TEST_ROOT/home/.config/codex-work/projects.conf" ||
    fail "existing config was overwritten"

status_output="$(
    HOME="$TEST_ROOT/home" \
    PATH="$TEST_ROOT/fake-bin:$PATH" \
    CODEX_WORK_CONFIG="$TEST_ROOT/home/.config/codex-work/projects.conf" \
        "$REPO_ROOT/bin/codex-work" --status
)"
grep -Fq 'solo -> ' <<< "$status_output" || fail "project missing from status"
grep -Fq "solo -> $TEST_ROOT/home/work/solo" <<< "$status_output" ||
    fail "~/ checkout path was not expanded against HOME"
grep -Fq 'State: stopped' <<< "$status_output" || fail "stopped state not reported"

printf 'bad entry\n' > "$TEST_ROOT/bad.conf"
if HOME="$TEST_ROOT/home" CODEX_WORK_CONFIG="$TEST_ROOT/bad.conf" \
    "$REPO_ROOT/bin/codex-work" --status >/dev/null 2>&1; then
    fail "invalid config was accepted"
fi

printf 'PASS: syntax, idempotent install, status and config validation\n'
