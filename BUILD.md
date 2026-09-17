# Build & chạy DSH Docker trên máy khác

Image local: `dsh-runtime:1.2.1`  
Image Hub: `vietvqworkspace/dsh-web:1.2.1`

UI: http://127.0.0.1:3080 — lấy URL có `?token=` từ `docker compose logs dsh`.

Không commit: `.env`, `data/.credentials.yaml`, `data/settings.yaml`, sessions, cache, `workspace/`.

Ba tài liệu cũ (`README.md` dài, `README_DSH_DEPLOY.md`) dễ lệch compose. **File này là nguồn sự thật** cho build/deploy.

---

## 1. Hai loại máy

| | Máy BUILD | Máy CHẠY (máy khác) |
|---|---|---|
| Cần `deepseek-harness/` | Có — `Dockerfile` COPY vào image | **Không** |
| Cần Docker Desktop | Có | Có |
| Node/pnpm trên host | Không (build trong Docker) | Không |
| Image | `docker compose build` → `dsh-runtime:1.2.1` | `docker pull` / `docker load` |
| `.env` `DSH_IMAGE` | `dsh-runtime:1.2.1` | tag Hub hoặc tag đã load |
| `DSH_SOURCE_OVERLAY` | `0` (prod) hoặc `1` + compose.dev | **luôn `0`** |
| Sửa path | `DSH_HOST_ROOT` / `DSH_HOST_PATH_MAP` | **bắt buộc** đổi sang ổ đĩa máy này |

Mang sang máy khác **không** cần: `deepseek-harness/`, `node_modules/`, `data/sessions/`, `data/cache/`.

Mang **có**: repo infra (`docker-compose.yml`, `Dockerfile` nếu sẽ build, `entrypoint.sh`, `data/profiles`, `proxy/`), file `.env` **mới**, image tar hoặc Hub.

---

## 2. Kiến trúc runtime

```text
Browser  →  127.0.0.1:3080
              web-gateway (socat, network frontend+sandbox)
                → deepseek-harness:3081
                    socat trong dsh → 127.0.0.1:3080 (process DSH)
```

| Service | Image | Network | Vai trò |
|---|---|---|---|
| `dsh` | `${DSH_IMAGE}` | **chỉ** `sandbox` (internal) | Harness + Chromium |
| `web-gateway` | `alpine/socat` | sandbox + frontend | Publish UI localhost |
| `egress-proxy` | `ubuntu/squid` | sandbox + **internet** | Allowlist HTTPS |

Mọi `HTTP_PROXY`/`HTTPS_PROXY` của DSH (và Chrome launch) trỏ `http://egress-proxy:3128`.  
`NO_PROXY=localhost,127.0.0.1,egress-proxy`.

Harness trong container: `/opt/dsh` (nướng lúc build). Entrypoint host được **bind-mount** nên sửa `entrypoint.sh` rồi `restart` là đủ, không rebuild.

---

## 3. Máy khác — không build (pull / load image)

Cần Docker Desktop. Clone **repo infra** (không clone harness).

```powershell
git clone <repo-infra> dsh-docker
cd dsh-docker
Copy-Item .env.example .env
New-Item -ItemType Directory -Force workspace | Out-Null
```

Sửa `.env` (Windows: dùng `/`, đúng ổ máy này):

```env
DSH_IMAGE=vietvqworkspace/dsh-web:1.2.1
DSH_HOST_ROOT=D:/path/tren/may-nay/dsh-docker
DSH_SOURCE_OVERLAY=0
```

Code **không** nằm trong `./workspace` — xem mục 3.1.

```powershell
docker pull vietvqworkspace/dsh-web:1.2.1
docker pull alpine/socat:latest
docker pull ubuntu/squid:latest
docker compose up -d --pull never
docker compose logs dsh | Select-String "dsh web:"
```

Mở đúng URL in ra (có token). Hard-refresh trình duyệt nếu UI cũ.

### 3.1 Workspace trên ổ/thư mục khác

Agent chỉ thấy path **trong container** (`/workspace/...`). Bind mount quyết định folder Windows.

**Cả `/workspace` trỏ sang ổ khác** — `.env`:

```env
DSH_WORKSPACE_HOST=E:/code
DSH_HOST_PATH_MAP=/workspace=E:/code;/data=D:/path/tren/may-nay/dsh-docker/data
```

`DSH_HOST_PATH_MAP` có thể bỏ nếu chỉ đổi workspace: compose mặc định `/workspace=${DSH_WORKSPACE_HOST}` và `/data=${DSH_HOST_ROOT}/data`.

**Thêm thư mục** (ổ D + ổ E, repo rời) — copy `docker-compose.override.example.yml` → `docker-compose.override.yml`:

```yaml
services:
  dsh:
    volumes:
      - E:/code/app:/workspace/app
      - D:/libs/shared:/workspace/shared
```

Kèm PATH_MAP (prefix dài hơn thắng khi Open on host):

```env
DSH_HOST_PATH_MAP=/workspace=D:/path/dsh-docker/workspace;/workspace/app=E:/code/app;/workspace/shared=D:/libs/shared;/data=D:/path/dsh-docker/data
```

Policy `pathAllowPrefixes: /workspace` đã cover mọi mount dưới `/workspace/...`.

Docker Desktop phải **share** ổ đó. Không mount `/`, `C:/Users/.../.ssh`, cloud keys. Sau khi sửa: `docker compose up -d` (không chỉ `restart`).

Hoặc copy tar từ máy đã build:

```powershell
# máy nguồn
docker save dsh-runtime:1.2.1 alpine/socat:latest ubuntu/squid:latest -o dsh-stack.tar

# máy đích
docker load -i dsh-stack.tar
# trong .env: DSH_IMAGE=dsh-runtime:1.2.1
docker compose up -d --pull never
```

Nút **Open configuration file** trên Windows (để chạy song song với compose):

```powershell
.\host-open.ps1
```

API key: Settings trong UI, hoặc copy file vào volume (mục Credential). Không commit key.

Kiểm tra isolation:

```powershell
.\security-test.ps1
```

---

## 4. Máy BUILD — nướng image từ source

Cần: Docker, Git. Fork harness (đã patch Browser Use / Chromium Dockerfile) nằm cạnh compose:

```text
dsh-docker/
  Dockerfile
  docker-compose.yml
  deepseek-harness/    # clone fork, checkout nhánh đúng
  data/
  proxy/
```

`.dockerignore` bỏ `node_modules` harness — `pnpm install` chạy **trong** builder.

Lần đầu / sau khi đổi Dockerfile (Chromium) / đổi source harness:

```powershell
git clone <fork-harness> deepseek-harness
# checkout nhánh đã patch

$env:DSH_COMMIT_HASH = (git -C .\deepseek-harness rev-parse --short HEAD)
$env:DSH_IMAGE = "dsh-runtime:1.2.1"
Copy-Item .env.example .env   # nếu chưa có; sửa DSH_HOST_*
docker compose build
docker compose up -d
```

Build stage: `pnpm install --frozen-lockfile` + `pnpm run build` trong image. Runtime cài **Chromium** tại `/usr/bin/chromium` (Browser Use).

Đẩy Hub:

```powershell
docker tag dsh-runtime:1.2.1 vietvqworkspace/dsh-web:1.2.1
docker push vietvqworkspace/dsh-web:1.2.1
```

Sửa harness **không** rebuild image (dev):

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

(`DSH_SOURCE_OVERLAY=1`, mount `./deepseek-harness` RO → `/source/dsh`). Máy deploy **không** dùng overlay.

---

## 5. Browser Use (Chrome DevTools MCP)

Đã bật trong `data/profiles/web/cordis.patch.yml`:

- `@deepseek-ai/dsh-browser-use`
- `@deepseek-ai/dsh-experimental-browser-use-chrome-devtools-mcp`
- `mode: launch`, `headless: true`, `executablePath: /usr/bin/chromium`

Provider (trong image) thêm: `--no-usage-statistics`, `--no-performance-crux`, `--proxy-server` từ env, `--no-sandbox` / `--disable-dev-shm-usage`.

**Dùng:** tạo **session chat mới** (session cũ không nhận plugin). Nhờ agent bằng ngôn ngữ tự nhiên, ví dụ:

```text
Mở <URL nội bộ>, login nếu cần, reproduce lỗi.
Liệt kê console error và network requests, lấy requestId.
Chụp screenshot. Không dùng performance_* hay lighthouse_audit.
```

Không có cửa sổ Chrome (headless). Mỗi session một browser; login không giữ sang session khác.

**Máy khác:** image phải được **build sau** khi Dockerfile có Chromium. Image Hub/tar cũ sẽ fail `executablePath`.

Domain web agent mở phải nằm trong `proxy/allow-domains.txt` (trừ localhost). Restart proxy sau khi sửa:

```powershell
docker compose restart egress-proxy
```

Không liệt kê `mcp__chrome-devtools-mcp__*` trong `toolOrder`.

---

## 6. Bật / tắt tính năng

Restart sau khi sửa profile: `docker compose restart dsh`.

### `.env`

| Biến | Deploy máy khác |
|---|---|
| `DSH_IMAGE` | tag Hub hoặc tag `docker load` |
| `DSH_HOST_ROOT` / `DSH_WORKSPACE_HOST` / `DSH_HOST_PATH_MAP` | path máy này; extra bind → override.yml |
| `DSH_SOURCE_OVERLAY` | `0` |
| `DSH_COMMIT_HASH` | chỉ khi `compose build` |

### `data/profiles/web/cordis.patch.yml`

Ghi đè row cùng `id` của bundle. `package.json` profile do DSH tạo lúc chạy (gitignore) — **đừng copy** `node_modules` profile từ máy cũ.

| Row `id` | Mặc định |
|---|---|
| `llm-deepseek` | tắt Official adapter |
| `web-search-deepseek` | tắt |
| `tool-web` | `search: false` |
| `skill-badge` | bật |
| `browser-use` + `browser-use-chrome-devtools-mcp` | bật launch Chromium |
| `workflow-ptc` + `tool-workflow` | comment = theo preset |
| `ui-settings-models` | `catalogAdd: false` ẩn **Add provider**; `true` để bật lại (restart DSH) |
| `ui-schedule` | web bundle tắt; `disabled: false` để bật |

### Egress

`proxy/allow-domains.txt` — LLM, Git, npm nếu thật sự cần. Không whitelist telemetry.

### Trusted operations

`data/policies/trusted-operations.yml` — thu hẹp `bashAllow` trên máy khác nếu cần.

### Credential (không commit)

Ghi key vào `.env` của compose (inject vào container). Tên biến **trùng** `apiKeyEnv` trên Models, ví dụ OpenAI → `OPENAI_API_KEY`, custom provider → đúng tên field API key.

```env
OPENAI_API_KEY=sk-...
DEEPSEEK_API_KEY=sk-...
```

Sau khi sửa key: `docker compose up -d` (`restart` không đọc lại `.env`).

Key nhập trên Models nằm ở `data/.credentials.yaml` (bind mount, gitignore). Entrypoint **không** xóa file này khi restart.

```powershell
docker cp .\local-credentials.yaml deepseek-harness:/credentials/.credentials.yaml
docker compose exec -u root dsh sh -c "chown dsh:dsh /credentials/.credentials.yaml && chmod 600 /credentials/.credentials.yaml"
docker compose restart dsh
```

User trong image là `dsh` (không phải `node` trừ fallback entrypoint).

---

## 7. Checklist máy mới

1. Docker Desktop chạy, đủ RAM (build image nặng; runtime nhẹ hơn).
2. `.env` path và `DSH_IMAGE` đúng máy này.
3. `DSH_SOURCE_OVERLAY=0`.
4. `mkdir workspace` nếu chưa có.
5. Image có Chromium nếu dùng Browser Use (`docker compose exec dsh test -x /usr/bin/chromium`).
6. `proxy/allow-domains.txt` đủ domain LLM / web nội bộ.
7. `cordis.patch.yml` đúng bật/tắt.
8. `docker compose up -d --pull never` sau khi image đã có local.
9. Mở URL **có token**; hard-refresh browser.
10. `.\security-test.ps1` — allow / block / `--noproxy` phải fail.
11. Session chat **mới** để Browser Use.

Telemetry luôn tắt: `DSH_TELEMETRY_DISABLED=1`.

---

## 8. `.env` không ăn — kiểm tra này trước

Compose **có** đọc file `.env` ở **thư mục repo** (cùng `docker-compose.yml`), nhưng:

1. **`docker compose restart` không đọc lại `.env`.** Container giữ env lúc tạo. Sau khi sửa `.env`:

```powershell
cd D:\project\dsh-docker
docker compose up -d
```

Nếu vẫn cũ: `docker compose up -d --force-recreate`.

2. **Biến shell thắng `.env`.** PowerShell `$env:DSH_IMAGE=...` sẽ đè file. Xóa: `Remove-Item Env:DSH_IMAGE`.

3. **Chạy compose đúng thư mục.** `docker compose` tìm `.env` theo project dir, không theo chỗ bạn ngồi nếu `-f` file ở chỗ khác mà không `--project-directory`.

4. **`DSH_HOST_ROOT` trước đây không được compose dùng** (chỉ PATH_MAP vào container). Bản compose hiện tại: nếu không set `DSH_HOST_PATH_MAP` thì map mặc định từ `DSH_HOST_ROOT`.

5. Kiểm tra giá trị thật:

```powershell
docker compose config | Select-String "DSH_|image:"
docker compose exec dsh printenv DSH_HOST_PATH_MAP
docker compose exec dsh printenv DSH_SOURCE_OVERLAY
```

6. File `.env` phải UTF-8 (không UTF-16). Không dùng `Out-File`; dùng `Copy-Item .env.example .env`.

### Squid 503 trên domain đã allow

Đó **không** phải allowlist (deny là **403**). 503 sau một lúc rồi hết khi restart thường là DNS IPv6 treo. Compose tắt IPv6 trên Squid; resolver là Docker `127.0.0.11` (DNS máy host, không 1.1.1.1/8.8.8.8). Áp dụng:

```powershell
docker compose up -d --force-recreate egress-proxy
docker compose logs -f egress-proxy
```

---

## 9. Lệnh thường dùng

```powershell
docker compose up -d --pull never
docker compose ps
docker compose logs -f dsh
docker compose logs dsh | Select-String "dsh web:"
docker compose restart dsh
docker compose restart egress-proxy
docker compose exec dsh env | Select-String DSH_TELEMETRY
docker compose down
```

Test proxy từ trong DSH:

```powershell
docker compose exec dsh curl -sI https://api.deepseek.com
docker compose exec dsh curl -sI --noproxy "*" https://example.com
```

Cái sau phải fail (không bypass Squid).
