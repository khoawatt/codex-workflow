#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

bash -n "$REPO_ROOT/bin/codex-work" "$REPO_ROOT/install.sh" \
    "$REPO_ROOT/install-project.sh" "$REPO_ROOT/templates/merge-approved-pr.sh"
node --check "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs"
node --check "$REPO_ROOT/gemini-web/gemini-consult.mjs" "$REPO_ROOT/gemini-web/session-auth.mjs"
bash -n "$REPO_ROOT/chatgpt-web/chatgpt-consult" "$REPO_ROOT/chatgpt-web/chatgpt-autoreview" \
    "$REPO_ROOT/gemini-web/gemini-consult" "$REPO_ROOT/install-chatgpt-web.sh" \
    "$REPO_ROOT/install-gemini-web.sh"
if "$REPO_ROOT/templates/merge-approved-pr.sh" --admin >/dev/null 2>&1; then
    fail "merge wrapper accepted a bypass argument"
fi
if grep -Eqi 'approval|autoreview|merge|project' "$REPO_ROOT/gemini-web/gemini-consult.mjs"; then
    fail "Gemini scraper contains workflow-only capabilities"
fi

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

chatgpt_home="$TEST_ROOT/chatgpt-home"
chatgpt_bin="$chatgpt_home/bin"
chatgpt_bridge="$chatgpt_home/bridge"
chatgpt_codex="$chatgpt_home/codex"
mkdir -p "$chatgpt_codex" "$chatgpt_bridge"
printf '# existing global guidance\n' > "$chatgpt_codex/AGENTS.md"
printf '{"max_turns": 7}\n' > "$chatgpt_bridge/bridge-config.json"

HOME="$chatgpt_home" \
CODEX_HOME="$chatgpt_codex" \
CODEX_WORK_BIN_DIR="$chatgpt_bin" \
CODEX_WORK_CHATGPT_DIR="$chatgpt_bridge" \
CODEX_WORK_SKIP_NPM_INSTALL=1 \
    bash "$REPO_ROOT/install-chatgpt-web.sh" >/dev/null

[[ -x "$chatgpt_bin/chatgpt-consult" ]] || fail "chatgpt-consult was not installed"
[[ -x "$chatgpt_bin/chatgpt-autoreview" ]] || fail "chatgpt-autoreview was not installed"
[[ -f "$chatgpt_bridge/chatgpt-consult.mjs" ]] || fail "bridge source was not installed"
grep -Fxq '{"max_turns": 7}' "$chatgpt_bridge/bridge-config.json" ||
    fail "existing bridge config was overwritten"
grep -Fq '# existing global guidance' "$chatgpt_codex/AGENTS.md" ||
    fail "existing global Codex instructions were not preserved"
[[ "$(grep -Fc '<!-- codex-work:chatgpt-web:start -->' "$chatgpt_codex/AGENTS.md")" -eq 1 ]] ||
    fail "managed global instruction block was not installed exactly once"
compgen -G "$chatgpt_codex/AGENTS.md.backup.*" >/dev/null ||
    fail "existing global instructions were not backed up"

HOME="$chatgpt_home" \
CODEX_HOME="$chatgpt_codex" \
CODEX_WORK_BIN_DIR="$chatgpt_bin" \
CODEX_WORK_CHATGPT_DIR="$chatgpt_bridge" \
CODEX_WORK_SKIP_NPM_INSTALL=1 \
    bash "$REPO_ROOT/install-chatgpt-web.sh" >/dev/null
[[ "$(grep -Fc '<!-- codex-work:chatgpt-web:start -->' "$chatgpt_codex/AGENTS.md")" -eq 1 ]] ||
    fail "managed global instruction block was duplicated"

printf '# temporary override\n' > "$chatgpt_codex/AGENTS.override.md"
override_warning="$(
    HOME="$chatgpt_home" \
    CODEX_HOME="$chatgpt_codex" \
    CODEX_WORK_BIN_DIR="$chatgpt_bin" \
    CODEX_WORK_CHATGPT_DIR="$chatgpt_bridge" \
    CODEX_WORK_SKIP_NPM_INSTALL=1 \
        bash "$REPO_ROOT/install-chatgpt-web.sh" 2>&1 >/dev/null
)"
grep -Fq 'Codex ignores' <<< "$override_warning" ||
    fail "AGENTS.override.md shadow warning was not reported"

CODEX_WORK_CHATGPT_DIR="$chatgpt_bridge" "$REPO_ROOT/chatgpt-web/chatgpt-autoreview" on >/dev/null
CODEX_WORK_CHATGPT_DIR="$chatgpt_bridge" "$REPO_ROOT/chatgpt-web/chatgpt-autoreview" status |
    grep -Fxq 'auto-review: ON' || fail "auto-review did not turn on"
[[ "$(stat -c '%a' "$chatgpt_bridge/autoreview.json")" == 600 ]] ||
    fail "auto-review state permissions are not 0600"
CODEX_WORK_CHATGPT_DIR="$chatgpt_bridge" "$REPO_ROOT/chatgpt-web/chatgpt-autoreview" off >/dev/null

approval_bridge="$TEST_ROOT/approval-bridge"
head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
(
    cd "$REPO_ROOT"
    CODEX_WORK_CHATGPT_DIR="$approval_bridge" \
        node chatgpt-web/chatgpt-consult.mjs approval set approve "$head_sha" none >/dev/null
    approval="$(CODEX_WORK_CHATGPT_DIR="$approval_bridge" node chatgpt-web/chatgpt-consult.mjs approval get)"
    grep -Fq "\"head_sha\":\"$head_sha\"" <<< "$approval" || fail "approval HEAD was not persisted"
    grep -Fq '"repo":' <<< "$approval" || fail "approval repo identity was not persisted"
    if CODEX_WORK_CHATGPT_DIR="$approval_bridge" \
        node chatgpt-web/chatgpt-consult.mjs approval set invalid "$head_sha" none >/dev/null 2>&1; then
        fail "invalid approval verdict was accepted"
    fi
)
[[ "$(stat -c '%a' "$approval_bridge/chats.json")" == 600 ]] || fail "approval state permissions are not 0600"

project_target="$TEST_ROOT/project-target"
mkdir -p "$project_target/.git"
printf '# existing project guidance\n' > "$project_target/AGENTS.md"
bash "$REPO_ROOT/install-project.sh" "$project_target" >/dev/null
grep -Fq '# existing project guidance' "$project_target/AGENTS.md" || fail "project guidance was overwritten"
[[ "$(grep -Fc '<!-- codex-work:project-workflow:start -->' "$project_target/AGENTS.md")" -eq 1 ]] ||
    fail "project workflow block was not installed exactly once"
[[ -x "$project_target/.codex/scripts/merge-approved-pr.sh" ]] || fail "merge guard was not installed"
bash "$REPO_ROOT/install-project.sh" "$project_target" >/dev/null
[[ "$(grep -Fc '<!-- codex-work:project-workflow:start -->' "$project_target/AGENTS.md")" -eq 1 ]] ||
    fail "project workflow block was duplicated"

gemini_home="$TEST_ROOT/gemini-home"
gemini_bin="$gemini_home/bin"
gemini_bridge="$gemini_home/bridge"
HOME="$gemini_home" \
CODEX_WORK_BIN_DIR="$gemini_bin" \
CODEX_WORK_GEMINI_DIR="$gemini_bridge" \
CODEX_WORK_SKIP_NPM_INSTALL=1 \
    bash "$REPO_ROOT/install-gemini-web.sh" >/dev/null
[[ -x "$gemini_bin/gemini-consult" ]] || fail "gemini-consult was not installed"
[[ -f "$gemini_bridge/gemini-consult.mjs" ]] || fail "Gemini bridge source was not installed"
[[ -f "$gemini_bridge/session-auth.mjs" ]] || fail "Gemini auth classifier was not installed"
printf '{"max_turns":9}\n' > "$gemini_bridge/bridge-config.json"
HOME="$gemini_home" \
CODEX_WORK_BIN_DIR="$gemini_bin" \
CODEX_WORK_GEMINI_DIR="$gemini_bridge" \
CODEX_WORK_SKIP_NPM_INSTALL=1 \
    bash "$REPO_ROOT/install-gemini-web.sh" >/dev/null
grep -Fxq '{"max_turns":9}' "$gemini_bridge/bridge-config.json" ||
    fail "existing Gemini config was overwritten"
gemini_state="$TEST_ROOT/gemini-state"
(
    cd "$REPO_ROOT"
    CODEX_WORK_GEMINI_DIR="$gemini_state" node gemini-web/gemini-consult.mjs reset >/dev/null
    for forbidden in approval project autoreview merge; do
        if CODEX_WORK_GEMINI_DIR="$gemini_state" \
            node gemini-web/gemini-consult.mjs "$forbidden" >/dev/null 2>&1; then
            fail "Gemini accepted forbidden workflow command: $forbidden"
        fi
    done
)
[[ "$(stat -c '%a' "$gemini_state/chats.json")" == 600 ]] || fail "Gemini state permissions are not 0600"

REPO_ROOT="$REPO_ROOT" node --input-type=module <<'EOF'
import { strict as assert } from 'node:assert'
import { pathToFileURL } from 'node:url'

const auth = await import(pathToFileURL(`${process.env.REPO_ROOT}/gemini-web/session-auth.mjs`))
const classify = auth.classifyGeminiSession

assert.deepEqual(classify({ onGeminiOrigin: true, explicitSignedOut: true, identityEvidence: false, canAsk: true, cookieNames: ['NID', 'COMPASS'] }), {
  loggedIn: false, canAsk: true, guestAvailable: true, googleSessionCookie: false,
})
assert.equal(classify({ onGeminiOrigin: true, explicitSignedOut: true, identityEvidence: true, canAsk: true, cookieNames: ['SID'] }).loggedIn, false)
assert.equal(classify({ onGeminiOrigin: true, explicitSignedOut: false, identityEvidence: false, canAsk: true, cookieNames: ['SID'] }).loggedIn, false)
assert.equal(classify({ onGeminiOrigin: false, explicitSignedOut: false, identityEvidence: true, canAsk: true, cookieNames: ['SID'] }).loggedIn, false)
assert.deepEqual(classify({ onGeminiOrigin: true, explicitSignedOut: false, identityEvidence: true, canAsk: false, cookieNames: ['SID'] }), {
  loggedIn: true, canAsk: false, guestAvailable: false, googleSessionCookie: true,
})

const ready = { loggedIn: true, canAsk: true }
assert.equal(auth.advanceLoginStability(0, ready, true), 1)
assert.equal(auth.advanceLoginStability(1, ready, true), 2)
assert.equal(auth.advanceLoginStability(2, ready, false), 1)
assert.equal(auth.advanceLoginStability(2, null, true), 0)
assert.equal(auth.advanceLoginStability(2, { loggedIn: true, canAsk: false }, true), 0)
assert.equal(auth.advanceLoginStability(2, ready, true, false), 0)
EOF

printf 'PASS: launcher, workflow installers, ChatGPT review controls, and Gemini scraper safe-install checks\n'
