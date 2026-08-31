# Codex review workflow

Workflow mở rộng ChatGPT Web từ kênh tư vấn thành reviewer có output máy đọc
được, nhưng không trao quyền quyết định cho AI.

```text
IMPLEMENTING -> IMPLEMENTATION_COMPLETE -> CHATGPT_REVIEW
  -> request-changes -> FIXES -> RE-REVIEW
  -> approve -> HUMAN_ACTION_REQUIRED
```

Review prompt là envelope có cấu trúc (không dump hội thoại), phải nêu:

```text
GOAL: <mục tiêu tổng thể>
CURRENT_STAGE: IMPLEMENTING | IMPLEMENTATION_COMPLETE | CHATGPT_REVIEW | FIXES | APPROVED
TASK_SUMMARY: <một dòng>
RESULT_TEXT: <verbatim summary "Done / What changed / Verification">
REQUESTED_DECISION: <yêu cầu ChatGPT quyết định gì>
NEXT_ACTION_IF_APPROVED / NEXT_ACTION_IF_CHANGES_REQUESTED
REPO / BRANCH / HEAD_SHA / PR / BASE
AUTHORITY: ChatGPT=review; Codex=implement; Human=merge/deploy
```

Không gửi raw diff hoặc secret. Response contract là:

```text
VERDICT: approve | approve-with-changes | request-changes | reject
NEXT_ACTION: <one explicit action>
ISSUES: <numbered actionable issues, or "none">
SUGGESTIONS: <optional>
```

Semantics: `approve` — không còn việc chặn; `approve-with-changes` — chỉ cleanup không chặn; `request-changes` — phải sửa rồi re-review; `reject` — cần replan.

Chỉ lưu verdict parse được bằng `chatgpt-consult approval set <verdict> <sha> <pr>`. Approval chỉ hợp
lệ cho đúng repository identity (`owner/repo` qua `gh remote`), branch, PR và full HEAD SHA 40 ký tự. Code, HEAD, base,
CI, scope hoặc security state đổi thì phải review lại. Trước khi review, chạy `chatgpt-consult approval get` — nếu `approve` và HEAD SHA bằng recorded và không có đổi chất thì không review lại, báo “awaiting human merge”.

Workflow approval là local advisory artifact. Nó không thay GitHub review
approval, CODEOWNERS, branch protection, repository ruleset hoặc phán đoán của
maintainer. Merge wrapper là safety gate cho một yêu cầu merge đã được con người
cho phép, không phải hệ thống tự động cấp quyền merge.

## Cài policy theo project

```bash
bash install-project.sh /path/to/repo
```

Installer không overwrite file hiện có. Nó nối managed block vào `AGENTS.md` và
cài `.codex/scripts/merge-approved-pr.sh` nếu path đó chưa tồn tại.

## Merge wrapper

Wrapper kiểm tra fail-closed: đúng một open same-repo PR, PR mergeable, local
HEAD bằng remote PR HEAD, recorded verdict là `approve` cho đúng repo/PR/SHA và
mọi required check là `SUCCESS`; sau đó refresh PR ngay trước merge bằng
`--match-head-commit`.

Việc cài wrapper không merge gì. Chỉ con người được phép yêu cầu và chủ động chạy:

```bash
.codex/scripts/merge-approved-pr.sh
```

Không agent nào được diễn giải approval của ChatGPT thành quyền tự chạy wrapper.
