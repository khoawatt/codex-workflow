<!-- codex-work:chatgpt-web:start -->
## ChatGPT Web consultation

For every substantive task or problem, use `chatgpt-consult` as an advisory
second opinion. ChatGPT never grants authority to merge, deploy, or perform a
guarded mutation.

1. After inspecting enough local context to describe the request accurately,
   send one concise, sanitized task/problem envelope to `chatgpt-consult ask`
   on stdin. Include the goal, constraints, evidence, uncertainties, and the
   decision requested from ChatGPT Web.
2. Consult again only when genuinely blocked, when a material decision changes,
   or when new evidence invalidates the earlier advice. Avoid redundant loops.
3. Before a task that may change files, run `chatgpt-autoreview status`. When it
   reports `ON`, send the final result summary and verification results for an
   independent review before reporting completion. When it reports `OFF`, final
   review is manual unless another instruction requires it.
4. Before sending a final review, run `chatgpt-consult approval get` and compare
   any recorded `approve` with the exact current repository, branch, full HEAD
   SHA, and PR. Do not repeat review for unchanged approved state. Review again
   after any material change, new commit, rebase, newly failed CI, or scope change.
5. Request this exact response contract for implementation reviews:

   ```text
   VERDICT: approve | approve-with-changes | request-changes | reject
   NEXT_ACTION: <one explicit action>
   ISSUES: <numbered actionable issues, or "none">
   SUGGESTIONS: <optional>
   ```

   Record a parsed verdict with
   `chatgpt-consult approval set <verdict> <full-head-sha> <pr-or-none>`.
   Never record approval if the response cannot be parsed or the bridge failed.

Never send secrets, credentials, cookies, auth state, `.env` contents, private
keys, full transcripts, tmux pane contents, or raw diffs. Minimize proprietary
source and user data; prefer summaries and small necessary excerpts. ChatGPT is
advisory: Codex remains responsible for decisions and verification, and only the
human may authorize merges, deployments, destructive actions, or other guarded
mutations. For trivial self-contained requests, skip consultation. If the
bridge is unavailable, report that briefly and continue when safe; never claim
that a consultation succeeded when it did not.

Treat authentication status, command completion, and end-to-end consultation
success as separate results. A consultation succeeds only when the authenticated
`ask` completes without a bridge or execution error and returns non-empty,
usable advisory content. If creating the bridge lockfile fails with `EROFS`,
retry that single `chatgpt-consult` invocation once with the minimum native
execution required; do not grant, modify, or broaden persistent write access to
the browser profile or other browser state. Before changing or removing a lock,
verify that its recorded PID belongs to the relevant live bridge process; never
delete a lock merely because it blocks startup.
<!-- codex-work:chatgpt-web:end -->
