<!-- codex-work:project-workflow:start -->
## Codex project workflow

The linked GitHub Issue, when present, is the scope authority. Before changing
files, inspect repository instructions and the working tree, preserve unrelated
changes, identify acceptance criteria, and state stop conditions for guarded or
production work.

Use `chatgpt-consult` only with concise sanitized summaries. Never send secrets,
raw diffs, authentication state, full transcripts, or unnecessary proprietary
source. For implementation review, require this response format:

```text
VERDICT: approve | approve-with-changes | request-changes | reject
NEXT_ACTION: <one explicit action>
ISSUES: <numbered actionable issues, or "none">
SUGGESTIONS: <optional>
```

An `approve` verdict is advisory and valid only for the recorded repository, PR,
branch, and exact HEAD SHA. It is invalid after code, HEAD, base, CI, scope, or
security state changes. It never authorizes merge, deployment, destructive
actions, or production mutations. Only the human maintainer may authorize those.
It does not replace GitHub review approvals, CODEOWNERS, branch protections,
repository rulesets, or maintainer judgment.

Run real verification and report failures or skipped checks truthfully. Never
merge automatically. The optional `.codex/scripts/merge-approved-pr.sh` may be
run only when the human explicitly requests that exact merge operation.
<!-- codex-work:project-workflow:end -->
