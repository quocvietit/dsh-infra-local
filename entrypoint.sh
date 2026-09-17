#!/bin/sh
set -e

CREDENTIAL_FILE="/credentials/.credentials.yaml"
TARGET_LINK="/data/.credentials.yaml"

# Image files are `dsh:dsh`; the Node base image also has user `node`.
# Always run the app as whoever owns /opt/dsh so pnpm/dsh can write lib/.
APP_USER=$(stat -c %U /opt/dsh 2>/dev/null || echo dsh)
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  if id -u dsh >/dev/null 2>&1; then
    APP_USER=dsh
  else
    APP_USER=node
  fi
fi

# Make overlay/patch targets writable. cap-drop ALL without DAC_OVERRIDE used
# to make even root fail on dsh-owned 755 paths.
ensure_writable() {
  for path in "$@"; do
    [ -e "$path" ] || continue
    chown -R "$APP_USER:$APP_USER" "$path" 2>/dev/null || true
    chmod -R a+rwX "$path" 2>/dev/null || true
  done
}

# Optional host overlay: copy /source/dsh onto the baked /opt/dsh tree.
# The image already contains harness source (Enter-newline, Windows uploads).
# DSH_SOURCE_OVERLAY=0  never overlay, never wait (Hub / standalone image)
# DSH_SOURCE_OVERLAY=1  wait for the Windows bind mount, then overlay (dev)
# unset                 overlay only if /source/dsh/packages is already mounted
source_overlay_forced() {
  case "${DSH_SOURCE_OVERLAY-}" in
    1|true|on|yes) return 0 ;;
    *) return 1 ;;
  esac
}

source_overlay_disabled() {
  case "${DSH_SOURCE_OVERLAY-}" in
    0|false|off|no) return 0 ;;
    *) return 1 ;;
  esac
}

source_overlay_active() {
  if source_overlay_disabled; then
    return 1
  fi
  if source_overlay_forced; then
    return 0
  fi
  [ -d /source/dsh/packages ]
}

wait_for_overlay_file() {
  mark="$1"
  if source_overlay_disabled; then
    return 0
  fi
  if ! source_overlay_forced; then
    return 0
  fi
  i=0
  while [ ! -f "$mark" ] && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 1
  done
}

if source_overlay_disabled; then
  echo "dsh-entrypoint: source overlay off (baked /opt/dsh)"
elif source_overlay_forced; then
  echo "dsh-entrypoint: source overlay on (will wait for /source/dsh)"
fi

# ==================================================
# Windows bind mount /data
# ==================================================

# DSH cần ghi profile, state, cordis.yml... vào /data.
# Windows bind mount không chown sang node được,
# nên cho phép container user ghi vào các file config/state.
chmod -R a+rwX /data 2>/dev/null || true


# ==================================================
# Secure credentials
# ==================================================

if [ ! -f "$CREDENTIAL_FILE" ]; then
  touch "$CREDENTIAL_FILE"
fi

chown "$APP_USER:$APP_USER" "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"

# Xóa credentials cũ nằm trên Windows bind mount
if [ -e "$TARGET_LINK" ] || [ -L "$TARGET_LINK" ]; then
  rm -f "$TARGET_LINK"
fi

# Link sang credential nằm trong Linux named volume
ln -s "$CREDENTIAL_FILE" "$TARGET_LINK"


# ==================================================
# Overlay conversation UI from the host bind mount (optional)
# ==================================================
# Baked /opt/dsh already has Enter-newline / Ctrl+Enter-send. Overlay only
# when DSH_SOURCE_OVERLAY is on and /source/dsh is mounted.

CONV_SRC="/source/dsh/packages/client/ui-conversation"
CONV_DST="/opt/dsh/packages/client/ui-conversation"
CONV_MARK="$CONV_SRC/src/client/settings/PlainEnterRow.tsx"
WF_SRC="/source/dsh/packages/client/ui-workflow-run"
WF_DST="/opt/dsh/packages/client/ui-workflow-run"
WF_TOOL_SRC="/source/dsh/packages/workflow/tool-workflow"
WF_TOOL_DST="/opt/dsh/packages/workflow/tool-workflow"
if source_overlay_active; then
  wait_for_overlay_file "$CONV_MARK"
  ensure_writable "$CONV_DST" "$WF_DST" "$WF_TOOL_DST"
  if [ -f "$CONV_MARK" ]; then
    echo "dsh-entrypoint: overlaying ui-conversation from /source/dsh"
    tar -C "$CONV_SRC" --exclude=node_modules --exclude=lib --overwrite -cf - . \
      | tar -C "$CONV_DST" --overwrite -xf - || true
    ensure_writable "$CONV_DST"
  fi
  if [ -f "$WF_SRC/src/client/WorkflowRunPanel.tsx" ]; then
    echo "dsh-entrypoint: overlaying ui-workflow-run from /source/dsh"
    tar -C "$WF_SRC" --exclude=node_modules --overwrite -cf - . \
      | tar -C "$WF_DST" --overwrite -xf - || true
    ensure_writable "$WF_DST"
  fi
  if [ -f "$WF_TOOL_SRC/src/index.ts" ]; then
    echo "dsh-entrypoint: overlaying tool-workflow from /source/dsh"
    tar -C "$WF_TOOL_SRC" --exclude=node_modules --overwrite -cf - . \
      | tar -C "$WF_TOOL_DST" --overwrite -xf - || true
    ensure_writable "$WF_TOOL_DST"
  fi
fi


# ==================================================
# File uploads on a Windows bind-mounted DSH_HOME
# ==================================================
# Host publication chmods DSH_HOME (/data). Docker Desktop rejects chmod on
# that mount point (EPERM), so uploads fail even though files are writable.
# Wrap chmod in the image's already-built attachment-local lib. Overlay
# src/store.ts from /source/dsh only when host overlay is on (`dsh web`
# launches through tsx and can load TypeScript).

ATTACH_SRC="/source/dsh/packages/attachment/attachment-local/src/store.ts"
ATTACH_DST="/opt/dsh/packages/attachment/attachment-local/src/store.ts"
ATTACH_LIB="/opt/dsh/packages/attachment/attachment-local/lib/index.js"
ensure_writable "$ATTACH_DST" "$ATTACH_LIB"
if source_overlay_active && [ -f "$ATTACH_SRC" ]; then
  echo "dsh-entrypoint: overlaying attachment-local store from /source/dsh"
  if ! cp "$ATTACH_SRC" "$ATTACH_DST"; then
    sed -i 's/await mkdir(target, { recursive: true, mode: 0o700 })/await mkdir(target, { recursive: true })/' "$ATTACH_DST" || true
  fi
fi
ATTACH_PATCH="/tmp/patch-attachment-chmod.mjs"
cat > "$ATTACH_PATCH" <<'EOF'
import { readFileSync, writeFileSync } from 'node:fs'
const path = '/opt/dsh/packages/attachment/attachment-local/lib/index.js'
let source = readFileSync(path, 'utf8')
if (!source.includes('chmodIfSupported')) {
  const helper = `
async function chmodIfSupported(path, mode) {
  try { await chmod(path, mode) }
  catch (error) {
    if (error instanceof Error && 'code' in error && (error.code === 'EPERM' || error.code === 'EACCES' || error.code === 'ENOTSUP')) return
    throw error
  }
}
`
  source = source.replace(
    /import \{ chmod, ([^}]+) \} from "node:fs\/promises";/,
    `import { chmod, $1 } from "node:fs/promises";${helper}`,
  )
  source = source.replaceAll('await chmod(target,', 'await chmodIfSupported(target,')
}
source = source.replace(
  /await mkdir\(target, \{\s*recursive: true,\s*mode: 448\s*\}\)/,
  'await mkdir(target, { recursive: true })',
)
writeFileSync(path, source)
EOF
node "$ATTACH_PATCH"


# ==================================================
# Settings skill library (missing from the runtime image)
# ==================================================
# Source has host skill-library + Settings UI, but /opt/dsh does not. Overlay
# the packages, generate Typert remotes, and rebuild the remotes client so
# Settings → Skills can mount `remote.skillLibrary`.

wait_for_file() {
  wait_for_overlay_file "$1"
}

overlay_tree() {
  src="$1"
  dst="$2"
  mkdir -p "$dst"
  tar -C "$src" --exclude=node_modules --exclude=lib --exclude=tests --overwrite -cf - . \
    | tar -C "$dst" --overwrite -xf - || true
  chmod -R a+rwX "$dst"
}

SKILL_SRC="/source/dsh/packages/host/skill-library"
SKILL_DST="/opt/dsh/packages/host/skill-library"
SKILL_UI_SRC="/source/dsh/packages/client/ui-settings-skills"
SKILL_UI_DST="/opt/dsh/packages/client/ui-settings-skills"
if source_overlay_active; then
  wait_for_file "$SKILL_SRC/src/index.ts"
  wait_for_file "$SKILL_UI_SRC/src/client/index.ts"
fi

ensure_writable \
  /opt/dsh/packages/host \
  /opt/dsh/packages/client \
  /opt/dsh/packages/api \
  /opt/dsh/packages/api/remotes \
  /opt/dsh/packages/api/remotes/src \
  /opt/dsh/packages/api/remotes/src/client \
  /opt/dsh/packages/api/remotes/lib \
  /opt/dsh/packages/bundle/web-app \
  /opt/dsh/packages/bundle/web-app/node_modules/@deepseek-ai

if source_overlay_active && [ -f "$SKILL_SRC/src/index.ts" ] && [ -f "$SKILL_UI_SRC/src/client/index.ts" ]; then
  echo "dsh-entrypoint: overlaying skill-library from /source/dsh"
  overlay_tree "$SKILL_SRC" "$SKILL_DST"
  overlay_tree "$SKILL_UI_SRC" "$SKILL_UI_DST"

  if [ -f /source/dsh/packages/bundle/web-app/cordis.patch.yml ]; then
    chown root:root /opt/dsh/packages/bundle/web-app/cordis.patch.yml 2>/dev/null || true
    chmod a+w /opt/dsh/packages/bundle/web-app/cordis.patch.yml 2>/dev/null || true
    cp /source/dsh/packages/bundle/web-app/cordis.patch.yml /opt/dsh/packages/bundle/web-app/cordis.patch.yml
  fi
  if [ -f /source/dsh/packages/api/remotes/src/client/index.ts ]; then
    chown root:root /opt/dsh/packages/api/remotes/src/client/index.ts \
      /opt/dsh/packages/api/remotes/src/remote-events.ts 2>/dev/null || true
    chmod a+w /opt/dsh/packages/api/remotes/src/client/index.ts \
      /opt/dsh/packages/api/remotes/src/remote-events.ts 2>/dev/null || true
    cp /source/dsh/packages/api/remotes/src/client/index.ts /opt/dsh/packages/api/remotes/src/client/index.ts
    cp /source/dsh/packages/api/remotes/src/remote-events.ts /opt/dsh/packages/api/remotes/src/remote-events.ts
    sed -i "s|'@deepseek-ai/dsh-host-skill-library/remote'|'../../../../host/skill-library/lib/typert.remote-client.js'|g" \
      /opt/dsh/packages/api/remotes/src/client/index.ts
    sed -i "s|'@deepseek-ai/dsh-host-skill-library/types'|'../../../../host/skill-library/src/types.ts'|g" \
      /opt/dsh/packages/api/remotes/src/client/index.ts
  fi

  WEB_SCOPE="/opt/dsh/packages/bundle/web-app/node_modules/@deepseek-ai"
  ln -sfn ../../../../host/skill-library "$WEB_SCOPE/dsh-host-skill-library"
  ln -sfn ../../../../client/ui-settings-skills "$WEB_SCOPE/dsh-client-ui-settings-skills"

  mkdir -p "$SKILL_DST/node_modules"
  ln -sfn /opt/dsh/packages/skill/skill-filesystem/node_modules/yaml "$SKILL_DST/node_modules/yaml"
  ln -sfn /opt/dsh/packages/host/plugin-inventory/node_modules/zod "$SKILL_DST/node_modules/zod"

  chown root:root /opt/dsh/tsconfig.host.json /opt/dsh/tsconfig.client.json \
    /opt/dsh/tsconfig.base.json \
    /opt/dsh/packages/api/remotes/tsconfig.client.json 2>/dev/null || true
  chmod a+w /opt/dsh/tsconfig.host.json /opt/dsh/tsconfig.client.json \
    /opt/dsh/tsconfig.base.json \
    /opt/dsh/packages/api/remotes/tsconfig.client.json \
    /opt/dsh/packages/api/remotes/lib /opt/dsh/packages/api/remotes/src 2>/dev/null || true
  chown -R root:root /opt/dsh/packages/api/remotes/lib 2>/dev/null || true
  chmod -R a+rwX /opt/dsh/packages/api/remotes/lib 2>/dev/null || true
  if [ -f /source/dsh/tsconfig.base.json ]; then
    cp /source/dsh/tsconfig.base.json /opt/dsh/tsconfig.base.json
  fi
  mkdir -p /opt/dsh/packages/api/remotes/node_modules/@deepseek-ai 2>/dev/null || true
  chmod a+rwx /opt/dsh/packages/api/remotes/node_modules \
    /opt/dsh/packages/api/remotes/node_modules/@deepseek-ai 2>/dev/null || true
  ln -sfn ../../../../host/skill-library \
    /opt/dsh/packages/api/remotes/node_modules/@deepseek-ai/dsh-host-skill-library 2>/dev/null || true

  node <<'EOF'
import { readFileSync, writeFileSync } from 'node:fs'

function insertLine(path, needle, extra) {
  let text = readFileSync(path, 'utf8')
  if (text.includes(extra.trim())) return
  if (!text.includes(needle)) throw new Error(`missing ${needle} in ${path}`)
  writeFileSync(path, text.replace(needle, `${needle}\n${extra}`))
}

insertLine(
  '/opt/dsh/tsconfig.host.json',
  '    { "path": "./packages/host/plugin-inventory" },',
  '    { "path": "./packages/host/skill-library" },',
)
insertLine(
  '/opt/dsh/tsconfig.client.json',
  '    { "path": "./packages/client/ui-settings-plugin-inventory" },',
  '    { "path": "./packages/client/ui-settings-skills" },',
)

const remotesTsconfig = '/opt/dsh/packages/api/remotes/tsconfig.client.json'
const json = JSON.parse(readFileSync(remotesTsconfig, 'utf8'))
if (!json.references.some((row) => String(row.path).includes('skill-library'))) {
  const index = json.references.findIndex((row) => String(row.path).includes('plugin-inventory'))
  json.references.splice(index + 1, 0, { path: '../../host/skill-library' })
  writeFileSync(remotesTsconfig, `${JSON.stringify(json, null, 2)}\n`)
}
EOF

  export PATH="/opt/dsh/node_modules/.bin:$PATH"
  NEED_BUILD=0
  if [ ! -f "$SKILL_DST/lib/typert.remote-client.js" ]; then NEED_BUILD=1; fi
  if [ ! -f "$SKILL_UI_DST/lib/client.js" ]; then NEED_BUILD=1; fi
  if ! grep -q skillLibraryRemote /opt/dsh/packages/api/remotes/lib/client.js 2>/dev/null; then NEED_BUILD=1; fi
  if [ "$SKILL_SRC/src/index.ts" -nt "$SKILL_DST/lib/typert.remote-client.js" ] 2>/dev/null; then NEED_BUILD=1; fi
  if [ "$SKILL_UI_SRC/src/client/index.ts" -nt "$SKILL_UI_DST/lib/client.js" ] 2>/dev/null; then NEED_BUILD=1; fi

  if [ "$NEED_BUILD" = 1 ]; then
    echo "dsh-entrypoint: building skill library settings packages"
    (cd /opt/dsh && tsc -b packages/host/skill-library)
    (cd "$SKILL_DST" && tsdown)
    (cd /opt/dsh && node <<'EOF'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { WorkspaceTypertGenerator } from '/opt/dsh/packages/typert/generator/lib/index.js'

const root = '/opt/dsh'
const generator = new WorkspaceTypertGenerator(root, { checkDiagnostics: false })
const artifacts = generator.generate(['@deepseek-ai/dsh-host-skill-library'], ['host'])
if (artifacts.length === 0) throw new Error('typert generated no skill-library artifacts')
const output = join(root, 'packages/host/skill-library/lib')
mkdirSync(output, { recursive: true })
for (const artifact of artifacts) {
  writeFileSync(join(output, `typert.${artifact.face}.js`), artifact.js)
  writeFileSync(join(output, `typert.${artifact.face}.d.ts`), artifact.dts)
  if (artifact.remote === undefined) throw new Error('skill-library remote artifact missing')
  writeFileSync(join(output, 'typert.remote-client.js'), artifact.remote.js)
  writeFileSync(join(output, 'typert.remote-client.d.ts'), artifact.remote.dts)
  writeFileSync(join(output, 'typert.remote-client.d.ts.map'), artifact.remote.dtsMap)
}
console.log('dsh-entrypoint: wrote skill-library typert remotes')
EOF
    )
    chown root:root /opt/dsh/packages/api/remotes/node_modules/@deepseek-ai 2>/dev/null || true
    chmod a+rwx /opt/dsh/packages/api/remotes/node_modules/@deepseek-ai 2>/dev/null || true
    ln -sfn ../../../../host/skill-library \
      /opt/dsh/packages/api/remotes/node_modules/@deepseek-ai/dsh-host-skill-library || true
    chown -R root:root /opt/dsh/packages/api/remotes/lib 2>/dev/null || true
    chmod -R a+rwX /opt/dsh/packages/api/remotes/lib 2>/dev/null || true
    (cd /opt/dsh/packages/api/remotes && tsdown)
    mkdir -p "$SKILL_UI_DST/lib/types"
    printf 'export function apply() {}\n' > "$SKILL_UI_DST/lib/types/index.js"
    (cd "$SKILL_UI_DST" && tsdown)
    chmod -R a+rX "$SKILL_DST/lib" "$SKILL_UI_DST/lib" /opt/dsh/packages/api/remotes/lib
  fi

  mkdir -p /data/profiles/web/node_modules/@deepseek-ai
  ln -sfn /opt/dsh/packages/host/skill-library \
    /data/profiles/web/node_modules/@deepseek-ai/dsh-host-skill-library
  ln -sfn /opt/dsh/packages/client/ui-settings-skills \
    /data/profiles/web/node_modules/@deepseek-ai/dsh-client-ui-settings-skills
elif [ -f "$SKILL_DST/src/index.ts" ] && [ -f "$SKILL_UI_DST/src/client/index.ts" ]; then
  mkdir -p /data/profiles/web/node_modules/@deepseek-ai
  ln -sfn /opt/dsh/packages/host/skill-library \
    /data/profiles/web/node_modules/@deepseek-ai/dsh-host-skill-library
  ln -sfn /opt/dsh/packages/client/ui-settings-skills \
    /data/profiles/web/node_modules/@deepseek-ai/dsh-client-ui-settings-skills
fi


# ==================================================
# Stable web token + Windows Explorer host-open
# ==================================================
AUTH_SRC="/source/dsh/packages/client/connection/src/browser-auth.ts"
AUTH_DST="/opt/dsh/packages/client/connection/src/browser-auth.ts"
OPEN_SRC="/source/dsh/packages/util/native-command/src/path-opener.ts"
OPEN_DST="/opt/dsh/packages/util/native-command/src/path-opener.ts"
if source_overlay_active; then
  wait_for_file "$AUTH_SRC"
  wait_for_file "$OPEN_SRC"
fi
ensure_writable "$AUTH_DST" "$OPEN_DST" \
  /opt/dsh/packages/client/connection/lib/index.js \
  /opt/dsh/packages/util/native-command/lib/index.js
if source_overlay_active; then
  if [ -f "$AUTH_SRC" ]; then cp "$AUTH_SRC" "$AUTH_DST" || true; fi
  if [ -f "$OPEN_SRC" ]; then cp "$OPEN_SRC" "$OPEN_DST" || true; fi
fi
if [ -f /usr/local/bin/dsh-patch-runtime.mjs ]; then
  node /usr/local/bin/dsh-patch-runtime.mjs
fi


# ==================================================
# Run DSH as non-root
# ==================================================

# Forward port Docker-accessible 3081 -> DSH localhost:3080
socat TCP-LISTEN:3081,fork,reuseaddr TCP:127.0.0.1:3080 &

# Bundle conversation UI as root (writes /opt/dsh/.../lib). Then drop to the
# image owner of /opt/dsh — not `node`, which cannot write dsh-owned trees.
echo "dsh-entrypoint: starting as ${APP_USER}"
pnpm --dir /opt/dsh --filter @deepseek-ai/dsh-client-ui-conversation bundle
pnpm --dir /opt/dsh --filter @deepseek-ai/dsh-client-ui-workflow-run bundle || true
exec su -s /bin/sh "$APP_USER" -c 'pnpm --dir /opt/dsh dsh web --no-open'
