# Troubleshooting và rollback

| Hiện tượng | Cách xử lý |
|---|---|
| `Config not found` | Chạy lại `bash install.sh` hoặc đặt `CODEX_WORK_CONFIG`. |
| `Project ... is missing` | Chạy `bash install.sh` để clone, hoặc sửa checkout path. |
| Session không khớp config | Chạy `codex-work --reset`. |
| `codex-work: command not found` | Thêm `~/.local/bin` vào `PATH`, rồi mở shell mới. |
| Đang ở trong tmux | Launcher dùng `switch-client`, không tạo tmux lồng nhau. |
| Private repo clone thất bại | Cấu hình SSH/Git credential; không lưu token trong config. |

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
