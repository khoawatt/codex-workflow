#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$REPO_ROOT/gemini-web"
BIN_DIR="${CODEX_WORK_BIN_DIR:-$HOME/.local/bin}"
BRIDGE_DIR="${CODEX_WORK_GEMINI_DIR:-$HOME/.config/codex-work/gemini-web}"

command -v node >/dev/null 2>&1 || { printf 'install-gemini-web.sh: Node.js is required.\n' >&2; exit 1; }

install_local_browser_libraries() {
    command -v apt-get >/dev/null 2>&1 || return 0
    command -v dpkg-deb >/dev/null 2>&1 || return 0

    local chromium_bin missing packages temp_dir archive
    # Probe chromium binary: try playwright ESM, then cache scan (mirrors opencode-workflow)
    chromium_bin="$(node -e "
      const { existsSync, readdirSync } = require('fs');
      const { join } = require('path');
      const os = require('os');
      try {
        import('$BRIDGE_DIR/node_modules/playwright/index.mjs').then(m => {
          if (m.chromium && m.chromium.executablePath) {
            const p = m.chromium.executablePath();
            if (p && existsSync(p)) { process.stdout.write(p); process.exit(0); }
          }
          throw new Error('no ESM path');
        }).catch(() => {
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
        sudo apt-get install -y --no-install-recommends libnspr4 libnss3 libasound2 >/dev/null 2>&1 && return 0 || true
    fi

    echo "No passwordless sudo. Downloading .deb packages into $BRIDGE_DIR/libs (user-space)." >&2
    temp_dir="$(mktemp -d)"
    if ! (
        cd "$temp_dir"
        apt-get download $packages >/dev/null
        for archive in ./*.deb; do dpkg-deb -x "$archive" extracted; done
        install -d -m 0700 "$BRIDGE_DIR/libs"
        while IFS= read -r library; do
            install -m 0644 "$(readlink -f -- "$library")" "$BRIDGE_DIR/libs/$(basename -- "$library")"
        done < <(find extracted \( -type f -o -type l \) \( -name 'libnspr4.so' -o -name 'libnss*.so' \
            -o -name 'libplc4.so' -o -name 'libplds4.so' -o -name 'libsmime3.so' -o -name 'libssl3.so' \
            -o -name 'libsoftokn3.so' -o -name 'libfreebl*.so' -o -name 'libasound.so.*' \))
    ); then
        rm -rf -- "$temp_dir"
        return 1
    fi
    rm -rf -- "$temp_dir"
}

install -d -m 0700 "$BRIDGE_DIR" "$BRIDGE_DIR/profile"
install -d "$BIN_DIR"
install -m 0755 "$SOURCE_DIR/gemini-consult" "$BIN_DIR/gemini-consult"
install -m 0755 "$SOURCE_DIR/gemini-consult.mjs" "$BRIDGE_DIR/gemini-consult.mjs"
install -m 0644 "$SOURCE_DIR/session-auth.mjs" "$BRIDGE_DIR/session-auth.mjs"
install -m 0644 "$SOURCE_DIR/package.json" "$BRIDGE_DIR/package.json"
install -m 0644 "$SOURCE_DIR/package-lock.json" "$BRIDGE_DIR/package-lock.json"

if [[ -e "$BRIDGE_DIR/bridge-config.json" ]]; then
    printf 'Kept existing Gemini bridge config: %s\n' "$BRIDGE_DIR/bridge-config.json"
else
    install -m 0600 "$SOURCE_DIR/bridge-config.json" "$BRIDGE_DIR/bridge-config.json"
fi

if [[ "${CODEX_WORK_SKIP_NPM_INSTALL:-0}" != 1 ]]; then
    command -v npm >/dev/null 2>&1 || { printf 'install-gemini-web.sh: npm is required.\n' >&2; exit 1; }
    npm ci --omit=dev --no-audit --no-fund --prefix "$BRIDGE_DIR"
    npm exec --prefix "$BRIDGE_DIR" -- playwright install chromium
    install_local_browser_libraries
fi

printf 'Installed Gemini scraper: %s/gemini-consult\n' "$BIN_DIR"
printf 'Next: gemini-consult login, then gemini-consult status.\n'
