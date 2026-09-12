# Codex Workflow

Launcher tmux portable để mở nhiều project song song, mỗi pane chạy một Codex CLI.
Repo này tách danh sách project khỏi script nên khi đổi máy hoặc team có project
mới, chỉ cần clone, cài và sửa một file config.

Repo cũng có integration tùy chọn để Codex trao đổi với ChatGPT Web qua một
browser Playwright cục bộ khi bắt đầu task/vấn đề quan trọng, khi bị chặn, và để
review kết quả của task có thay đổi code. Workflow hỗ trợ verdict có cấu trúc,
approval gắn repo/branch/HEAD/PR, auto-review opt-in và merge guard do con người
chủ động gọi. Gemini Web được tích hợp riêng ở mức scraper/consult cơ bản, không
tham gia approval hoặc workflow.

## Cài nhanh trên máy mới

Yêu cầu: Linux/WSL, Bash, Git, tmux và Codex CLI đã đăng nhập.

```bash
git clone https://github.com/khoawatt/codex-workflow.git
cd codex-workflow
bash install.sh
codex-work
```

## Bật trao đổi với ChatGPT Web

```bash
bash install-chatgpt-web.sh
chatgpt-consult login
```

Lệnh `login` mở Chromium để bạn tự đăng nhập một lần. Sau đó đóng và mở lại
Codex để `~/.codex/AGENTS.md` được nạp. Kiểm tra bằng:

```bash
chatgpt-consult status
printf '%s\n' 'GOAL: kiểm tra bridge; REQUEST: trả lời OK' | chatgpt-consult ask
chatgpt-autoreview on
```

Profile trình duyệt, mapping hội thoại và config nằm ở
`~/.config/codex-work/chatgpt-web/`, không nằm trong Git. Xem hướng dẫn, giới
hạn dữ liệu và rollback tại [`docs/CHATGPT_WEB.md`](docs/CHATGPT_WEB.md).

## Bật Gemini Web scraper

```bash
bash install-gemini-web.sh
gemini-consult login
gemini-consult status
printf '%s\n' 'REQUEST: tóm tắt chủ đề này' | gemini-consult ask
```

Gemini dùng browser profile và conversation mapping riêng. Xem
[`docs/GEMINI_WEB.md`](docs/GEMINI_WEB.md).

`install.sh` sẽ:

- cài launcher vào `~/.local/bin/codex-work`;
- tạo `~/.config/codex-work/projects.conf` nếu chưa có;
- clone các project còn thiếu theo config;
- không ghi đè config hoặc project đã tồn tại.

Mặc định config mở hai repo:

- `~/projects/personal/Feaon-ldp-v2`
- `~/projects/personal/qvak-portfolio`

## Lệnh thường dùng

```bash
codex-work             # tạo session hoặc attach session đang chạy
codex-work --status    # xem config, project và pane hiện tại
codex-work --reset     # chỉ dựng lại session codex-work
chatgpt-consult chats
chatgpt-consult approval get
chatgpt-consult project resolve  # experimental, opt-in
chatgpt-autoreview on|off|status
```

Trong tmux: `Ctrl+b d` để detach, `Ctrl+b` rồi phím mũi tên để đổi pane,
`Ctrl+b z` để zoom pane.

Với đúng hai project, hai pane được chia đều 50–50 theo chiều trái/phải. Số
project khác dùng layout `tiled`.

## Tài liệu

- [`docs/SETUP.md`](docs/SETUP.md): onboarding máy mới từ đầu.
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md): thêm, bỏ hoặc đổi project.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md): lỗi thường gặp và rollback.
- [`docs/CHATGPT_WEB.md`](docs/CHATGPT_WEB.md): browser bridge và auto-consult.
- [`docs/IMAGE_GENERATION.md`](docs/IMAGE_GENERATION.md): gen 1–N ảnh qua ChatGPT Web, chạy nền.
- [`docs/WORKFLOW.md`](docs/WORKFLOW.md): verdict, approval, project installer và merge guard.
- [`docs/GEMINI_WEB.md`](docs/GEMINI_WEB.md): Gemini scraper-only bridge.
- [`AGENTS.md`](AGENTS.md): runbook cho AI agent tự cài và xác minh môi trường.

## An toàn

Repo không lưu token, Codex session, SSH key hay cấu hình đăng nhập. Config local
được giữ ở `~/.config/codex-work/`. `--reset` chỉ kill tmux session tên
`codex-work`, không kill tmux server hoặc các session khác.

Bridge ChatGPT Web không dùng API key và không in cookie. Nó điều khiển profile
Chromium riêng đã đăng nhập; chỉ gửi nội dung prompt mà Codex chuẩn bị. Không dùng
bridge cho secret, `.env`, auth state, raw diff, transcript đầy đủ hay pane tmux.
Approval ChatGPT chỉ là bằng chứng review cho đúng SHA/PR, không phải quyền merge.

---

## Đóng góp (Contributing)

Mọi đóng góp đều được hoan nghênh. Vui lòng xem [CONTRIBUTING.md](CONTRIBUTING.md) và [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) trước khi tạo pull request.

---

## Tác giả & Contributors

* **Quách Võ Anh Khoa** ([@khoawatt](https://github.com/khoawatt)) — Author & Maintainer
* **Audition MLD** ([@audition-mld](https://github.com/audition-mld)) — Contributor

---

## Giấy phép (License)

Dự án được phân phối dưới giấy phép **MIT License**. Xem chi tiết tại [LICENSE](LICENSE).
