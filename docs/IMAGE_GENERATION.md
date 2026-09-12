# Gen ảnh qua ChatGPT Web (chạy nền)

Quy trình chuẩn khi user yêu cầu `gen ảnh` / `tạo ảnh` / `vẽ ảnh` (1 hoặc nhiều
ảnh cùng lúc): đưa prompt + mô tả ảnh cho `chatgpt-consult`, chạy nền vì gen
lâu, đợi hoàn tất rồi tải ảnh về và lưu vào nơi hợp lý. Playbook canonical
dùng chung với opencode nằm tại
`/home/audition/projects/personal/workflow-playbooks/docs/ai-agents/chatgpt-review-image-generation-playbook.md`;
trang này là bản port sang lệnh và state dir của codex-workflow.

## Khi nào dùng

- User gửi mô tả ảnh (prompt, phong cách, tỉ lệ, số lượng).
- Cần gen batch nhiều ảnh trong một lần — pattern chuẩn: **1 prompt → N ảnh**
  trong một lần `ask`, không bắn N lần `ask` song song.
- Task gen dự kiến lâu (vài phút), không muốn block session Codex chính.

## Điều kiện

- Bridge đã login: `chatgpt-consult status` phải có `"loggedIn": true`. Nếu
  `false` thì `chatgpt-consult login` (manual, xử được 2FA/CAPTCHA) hoặc fill
  `~/.config/codex-work/chatgpt-web/.env` (`CHATGPT_EMAIL`/`CHATGPT_PASSWORD`,
  `chmod 600`) rồi `chatgpt-consult login --auto`. Chi tiết xem
  [`docs/CHATGPT_WEB.md`](CHATGPT_WEB.md) và [`docs/AUTO_LOGIN.md`](AUTO_LOGIN.md).
- Browser chạy headful mặc định (headless dễ bị Cloudflare chặn); server
  headless cần virtual display.
- Thư mục temp `/tmp` (khuyên dùng `/tmp/img-out/`) writable.
- Giới hạn bridge: **single Chromium profile + serialize qua một lock duy nhất**
  (`~/.config/codex-work/chatgpt-web/.lock`, stale auto-clear). Hai lần `ask`
  đồng thời sẽ xếp hàng, nên batch N ảnh luôn gộp vào một prompt.

## Workflow

### 1. Chuẩn bị prompt file (1 prompt → N ảnh)

Viết prompt vào file để `ask --file` đọc, đánh số từng ảnh:

```bash
mkdir -p /tmp/img-out
cat > /tmp/img-out/img-prompt.txt <<'EOF'
Tạo 3 ảnh minh họa cho landing page khóa học:
- Ảnh 1: hero banner 16:9, phong cách flat, robot thân thiện + chữ "Học AI từ số 0", nền sáng.
- Ảnh 2: square 1:1, icon-style, biểu đồ tăng trưởng trên laptop.
- Ảnh 3: portrait 3:4, chân dung giáo viên nữ đang giảng bài, ánh sáng studio.
Trả về từng ảnh riêng biệt, giữ đúng thứ tự 1→3, không gộp chung vào một ảnh.
EOF
cat /tmp/img-out/img-prompt.txt
```

Luôn ghi số lượng + tỉ lệ (`16:9`/`1:1`/`3:4`) + phong cách + nội dung chính mỗi
ảnh. Với 1 ảnh vẫn dùng file để dễ log lại.

### 2. Kiểm tra bridge trước khi gen

```bash
chatgpt-consult status
# phải có "loggedIn": true

cd <repo-hien-tai> && chatgpt-consult chats
# xem key repo+branch hiện tại, tránh nhầm thread
```

`loggedIn: false` → dừng, hướng dẫn login lại, không gen. Muốn thread mới sạch
cho batch ảnh: thêm `--new` ở lệnh `ask`.

### 3. Chạy gen nền (`nohup … &` + poll)

```bash
LOG=/tmp/img-out/img-gen-$(date +%Y%m%d-%H%M%S).log

nohup chatgpt-consult ask --file /tmp/img-out/img-prompt.txt > "$LOG" 2>&1 &
echo $! > /tmp/img-out/img-gen.pid

echo "PID: $(cat /tmp/img-out/img-gen.pid)"
echo "LOG: $LOG"
tail -n 20 "$LOG"
```

Poll đợi hoàn tất (làm việc khác trong lúc chờ):

```bash
PID=$(cat /tmp/img-out/img-gen.pid)
LOG=$(ls -t /tmp/img-out/img-gen-*.log | head -n1)

if kill -0 "$PID" 2>/dev/null; then echo "RUNNING pid=$PID"; else echo "DONE pid=$PID"; fi
tail -n 40 "$LOG"

for i in $(seq 1 30); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 30
  echo "--- poll $i --- $(date -u +%H:%M:%S)"
  tail -n 5 "$LOG"
done
```

Không bắn batch thứ hai khi batch đầu còn `RUNNING`. Không xóa `.lock` thủ công
trừ khi PID đã chết mà lock còn.

### 4. Lấy ảnh về, lưu tùy ngữ cảnh

Lấy URL/file ảnh từ output `ask` trong log rồi `curl` về. Quy ước lưu:

| Ngữ cảnh repo | Nơi lưu đề xuất | Ví dụ |
|---|---|---|
| Web app | `assets/generated/<yyyy-mm-dd>/` hoặc `public/images/generated/` | `assets/generated/2026-09-12/hero-01.png` |
| Docs repo | `docs/assets/<topic>/` | `docs/assets/landing/hero-01.png` |
| Task tạm / chưa chốt | `/tmp/img-out/` rồi `move` khi chốt | `/tmp/img-out/batch-01/` |
| QA evidence | cùng folder evidence của task | `docs/qa/<task-id>/` |

```bash
mkdir -p "assets/generated/$(date +%F)"
curl -L "<IMAGE_URL_1>" -o "assets/generated/$(date +%F)/img-01.png"
ls -lh "assets/generated/$(date +%F)/"
```

Tên file `lowercase-kebab-case.png/jpg`, gắn số thứ tự khớp prompt. Không commit
profile, `chats.json`, `.lock`, `.env` của bridge.

### 5. Verify ảnh trước khi bàn giao

- `ls -lh` nơi đích: đủ N file, mỗi file > 50KB, đúng tên/số thứ tự.
- Mở từng ảnh kiểm tra khớp mô tả, đúng tỉ lệ, không lỗi chữ/mặt/tay. Ảnh nào
  sai thì gen bù riêng bằng prompt lẻ, không gen lại cả batch.

## Troubleshooting

| Hiện tượng | Nguyên nhân | Cách xử |
|---|---|---|
| `status` báo `"loggedIn": false` | Session hết hạn / chưa login | `chatgpt-consult login` (manual) hoặc `login --auto` khi `.env` đã cấu hình; check lại `status` |
| `ask` treo lâu, log không ra | Run khác giữ `.lock` / Cloudflare chặn headless | Đợi run trước xong; server headless dùng virtual display; không xóa lock khi PID còn sống |
| Batch thiếu ảnh (xin 3, về 2) | Prompt gộp ảnh, model gộp/sót | Đánh số `Ảnh 1/2/3`, yêu cầu "trả từng ảnh riêng, đúng thứ tự"; gen bù ảnh thiếu bằng prompt lẻ |
| Ảnh sai tỉ lệ / style | Prompt thiếu tỉ lệ/phong cách | Bổ sung `16:9/1:1` + style + negative ("không gộp chung") rồi gen lại ảnh đó |
| File tải về < 50KB, là HTML login | URL hết hạn / cần auth | Mở lại thread (`chats`), lấy URL mới từ output `ask`; không commit URL signed vào git |
| Muốn N prompt song song cho nhanh | Bridge single-profile serialize | Không làm vậy; luôn **1 prompt → N ảnh** trong một `ask` |

## References

- Playbook canonical (dùng chung opencode + codex):
  `/home/audition/projects/personal/workflow-playbooks/docs/ai-agents/chatgpt-review-image-generation-playbook.md`
- Bridge và login: [`docs/CHATGPT_WEB.md`](CHATGPT_WEB.md),
  [`docs/AUTO_LOGIN.md`](AUTO_LOGIN.md)
- Review workflow và approval: [`docs/WORKFLOW.md`](WORKFLOW.md)
