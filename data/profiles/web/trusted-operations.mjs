/**
 * Cordis Plugin: Auto-approve allowlisted operations; deny dangerous operations.
 * Remaining approval requests go to the UI.
 * Policy file: /data/policies/trusted-operations.yml
 */

import { readFileSync } from 'node:fs'

export const name = 'trusted-operations'

const POLICY_PATH = process.env.DSH_TRUSTED_OPERATIONS
  ?? '/data/policies/trusted-operations.yml'

const DEFAULT_POLICY = {
  filesystemAllow: ['read', 'glob', 'grep'],
  pathAllowPrefixes: [
    '/workspace',
    '/data/runs',
    '/data/policies',
    '/data/projects',
    '/data/schemas',
    '/data/skills',
    '/data/workflows',
    '/home/node',
  ],
  bashAllow: [
    'ls', 'dir', 'pwd', 'cat', 'head', 'tail', 'find', 'wc', 'file', 'stat',
    'python', 'python3', 'pip', 'pip3',
  ],
  bashDeny: [
    'sudo', 'git push', 'curl', 'wget', 'chmod', 'chown', 'rm -rf /', 'mkfs', 'dd if=',
  ],
}

function parseSimpleYaml(text) {
  const result = {
    filesystemAllow: [],
    pathAllowPrefixes: [],
    bashAllow: [],
    bashDeny: [],
  }
  let current = null
  for (const raw of text.split(/\r?\n/)) {
    const trimmed = raw.replace(/#.*$/, '').trimEnd().trim()
    if (trimmed === '') continue
    const keyMatch = trimmed.match(/^([A-Za-z][A-Za-z0-9_]*):\s*$/)
    const keyName = keyMatch?.[1]
    if (keyName !== undefined && keyName in result) {
      current = keyName
      continue
    }
    const itemMatch = trimmed.match(/^-\s+(.+)$/)
    const itemValue = itemMatch?.[1]
    if (itemValue !== undefined && current !== null) {
      result[current].push(itemValue.trim())
    }
  }
  for (const key of Object.keys(result)) {
    if (result[key].length === 0) result[key] = DEFAULT_POLICY[key]
  }
  return result
}

function loadPolicy() {
  try {
    return parseSimpleYaml(readFileSync(POLICY_PATH, 'utf8'))
  } catch {
    return DEFAULT_POLICY
  }
}

function pathAllowed(path, prefixes) {
  if (!path || path.trim() === '') return false
  const normalized = path.replace(/\\/g, '/')
  return prefixes.some(prefix => normalized === prefix || normalized.startsWith(`${prefix}/`))
}

function firstPathArg(args) {
  return args.path ?? args.file ?? args.target ?? args.pattern
}

function splitShellSegments(command) {
  return command.split(/(?:&&|\|\||;|\n)/).map(part => part.trim()).filter(Boolean)
}

function leadingToken(segment) {
  const cleaned = segment.replace(/^cd\s+\S+\s*(?:&&|;)\s*/i, '').trim()
  const match = cleaned.match(/^([A-Za-z0-9._+-]+)/)
  return match?.[1]?.toLowerCase() ?? ''
}

function classifyBash(command, policy) {
  const raw = String(command || '')
  const lower = raw.toLowerCase()
  for (const denied of policy.bashDeny) {
    if (lower.includes(denied.toLowerCase())) return 'deny'
  }
  if (/^\s*cd\s+\S+\s*$/i.test(raw)) return 'allow'
  const segments = splitShellSegments(raw)
  if (segments.length === 0) return 'ask'
  for (const segment of segments) {
    if (/^\s*cd\s+/i.test(segment) && !/(?:&&|;)/.test(segment) && segments.length > 1) continue
    const token = leadingToken(segment)
    if (token === 'cd') continue
    if (!policy.bashAllow.includes(token)) return 'ask'
    if (token === 'python' || token === 'python3') {
      const pyPath = segment.match(/((?:\/|\.\/)[^\s]+\.py)\b/)?.[1]
      if (pyPath !== undefined && !pathAllowed(pyPath, policy.pathAllowPrefixes)) return 'ask'
    }
  }
  return 'allow'
}

function classifyExec(name, args, policy) {
  const toolName = String(name || '')
  const record = args !== null && typeof args === 'object' && !Array.isArray(args)
    ? args
    : {}
  if (policy.filesystemAllow.includes(toolName)) {
    const path = firstPathArg(record)
    if (path === undefined) return 'allow'
    return pathAllowed(String(path), policy.pathAllowPrefixes) ? 'allow' : 'ask'
  }
  if (toolName === 'bash' || toolName === 'pwsh') {
    return classifyBash(String(record.command ?? ''), policy)
  }
  return 'ask'
}

export function apply(ctx) {
  const policy = loadPolicy()
  const pending = new Map()
  console.log(`[trusted-operations] plugin loaded with policy from ${POLICY_PATH}`)

  ctx.on('tools/pre-execute', async (exec, next) => {
    try {
      if (exec?.callId !== undefined) {
        pending.set(String(exec.callId), { name: exec.name, arguments: exec.arguments })
      }
      if (classifyExec(exec.name, exec.arguments, policy) === 'deny') {
        return { kind: 'deny', reason: 'Denied by trusted-operations policy.' }
      }
    } catch (error) {
      console.warn(`[trusted-operations] pre-execute classify failed: ${String(error)}`)
    }
    return next()
  })

  ctx.on('approval/request', async (req, next) => {
    try {
      const call = req.callId === undefined ? undefined : pending.get(String(req.callId))
      const verdict = classifyExec(
        call?.name ?? req.toolName,
        call?.arguments ?? {},
        policy,
      )
      if (verdict === 'allow') return 'allowed-once'
      if (verdict === 'deny') return 'rejected'
    } catch (error) {
      console.warn(`[trusted-operations] approval classify failed: ${String(error)}`)
    }
    return next()
  }, { prepend: true })
}
