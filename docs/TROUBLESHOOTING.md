# Troubleshooting và rollback

| Hiện tượng | Cách xử lý |
|---|---|
| `Config not found` | Chạy lại `bash install.sh` hoặc đặt `CODEX_WORK_CONFIG`. |
| `Project ... is missing` | Chạy `bash install.sh` để clone, hoặc sửa checkout path. |
| Session không khớp config | Chạy `codex-work --reset`. |
| `codex-work: command not found` | Thêm `~/.local/bin` vào `PATH`, rồi mở shell mới. |
| Đang ở trong tmux | Launcher dùng `switch-client`, không tạo tmux lồng nhau. |
| Private repo clone thất bại | Cấu hình SSH/Git credential; không lưu token trong config. |
| `chatgpt-consult` báo chưa đăng nhập | Chạy `chatgpt-consult login` trong desktop/WSL có display. Nếu đã login rồi muốn đổi account: `chatgpt-consult logout` rồi `login`, hoặc `chatgpt-consult login --switch` (giữ browser mở, đợi token đổi; thêm `--wait=30` để giữ mở 30s). |
| `Oops, an error occurred / Route Error (400 Invalid content type)` khi login email | Bridge tự nhận diện transaction Auth0 stale/hỏng, xóa riêng OpenAI/Auth0 transaction cookies/storage rồi restart từ `chatgpt.com` (tối đa 3 lần); password submit được serialize, không tự bấm lại khi request trước chưa settle. Nếu vẫn lỗi: chạy `chatgpt-consult logout`, sau đó `chatgpt-consult login` |
| `login --auto` gặp mã xác minh / 2FA / CAPTCHA | `login --auto` giữ browser mở và chờ tối đa 20 phút để bạn nhập code/xác minh thủ công trong chính cửa sổ đó; sau khi session xuất hiện bridge tự tiếp tục và lưu profile. Auto-login phát sinh trong `ask` vẫn fail-fast thay vì chờ tương tác |
| Auto-TOTP báo secret không hợp lệ | Kiểm tra `CHATGPT_TOTP_SECRET` là base32 (A-Z, 2-7, không khoảng trắng lạ); log không bao giờ in secret |
| Auto-TOTP thất bại dù secret đúng | Đồng bộ giờ hệ thống (NTP/chrony) — mã TOTP chỉ sống 30s; bridge thử tối đa 2 mã rồi chờ nhập tay, không spam để tránh rate-limit |
| Đổi/lộ TOTP secret | Re-enroll 2FA trên OpenAI, cập nhật `.env`, `chmod 600`, chạy `login --auto` lại |
| `chatgpt-consult login` treo sau khi đóng window | Đã fix `browserClosed` detection — đóng window sẽ báo `Login verified (browser closed)` nếu có session, else `No session cookie`; nếu vẫn treo, kiểm tra `ps` và xóa `~/.config/codex-work/chatgpt-web/.lock` stale. |
| Bridge không tìm thấy prompt input | ChatGPT Web có thể đã đổi UI; cập nhật bridge, không coi lần consult là thành công. Thử `chatgpt-consult status` headful (mới port) để debug `url/title/loggedIn`. |
| Chromium báo thiếu `libnspr4.so`/`libnss3.so` | Chạy lại `bash install-chatgpt-web.sh`; installer extract browser libraries vào bridge mà không cần sudo (port thêm probe `chromium.executablePath()` + `ldd` + `sudo` fallback). |
| Codex không tự consult | Kiểm tra cảnh báo `AGENTS.override.md`, rồi restart Codex để nạp lại global instructions. |
| Bridge đang bị lock | Chờ lần consult hiện tại xong; lock của PID đã chết sẽ tự được dọn (`kill(pid,0)` + `Atomics.wait`). Kiểm tra `cat ~/.config/codex-work/chatgpt-web/.lock`. |
| Auto-review đổi trạng thái nhưng session cũ không làm theo | Cài lại managed block rồi restart Codex session đó. |
| Approval không khớp HEAD/PR/repo | Không merge; `chatgpt-consult approval get` so sánh `head_sha` 40-char + `pr` + repo case-insensitive, clear approval, review lại exact HEAD rồi `approval set approve <sha> <pr>`. |
| ChatGPT Project command lỗi / `could not fetch projects` | Đã fix direct `fetch` + 3 lần retry (in-flight → goto → reload); nếu vẫn lỗi, dùng plain `ask --no-project` và cập nhật selector sau. Kiểm tra `chatgpt-consult project list` headful. |
| Sidebar collapsed làm `create project` bấm hụt | Đã fix auto-expand `Open sidebar` + `data-state` check (dbg3 vs dbg4); nếu vẫn fail, mở sidebar tay rồi chạy lại. |
| `gemini-consult` chưa đăng nhập | Chạy `gemini-consult login` trong môi trường có display. |
| Gemini không tìm thấy prompt/send/response | Gemini Web đã đổi UI; không coi scrape thành công và cập nhật selector. |

## Kiểm tra session

```bash
codex-work --status
tmux ls
tmux list-panes -t codex-work -F '#{pane_id}|#{pane_current_path}|#{pane_current_command}'
```

## Rollback local

Detach trước nếu đang ở trong session, rồi:

```bash
tmux kill-session -t codex-work       # chỉ khi muốn dừng các Codex process trong workspace
rm ~/.local/bin/codex-work
```

Config local có thể giữ để cài lại. Nếu thật sự không cần nữa, tự backup rồi xóa
`~/.config/codex-work/`. Không dùng `tmux kill-server`: lệnh đó sẽ đóng cả các
session tmux không liên quan.

Rollback riêng ChatGPT Web được mô tả trong `docs/CHATGPT_WEB.md`; việc xóa
profile browser sẽ đăng xuất bridge và không ảnh hưởng Codex auth.
Rollback Gemini được mô tả trong `docs/GEMINI_WEB.md`.
