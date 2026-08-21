# Setup máy mới / onboarding team

## 1. Cài prerequisites

Trên Ubuntu/WSL:

```bash
sudo apt update
sudo apt install -y git tmux
```

Cài Codex CLI bằng standalone installer chính thức của OpenAI:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Mở một project directory rồi chạy `codex`. Lần đầu, chọn **Sign in with
ChatGPT** (hoặc phương thức đăng nhập khác đang được cung cấp), sau đó kiểm tra:

```bash
codex --version
codex login status
```

Tham khảo: [Official Codex CLI documentation](https://developers.openai.com/codex/cli/).

Không copy token, thư mục auth hoặc state Codex từ máy cũ vào repo này.

## 2. Clone và cài workspace

```bash
mkdir -p ~/projects/personal
cd ~/projects/personal
git clone https://github.com/Akbi47/codex-workflow.git
cd codex-workflow
bash install.sh
```

Nếu chỉ muốn cài launcher/config mà chưa clone project:

```bash
bash install.sh --no-clone
```

Nếu installer báo `~/.local/bin` chưa nằm trong `PATH`, thêm dòng được in ra vào
`~/.bashrc`, rồi chạy `source ~/.bashrc`.

## 3. Kiểm tra

```bash
command -v codex-work
bash -n ~/.local/bin/codex-work
codex-work --status
codex-work
```

Trong terminal khác:

```bash
tmux list-panes -t codex-work -F '#{pane_index}|#{pane_current_path}|#{pane_current_command}|#{pane_active}'
```

Kỳ vọng: mỗi dòng config có đúng một pane, đúng checkout path và command đang là
`codex` (hoặc process con của Codex).

## 4. Bàn giao cho agent

Sau khi clone repo, có thể giao prompt sau:

```text
Đọc AGENTS.md và docs/ trong repo này. Cài codex-work trên máy hiện tại,
không ghi đè config/project đã có, rồi chạy toàn bộ verification checklist.
Không copy hoặc in credential.
```
