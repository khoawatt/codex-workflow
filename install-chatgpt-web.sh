#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$REPO_ROOT/chatgpt-web"
BIN_DIR="${CODEX_WORK_BIN_DIR:-$HOME/.local/bin}"
BRIDGE_DIR="${CODEX_WORK_CHATGPT_DIR:-$HOME/.config/codex-work/chatgpt-web}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
AGENTS_FILE="$CODEX_DIR/AGENTS.md"
OVERRIDE_FILE="$CODEX_DIR/AGENTS.override.md"
START_MARKER='<!-- codex-work:chatgpt-web:start -->'
END_MARKER='<!-- codex-work:chatgpt-web:end -->'

command -v node >/dev/null 2>&1 || {
    printf 'install-chatgpt-web.sh: Node.js is required.\n' >&2
    exit 1
}

install_local_browser_libraries() {
    command -v apt-get >/dev/null 2>&1 || return 0
    command -v dpkg-deb >/dev/null 2>&1 || return 0

    local chromium_bin missing packages temp_dir archive
    # Probe chromium binary: try playwright ESM, then CJS, then cache scan (mirrors opencode-workflow)
    chromium_bin="$(node -e "
      const { existsSync, readdirSync } = require('fs');
      const { join } = require('path');
      const os = require('os');
      try {
        // Try ESM import first
        import('$BRIDGE_DIR/node_modules/playwright/index.mjs').then(m => {
          if (m.chromium && m.chromium.executablePath) {
            const p = m.chromium.executablePath();
            if (p && existsSync(p)) { process.stdout.write(p); process.exit(0); }
          }
          throw new Error('no ESM path');
        }).catch(() => {
          // Fallback to cache scan
          const root = join(os.homedir(), '.cache', 'ms-playwright');
          try {
            const dirs = readdirSync(root).sort().reverse();
            for (const d of dirs) {
              if (!d.startsWith('chromium-')) continue;
              for (const c of [join(root,d,'chrome-linux64','chrome'), join(root,d,'chrome-linux','chrome')]) {
                if (existsSync(c)) { process.stdout.write(c); process.exit(0); }
              }
            }
          } catch {}
        });
      } catch {}
    " 2>/dev/null | head -n1 || true)"
    # Fallback: if node ESM probe produced no output, try CJS require
    if [[ -z "$chromium_bin" || ! -x "$chromium_bin" ]]; then
        chromium_bin="$(node -e "
          const { existsSync, readdirSync } = require('fs');
          const { join } = require('path');
          const os = require('os');
          const root = join(os.homedir(), '.cache', 'ms-playwright');
          try {
            const dirs = readdirSync(root).sort().reverse();
            for (const d of dirs) {
              if (!d.startsWith('chromium-')) continue;
              for (const c of [join(root,d,'chrome-linux64','chrome'), join(root,d,'chrome-linux','chrome')]) {
                if (existsSync(c)) { console.log(c); process.exit(0); }
              }
            }
          } catch {}
        " 2>/dev/null || true)"
    fi
    [[ -x "$chromium_bin" ]] || return 0
    missing="$(ldd "$chromium_bin" 2>/dev/null | awk '/not found/{print $1}')"
    [[ -n "$missing" ]] || return 0

    packages=''
    grep -Eq '^lib(nspr4|nss3|nssutil3)\.so' <<< "$missing" && packages='libnspr4 libnss3'
    if grep -Eq '^libasound\.so' <<< "$missing"; then
        if apt-cache show libasound2t64 >/dev/null 2>&1; then
            packages="$packages libasound2t64"
        else
            packages="$packages libasound2"
        fi
    fi
    [[ -n "${packages// /}" ]] || return 0

    # Try passwordless sudo first (mirrors opencode-workflow/install.sh)
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        echo "Installing missing libraries via apt (passwordless sudo available): $packages" >&2
        sudo apt-get update -y >/dev/null 2>&1 || true
        if sudo apt-get install -y --no-install-recommends $packages >/dev/null 2>&1; then
            return 0
        fi
        # fallback to libasound2 if t64 variant failed
        sudo apt-get install -y --no-install-recommends libnspr4 libnss3 libasound2 >/dev/null 2>&1 && return 0 || true
    fi

    echo "No passwordless sudo. Downloading .deb packages into $BRIDGE_DIR/libs (user-space)." >&2
    temp_dir="$(mktemp -d)"
    if ! (
        cd "$temp_dir"
        # Extract user-local shared libraries; do not mutate system packages.
        apt-get download $packages >/dev/null
        for archive in ./*.deb; do
            dpkg-deb -x "$archive" extracted
        done
        install -d -m 0700 "$BRIDGE_DIR/libs"
        while IFS= read -r library; do
            install -m 0644 "$(readlink -f -- "$library")" "$BRIDGE_DIR/libs/$(basename -- "$library")"
        done < <(find extracted \( -type f -o -type l \) \( -name 'libnspr4.so' -o -name 'libnss*.so' -o -name 'libplc4.so' \
            -o -name 'libplds4.so' -o -name 'libsmime3.so' -o -name 'libssl3.so' \
            -o -name 'libsoftokn3.so' -o -name 'libfreebl*.so' -o -name 'libasound.so.*' \))
    ); then
        rm -rf -- "$temp_dir"
        return 1
    fi
    rm -rf -- "$temp_dir"
}

install -d -m 0700 "$BRIDGE_DIR" "$BRIDGE_DIR/profile"
install -d "$BIN_DIR" "$CODEX_DIR"
install -m 0755 "$SOURCE_DIR/chatgpt-consult" "$BIN_DIR/chatgpt-consult"
install -m 0755 "$SOURCE_DIR/chatgpt-autoreview" "$BIN_DIR/chatgpt-autoreview"
install -m 0755 "$SOURCE_DIR/chatgpt-consult.mjs" "$BRIDGE_DIR/chatgpt-consult.mjs"
install -m 0644 "$SOURCE_DIR/bridge-env.mjs" "$BRIDGE_DIR/bridge-env.mjs"
install -m 0644 "$SOURCE_DIR/package.json" "$BRIDGE_DIR/package.json"
install -m 0644 "$SOURCE_DIR/package-lock.json" "$BRIDGE_DIR/package-lock.json"

if [[ -e "$BRIDGE_DIR/bridge-config.json" ]]; then
    printf 'Kept existing bridge config: %s\n' "$BRIDGE_DIR/bridge-config.json"
else
    install -m 0600 "$SOURCE_DIR/bridge-config.json" "$BRIDGE_DIR/bridge-config.json"
    printf 'Installed bridge config: %s\n' "$BRIDGE_DIR/bridge-config.json"
fi

# Per-bridge .env for auto-login (never overwrite real creds)
if [[ ! -f "$BRIDGE_DIR/.env" ]]; then
    printf '# ChatGPT auto-login (chmod 600, never commit)\n# See config/chatgpt-bridge.env.example for docs.\nCHATGPT_EMAIL=\nCHATGPT_PASSWORD=\n' > "$BRIDGE_DIR/.env"
    chmod 0600 "$BRIDGE_DIR/.env" 2>/dev/null || true
    printf 'Created %s/.env (fill CHATGPT_EMAIL/CHATGPT_PASSWORD, chmod 600) — or run manual login\n' "$BRIDGE_DIR"
else
    chmod 0600 "$BRIDGE_DIR/.env" 2>/dev/null || true
    printf 'Kept existing %s/.env\n' "$BRIDGE_DIR"
fi

if [[ "${CODEX_WORK_SKIP_NPM_INSTALL:-0}" != "1" ]]; then
    command -v npm >/dev/null 2>&1 || {
        printf 'install-chatgpt-web.sh: npm is required.\n' >&2
        exit 1
    }
    npm ci --omit=dev --no-audit --no-fund --prefix "$BRIDGE_DIR"
    npm exec --prefix "$BRIDGE_DIR" -- playwright install chromium
    install_local_browser_libraries
fi

has_start=0
has_end=0
if [[ -s "$AGENTS_FILE" ]]; then
    grep -Fq "$START_MARKER" "$AGENTS_FILE" && has_start=1
    grep -Fq "$END_MARKER" "$AGENTS_FILE" && has_end=1
fi
if [[ "$has_start" != "$has_end" ]]; then
    printf 'install-chatgpt-web.sh: incomplete managed block in %s; restore its backup or repair both markers first.\n' \
        "$AGENTS_FILE" >&2
    exit 1
fi

if [[ "$has_start" == "1" ]]; then
    backup="$(mktemp "$AGENTS_FILE.backup.$(date +%Y%m%d%H%M%S).XXXXXX")"
    cp -p -- "$AGENTS_FILE" "$backup"
    temp="$(mktemp "$CODEX_DIR/AGENTS.md.XXXXXX")"
    awk -v start="$START_MARKER" -v end="$END_MARKER" -v block="$SOURCE_DIR/codex-agents-block.md" '
        $0 == start {
            while ((getline line < block) > 0) print line
            close(block)
            skipping=1
            next
        }
        skipping && $0 == end { skipping=0; next }
        !skipping { print }
    ' "$AGENTS_FILE" > "$temp"
    chmod 0600 "$temp"
    mv -f -- "$temp" "$AGENTS_FILE"
    printf 'Updated managed ChatGPT Web instructions in %s (backup: %s)\n' "$AGENTS_FILE" "$backup"
else
    if [[ -e "$AGENTS_FILE" ]]; then
        backup="$(mktemp "$AGENTS_FILE.backup.$(date +%Y%m%d%H%M%S).XXXXXX")"
        cp -p -- "$AGENTS_FILE" "$backup"
        printf 'Backed up existing Codex instructions: %s\n' "$backup"
        printf '\n' >> "$AGENTS_FILE"
    fi
    cat "$SOURCE_DIR/codex-agents-block.md" >> "$AGENTS_FILE"
    chmod 0600 "$AGENTS_FILE"
    printf 'Installed global Codex instructions: %s\n' "$AGENTS_FILE"
fi

if [[ -s "$OVERRIDE_FILE" ]]; then
    printf 'Warning: %s exists, so Codex ignores %s. Add the managed block to the override or remove the override.\n' \
        "$OVERRIDE_FILE" "$AGENTS_FILE" >&2
fi

printf '\nInstalled command: %s/chatgpt-consult\n' "$BIN_DIR"
printf 'Next: chatgpt-consult login (--auto from .env) or chatgpt-consult login --auto; then chatgpt-consult status.\n'
printf '  Manual: chatgpt-consult login   | Auto: fill %s/.env (CHATGPT_EMAIL/PASSWORD) then chatgpt-consult login --auto\n' "$BRIDGE_DIR"
