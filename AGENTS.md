# AGENTS.md — codex-work setup runbook

This repository installs a local tmux launcher for one Codex CLI process per
configured project. When asked to set it up, read `README.md` and all files in
`docs/` before changing the machine.

## Installation contract

1. Inspect `~/.config/codex-work/projects.conf`, `~/.local/bin/codex-work`, the
   requested checkout paths, and any existing `codex-work` tmux session.
2. Run `bash install.sh`. Use `--no-clone` if the owner did not authorize cloning
   missing repositories.
3. Never overwrite an existing config or project directory.
4. Never copy, print or commit Codex auth state, GitHub tokens, SSH keys, `.env`
   files or tmux pane output.
5. Do not reset an existing tmux session unless the owner requested it or a
   config change requires rebuilding it. Explain that reset stops the Codex
   processes in that session.

## Verification checklist

```bash
bash -n bin/codex-work install.sh
bash tests/test.sh
command -v codex-work
codex-work --status
```

After the owner starts the workspace, verify without exposing pane contents:

```bash
tmux list-panes -t codex-work -F '#{pane_index}|#{pane_current_path}|#{pane_current_command}|#{pane_active}'
```

Expected: one pane per non-comment config entry and the exact configured paths.
