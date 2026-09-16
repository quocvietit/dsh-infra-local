/**
 * Bind the baked @anionex/dsh-vision-toolkit into DSH_HOME's web profile.
 * Host bind-mount of /data would otherwise hide an install that only lived in the image.
 */
import { mkdirSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { spawnSync } from 'node:child_process'

const PROFILE_DIR = '/data/profiles/web'
const PROFILE_PKG = join(PROFILE_DIR, 'package.json')
const BUNDLE = '@anionex/dsh-vision-toolkit'
const BAKED = '/opt/dsh-plugins/node_modules/@anionex/dsh-vision-toolkit'
const LINK = join(PROFILE_DIR, 'node_modules/@anionex/dsh-vision-toolkit')

function readProfile() {
  try {
    return JSON.parse(readFileSync(PROFILE_PKG, 'utf8'))
  } catch {
    return {
      name: 'dsh-profile-web',
      private: true,
      dependencies: {},
      dsh: {
        profile: {
          bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'],
          patchReload: 'live',
        },
      },
    }
  }
}

const pkg = readProfile()
pkg.dependencies = pkg.dependencies ?? {}
pkg.dsh = pkg.dsh ?? {}
pkg.dsh.profile = pkg.dsh.profile ?? {}
const bundles = Array.isArray(pkg.dsh.profile.bundles) ? pkg.dsh.profile.bundles : []
if (!bundles.includes('@deepseek-ai/dsh-base')) bundles.unshift('@deepseek-ai/dsh-base')
if (!bundles.includes('@deepseek-ai/dsh-web-app')) {
  const at = bundles.indexOf('@deepseek-ai/dsh-base')
  bundles.splice(at + 1, 0, '@deepseek-ai/dsh-web-app')
}
if (!bundles.includes(BUNDLE)) bundles.push(BUNDLE)
pkg.dsh.profile.bundles = bundles
pkg.dependencies[BUNDLE] = pkg.dependencies[BUNDLE] ?? `file:${BAKED}`

mkdirSync(PROFILE_DIR, { recursive: true })
writeFileSync(PROFILE_PKG, `${JSON.stringify(pkg, null, 2)}\n`)

mkdirSync(dirname(LINK), { recursive: true })
try {
  unlinkSync(LINK)
} catch {
  // missing link
}
symlinkSync(BAKED, LINK)
console.log('dsh-entrypoint: vision-toolkit bundle linked into web profile')
spawnSync(process.execPath, ['/usr/local/bin/dsh-hide-vision-updates.mjs'], { stdio: 'inherit' })

