# Contributing to Codex Workflow (codex-workflow)

Thank you for your interest in contributing to `codex-workflow`! This project provides a portable tmux launcher and browser bridges (ChatGPT Plus / Gemini Web) for Codex CLI.

---

## Code of Conduct

Please be respectful and constructive when reporting issues, discussing proposals, or reviewing PRs. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

## Development Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/khoawatt/codex-workflow.git
   cd codex-workflow
   ```

2. **Install launcher locally**:
   ```bash
   bash install.sh
   codex-work --status
   ```

3. **Verify tests pass**:
   ```bash
   bash tests/test.sh
   bash -n bin/codex-work install.sh install-project.sh install-chatgpt-web.sh install-gemini-web.sh
   ```

4. **(Optional) Enable ChatGPT/Gemini bridge**:
   ```bash
   bash install-chatgpt-web.sh && chatgpt-consult login
   bash install-gemini-web.sh && gemini-consult login
   ```

---

## Pull Request Guidelines

1. **Keep it focused**: One bugfix or feature per PR.
2. **Backward compatibility**: Ensure `codex-work`, `chatgpt-consult`, `gemini-consult` and tmux layouts are not broken.
3. **Safe permissions**: Browser profiles under `~/.config/codex-work/` must remain `0700`/`0600`; never commit `profile/`, `chats.json`, or auth state.
4. **No secrets**: Never commit tokens, cookies, `.env`, or tmux pane output.
5. **Test before pushing**: `bash tests/test.sh` must pass.

---

## Security

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

---

## Author & Maintainer

* **Quách Võ Anh Khoa** ([@khoawatt](https://github.com/khoawatt)) — Author & Lead Maintainer
* **Audition MLD** ([@audition-mld](https://github.com/audition-mld)) — Contributor
