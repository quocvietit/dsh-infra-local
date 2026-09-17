# DeepSeek Harness — Docker sandbox

Môi trường chạy DSH trong Docker Desktop: **không Internet trực tiếp**, egress qua Squid allowlist, telemetry tắt.

**Build / mang sang máy khác / bật-tắt tính năng / Browser Use:** [BUILD.md](BUILD.md).

| Image | Khi nào |
|---|---|
| `dsh-runtime:1.2.1` | Build local (`docker compose build`) |
| `vietvqworkspace/dsh-web:1.2.1` | Máy khác pull Hub (đặt `DSH_IMAGE` trong `.env`) |

UI chỉ bind localhost: [http://127.0.0.1:3080](http://127.0.0.1:3080) — URL phải có `?token=` (xem log `dsh`).

---

## Kiến trúc (khớp `docker-compose.yml`)

```text
 HOST  127.0.0.1:3080
        │
        ▼
 ┌──────────────────┐     sandbox (internal)      ┌─────────────────────┐
 │  web-gateway     │ ──────────────────────────► │  dsh                │
 │  alpine/socat    │   TCP :3080 → :3081         │  /opt/dsh  (image)  │
 │  networks:       │                             │  /data     (bind)   │
 │   sandbox+frontend│                             │  /workspace (bind)  │
 └──────────────────┘                             │  Chromium headless  │
                                                  │  HTTP(S)_PROXY ──┐  │
                                                  └─────────────────┼──┘
                                                                    │
                                                                    ▼
                                                  ┌─────────────────────┐
                                                  │  egress-proxy       │
                                                  │  Squid :3128        │
                                                  │  sandbox + internet │
                                                  └──────────┬──────────┘
                                                             │ allowlist
                                                             ▼
                                                         Internet
```

- **dsh** chỉ nằm trên `sandbox` (`internal: true`) — không default route ra Internet.
- **web-gateway** nằm `sandbox` + `frontend` để publish `127.0.0.1:3080` (DSH không join `internet`).
- **egress-proxy** là hop duy nhất ra ngoài; domain trong `proxy/allow-domains.txt`.
- Runtime Harness nằm **trong image** `/opt/dsh`. Không mount `deepseek-harness` khi deploy (`DSH_SOURCE_OVERLAY=0`).
- Credential: `data/.credentials.yaml` trên bind mount `/data` (gitignore, mode 600). Entrypoint không xóa file khi restart.
- Browser Use: Chromium trong image; page traffic `--proxy-server` → Squid (xem BUILD.md).

Overlay source host chỉ khi dev: `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d`.

---

## Thư mục

```text
dsh-docker/
├── Dockerfile                 # nướng /opt/dsh + Chromium
├── docker-compose.yml         # prod: overlay=0
├── docker-compose.dev.yml     # overlay harness từ host
├── entrypoint.sh              # mount vào container (sửa không cần rebuild)
├── patch-runtime.mjs          # token UI + host-open
├── host-open.ps1              # mở file trên Windows
├── security-test.ps1
├── .env.example               # copy thành .env (không commit)
├── data/                      # DSH_HOME: profile, policy, skills
├── workspace/                 # mặc định bind → /workspace (đổi bằng DSH_WORKSPACE_HOST / override.yml)
├── docker-compose.override.example.yml  # thêm folder/ổ khác vào /workspace/...
├── proxy/                     # squid.conf + allow-domains.txt
└── deepseek-harness/          # chỉ cần trên máy BUILD
```

---

## Bảo mật (tóm tắt)

- Không mount Docker socket, `/`, `~/.ssh`, cloud credentials.
- `cap_drop: ALL`, `no-new-privileges`.
- Squid lọc **hostname**, không lọc path HTTPS.
- Không whitelist telemetry (`harness-telemetry.deepseeksvc.com`).
- `DSH_TELEMETRY_DISABLED=1` (mọi giá trị non-empty đều tắt).

Chi tiết thao tác: [BUILD.md](BUILD.md).
