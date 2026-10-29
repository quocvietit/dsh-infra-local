/**
 * Patch the runtime image libs for a stable web token and Windows host-open.
 * Idempotent: skips a file that already contains the docker markers.
 */
import { chmodSync, readFileSync, writeFileSync } from 'node:fs'

function patch(path, apply) {
  const source = readFileSync(path, 'utf8')
  const next = apply(source)
  if (next === source) return
  try {
    writeFileSync(path, next)
  } catch {
    chmodSync(path, 0o644)
    writeFileSync(path, next)
  }
}

const connection = '/opt/dsh/packages/client/connection/lib/index.js'
patch(connection, (source) => {
  let next = source
  if (!next.includes('DSH_WEB_LAUNCH_TOKEN_FILE')) {
    if (!next.includes('from "node:fs"')) {
      next = next.replace(
        'import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";',
        'import { mkdirSync, readFileSync, writeFileSync } from "node:fs";\n'
        + 'import { dirname, join } from "node:path";\n'
        + 'import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";',
      )
    }
    const start = next.indexOf('function processLaunchToken(owner) {')
    const end = next.indexOf('function header(', start)
    if (start === -1 || end === -1) throw new Error('processLaunchToken not found')
    const replacement = `function isLaunchToken(value) {
	const decoded = decodeBase64Url(value);
	return decoded !== void 0 && decoded.byteLength === SECRET_BYTES;
}
function persistedLaunchTokenPath() {
	const explicit = process.env.DSH_WEB_LAUNCH_TOKEN_FILE;
	if (explicit !== void 0 && explicit !== "") return explicit;
	const home = process.env.DSH_HOME;
	if (home !== void 0 && home !== "") return join(home, ".web-launch-token");
}
function processLaunchToken(owner) {
	const existing = PROCESS_LAUNCH_TOKENS.get(owner);
	if (existing !== void 0) return existing;
	const fromEnv = process.env.DSH_WEB_LAUNCH_TOKEN?.trim();
	let token = fromEnv !== void 0 && isLaunchToken(fromEnv) ? fromEnv : void 0;
	const file = persistedLaunchTokenPath();
	if (token === void 0 && file !== void 0) {
		try {
			const stored = readFileSync(file, "utf8").trim();
			if (isLaunchToken(stored)) token = stored;
		} catch {}
	}
	if (token === void 0) token = encodeBase64Url(randomBytes(SECRET_BYTES));
	if (file !== void 0) {
		try {
			mkdirSync(dirname(file), { recursive: true });
			writeFileSync(file, \`\${token}\\n\`, { encoding: "utf8", mode: 384 });
		} catch {}
	}
	PROCESS_LAUNCH_TOKENS.set(owner, token);
	return token;
}
`
    next = `${next.slice(0, start)}${replacement}${next.slice(end)}`
  }

  const oldAutoAuth = 'const authority = requestAudience(req.headers, secure);\n\t\tif (authority !== void 0) {'
  if (next.includes(oldAutoAuth)) {
    next = next.replace(oldAutoAuth, 'const authority = requestAudience(req.headers, secure) ?? (url.host || "127.0.0.1:3080");\n\t\tif (true) {')
  }

  const authTarget = 'if (this.isAuthenticated(req, secure)) return true;\n\t\tthis.writeUnauthorized(req, res);\n\t\treturn false;'
  if (next.includes(authTarget) && !next.includes('auto-login on plain index')) {
    const autoAuth = `if (this.isAuthenticated(req, secure)) return true;
		/* auto-login on plain index without token */
		const authority = requestAudience(req.headers, secure) ?? (url.host || "127.0.0.1:3080");
		const issuedAt = Date.now();
		const expiresAt = issuedAt + this.maxAgeMilliseconds;
		const value = encodeCookie({
			version: COOKIE_PAYLOAD_VERSION,
			authority,
			issuedAt,
			expiresAt
		}, this.secret);
		res.writeHead(303, {
			"cache-control": "no-store",
			"location": "./",
			"referrer-policy": "no-referrer",
			"set-cookie": sessionCookie(cookieName(authority), value, expiresAt, Math.floor(this.maxAgeMilliseconds / 1e3), secure)
		});
		res.end();
		return false;
		this.writeUnauthorized(req, res);
		return false;`
    next = next.replace(authTarget, autoAuth)
  }

  const rpcBroken = '() => owner.webServer.register(route)'
  const rpcFixed = "() => owner.get('webServer').register(route)"
  if (next.includes(rpcBroken) && !next.includes(rpcFixed)) {
    next = next.replace(rpcBroken, rpcFixed)
  }

  return next
})

const native = '/opt/dsh/packages/util/native-command/lib/index.js'
patch(native, (source) => {
  if (source.includes('DSH_HOST_OPEN_QUEUE')) return source
  let next = source
  if (!next.includes('from "node:fs"')) {
    next = next.replace(
      'import { release } from "node:os";',
      'import { writeFileSync } from "node:fs";\nimport { release } from "node:os";',
    )
  }
  const helpers = `
function hostOpenQueue(env) {
	const queue = env.DSH_HOST_OPEN_QUEUE;
	return queue !== void 0 && queue !== "" ? queue : void 0;
}
function mapDockerPathToHost(containerPath, env) {
	const map = env.DSH_HOST_PATH_MAP;
	if (map === void 0 || map === "") return containerPath;
	let bestFrom = "";
	let bestTo = "";
	for (const raw of map.split(";")) {
		const entry = raw.trim();
		const at = entry.indexOf("=");
		if (at <= 0) continue;
		const from = entry.slice(0, at);
		const to = entry.slice(at + 1);
		if (containerPath === from || containerPath.startsWith(\`\${from}/\`)) {
			if (from.length >= bestFrom.length) {
				bestFrom = from;
				bestTo = to;
			}
		}
	}
	if (bestFrom === "") return containerPath;
	const rest = containerPath.slice(bestFrom.length).replaceAll("/", "\\\\");
	const base = bestTo.replace(/[/\\\\]+$/u, "").replaceAll("/", "\\\\");
	return rest === "" ? base : \`\${base}\${rest}\`;
}
function openViaDockerHost(containerPath, action, signal, env) {
	const queue = hostOpenQueue(env);
	if (queue === void 0) return Promise.resolve(false);
	signal.throwIfAborted();
	writeFileSync(queue, \`\${JSON.stringify({ path: mapDockerPathToHost(containerPath, env), action, at: Date.now() })}\\n\`, { encoding: "utf8" });
	return Promise.resolve(true);
}
`
  const marker = 'function canOpenNativePath(internals = {}) {'
  const at = next.indexOf(marker)
  if (at === -1) throw new Error('canOpenNativePath not found')
  next = `${next.slice(0, at)}${helpers}${next.slice(at)}`
  next = next.replace(
    'return isWsl(internals) || present(env.DISPLAY) || present(env.WAYLAND_DISPLAY);',
    'return isWsl(internals) || present(env.DISPLAY) || present(env.WAYLAND_DISPLAY) || hostOpenQueue(env) !== void 0;',
  )
  next = next.replace(
    'if (platform === "win32" || platform === "linux" && isWsl(internals)) return "explorer";\n	return platform === "linux" ? "directory" : null;',
    'if (platform === "win32" || platform === "linux" && isWsl(internals)) return "explorer";\n	if (hostOpenQueue(internals.env ?? process.env) !== void 0) return "explorer";\n	return platform === "linux" ? "directory" : null;',
  )
  next = next.replace(
    'const wsl = platform === "linux" && isWsl(internals);\n	if (!wsl && intent === "default"',
    'const wsl = platform === "linux" && isWsl(internals);\n	if (await openViaDockerHost(path, "open", signal, env)) return;\n	if (!wsl && intent === "default"',
  )
  if (!next.includes('openViaDockerHost(path, "open"')) {
    throw new Error('failed to patch openNativePathWithIntent')
  }
  next = next.replace(
    'async function revealNativePath(path, signal, internals = {}) {\n	signal.throwIfAborted();\n	const platform = internals.platform ?? process.platform;\n	const run = internals.run ?? runNativeCommand;\n	const manager = nativeFileManager({',
    'async function revealNativePath(path, signal, internals = {}) {\n	signal.throwIfAborted();\n	const platform = internals.platform ?? process.platform;\n	const run = internals.run ?? runNativeCommand;\n	const env = internals.env ?? process.env;\n	if (await openViaDockerHost(path, "reveal", signal, env)) return;\n	const manager = nativeFileManager({',
  )
  if (!next.includes('openViaDockerHost(path, "reveal"')) {
    throw new Error('failed to patch revealNativePath')
  }
  return next
})

// `dsh web` loads this TypeScript source via tsx (not lib/index.js). Docker
// Desktop bind mounts reject chmod with EPERM, which fails every upload.
const attachmentStore = '/opt/dsh/packages/attachment/attachment-local/src/store.ts'
patch(attachmentStore, (source) => {
  if (source.includes('chmodIfSupported')) return source
  const importLine = "import { dirname, join, parse, resolve } from 'node:path'\n"
  if (!source.includes(importLine)) throw new Error('attachment store import anchor not found')
  const helper = `
async function chmodIfSupported(path: string, mode: number): Promise<void> {
  try {
    await chmod(path, mode)
  } catch (error) {
    if (error instanceof Error && 'code' in error && (error.code === 'EPERM' || error.code === 'EACCES' || error.code === 'ENOTSUP')) return
    throw error
  }
}
`
  const next = source.replaceAll('await chmod(target,', 'await chmodIfSupported(target,')
  return next.replace(importLine, `${importLine}${helper}`)
})

// Same reason: the web launch token lives in src/browser-auth.ts at runtime.
const browserAuth = '/opt/dsh/packages/client/connection/src/browser-auth.ts'
patch(browserAuth, (source) => {
  if (source.includes('DSH_WEB_LAUNCH_TOKEN_FILE')) return source
  const nodeImport = "import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto'\n"
  const start = source.indexOf('function processLaunchToken(owner: object): string {')
  const end = source.indexOf('function header(', start)
  if (!source.includes(nodeImport) || start === -1 || end === -1) {
    throw new Error('browser-auth launch token anchors not found')
  }
  const replacement = String.raw`function persistedLaunchTokenPath(): string | undefined {
  const explicit = process.env.DSH_WEB_LAUNCH_TOKEN_FILE
  if (explicit !== undefined && explicit !== '') return explicit
  const home = process.env.DSH_HOME
  if (home !== undefined && home !== '') return join(home, '.web-launch-token')
  return undefined
}

function isLaunchToken(value: string): boolean {
  const decoded = decodeBase64Url(value)
  return decoded !== undefined && decoded.byteLength === SECRET_BYTES
}

function processLaunchToken(owner: object): string {
  const existing = PROCESS_LAUNCH_TOKENS.get(owner)
  if (existing !== undefined) return existing
  const fromEnv = process.env.DSH_WEB_LAUNCH_TOKEN?.trim()
  let token = fromEnv !== undefined && isLaunchToken(fromEnv) ? fromEnv : undefined
  const file = persistedLaunchTokenPath()
  if (token === undefined && file !== undefined) {
    try {
      const stored = readFileSync(file, 'utf8').trim()
      if (isLaunchToken(stored)) token = stored
    } catch {}
  }
  if (token === undefined) token = encodeBase64Url(randomBytes(SECRET_BYTES))
  if (file !== undefined) {
    try {
      mkdirSync(dirname(file), { recursive: true })
      writeFileSync(file, token + '\n', { encoding: 'utf8', mode: 0o600 })
    } catch {}
  }
  PROCESS_LAUNCH_TOKENS.set(owner, token)
  return token
}

`
  const imports = nodeImport
    + "import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'\n"
    + "import { dirname, join } from 'node:path'\n"
  return (source.slice(0, start) + replacement + source.slice(end)).replace(nodeImport, imports)
})

// Plugin RPC 405: Context.webServer is not injected on the reader scope, so
// connection.rpc.handle() never registers /dsh-mnemon-* (and other plugin
// channels). POSTs fall through to the SPA and return 405 ("Mnemon is not ready").
// https://github.com/deepseek-ai/deepseek-harness/discussions/6179
const rpcHost = '/opt/dsh/packages/client/connection/src/rpc-host.ts'
patch(rpcHost, (source) => {
  const broken = '() => owner.webServer.register(route)'
  const fixed = "() => owner.get('webServer').register(route)"
  if (!source.includes(broken) || source.includes(fixed)) return source
  return source.replace(broken, fixed)
})

console.log('dsh-entrypoint: patched web token + host-open + attachment chmod + plugin rpc webServer')
