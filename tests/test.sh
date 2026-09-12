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
node --check "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" "$REPO_ROOT/chatgpt-web/bridge-env.mjs" "$REPO_ROOT/chatgpt-web/chatgpt-auth-flow.mjs"
node --check "$REPO_ROOT/gemini-web/gemini-consult.mjs" "$REPO_ROOT/gemini-web/session-auth.mjs" "$REPO_ROOT/gemini-web/bridge-env.mjs"
node --check "$REPO_ROOT/bridge-env.mjs" 2>/dev/null || true
bash -n "$REPO_ROOT/chatgpt-web/chatgpt-consult" "$REPO_ROOT/chatgpt-web/chatgpt-autoreview" \
    "$REPO_ROOT/gemini-web/gemini-consult" "$REPO_ROOT/install-chatgpt-web.sh" \
    "$REPO_ROOT/install-gemini-web.sh"
if "$REPO_ROOT/templates/merge-approved-pr.sh" --admin >/dev/null 2>&1; then
    fail "merge wrapper accepted a bypass argument"
fi
# .env loader checks (port from opencode-workflow 768bf4c)
node --check "$REPO_ROOT/chatgpt-web/bridge-env.mjs" 2>/dev/null || fail "chatgpt bridge-env missing"
node --check "$REPO_ROOT/gemini-web/bridge-env.mjs" 2>/dev/null || fail "gemini bridge-env missing"
grep -Eq '^\.env$' "$REPO_ROOT/.gitignore" || fail ".gitignore missing .env rule"
[[ -f "$REPO_ROOT/config/chatgpt-bridge.env.example" ]] || fail "chatgpt .env example missing"
[[ -f "$REPO_ROOT/config/gemini-bridge.env.example" ]] || fail "gemini .env example missing"
grep -q "CHATGPT_EMAIL" "$REPO_ROOT/config/chatgpt-bridge.env.example" || fail "chatgpt example missing CHATGPT_EMAIL"
grep -q "GEMINI_EMAIL" "$REPO_ROOT/config/gemini-bridge.env.example" || fail "gemini example missing GEMINI_EMAIL"
grep -q "bridge-env.mjs" "$REPO_ROOT/install-chatgpt-web.sh" || fail "install-chatgpt-web.sh does not install bridge-env.mjs"
grep -q "bridge-env.mjs" "$REPO_ROOT/install-gemini-web.sh" || fail "install-gemini-web.sh does not install bridge-env.mjs"
grep -q 'login --auto' "$REPO_ROOT/install-chatgpt-web.sh" || fail "install-chatgpt-web.sh missing login --auto hint"
grep -q 'login --auto' "$REPO_ROOT/install-gemini-web.sh" || fail "install-gemini-web.sh missing login --auto hint"
grep -q "chatgpt-auth-flow.mjs" "$REPO_ROOT/install-chatgpt-web.sh" || fail "install-chatgpt-web.sh does not install chatgpt-auth-flow.mjs"
grep -q "CHATGPT_TOTP_SECRET" "$REPO_ROOT/config/chatgpt-bridge.env.example" || fail "chatgpt example missing CHATGPT_TOTP_SECRET"
[[ -f "$REPO_ROOT/chatgpt-web/chatgpt-auth-flow.mjs" ]] || fail "chatgpt-auth-flow.mjs missing"

# ChatGPT/OpenAI auth transaction behavior (no browser required, port from opencode-workflow).
REPO_ROOT="$REPO_ROOT" node --input-type=module <<'EOF'
import { strict as assert } from 'node:assert'
import { pathToFileURL } from 'node:url'

const auth = await import(pathToFileURL(`${process.env.REPO_ROOT}/chatgpt-web/chatgpt-auth-flow.mjs`))

for (const body of ['Oops, an error occurred', 'Route Error', '400 Invalid content type']) {
  assert.equal(auth.isAuth0RouteError(body), true, `missed Route Error text: ${body}`)
}
assert.equal(auth.isAuth0RouteError('Incorrect password'), false)
assert.equal(auth.isRecoverableOpenAiRouteError('Oops, an error occurred', 'https://auth.openai.com/u/login'), true)
assert.equal(auth.isRecoverableOpenAiRouteError('Oops, an error occurred', 'https://accounts.google.com/signin'), false)
assert.equal(auth.isRecoverableOpenAiRouteError('Oops, an error occurred', 'https://chatgpt.com/'), false)
assert.match(auth.detectOpenAiAuthBlocker('Incorrect password', 'https://auth.openai.com/'), /email\/password/)
assert.match(auth.detectOpenAiAuthBlocker('Enter your verification code', 'https://auth.openai.com/'), /2FA/)
assert.equal(auth.detectOpenAiAuthBlocker('', 'https://auth.openai.com/'), null)
assert.equal(auth.isInteractiveOpenAiChallenge('Enter your verification code', 'https://auth.openai.com/'), true)
assert.equal(auth.isInteractiveOpenAiChallenge('Verify you are human', 'https://auth.openai.com/'), true)
assert.equal(auth.isInteractiveOpenAiChallenge('', 'https://example.com/?__cf_chl=1'), true)
assert.equal(auth.isInteractiveOpenAiChallenge('Incorrect password', 'https://auth.openai.com/'), false)

const attempt = auth.createOpenAiAuthAttempt()
assert.equal(auth.claimPasswordSubmit(attempt), true)
assert.equal(auth.claimPasswordSubmit(attempt), false, 'password was submitted twice in one transaction')
for (let recovery = 1; recovery <= 3; recovery++) {
  assert.equal(auth.claimRouteRecovery(attempt), true, `recovery ${recovery} should be allowed`)
  assert.equal(attempt.recoveries, recovery)
  assert.equal(auth.claimPasswordSubmit(attempt), true, 'a recovered transaction should allow one new submit')
  assert.equal(auth.claimPasswordSubmit(attempt), false, 'recovered transaction allowed a duplicate submit')
}
assert.equal(auth.claimRouteRecovery(attempt), false, 'manual/auto recovery exceeded three attempts')
assert.match(auth.ROUTE_RECOVERY_EXHAUSTED_MESSAGE, /chatgpt-consult logout\nchatgpt-consult login/)

async function runWait({ busy, terminalAt = null }) {
  let clock = 0
  const result = await auth.waitForOpenAiPasswordOutcome({
    observe: async () => {
      if (terminalAt !== null && clock >= terminalAt) return { state: 'auth0-error' }
      return { state: 'pending', busy }
    },
    wait: async (ms) => { clock += ms },
    now: () => clock,
    pollMs: 1000,
  })
  return { result, clock }
}

const quiet = await runWait({ busy: false })
assert.deepEqual(quiet.result, { state: 'stuck' })
assert.equal(quiet.clock, 25000, 'quiet submit was declared stuck before 25 seconds')

const busy = await runWait({ busy: true })
assert.deepEqual(busy.result, { state: 'timeout' })
assert.equal(busy.clock, 60000, 'busy submit did not continue to the 60-second hard timeout')

const routeError = await runWait({ busy: false, terminalAt: 5000 })
assert.deepEqual(routeError.result, { state: 'auth0-error' })
assert.equal(routeError.clock, 5000)

assert.equal(auth.isOpenAiAuthTransactionCookie({ domain: '.auth.openai.com', name: 'state' }), true)
assert.equal(auth.isOpenAiAuthTransactionCookie({ domain: 'tenant.us.auth0.com', name: 'a0.spajs.txs.example' }), true)
assert.equal(auth.isOpenAiAuthTransactionCookie({ domain: 'auth0.openai.com', name: 'nonce' }), true)
assert.equal(auth.isOpenAiAuthTransactionCookie({ domain: '.auth.openai.com', name: 'auth0' }), false, 'Auth0 SSO cookie must be preserved')
assert.equal(auth.isOpenAiAuthTransactionCookie({ domain: 'accounts.google.com', name: 'state' }), false)
assert.equal(auth.isOpenAiAuthTransactionCookie({ domain: '.chatgpt.com', name: 'state' }), false)
assert.equal(auth.isOpenAiAuthTransactionStorageKey('a0.spajs.txs.example'), true)
assert.equal(auth.isOpenAiAuthTransactionStorageKey('oauth_state'), true)
assert.equal(auth.isOpenAiAuthTransactionStorageKey('@@auth0spajs@@::client::audience::scope'), false, 'Auth0 token cache must be preserved')
assert.equal(auth.isOpenAiAuthUrl('https://auth.openai.com/u/login/password'), true)
assert.equal(auth.isOpenAiAuthUrl('https://tenant.us.auth0.com/authorize'), true)
assert.equal(auth.isOpenAiAuthUrl('https://auth0.openai.com/authorize'), true)
assert.equal(auth.isOpenAiAuthUrl('https://accounts.google.com/signin'), false)
assert.equal(auth.isOpenAiAuthUrl('https://chatgpt.com/'), false)
assert.equal(auth.isOpenAiAuthUrl('https://auth0.com.evil.example/'), false)
assert.equal(auth.isOpenAiAuthUrl('https://notauth0.com/'), false)

const RFC_B32 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
assert.deepEqual(auth.base32Decode(RFC_B32), Buffer.from('12345678901234567890'), 'base32 must decode to the RFC 6238 raw key')
assert.equal(auth.base32Decode('  gezd gnbv gy3t qojq gezd gnbv gy3t qojq ').toString(), '12345678901234567890', 'base32 must ignore whitespace/case')
for (const bad of ['', 'ABC!DEFG', 'MZ======', 'AB==CD==', 'A']) {
  assert.throws(() => auth.base32Decode(bad), /invalid TOTP secret/, `bad secret accepted: ${bad}`)
}
try { auth.base32Decode('!!'); assert.fail('expected throw') } catch (e) { assert.match(e.message, /invalid TOTP secret/); assert.ok(!/!!/.test(e.message), 'error echoed the secret') }
// RFC 6238 Appendix B SHA-1 vectors, 8 digits
for (const [t, expected] of [[59, '94287082'], [1111111109, '07081804'], [1111111111, '14050471'], [1234567890, '89005924'], [2000000000, '69279037'], [20000000000, '65353130']]) {
  const { code } = auth.totpCode(RFC_B32, { timeMs: t * 1000, digits: 8 })
  assert.equal(code, expected, `RFC6238 vector t=${t}`)
}
assert.equal(auth.totpCounterAt(59000), 1)
assert.equal(auth.totpMsRemainingInWindow(59000), 1000)

const mfaUrl = 'https://auth.openai.com/mfa-challenge/abc'
assert.equal(auth.isOpenAiAuthenticatorChallenge('Check your authenticator app. Enter the one-time authentication code.', mfaUrl), true)
assert.equal(auth.isOpenAiAuthenticatorChallenge('Check your email. We sent you a code.', 'https://auth.openai.com/u/email-verify'), false, 'email-code must not be TOTP-eligible')
assert.equal(auth.isOpenAiAuthenticatorChallenge('Enter the one-time code from your app', 'https://evil.example/otp'), false, 'non-OpenAI origin must never be TOTP-eligible')
assert.equal(auth.isOpenAiAuthenticatorChallenge('Enter the one-time code from your app', 'https://chatgpt.com/'), false, 'chatgpt.com is not an auth origin')

const totpAttempt = auth.createOpenAiAuthAttempt()
assert.equal(totpAttempt.totpSubmittedCounter, null)
assert.equal(auth.claimTotpSubmit(totpAttempt, 100), true, 'first TOTP submit')
assert.equal(auth.claimTotpSubmit(totpAttempt, 100), false, 'same TOTP counter replayed')
assert.equal(auth.claimTotpSubmit(totpAttempt, 101), true, 'single retry with advanced counter')
assert.equal(auth.claimTotpSubmit(totpAttempt, 102), false, 'second retry must be blocked')
EOF

grep -q "allowInteractive: true" "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" || fail "login --auto does not enable interactive verification fallback"
grep -q "interactiveTimeoutSec: 1200" "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" || fail "login --auto interactive verification window is not 20 minutes"
grep -q "interactive: isInteractiveOpenAiChallenge(body, url)" "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" || fail "password outcome does not preserve interactive challenge classification"
grep -q "allowInteractive && settled.interactive" "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" || fail "password blocker can still abort before interactive handoff"
grep -q "await tryAutoTotpSubmit(page, creds, authAttempt)" "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" || fail "TOTP autofill hook missing"
grep -q "totpConfigured" "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" || fail "status does not report totpConfigured"

# logout must delete the saved profile without touching .env (no browser needed)
logout_bridge="$TEST_ROOT/logout-bridge"
mkdir -p "$logout_bridge/profile/Default"
printf 'CHATGPT_EMAIL=a@ex.com\nCHATGPT_PASSWORD=x\n' > "$logout_bridge/.env"
chmod 600 "$logout_bridge/.env"
printf '{"chats":{}}\n' > "$logout_bridge/chats.json"
printf '{"projects":{}}\n' > "$logout_bridge/projects.json"
CODEX_WORK_CHATGPT_DIR="$logout_bridge" node "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" logout --clear-all >/dev/null 2>&1 || fail "chatgpt logout --clear-all failed"
[[ ! -e "$logout_bridge/profile" ]] || fail "logout did not delete profile/"
[[ ! -e "$logout_bridge/chats.json" ]] || fail "logout --clear-all did not delete chats.json"
[[ ! -e "$logout_bridge/projects.json" ]] || fail "logout --clear-all did not delete projects.json"
[[ -f "$logout_bridge/.env" ]] || fail "logout deleted .env credentials"
if CODEX_WORK_CHATGPT_DIR="$logout_bridge" node "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" logout --bogus >/dev/null 2>&1; then
  fail "logout accepted an unknown option"
fi

if grep -Eqi 'approval|autoreview|merge|project' "$REPO_ROOT/gemini-web/gemini-consult.mjs"; then
    # Gemini must remain scraper-only, not workflow-coupled — check for approval handling specifically
    if grep -q "approval" "$REPO_ROOT/gemini-web/gemini-consult.mjs"; then
        fail "Gemini scraper contains workflow-only capabilities"
    fi
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

# Bridge .env loader unit tests (no browser needed)
REPO_ROOT="$REPO_ROOT" node --input-type=module <<'EOF'
import { strict as assert } from 'node:assert'
import { pathToFileURL } from 'node:url'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const mod = await import(pathToFileURL(`${process.env.REPO_ROOT}/chatgpt-web/bridge-env.mjs`))
assert.deepEqual(mod.parseDotEnv('A=val # c\nB="a # b" # d\nC=\'x#y\'\nexport D=e\n'), { A: 'val', B: 'a # b', C: 'x#y', D: 'e' })
assert.equal(mod.maskEmail('ab@example.com'), 'ab***@example.com')
assert.equal(mod.maskEmail(''), '(missing)')
assert.equal(mod.resolveBridgeDir('/dflt', 'CHATGPT_BRIDGE_DIR_TEST_XYZ'), '/dflt')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-env-test-'))
fs.writeFileSync(path.join(tmp, '.env'), 'CHATGPT_EMAIL=file@ex.com\nCHATGPT_PASSWORD=fp\n', { mode: 0o600 })
let c = mod.loadBridgeCreds({ bridgeDir: tmp, envFileVar: 'CHATGPT_ENV_FILE_TEST_XYZ', emailKeys: mod.CHATGPT_KEYS.emailKeys, passwordKeys: mod.CHATGPT_KEYS.passwordKeys })
assert.equal(c.email, 'file@ex.com')
assert.equal(c.configured, true)
fs.rmSync(tmp, { recursive: true, force: true })
EOF

# login --auto with missing creds must fail fast with .env help (no browser)
env_missing="$TEST_ROOT/env-missing"
mkdir -p "$env_missing/bridge"
if CODEX_WORK_CHATGPT_DIR="$env_missing/bridge" CHATGPT_ENV_FILE="$env_missing/nope.env" \
    node "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" login --auto >/tmp/chatgpt-auto-missing.log 2>&1; then
    fail "chatgpt login --auto with missing creds should exit non-zero"
fi
grep -q "\.env" /tmp/chatgpt-auto-missing.log || fail "chatgpt login --auto missing-creds help has no .env hint"
if CODEX_WORK_GEMINI_DIR="$env_missing/bridge" GEMINI_ENV_FILE="$env_missing/nope.env" \
    node "$REPO_ROOT/gemini-web/gemini-consult.mjs" login --auto >/tmp/gemini-auto-missing.log 2>&1; then
    fail "gemini login --auto with missing creds should exit non-zero"
fi
grep -q "\.env" /tmp/gemini-auto-missing.log || fail "gemini login --auto missing-creds help has no .env hint"

# status must report envConfigured without leaking secrets
env_status="$TEST_ROOT/env-status"
mkdir -p "$env_status/cbridge" "$env_status/gbridge"
printf 'CHATGPT_EMAIL=a@ex.com\nCHATGPT_PASSWORD=supersecret123\n' > "$env_status/cbridge/.env"
chmod 600 "$env_status/cbridge/.env"
chatgpt_status="$(CODEX_WORK_CHATGPT_DIR="$env_status/cbridge" node "$REPO_ROOT/chatgpt-web/chatgpt-consult.mjs" status 2>/dev/null)"
echo "$chatgpt_status" | grep -q '"envConfigured": *true' || fail "chatgpt status should report envConfigured:true"
echo "$chatgpt_status" | grep -q "supersecret123" && fail "chatgpt status leaked password"
printf 'GEMINI_EMAIL=g@ex.com\n' > "$env_status/gbridge/.env"
chmod 600 "$env_status/gbridge/.env"
gemini_status="$(CODEX_WORK_GEMINI_DIR="$env_status/gbridge" node "$REPO_ROOT/gemini-web/gemini-consult.mjs" status 2>/dev/null)"
echo "$gemini_status" | grep -q '"envConfigured": *false' || fail "gemini status should report envConfigured:false when password missing"
echo "$gemini_status" | grep -q '"envFileExists": *true' || fail "gemini status should report envFileExists:true"

# install must create 0600 .env templates and never overwrite real creds
install_home="$TEST_ROOT/install-home"
mkdir -p "$install_home"
HOME="$install_home" CODEX_WORK_BIN_DIR="$install_home/bin" CODEX_WORK_CHATGPT_DIR="$install_home/bridge/chatgpt" CODEX_WORK_SKIP_NPM_INSTALL=1 bash "$REPO_ROOT/install-chatgpt-web.sh" >/dev/null 2>&1 || fail "install-chatgpt-web.sh failed"
[[ -f "$install_home/bridge/chatgpt/.env" ]] || fail "chatgpt .env not created by install"
[[ "$(stat -c '%a' "$install_home/bridge/chatgpt/.env")" == 600 ]] || fail "chatgpt .env not 0600"
[[ -f "$install_home/bridge/chatgpt/bridge-env.mjs" ]] || fail "bridge-env.mjs not installed (chatgpt)"
[[ -f "$install_home/bridge/chatgpt/chatgpt-auth-flow.mjs" ]] || fail "chatgpt-auth-flow.mjs not installed (chatgpt)"
[[ -f "$install_home/bridge/chatgpt/chatgpt-consult.mjs" ]] || fail "chatgpt-consult.mjs not installed (chatgpt)"
HOME="$install_home" CODEX_WORK_BIN_DIR="$install_home/bin" CODEX_WORK_GEMINI_DIR="$install_home/bridge/gemini" CODEX_WORK_SKIP_NPM_INSTALL=1 bash "$REPO_ROOT/install-gemini-web.sh" >/dev/null 2>&1 || fail "install-gemini-web.sh failed"
[[ -f "$install_home/bridge/gemini/.env" ]] || fail "gemini .env not created by install"
[[ "$(stat -c '%a' "$install_home/bridge/gemini/.env")" == 600 ]] || fail "gemini .env not 0600"
printf 'CHATGPT_EMAIL=real@ex.com\nCHATGPT_PASSWORD=realpass\n' > "$install_home/bridge/chatgpt/.env"
HOME="$install_home" CODEX_WORK_BIN_DIR="$install_home/bin" CODEX_WORK_CHATGPT_DIR="$install_home/bridge/chatgpt" CODEX_WORK_SKIP_NPM_INSTALL=1 bash "$REPO_ROOT/install-chatgpt-web.sh" >/dev/null 2>&1 || fail "install-chatgpt-web.sh rerun failed"
grep -q "real@ex.com" "$install_home/bridge/chatgpt/.env" || fail "install overwrote existing chatgpt .env"

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
