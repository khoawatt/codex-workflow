# Image generation via ChatGPT Web — Codex port

The canonical lifecycle is maintained in
`workflow-playbooks/docs/ai-agents/chatgpt-review-image-generation-playbook.md`.
Resolve that repository through `$WORKFLOW_PLAYBOOKS_DIR` when set, otherwise
use the sibling checkout `../workflow-playbooks`. Read the canonical playbook
before generating, recovering, reviewing, or publishing an image. Do not copy
its state model or retry rules into this port.

## Codex-specific adapter

- Use `chatgpt-consult status`; continue only when it reports
  `"loggedIn": true`.
- Codex bridge state lives under `~/.config/codex-work/chatgpt-web/`. Never
  commit its profile, `.env`, lock, conversation state, cookies, or signed URLs.
- The bridge accepts prompts on stdin. Use a generous task-appropriate timeout,
  but treat timeout only as an unobserved text completion—not as generation
  failure.
- Preserve the single-profile lock. Do not start a second Chromium instance
  against the same active profile, delete a live Chromium singleton lock, or
  use broad process-kill commands.
- Capture the ChatGPT conversation ID as the durable generation identifier as
  soon as it is observable. If the bridge exits before returning text, inspect
  its saved conversation state and reconcile that conversation before any new
  submission.
- For ChatGPT Web recovery mechanics, follow the provider adapter section in
  the canonical playbook: reopen the exact conversation, account for DOM
  hydration/lazy loading, deduplicate candidates, and fetch the original through
  the authenticated browser context.

Temporary Codex artifacts may live under `/tmp/img-out/` until accepted. Final
paths, formats, dimensions, transformations, review requirements, and publish
authorization come from the active task or repository—not from this port.

## Required handoff

Report the canonical lifecycle state, durable generation ID, audit path,
original/canonical paths, review status, and any separately authorized publish
and production-verification status.

Bridge setup and authentication remain documented in
[`CHATGPT_WEB.md`](CHATGPT_WEB.md) and [`AUTO_LOGIN.md`](AUTO_LOGIN.md).
