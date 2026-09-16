# DeepSeek Harness Docker Sandbox

Hướng dẫn **build / máy khác / bật-tắt tính năng**: [BUILD.md](BUILD.md).

Image: `dsh-runtime:1.2.1` (local) hoặc `vietvqworkspace/dsh-web:1.2.1` (Hub).

Môi trường Docker dành cho chạy DeepSeek Harness với các mục tiêu:

* DeepSeek Harness chạy bên trong container.
* Source DeepSeek Harness được mount từ máy host.
* Toàn bộ cấu hình, credentials, session và state được lưu trong `./data`.
* Workspace/project mà agent thao tác được mount riêng tại `./workspace`.
* Container DeepSeek Harness không được kết nối Internet trực tiếp.
* Chỉ cho phép outbound tới các domain được khai báo trong allowlist.
* Telemetry của DeepSeek Harness được hard-disable.
* Không mount Docker socket hoặc filesystem nhạy cảm của máy host.

---

# 1. Architecture

```text
                       HOST
────────────────────────────────────────────────

 ./deepseek-harness/
         │
         │ read-only
         ▼
 ┌─────────────────────────────────────┐
 │       DeepSeek Harness              │
 │                                     │
 │ /source/dsh   <- Harness source RO  │
 │ /runtime/dsh  <- runtime/build      │
 │ /data         <- config/state       │
 │ /workspace    <- project source RW  │
 │                                     │
 │ Telemetry: OFF                      │
 │ Direct Internet: BLOCKED            │
 └────────────────┬────────────────────┘
                  │
          Docker internal network
                  │
                  ▼
 ┌─────────────────────────────────────┐
 │          Egress Proxy               │
 │                                     │
 │ allow-domains.txt                   │
 │                                     │
 │ api.deepseek.com       ✓            │
 │ github.com             ✓            │
 │ registry.npmjs.org     ✓            │
 │ google.com             ✗            │
 │ unknown-domain.com     ✗            │
 └────────────────┬────────────────────┘
                  │
                  ▼
              Internet
```

DeepSeek Harness không nằm trên Docker network có Internet.

Chỉ container `egress-proxy` có quyền truy cập Internet.

---

# 2. Directory Structure

```text
dsh-docker/
│
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh
│
├── deepseek-harness/
│   └── ...
│
├── data/
│   ├── .env
│   ├── .credentials.yaml
│   ├── settings.yaml
│   ├── AGENTS.md
│   └── profiles/
│
├── workspace/
│   └── ...
│
└── proxy/
    ├── squid.conf
    └── allow-domains.txt
```

Ý nghĩa:

```text
deepseek-harness/
```

Source code DeepSeek Harness được clone từ GitHub.

```text
data/
```

Lưu toàn bộ cấu hình và state persistent của Harness.

```text
workspace/
```

Source project mà AI Agent được phép đọc/sửa.

```text
proxy/
```

Cấu hình outbound network.

---

# 3. Clone DeepSeek Harness

Clone source:

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness
```

Tạo các thư mục còn lại:

```bash
mkdir -p data
mkdir -p workspace
mkdir -p proxy
```

Sau đó cấu trúc tối thiểu:

```text
dsh-docker/
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh
├── deepseek-harness/
├── data/
├── workspace/
└── proxy/
```

---

# 4. DeepSeek Harness Home

Container sử dụng:

```bash
DSH_HOME=/data
```

DeepSeek Harness sẽ dùng `/data` làm Harness Home.

Ví dụ:

```text
/data/settings.yaml
/data/.credentials.yaml
/data/.env
/data/AGENTS.md
/data/profiles/
```

Do `/data` được mount từ:

```text
./data
```

nên restart hoặc recreate container không làm mất cấu hình.

Ví dụ:

```yaml
volumes:
  - ./data:/data
```

---

# 5. Disable Telemetry

Đây là cấu hình quan trọng khi chạy với source nội bộ.

Trong `docker-compose.yml`:

```yaml
environment:
  DSH_TELEMETRY_DISABLED: "1"
```

Nên cấu hình thêm:

```yaml
environment:
  DSH_TELEMETRY_DISABLED: "1"
  DSH_TELEMETRY_MODE: "DISABLED"
```

Cấu hình đề xuất:

```yaml
environment:
  DSH_HOME: /data

  DSH_TELEMETRY_DISABLED: "1"
  DSH_TELEMETRY_MODE: "DISABLED"
```

`DSH_TELEMETRY_DISABLED` là hard opt-out.

Chỉ cần biến này tồn tại với giá trị không rỗng thì telemetry sẽ bị disable.

Ví dụ tất cả các giá trị sau đều disable telemetry:

```bash
DSH_TELEMETRY_DISABLED=1
```

```bash
DSH_TELEMETRY_DISABLED=true
```

```bash
DSH_TELEMETRY_DISABLED=false
```

```bash
DSH_TELEMETRY_DISABLED=0
```

Vì Harness kiểm tra sự tồn tại của giá trị không rỗng.

Khuyến nghị dùng rõ ràng:

```bash
DSH_TELEMETRY_DISABLED=1
```

---

# 6. Verify Telemetry Configuration

Sau khi container chạy:

```bash
docker compose exec dsh env | grep DSH_TELEMETRY
```

Kết quả mong muốn:

```text
DSH_TELEMETRY_DISABLED=1
DSH_TELEMETRY_MODE=DISABLED
```

Có thể kiểm tra riêng:

```bash
docker compose exec dsh printenv DSH_TELEMETRY_DISABLED
```

Expected:

```text
1
```

và:

```bash
docker compose exec dsh printenv DSH_TELEMETRY_MODE
```

Expected:

```text
DISABLED
```

Sau khi thay đổi telemetry configuration nên restart Harness:

```bash
docker compose restart dsh
```

---

# 7. Additional Telemetry Protection

Ngoài việc:

```bash
DSH_TELEMETRY_DISABLED=1
```

kiến trúc này còn chặn ở network layer.

Không thêm telemetry endpoint vào:

```text
proxy/allow-domains.txt
```

Ví dụ KHÔNG thêm:

```text
harness-telemetry.deepseeksvc.com
```

Như vậy có hai lớp bảo vệ:

```text
Layer 1
DSH_TELEMETRY_DISABLED=1

             +

Layer 2
Network allowlist không cho telemetry endpoint ra Internet
```

Ngay cả khi Harness configuration vô tình bật telemetry sau này, network layer vẫn block connection tới telemetry endpoint nếu domain đó không nằm trong allowlist.

---

# 8. Configure Credentials

Có thể đặt credentials tại:

```text
data/.credentials.yaml
```

Ví dụ:

```yaml
DEEPSEEK_API_KEY: <your-key>
```

Không commit file này vào Git.

Thêm vào `.gitignore`:

```gitignore
data/.credentials.yaml
data/.env
```

Nếu dùng LLM local thì có thể không cần DeepSeek API key.

---

# 9. Environment Configuration

Có thể dùng:

```text
data/.env
```

Ví dụ:

```env
DEEPSEEK_API_KEY=<your-key>
LLM_BASE_URL=http://local-llm:11434
LOG_LEVEL=info
```

Không nên đặt secret trực tiếp vào:

```yaml
docker-compose.yml
```

nếu repository được commit lên Git.

---

# 10. Workspace

Project cần cho agent xử lý đặt trong:

```text
./workspace
```

Container nhìn thấy tại:

```text
/workspace
```

Compose:

```yaml
volumes:
  - ./workspace:/workspace
```

Ví dụ:

```text
workspace/
└── payment-service/
    ├── pom.xml
    └── src/
```

Trong container:

```text
/workspace/payment-service
```

Agent có thể:

```bash
cd /workspace/payment-service

git status

grep -R "PaymentService" .

mvn test
```

và có thể sửa source nếu workspace được mount `rw`.

---

# 11. Mount DeepSeek Harness Source

Harness source được mount:

```yaml
volumes:
  - ./deepseek-harness:/source/dsh:ro
```

`ro` có nghĩa là read-only.

Container không được phép sửa:

```text
/source/dsh
```

Khi start, `entrypoint.sh` copy source sang:

```text
/runtime/dsh
```

rồi build/run ở đó.

Luồng:

```text
HOST

deepseek-harness/
      │
      │ mount read-only
      ▼
/source/dsh
      │
      │ rsync
      ▼
/runtime/dsh
      │
      ├── pnpm install
      ├── pnpm build
      │
      └── pnpm dsh web
```

Điều này tránh việc agent hoặc build process thay đổi source Harness trên host.

---

# 12. Update DeepSeek Harness

Update source trên host:

```bash
cd deepseek-harness
git pull
```

Sau đó:

```bash
docker compose restart dsh
```

Nếu dependency thay đổi lớn, nên rebuild:

```bash
docker compose down

docker compose build --no-cache

docker compose up -d
```

---

# 13. Configure Allowed Domains

File:

```text
proxy/allow-domains.txt
```

Ví dụ:

```text
api.deepseek.com
github.com
api.github.com
registry.npmjs.org
```

Chỉ những domain trong file này mới được proxy cho phép.

Ví dụ muốn thêm GitLab nội bộ:

```text
gitlab.company.local
```

Hoặc Redmine:

```text
redmine.company.local
```

Sau khi sửa:

```bash
docker compose restart egress-proxy
```

---

# 14. Test Allowed Domain

Vào container:

```bash
docker compose exec dsh bash
```

Test:

```bash
curl https://api.deepseek.com
```

Nếu domain được allow thì request có thể đi qua proxy.

---

# 15. Test Blocked Domain

Ví dụ:

```bash
curl https://google.com
```

Nếu `google.com` không nằm trong allowlist thì Squid phải trả về lỗi, thường là:

```text
403 Forbidden
```

---

# 16. Test Proxy Bypass

Đây là test quan trọng hơn.

Trong container chạy:

```bash
curl --noproxy "*" https://google.com
```

Request này phải fail.

Mục tiêu là:

```text
DSH
 │
 ├── direct Internet ─────── X
 │
 └── proxy ───────────────── ✓
          │
          └── allowlist
```

Nếu `curl --noproxy "*"` vẫn truy cập được Internet thì network isolation chưa đúng.

---

# 17. Check Docker Network

Kiểm tra:

```bash
docker network ls
```

Container DSH chỉ nên nằm trên internal network.

Có thể kiểm tra:

```bash
docker inspect deepseek-harness
```

DSH không nên trực tiếp join network:

```text
internet
```

Chỉ:

```text
sandbox
```

Trong khi proxy:

```text
sandbox
internet
```

---

# 18. Start

Hướng dẫn build/chạy (máy này, máy khác, bật/tắt tính năng): [BUILD.md](BUILD.md). Image `dsh-runtime:1.2.1` / `vietvqworkspace/dsh-web:1.2.1`.

Build:

```bash
docker compose build
```

Start:

```bash
docker compose up -d
```

Xem trạng thái:

```bash
docker compose ps
```

---

# 19. Logs

DeepSeek Harness:

```bash
docker compose logs -f dsh
```

Proxy:

```bash
docker compose logs -f egress-proxy
```

---

# 20. Open Web UI

Mặc định:

```text
http://localhost:3080
```

Port chỉ nên bind localhost:

```yaml
ports:
  - "127.0.0.1:3080:3080"
```

Không nên dùng:

```yaml
ports:
  - "3080:3080"
```

nếu không muốn các máy khác trong network truy cập Harness.

---

# 21. Stop

Stop container:

```bash
docker compose stop
```

Hoặc:

```bash
docker compose down
```

Dữ liệu trong:

```text
./data
```

và:

```text
./workspace
```

không bị xóa.

---

# 22. Rebuild

Nếu thay đổi:

```text
Dockerfile
entrypoint.sh
```

chạy:

```bash
docker compose down

docker compose build

docker compose up -d
```

---

# 23. Restart After Configuration Change

Nếu sửa Harness config:

```text
data/settings.yaml
data/.env
data/.credentials.yaml
```

có thể restart:

```bash
docker compose restart dsh
```

Một số settings của Harness có cơ chế watch/hot reload, tuy nhiên với security configuration nên restart để chắc chắn process mới nhận đúng environment.

---

# 24. Security Rules

Không mount Docker socket:

```text
/var/run/docker.sock
```

Không dùng:

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

Nếu agent có Docker socket, nó có thể tạo container khác và bypass security boundary.

Không mount:

```text
/
```

Không mount:

```text
/home
```

Không mount:

```text
~/.ssh
```

Không mount private SSH key.

Không mount Kubernetes credentials:

```text
~/.kube
```

Không mount cloud credentials như:

```text
~/.aws
~/.azure
~/.config/gcloud
```

trừ khi thực sự cần.

---

# 25. Recommended Container Security

Compose nên có:

```yaml
security_opt:
  - no-new-privileges:true

cap_drop:
  - ALL
```

Không sử dụng:

```yaml
privileged: true
```

Không thêm:

```yaml
network_mode: host
```

Không thêm capability không cần thiết.

---

# 26. Recommended Docker Compose Environment

Cấu hình DSH đề xuất:

```yaml
environment:
  DSH_HOME: /data

  # Hard disable telemetry
  DSH_TELEMETRY_DISABLED: "1"
  DSH_TELEMETRY_MODE: "DISABLED"

  # Outbound proxy
  HTTP_PROXY: http://egress-proxy:3128
  HTTPS_PROXY: http://egress-proxy:3128

  http_proxy: http://egress-proxy:3128
  https_proxy: http://egress-proxy:3128

  NO_PROXY: localhost,127.0.0.1,egress-proxy
  no_proxy: localhost,127.0.0.1,egress-proxy
```

---

# 27. Security Model

Security không dựa vào việc AI "tuân thủ prompt".

Security được enforce bởi Docker/network:

```text
Agent
  │
  │ command/tool
  ▼
DeepSeek Harness
  │
  ├──────── filesystem
  │
  │    /workspace       RW
  │    /data            RW
  │    /source/dsh      RO
  │
  └──────── network
           │
           ▼
       Squid Proxy
           │
           ▼
       Allowlist
           │
           ├── allowed domain     ✓
           └── other domain       X
```

Cho dù agent chạy:

```bash
curl
wget
node
python
maven
npm
git
```

thì network restriction vẫn nằm ở tầng Docker/network chứ không phụ thuộc vào agent.

---

# 28. Important Limitation: Domain vs URL Path

Squid có thể kiểm soát hostname:

```text
api.deepseek.com
```

nhưng với HTTPS thông thường nó không kiểm soát chính xác path bên trong request.

Ví dụ:

```text
https://api.deepseek.com/v1/chat/completions
```

và:

```text
https://api.deepseek.com/other-api
```

đều có hostname:

```text
api.deepseek.com
```

Nếu yêu cầu chỉ cho phép chính xác một số API endpoint/path thì nên thêm outbound API Gateway.

Ví dụ:

```text
DeepSeek Harness
       │
       ▼
Outbound Gateway
       │
       ├── POST /deepseek/chat       ✓
       ├── GET /gitlab/project       ✓
       │
       └── anything else             X
       │
       ▼
Internet / Internal APIs
```

Đây là kiến trúc nên dùng nếu hệ thống xử lý source code nội bộ có yêu cầu bảo mật cao.

---

# 29. Recommended Production Setup

Mô hình cuối cùng nên là:

```text
                        Host

                    DeepSeek Harness
                           │
         ┌─────────────────┼──────────────────┐
         │                 │                  │
         ▼                 ▼                  ▼

     /workspace           /data            /source/dsh

        RW                 RW                  RO


                           │
                           │
                           ▼

                    Internal Network
                           │
                           ▼
                    Egress Gateway
                           │
            ┌──────────────┼───────────────┐
            │              │               │
            ▼              ▼               ▼
          LLM            GitLab          Redmine
        Gateway            API             API
            │
            ▼
         Internet
```

Ưu tiên:

```text
DSH
 ↓
Internal LLM/API Gateway
 ↓
External provider
```

thay vì cho DSH gọi trực tiếp nhiều dịch vụ Internet.

---

# 30. Quick Commands

Start:

```bash
docker compose up -d
```

Build:

```bash
docker compose build
```

Logs:

```bash
docker compose logs -f dsh
```

Shell:

```bash
docker compose exec dsh bash
```

Restart DSH:

```bash
docker compose restart dsh
```

Restart proxy:

```bash
docker compose restart egress-proxy
```

Stop:

```bash
docker compose down
```

Check telemetry:

```bash
docker compose exec dsh env | grep DSH_TELEMETRY
```

Check direct Internet bypass:

```bash
docker compose exec dsh \
  curl --noproxy "*" https://google.com
```

Test allowlist:

```bash
docker compose exec dsh \
  curl https://api.deepseek.com
```

---

# 31. Recommended Telemetry Configuration

Luôn giữ:

```yaml
DSH_TELEMETRY_DISABLED: "1"
```

Và để configuration dễ audit:

```yaml
DSH_TELEMETRY_MODE: "DISABLED"
```

Tức là:

```yaml
environment:
  DSH_HOME: /data
  DSH_TELEMETRY_DISABLED: "1"
  DSH_TELEMETRY_MODE: "DISABLED"
```

Đồng thời KHÔNG whitelist:

```text
harness-telemetry.deepseeksvc.com
```

Khi đó telemetry được bảo vệ theo cả application layer và network layer.
