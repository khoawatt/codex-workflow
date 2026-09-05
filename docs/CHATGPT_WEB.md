# ChatGPT Web collaborator

Integration này dùng Playwright điều khiển một Chromium profile riêng để Codex
trao đổi với ChatGPT Web. Đây là kênh tư vấn độc lập, không phải quyền phê duyệt:
Codex vẫn chịu trách nhiệm kiểm tra kết quả; merge, deploy và thao tác phá hủy vẫn
cần chủ dự án quyết định.

## Cài đặt

Yêu cầu: Linux/WSL có Node.js, npm và display để mở Chromium.

```bash
bash install-chatgpt-web.sh
# Pick ONE login style — manual (handles 2FA/CAPTCHA) or --auto from .env (no typing):
chatgpt-consult login                    # đăng nhập thủ công 1 lần (xử lý được 2FA)
# ...hoặc tự động từ .env (không gõ tay):
# fill ~/.config/codex-work/chatgpt-web/.env (CHATGPT_EMAIL/CHATGPT_PASSWORD, chmod 600)
chatgpt-consult login --auto
chatgpt-consult status          # → {"profileExists":true,"loggedIn":true,"envConfigured":true}
# Đổi tài khoản:
chatgpt-consult login --switch              # giữ browser mở, đợi token đổi
chatgpt-consult login --wait=30             # sau khi login mới, giữ mở 30s để verify
```

LOGIN OPTIONS:
```text
--auto / --from-env / --env   Đăng nhập tự động từ .env (không gõ tay)
--switch              Giữ browser mở để đổi account (đợi session token đổi; không tự đóng nếu đã login).
--wait=SECONDS        Sau khi phát hiện login mới, giữ browser mở thêm SECONDS (default 0; implies --switch).
--keep-open / --stay-open   Alias cho --switch.
--timeout=SECONDS     Max seconds chờ auto-login (default 150)
--headless / --headful       Browser visibility (default headful)
```

`ask` tự retry `.env` login khi session hết hạn (unless `--no-auto-login`). Xem `docs/AUTO_LOGIN.md`.

Installer thực hiện:

- cài lệnh vào `~/.local/bin/chatgpt-consult`;
- cài code/dependency và giữ state tại
  `~/.config/codex-work/chatgpt-web/`;
- trên Ubuntu/WSL thiếu browser libraries, tải các gói `.deb` cần thiết và chỉ
  extract shared libraries vào bridge, không dùng `sudo` hay cài system-wide;
- giữ config có sẵn, không chạm profile OpenCode cũ;
- backup rồi thêm một managed block vào `~/.codex/AGENTS.md` nếu block chưa có.

Restart Codex sau khi cài. Theo
[OpenAI Docs về AGENTS.md](https://developers.openai.com/codex/guides/agents-md),
Codex đọc global instructions từ `~/.codex/AGENTS.md` khi bắt đầu một run/session;
`AGENTS.override.md` có độ ưu tiên cao hơn và làm file thường bị bỏ qua.

## Sử dụng

Bridge nhận prompt trên stdin để shell không phải nhét nội dung task vào argv:

```bash
chatgpt-consult status
printf '%s\n' 'GOAL: ...; EVIDENCE: ...; REQUESTED_DECISION: ...' |
  chatgpt-consult ask
chatgpt-consult reset
chatgpt-consult chats
```

`ask --new` tạo hội thoại mới. `ask --timeout=600` đổi timeout. Mặc định browser
hiện ra vì headless dễ bị Cloudflare chặn; `--headless` chỉ nên dùng khi môi
trường đã được kiểm chứng.

Mỗi repo + branch dùng một thread riêng (`identity:branch` qua `gh remote`, fallback `basename:branch`). Bridge tự tạo thread mới khi vượt
giới hạn tuổi, số lượt hoặc số ký tự trong `bridge-config.json` (`max_chars`/`max_turns`/`max_age_hours`). Một lock duy
nhất (`~/.config/codex-work/chatgpt-web/.lock` với PID check, stale auto-clear, `Atomics.wait`) bảo vệ profile khỏi hai Chromium ghi đồng thời.

`ask --file=PATH` đọc prompt từ file đã được kiểm tra an toàn. `ask` dùng direct `fetch('/backend-api/gizmos/snorlax/sidebar?owned_only...')` với `credentials:include` trước, fallback mới capture `response` event (3 lần thử: in-flight → goto → reload) nên không miss request. Tạo Project tự mở sidebar nếu đang collapsed (`stage-slideover-sidebar[data-state]`), poll input 15×500ms để đợi dialog animate.

ChatGPT Projects là experimental và tắt mặc định:

```bash
chatgpt-consult project list
chatgpt-consult project create my-project
chatgpt-consult project attach my-project
chatgpt-consult project resolve
printf '%s\n' '...' | chatgpt-consult ask --project
```

Nếu UI Projects hoặc identity không xác minh được, bridge fail và không gửi
prompt thay vì đoán thao tác.

## Review workflow

```bash
chatgpt-autoreview on|off|status
chatgpt-consult approval get
chatgpt-consult approval set approve <full-40-char-head-sha> <pr-or-none>
chatgpt-consult approval clear
```

Approval gắn với repository, branch, full HEAD SHA, PR và thời điểm review. Nó
chỉ dùng chống review loop, không phải quyền merge. Sau thay đổi HEAD, base, CI,
scope hoặc security state phải review lại. Session Codex đã chạy trước khi
managed block được cập nhật cần restart.

## Dữ liệu và an toàn

Không gửi qua bridge:

- credential, token, cookie, key, auth state hoặc `.env`;
- raw diff, toàn bộ source tree hoặc transcript đầy đủ;
- pane tmux, dữ liệu cá nhân hoặc nội dung proprietary không cần thiết.

Nên gửi goal, constraints, lỗi đã rút gọn, bằng chứng liên quan và câu hỏi quyết
định. Bridge chỉ in câu trả lời ChatGPT ra stdout; `status` chỉ báo profile có tồn
tại và trạng thái login, không in cookie. Profile browser vẫn là auth state nhạy
cảm: không copy, commit hoặc chia sẻ thư mục runtime.

Nếu bridge lỗi, Codex phải báo đúng lỗi và chỉ tiếp tục khi an toàn. Không được
coi lỗi/timeout là một lần review thành công.

## Verification

```bash
bash -n chatgpt-web/chatgpt-consult chatgpt-web/chatgpt-autoreview install-chatgpt-web.sh
node --check chatgpt-web/chatgpt-consult.mjs
bash tests/test.sh
command -v chatgpt-consult
chatgpt-consult status
chatgpt-autoreview status
```

## Rollback

Đầu tiên thoát mọi `chatgpt-consult` đang chạy. Sau đó:

1. Xóa đúng block giữa hai marker `codex-work:chatgpt-web:start` và
   `codex-work:chatgpt-web:end` khỏi `~/.codex/AGENTS.md`, hoặc phục hồi file
   backup mà installer đã ghi đường dẫn.
2. Xóa `~/.local/bin/chatgpt-consult`.
3. Nếu muốn xóa cả login/chat state, backup nếu cần rồi xóa riêng
   `~/.config/codex-work/chatgpt-web/`.

Restart Codex sau rollback. Không xóa `~/.codex/` hoặc toàn bộ
`~/.config/codex-work/` vì các thư mục đó có thể chứa state không liên quan.
