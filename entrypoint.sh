#!/bin/sh
set -e

CREDENTIAL_FILE="/credentials/.credentials.yaml"
TARGET_LINK="/data/.credentials.yaml"

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

chown node:node "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"

# Xóa credentials cũ nằm trên Windows bind mount
if [ -e "$TARGET_LINK" ] || [ -L "$TARGET_LINK" ]; then
  rm -f "$TARGET_LINK"
fi

# Link sang credential nằm trong Linux named volume
ln -s "$CREDENTIAL_FILE" "$TARGET_LINK"


# ==================================================
# Overlay conversation UI from the host bind mount
# ==================================================
# The image's /opt/dsh still treats unmodified Enter as send. /source/dsh has
# Enter-newline / Ctrl+Enter-send. Wait for the Windows bind mount — a first
# `[ -f ]` can miss the tree — then copy sources (tar has skipped new files).

CONV_SRC="/source/dsh/packages/client/ui-conversation"
CONV_DST="/opt/dsh/packages/client/ui-conversation"
CONV_MARK="$CONV_SRC/src/client/settings/PlainEnterRow.tsx"
i=0
while [ ! -f "$CONV_MARK" ] && [ "$i" -lt 30 ]; do
  i=$((i + 1))
  sleep 1
done
if [ -f "$CONV_MARK" ]; then
  chmod -R a+rwX "$CONV_DST" 2>/dev/null || true
  tar -C "$CONV_SRC" --exclude=node_modules --exclude=lib --overwrite -cf - . \
    | tar -C "$CONV_DST" --overwrite -xf - || true
  chmod -R a+rwX "$CONV_DST"
fi


# ==================================================
# File uploads on a Windows bind-mounted DSH_HOME
# ==================================================
# Host publication chmods DSH_HOME (/data). Docker Desktop rejects chmod on
# that mount point (EPERM), so uploads fail even though files are writable.
# Wrap chmod in the image's already-built attachment-local lib, and overlay
# src/store.ts because `dsh web` launches through tsx and loads TypeScript.

ATTACH_SRC="/source/dsh/packages/attachment/attachment-local/src/store.ts"
ATTACH_DST="/opt/dsh/packages/attachment/attachment-local/src/store.ts"
if [ -f "$ATTACH_SRC" ]; then
  chown root:root "$ATTACH_DST" 2>/dev/null || true
  chmod u+w "$ATTACH_DST" 2>/dev/null || true
  if ! cp "$ATTACH_SRC" "$ATTACH_DST"; then
    sed -i 's/await mkdir(target, { recursive: true, mode: 0o700 })/await mkdir(target, { recursive: true })/' "$ATTACH_DST" || true
  fi
  chmod a+r "$ATTACH_DST" 2>/dev/null || true
fi

ATTACH_LIB="/opt/dsh/packages/attachment/attachment-local/lib/index.js"
chmod a+w "$ATTACH_LIB" 2>/dev/null || true
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
  mark="$1"
  i=0
  while [ ! -f "$mark" ] && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 1
  done
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
wait_for_file "$SKILL_SRC/src/index.ts"
wait_for_file "$SKILL_UI_SRC/src/client/index.ts"

# cap-drop ALL removes DAC_OVERRIDE, so root cannot mkdir in dsh-owned 755 dirs.
chmod a+rwx /opt/dsh /opt/dsh/packages/host /opt/dsh/packages/client \
  /opt/dsh/packages/api /opt/dsh/packages/api/remotes \
  /opt/dsh/packages/api/remotes/src /opt/dsh/packages/api/remotes/src/client \
  /opt/dsh/packages/api/remotes/lib \
  /opt/dsh/packages/bundle/web-app \
  /opt/dsh/packages/bundle/web-app/node_modules/@deepseek-ai \
  /opt/dsh/packages/client 2>/dev/null || true

if [ -f "$SKILL_SRC/src/index.ts" ] && [ -f "$SKILL_UI_SRC/src/client/index.ts" ]; then
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
fi


# ==================================================
# Run DSH as non-root
# ==================================================

# Forward port Docker-accessible 3081 -> DSH localhost:3080
socat TCP-LISTEN:3081,fork,reuseaddr TCP:127.0.0.1:3080 &

exec su -s /bin/sh node -c 'pnpm --dir /opt/dsh --filter @deepseek-ai/dsh-client-ui-conversation bundle && pnpm --dir /opt/dsh dsh web --no-open'
