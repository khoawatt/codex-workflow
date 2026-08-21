# Cấu hình project

Config runtime nằm tại:

```text
~/.config/codex-work/projects.conf
```

Mỗi dòng có đúng ba trường, phân cách bằng `|`:

```text
name|git_url|checkout_path
```

Ví dụ thêm project mới:

```text
api|git@github.com:your-team/api.git|~/projects/team/api
web|https://github.com/your-team/web.git|~/projects/team/web
```

Quy tắc:

- `name` chỉ dùng chữ, số, `.`, `_`, `-`;
- `git_url` dùng khi `install.sh` clone project còn thiếu;
- `checkout_path` phải là đường dẫn tuyệt đối hoặc bắt đầu bằng `~/`;
- dòng trống và dòng bắt đầu bằng `#` được bỏ qua;
- thứ tự dòng là thứ tự pane; launcher dùng layout `tiled` nên hỗ trợ từ một
  project trở lên.

Sau khi sửa config:

```bash
bash /path/to/codex-workflow/install.sh  # clone project mới nếu cần
codex-work --reset
```

Bạn có thể dùng config/session khác mà không sửa script:

```bash
CODEX_WORK_CONFIG=/path/to/team.conf CODEX_WORK_SESSION=team-work codex-work
```

Không đưa credential vào URL. Với private repo, dùng SSH agent hoặc Git credential
manager đã cấu hình trên máy.
