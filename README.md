# Codex Workflow

Launcher tmux portable để mở nhiều project song song, mỗi pane chạy một Codex CLI.
Repo này tách danh sách project khỏi script nên khi đổi máy hoặc team có project
mới, chỉ cần clone, cài và sửa một file config.

## Cài nhanh trên máy mới

Yêu cầu: Linux/WSL, Bash, Git, tmux và Codex CLI đã đăng nhập.

```bash
git clone https://github.com/Akbi47/codex-workflow.git
cd codex-workflow
bash install.sh
codex-work
```

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
```

Trong tmux: `Ctrl+b d` để detach, `Ctrl+b` rồi phím mũi tên để đổi pane,
`Ctrl+b z` để zoom pane.

## Tài liệu

- [`docs/SETUP.md`](docs/SETUP.md): onboarding máy mới từ đầu.
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md): thêm, bỏ hoặc đổi project.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md): lỗi thường gặp và rollback.
- [`AGENTS.md`](AGENTS.md): runbook cho AI agent tự cài và xác minh môi trường.

## An toàn

Repo không lưu token, Codex session, SSH key hay cấu hình đăng nhập. Config local
được giữ ở `~/.config/codex-work/`. `--reset` chỉ kill tmux session tên
`codex-work`, không kill tmux server hoặc các session khác.
