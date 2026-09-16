/**
 * Patch the runtime image libs for a stable web token and Windows host-open.
 * Idempotent: skips a file that already contains the docker markers.
 */
import { readFileSync, writeFileSync } from 'node:fs'

function patch(path, apply) {
  const source = readFileSync(path, 'utf8')
  const next = apply(source)
  if (next !== source) writeFileSync(path, next)
}

const connection = '/opt/dsh/packages/client/connection/lib/index.js'
patch(connection, (source) => {
  if (source.includes('DSH_WEB_LAUNCH_TOKEN_FILE')) return source
  let next = source
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
  return `${next.slice(0, start)}${replacement}${next.slice(end)}`
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

console.log('dsh-entrypoint: patched web token + host-open')
