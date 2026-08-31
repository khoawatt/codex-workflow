# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| main    | ✅        |

## Reporting a Vulnerability

If you discover a security vulnerability in `codex-workflow`:

1. **Do not** open a public GitHub issue.
2. Contact the maintainer via GitHub (@khoawatt) or open a private security advisory at `https://github.com/khoawatt/codex-workflow/security/advisories/new`.
3. Include a description, reproduction steps, and potential impact.

We will acknowledge receipt within 48 hours and provide a fix or mitigation timeline.

## Secrets Handling

This repository deliberately contains **no secrets**. Browser profiles (`~/.config/codex-work/chatgpt-web/profile/`, `gemini-web/profile/`), `chats.json`, and any token files are gitignored and must never be committed. If you accidentally commit a secret, rotate it immediately and notify the maintainer.
