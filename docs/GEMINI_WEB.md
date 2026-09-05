# Gemini Web scraper

`gemini-consult` dùng Playwright và Chromium profile riêng để gửi prompt đã
sanitize lên Gemini Web rồi lấy text response. Đây chỉ là scraper/consult bridge:
không structured verdict, approval state, auto-review, Projects hoặc merge.

## Cài và dùng

```bash
bash install-gemini-web.sh
# Manual (handles 2FA/consent):
gemini-consult login
# ...hoặc tự động từ .env:
# fill ~/.config/codex-work/gemini-web/.env (GEMINI_EMAIL/GEMINI_PASSWORD, chmod 600)
gemini-consult login --auto
gemini-consult status  # → {"profileExists":true,"loggedIn":true,"envConfigured":true}
printf '%s\n' 'REQUEST: ...' | gemini-consult ask  # ask auto-retry .env login unless --no-auto-login
gemini-consult reset
```

`status` phân biệt account login với guest access. Gemini có thể cho guest thấy
composer và gửi câu hỏi, nhưng khi chưa có account identity thật kết quả vẫn là:

```json
{"profileExists":true,"loggedIn":false,"guestAvailable":true}
```

`login` chỉ xác nhận sau khi browser quay về đúng `gemini.google.com` và liên tục
hiển thị cả account identity lẫn composer ổn định. Google Auth form,
`accounts.google.com`, composer hoặc Google cookie đơn lẻ không được xem là bằng
chứng đăng nhập. Sign-in link chỉ cần tồn tại trong DOM là tín hiệu logged-out;
sau mỗi navigation, shell phải ổn định tối thiểu 5 giây trước khi bắt đầu xác nhận.

`ask` hỗ trợ `--new`, `--headless`, `--timeout=SECONDS` và `--file=PATH`. Mỗi
repo+branch reuse một Gemini conversation cho đến khi vượt ngưỡng trong
`~/.config/codex-work/gemini-web/bridge-config.json`.

Runtime state nằm dưới `~/.config/codex-work/gemini-web/`. Không copy hoặc commit
browser profile. Không gửi credential, cookie, `.env`, private key, raw diff,
transcript đầy đủ hoặc dữ liệu proprietary không cần thiết.

Gemini Web UI không có contract ổn định. Nếu prompt, send button hoặc response
selector không xác minh được, bridge fail rõ ràng và không click phần tử ngẫu nhiên.

## Verification và rollback

```bash
bash -n gemini-web/gemini-consult install-gemini-web.sh
node --check gemini-web/gemini-consult.mjs
gemini-consult status
```

Rollback: thoát mọi `gemini-consult`, xóa riêng `~/.local/bin/gemini-consult`;
nếu muốn xóa login state thì backup rồi xóa riêng
`~/.config/codex-work/gemini-web/`. Không xóa toàn bộ config `codex-work`.
