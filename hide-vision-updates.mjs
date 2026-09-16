/**
 * Hide Vision Toolkit "Plugin updates" UI and disable npm self-update.
 * The plugin is pinned in the Docker image (`file:` install).
 */
import { readFileSync, writeFileSync } from 'node:fs'

const MARKER = 'dsh-hide-vision-updates'
const ROOT = '/opt/dsh-plugins/node_modules/@anionex/dsh-vision-toolkit'

function patch(path, apply) {
  let source
  try {
    source = readFileSync(path, 'utf8')
  } catch {
    return
  }
  if (source.includes(MARKER)) return
  const next = apply(source)
  if (next !== source) writeFileSync(path, next)
}

patch(`${ROOT}/lib/client.js`, (source) => {
  const next = source.replace(
    /\(0, jsx_runtime_1\.jsxs\)\("section", \{ className: "dvt-panel dvt-update-panel"[\s\S]*?\}\), \(0, jsx_runtime_1\.jsxs\)\("details", \{ className: "dvt-advanced"/,
    `null, /* ${MARKER} */ (0, jsx_runtime_1.jsxs)("details", { className: "dvt-advanced"`,
  )
  if (next === source) throw new Error('vision client.js update panel not found')
  return next
})

patch(`${ROOT}/src/client/index.tsx`, (source) => {
  const next = source.replace(
    /\n      <section className="dvt-panel dvt-update-panel">[\s\S]*?\n      <\/section>\n\n      <details className="dvt-advanced">/,
    `\n      {/* ${MARKER} */}\n      <details className="dvt-advanced">`,
  )
  return next === source ? source : next
})

const disableCheck = `
  /* ${MARKER} */
  async check() {
    return {
      supported: false,
      reason: 'unsupported-install-source',
      currentVersion: this.currentVersion,
      updateAvailable: false,
      checkedAt: this.now().toISOString(),
    }
  }
  async __disabledCheck() {
`

patch(`${ROOT}/lib/plugin-update.js`, (source) => {
  if (!source.includes('async check()')) return source
  return source.replace('async check() {', disableCheck)
})

patch(`${ROOT}/src/plugin-update.ts`, (source) => {
  const needle = 'async check(): Promise<PluginUpdateCheck> {'
  if (!source.includes(needle)) return source
  return source.replace(
    needle,
    `${needle}
    return { /* ${MARKER} */
      supported: false,
      reason: 'unsupported-install-source',
      currentVersion: this.currentVersion,
      updateAvailable: false,
      checkedAt: this.now().toISOString(),
    }
    void 0; {`,
  )
})

console.log('dsh-entrypoint: vision-toolkit plugin updates hidden')
