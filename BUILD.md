# Build & chạy DSH Docker

Image local: `dsh-runtime:1.2.1`  
Image Hub: `vietvqworkspace/dsh-web:1.2.1`

UI: http://127.0.0.1:3080 (lấy URL có `?token=` từ `docker compose logs dsh`)

Không commit: `.env`, `data/.credentials.yaml`, `data/settings.yaml`, sessions, cache, workspace.

---

## Kiến trúc

| Lớp | Ở đâu | Máy khác |
|---|---|---|
| Runtime (Harness + UI + trusted-ops + Vision Toolkit) | trong image `/opt/dsh` | `docker pull` hoặc `docker load` |
| Entrypoint / patch | trong image **và** file host `entrypoint.sh` (compose mount) | copy repo deploy |
| `DSH_HOME` | `data/` | copy (không cần `sessions/`, `storages/`, `cache/`) |
| Egress | `proxy/` | copy |
| Compose | `docker-compose.yml` + `.env` | copy, **chỉ sửa path / image trong `.env`** |
| Workspace | `workspace/` | thư mục project |

Không mount `deepseek-harness` khi deploy. Overlay source chỉ khi sửa harness.

---

## Máy khác — dùng image có sẵn (không build)

Cần Docker Desktop. Clone repo infra (không cần clone harness).

```powershell
git clone <repo-infra> dsh-docker
cd dsh-docker
Copy-Item .env.example .env
```

Sửa `.env`:

```env
DSH_IMAGE=vietvqworkspace/dsh-web:1.2.1
DSH_HOST_ROOT=D:/path/tren/may-nay/dsh-docker
DSH_HOST_PATH_MAP=/workspace=D:/path/tren/may-nay/dsh-docker/workspace;/data=D:/path/tren/may-nay/dsh-docker/data
DSH_SOURCE_OVERLAY=0
DSH_VISION_TOOLKIT=1
```

```powershell
mkdir workspace
docker pull vietvqworkspace/dsh-web:1.2.1
docker compose up -d --pull never
docker compose logs dsh | Select-String "dsh web:"
```

Hoặc copy file tar từ máy đã build:

```powershell
docker save vietvqworkspace/dsh-web:1.2.1 -o dsh-web-1.2.1.tar
# máy đích:
docker load -i dsh-web-1.2.1.tar
```

Nút **Open configuration file** trên Windows:

```powershell
.\host-open.ps1
```

API key LLM: Settings trong UI, hoặc file credential trong volume (không commit). Xem mục Credential.

---

## Máy build — nướng image từ source harness

Cần: Docker, Git, Node không bắt buộc trên host (build trong Docker). Fork harness đã patch nằm cạnh compose:

```text
dsh-docker/
  docker-compose.yml
  deepseek-harness/   # git clone fork local_custom
  data/
  proxy/
```

```powershell
git clone <fork-harness> deepseek-harness
# checkout nhánh đã patch, ví dụ local_custom

$env:DSH_COMMIT_HASH = (git -C .\deepseek-harness rev-parse --short HEAD)
$env:DSH_IMAGE = "dsh-runtime:1.2.1"
docker compose build
docker compose up -d
```

Đẩy lên Hub:

```powershell
docker tag dsh-runtime:1.2.1 vietvqworkspace/dsh-web:1.2.1
docker push vietvqworkspace/dsh-web:1.2.1
```

Sửa harness khi đang chạy (không rebuild image):

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

(`DSH_SOURCE_OVERLAY=1`, mount `./deepseek-harness`)

---

## Bật / tắt tính năng

Restart sau khi sửa: `docker compose restart dsh`.

### 1. File `.env`

| Biến | Mặc định | Tắt | Ý nghĩa |
|---|---|---|---|
| `DSH_VISION_TOOLKIT` | `1` | `0` | Không gắn plugin Vision Toolkit vào profile web |
| `DSH_SOURCE_OVERLAY` | `0` | giữ `0` | `1` + `docker-compose.dev.yml` = overlay source host |
| `DSH_IMAGE` | `dsh-runtime:1.2.1` | — | Đổi sang `vietvqworkspace/dsh-web:1.2.1` trên máy khác |

### 2. `data/profiles/web/cordis.patch.yml`

File này **ghi đè** row cùng `id` của bundle/preset. Comment đã có trong file.

| Row `id` | Tắt | Bật |
|---|---|---|
| `llm-deepseek` | `disabled: true` (mặc định) | `disabled: false` — hiện adapter DeepSeek Official |
| `web-search-deepseek` | `disabled: true` (mặc định) | `disabled: false` |
| `tool-web` | `config.search: false` | `search: true` |
| `skill-badge` | `disabled: true` | `disabled: false` (mặc định) |
| `workflow-ptc` + `tool-workflow` | bỏ comment `disabled: true` cả hai | để comment (preset `standard` bật workflow, 8 agent) |
| `ui-schedule` | để web bundle `disabled: true` | `disabled: false` |

Ví dụ tắt workflow trên máy này — bỏ comment trong patch:

```yaml
- id: workflow-ptc
  disabled: true
- id: tool-workflow
  disabled: true
```

### 3. Egress

`proxy/allow-domains.txt` — thêm domain LLM/Git/npm. Restart:

```powershell
docker compose restart egress-proxy
```

Không whitelist telemetry.

### 4. Trusted operations

`data/policies/trusted-operations.yml` — lệnh được auto-approve. Thu hẹp `bashAllow` trên máy khác nếu cần.

### 5. Project / skill / workflow

- `data/projects/*.yml` — ví dụ `example-service.yml` (sửa `sourcePath` cho project thật)
- `data/skills/`, `data/workflows/` — prompt/JS; runtime plugin nằm trong image
- Vision API key: Settings → Vision Toolkit (không commit key)

### 6. Code nằm trong harness (chỉ đổi khi rebuild image)

- Workflow persist + bảng task: `packages/workflow/tool-workflow`, `packages/client/ui-workflow-run`
- 8 agent song song: `packages/preset/agent-presets/presets/standard/agent.cordis.yml` (`maxConcurrentAgents: 8`)
- Skills library UI, permission presets, terminal sidebar: bundle web

---

## Credential (không commit)

Compose mount volume `dsh-credentials` → `/credentials/.credentials.yaml` (mode `600`).

Không ghi API key vào `docker-compose.yml` hay git.

Sao chép file working vào volume:

```powershell
docker cp .\local-credentials.yaml deepseek-harness:/credentials/.credentials.yaml
docker compose exec -u root dsh sh -c "chown node:node /credentials/.credentials.yaml && chmod 600 /credentials/.credentials.yaml"
docker compose restart dsh
```

---

## Checklist máy mới

1. `.env` đúng ổ đĩa / `DSH_IMAGE` Hub  
2. Không có `.env` hay `.credentials.yaml` từ máy cũ trong git  
3. `DSH_SOURCE_OVERLAY=0`  
4. `proxy/allow-domains.txt` đủ domain LLM  
5. `data/profiles/web/cordis.patch.yml` đúng bật/tắt  
6. `mkdir workspace`  
7. Hard-refresh trình duyệt sau khi đổi image  

Telemetry luôn tắt: `DSH_TELEMETRY_DISABLED=1`.
