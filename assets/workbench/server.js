'use strict';

const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { chmod, lstat, mkdtemp, readFile, rm, writeFile } = require('node:fs/promises');
const os = require('node:os');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);
const host = '127.0.0.1';
const port = Number.parseInt(process.env.PORT || '4173', 10);
const publicRoot = path.join(__dirname, 'public');
const lucideBundle = path.join(publicRoot, 'vendor', 'lucide.min.js');
const powershell = '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';
const windowsStateScript = path.join(__dirname, 'scripts', 'Get-WindowsNetworkState.ps1');
const windowsManagerScript = 'C:\\Users\\__WINDOWS_USER__\\.wsl-server\\Configure-WslSshLan.ps1';
const windowsTerminal = '/mnt/c/Users/__WINDOWS_USER__/AppData/Local/Microsoft/WindowsApps/wt.exe';
const windowsWsl = 'C:\\Windows\\System32\\wsl.exe';
const healthCheckScript = path.join(__dirname, 'scripts', 'health-check.js');
const publicKeyScript = path.join(__dirname, 'scripts', 'add-ssh-public-key.sh');
const authorizedKeysPath = path.join(os.homedir(), '.ssh', 'authorized_keys');
const webuiRegistryPath = process.env.WEBUI_REGISTRY_PATH
  || path.join(os.homedir(), 'wsl-server', 'apps', 'registry.json');
const publicKeyMaxBytes = 16 * 1024;
const publicKeyRequestMaxBytes = 24 * 1024;
const authorizedKeysMaxBytes = 64 * 1024;
const supportedPublicKeyAlgorithms = new Set([
  'ssh-ed25519',
  'ssh-rsa',
  'ecdsa-sha2-nistp256',
  'ecdsa-sha2-nistp384',
  'ecdsa-sha2-nistp521',
  'sk-ssh-ed25519@openssh.com',
  'sk-ecdsa-sha2-nistp256@openssh.com'
]);
const stateRoot = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
const healthHistoryPath = path.join(stateRoot, 'wsl-server-workbench', 'health-history.jsonl');
const windowsStateCache = { expiresAt: 0, pending: null, value: null };
let publicKeyEnrollmentQueue = Promise.resolve();

const mimeTypes = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml'
};

function run(file, args, options = {}) {
  return execFileAsync(file, args, {
    timeout: options.timeout || 8000,
    maxBuffer: 1024 * 1024,
    windowsHide: true,
    ...(options.cwd ? { cwd: options.cwd } : {}),
    ...(options.env ? { env: options.env } : {})
  });
}

async function runText(file, args, options) {
  const { stdout } = await run(file, args, options);
  return stdout.trim();
}

async function attempt(task, fallback) {
  try {
    return await task();
  } catch {
    return fallback;
  }
}

function parseSshConfig(text) {
  const config = {};
  for (const line of text.split('\n')) {
    const match = line.trim().match(/^(\S+)\s+(.+)$/);
    if (match) config[match[1].toLowerCase()] = match[2].trim();
  }
  return {
    allowUsers: config.allowusers?.split(/\s+/) || [],
    passwordAuthentication: config.passwordauthentication === 'yes',
    permitRootLogin: config.permitrootlogin || 'unknown',
    publicKeyAuthentication: config.pubkeyauthentication === 'yes'
  };
}

function parseResolver(text) {
  const nameservers = [];
  let search = [];
  for (const line of text.split('\n')) {
    const clean = line.trim();
    if (clean.startsWith('nameserver ')) nameservers.push(clean.split(/\s+/)[1]);
    if (clean.startsWith('search ')) search = clean.split(/\s+/).slice(1);
  }
  return { nameservers, search };
}

function isValidGatewayHostname(value) {
  return typeof value === 'string'
    && value.length <= 253
    && value !== 'localhost'
    && net.isIP(value) === 0
    && /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(value);
}

async function getWebuiApplications() {
  const registry = JSON.parse(await readFile(webuiRegistryPath, 'utf8'));
  if (!Array.isArray(registry.apps)) return [];
  const rootGateway = registry?.gateway?.listen;
  let rootGatewayPort = null;
  if (registry.gateway !== undefined) {
    if (rootGateway?.host !== '127.0.0.1' || !Number.isInteger(rootGateway?.port)
      || rootGateway.port < 1024 || rootGateway.port > 65535) return [];
    rootGatewayPort = rootGateway.port;
  }

  return registry.apps.flatMap((app) => {
    const gateway = app?.gateway;
    const hostname = gateway?.hostname;
    const windowsPort = gateway?.windows_listen_port;
    const wslListenMatch = /^127\.0\.0\.1:([0-9]+)$/.exec(gateway?.wsl_listen || '');
    const wslPort = wslListenMatch ? Number(wslListenMatch[1]) : null;
    if (app?.enabled !== true || !isValidGatewayHostname(hostname)
      || !Number.isInteger(windowsPort) || windowsPort < 1 || windowsPort > 65535
      || gateway?.tls !== 'internal-ca' || gateway?.authentication !== 'basic'
      || !Number.isInteger(wslPort) || wslPort < 1024 || wslPort > 65535
      || (rootGatewayPort !== null && wslPort !== rootGatewayPort)) {
      return [];
    }
    const portSuffix = windowsPort === 443 ? '' : `:${windowsPort}`;
    return [{
      id: String(app.id || ''),
      displayName: String(app.display_name || app.id || hostname),
      version: typeof app.version === 'string' ? app.version : null,
      url: `https://${hostname}${portSuffix}/`,
      authentication: typeof gateway.authentication === 'string'
        ? gateway.authentication
        : null,
      tls: typeof gateway.tls === 'string' ? gateway.tls : null
    }];
  });
}

async function getWindowsState() {
  if (windowsStateCache.value && Date.now() < windowsStateCache.expiresAt) {
    return windowsStateCache.value;
  }
  if (windowsStateCache.pending) return windowsStateCache.pending;

  windowsStateCache.pending = readWindowsState();
  try {
    const value = await windowsStateCache.pending;
    windowsStateCache.value = value;
    windowsStateCache.expiresAt = Date.now() + 15000;
    return value;
  } finally {
    windowsStateCache.pending = null;
  }
}

async function readWindowsState() {
  const output = await runText(powershell, [
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', windowsStateScript
  ], { timeout: 12000 });
  return JSON.parse(output);
}

async function getOverview() {
  const [
    sshStatus,
    sshSocket,
    dockerStatus,
    addressesRaw,
    routeRaw,
    resolverRaw,
    sshConfigRaw,
    windows,
    applications
  ] = await Promise.all([
    attempt(() => runText('systemctl', ['is-active', 'ssh']), 'unknown'),
    attempt(() => runText('systemctl', ['is-enabled', 'ssh.socket']), 'unknown'),
    attempt(() => runText('systemctl', ['is-active', 'docker']), 'unavailable'),
    attempt(() => runText('ip', ['-j', '-4', 'address', 'show', 'eth0']), '[]'),
    attempt(() => runText('ip', ['-j', '-4', 'route', 'show', 'default']), '[]'),
    attempt(() => readFile('/etc/resolv.conf', 'utf8'), ''),
    attempt(() => readFile('/etc/ssh/sshd_config.d/99-server.conf', 'utf8'), ''),
    attempt(() => getWindowsState(), {
      error: 'Windows state unavailable',
      interfaces: [],
      portProxy: null,
      firewall: null,
      startupTask: null
    }),
    attempt(() => getWebuiApplications(), [])
  ]);

  const addressData = JSON.parse(addressesRaw);
  const routeData = JSON.parse(routeRaw);
  const eth0 = addressData[0] || {};
  const ipv4 = (eth0.addr_info || [])
    .filter((item) => item.family === 'inet')
    .map((item) => ({ address: item.local, prefix: item.prefixlen }));

  return {
    generatedAt: new Date().toISOString(),
    hostname: await attempt(() => runText('hostname', []), 'unknown'),
    network: {
      defaultRoute: routeData[0]?.gateway || null,
      interface: eth0.ifname || 'eth0',
      ipv4,
      mode: routeData.length ? 'NAT' : 'offline',
      resolver: parseResolver(resolverRaw)
    },
    services: {
      docker: dockerStatus,
      ssh: sshStatus,
      sshSocket
    },
    sshPolicy: parseSshConfig(sshConfigRaw),
    windows,
    applications
  };
}

function parseSshEvent(entry) {
  const message = entry.MESSAGE || '';
  const timestamp = Number(entry.__REALTIME_TIMESTAMP || 0) / 1000;
  let match = message.match(/^Accepted (\S+) for (\S+) from (\S+) port (\d+)/);
  if (match) {
    return {
      timestamp,
      status: 'success',
      method: match[1],
      user: match[2],
      address: match[3],
      port: Number(match[4]),
      message: 'Login accepted'
    };
  }

  match = message.match(/^Failed (\S+) for (?:invalid user )?(\S+) from (\S+) port (\d+)/);
  if (match) {
    return {
      timestamp,
      status: 'failed',
      method: match[1],
      user: match[2],
      address: match[3],
      port: Number(match[4]),
      message: 'Login rejected'
    };
  }

  match = message.match(/^User (\S+) from (\S+) not allowed/);
  if (match) {
    return {
      timestamp,
      status: 'blocked',
      method: 'policy',
      user: match[1],
      address: match[2],
      port: null,
      message: 'User blocked by policy'
    };
  }

  match = message.match(/^Invalid user (\S+) from (\S+) port (\d+)/);
  if (match) {
    return {
      timestamp,
      status: 'blocked',
      method: 'invalid-user',
      user: match[1],
      address: match[2],
      port: Number(match[3]),
      message: 'Invalid user'
    };
  }

  return null;
}

async function getLogs(hours) {
  const output = await runText('journalctl', [
    '-u', 'ssh',
    '--since', `${hours} hours ago`,
    '--no-pager',
    '-o', 'json',
    '-n', '500'
  ], { timeout: 10000 });

  const events = output
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      try {
        return parseSshEvent(JSON.parse(line));
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .reverse()
    .slice(0, 150);

  const summary = { success: 0, failed: 0, blocked: 0 };
  for (const event of events) summary[event.status] += 1;
  return { events, hours, summary };
}

async function getHealthHistory(limit) {
  let content;
  try {
    content = await readFile(healthHistoryPath, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return { entries: [] };
    throw error;
  }
  const entries = content
    .split('\n')
    .filter(Boolean)
    .slice(-limit)
    .map((line) => JSON.parse(line))
    .reverse();
  return { entries };
}

async function runHealthCheck() {
  const output = await runText(process.execPath, [healthCheckScript], { timeout: 35000 });
  return JSON.parse(output.split('\n').filter(Boolean).at(-1));
}

function sendJson(response, status, value) {
  response.writeHead(status, {
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
    'X-Content-Type-Options': 'nosniff'
  });
  response.end(JSON.stringify(value));
}

function requestError(status, message) {
  const error = new Error(message);
  error.statusCode = status;
  return error;
}

function isLoopbackHost(value) {
  const match = value.match(/^(127\.0\.0\.1|localhost)(?::(\d+))?$/i);
  return Boolean(match) && (!match[2] || Number.parseInt(match[2], 10) === port);
}

function isLoopbackOrigin(value) {
  if (!value) return true;
  try {
    const origin = new URL(value);
    return origin.protocol === 'http:'
      && (origin.hostname === '127.0.0.1' || origin.hostname === 'localhost')
      && Boolean(origin.port)
      && Number.parseInt(origin.port, 10) === port;
  } catch {
    return false;
  }
}

function validActionRequest(request) {
  const hostHeader = request.headers.host || '';
  const remoteAddress = request.socket.remoteAddress || '';
  const origin = request.headers.origin || '';
  return request.headers['x-workbench-action'] === 'confirm'
    && (remoteAddress === '127.0.0.1' || remoteAddress === '::1' || remoteAddress === '::ffff:127.0.0.1')
    && isLoopbackHost(hostHeader)
    && isLoopbackOrigin(origin);
}

async function readJsonBody(request, maxBytes = 4096) {
  const declaredLength = Number.parseInt(request.headers['content-length'] || '', 10);
  if (Number.isInteger(declaredLength) && declaredLength > maxBytes) {
    throw requestError(413, 'Request body too large');
  }
  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    totalBytes += buffer.length;
    if (totalBytes > maxBytes) throw requestError(413, 'Request body too large');
    chunks.push(buffer);
  }
  const body = Buffer.concat(chunks).toString('utf8');
  if (!body) return {};
  try {
    return JSON.parse(body);
  } catch {
    throw requestError(400, 'Invalid JSON body');
  }
}

function normalizePublicKey(value) {
  if (typeof value !== 'string') throw requestError(400, 'Public key must be a string');
  if (Buffer.byteLength(value, 'utf8') === 0) throw requestError(400, 'Public key is empty');
  if (Buffer.byteLength(value, 'utf8') > publicKeyMaxBytes) {
    throw requestError(413, 'Public key is too large');
  }
  if (value.includes('\0') || /-----BEGIN [^-]*PRIVATE KEY-----/i.test(value)) {
    throw requestError(400, 'Private keys are not accepted');
  }
  for (const character of value) {
    const code = character.codePointAt(0);
    if ((code < 32 && code !== 9 && code !== 10 && code !== 13) || code === 127) {
      throw requestError(400, 'Public key contains unsupported control characters');
    }
  }

  const normalized = value.replace(/\r\n/g, '\n');
  if (normalized.includes('\r')) throw requestError(400, 'Public key must use normal line endings');
  const keyLines = normalized.split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  if (keyLines.length !== 1) {
    throw requestError(400, 'Provide exactly one non-comment OpenSSH public-key line');
  }
  const keyLine = keyLines[0];
  const match = keyLine.match(/^([^\s]+)[ \t]+([A-Za-z0-9+/=]+)(?:[ \t]+.*)?$/);
  if (!match || !supportedPublicKeyAlgorithms.has(match[1])) {
    throw requestError(400, 'Unsupported or malformed OpenSSH public key');
  }
  return { keyLine, algorithm: match[1] };
}

async function fingerprintPublicKey(keyLine) {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'wsl-public-key-'));
  const keyPath = path.join(tempDir, 'key.pub');
  try {
    await chmod(tempDir, 0o700);
    await writeFile(keyPath, `${keyLine}\n`, { mode: 0o600 });
    let output;
    try {
      output = await runText('ssh-keygen', ['-lf', keyPath], { timeout: 5000 });
    } catch {
      throw requestError(400, 'Public key could not be parsed');
    }
    const fingerprint = output.split(/\s+/)[1] || '';
    if (!/^SHA256:[A-Za-z0-9+/=]+$/.test(fingerprint)) {
      throw requestError(400, 'Public key fingerprint could not be calculated');
    }
    return fingerprint;
  } finally {
    await rm(tempDir, { recursive: true, force: true }).catch(() => {});
  }
}

function parseAuthorizedKeyOutput(output) {
  const typeMap = {
    ED25519: 'ssh-ed25519',
    RSA: 'ssh-rsa',
    ECDSA: 'ecdsa-sha2',
    'ED25519-SK': 'sk-ssh-ed25519@openssh.com',
    'ECDSA-SK': 'sk-ecdsa-sha2-nistp256@openssh.com'
  };
  const seen = new Set();
  return output.split('\n').map((line) => {
    const fields = line.trim().split(/\s+/);
    const fingerprint = fields[1] || '';
    const type = line.match(/\(([^()]+)\)\s*$/)?.[1] || 'unknown';
    if (!/^SHA256:[A-Za-z0-9+/=]+$/.test(fingerprint) || seen.has(fingerprint)) return null;
    seen.add(fingerprint);
    return { fingerprint, algorithm: typeMap[type] || type.toLowerCase() };
  }).filter(Boolean);
}

async function getPublicKeys() {
  let output = '';
  try {
    const info = await lstat(authorizedKeysPath);
    if (!info.isFile() || info.isSymbolicLink()) {
      throw requestError(409, 'The authorized-keys path must be a regular file');
    }
    if (info.size === 0) return { count: 0, keys: [] };
  } catch (error) {
    if (error.code === 'ENOENT') return { count: 0, keys: [] };
    throw error;
  }
  try {
    output = await runText('ssh-keygen', ['-lf', authorizedKeysPath], { timeout: 5000 });
  } catch (error) {
    output = String(error.stdout || '');
    if (!output && /is not a public key file/i.test(String(error.stderr || ''))) {
      return { count: 0, keys: [] };
    }
    if (!output) throw error;
  }
  const keys = parseAuthorizedKeyOutput(output);
  return { count: keys.length, keys };
}

async function hasPublicKey(fingerprint) {
  const keys = await getPublicKeys();
  return keys.keys.some((item) => item.fingerprint === fingerprint);
}

async function checkAuthorizedKeysCapacity(keyLine) {
  let info;
  try {
    info = await lstat(authorizedKeysPath);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw requestError(409, 'The authorized-keys file cannot be inspected');
  }
  if (!info.isFile() || info.isSymbolicLink()) {
    throw requestError(409, 'The authorized-keys path must be a regular file');
  }
  if (info.size + Buffer.byteLength(keyLine, 'utf8') + 1 > authorizedKeysMaxBytes) {
    throw requestError(413, 'The authorized-keys file is full');
  }
}

function queuePublicKeyEnrollment(task) {
  const operation = publicKeyEnrollmentQueue.then(task, task);
  publicKeyEnrollmentQueue = operation.catch(() => {});
  return operation;
}

function logPublicKeyEnrollment(request, result, algorithm, fingerprint) {
  const record = {
    event: 'public-key-enrollment',
    timestamp: new Date().toISOString(),
    result,
    algorithm,
    fingerprint,
    remoteAddress: request.socket.remoteAddress || 'unknown'
  };
  const line = JSON.stringify(record);
  if (result === 'failed') console.error(line);
  else console.info(line);
}

async function enrollPublicKey(keyLine, fingerprint) {
  return queuePublicKeyEnrollment(async () => {
    const alreadyAuthorized = await hasPublicKey(fingerprint);
    if (!alreadyAuthorized) await checkAuthorizedKeysCapacity(keyLine);
    const tempDir = await mkdtemp(path.join(os.tmpdir(), 'wsl-public-key-'));
    const keyPath = path.join(tempDir, 'key.pub');
    try {
      await chmod(tempDir, 0o700);
      await writeFile(keyPath, `${keyLine}\n`, { mode: 0o600 });
      let scriptOutput = '';
      try {
        const environment = { ...process.env, HOME: os.homedir(), AUTHORIZED_KEYS_FILE: authorizedKeysPath };
        const result = await run('/bin/bash', [publicKeyScript, keyPath], { timeout: 10000, env: environment });
        scriptOutput = result.stdout || '';
      } catch {
        throw requestError(500, 'Public-key enrollment failed; check the workbench log');
      }
      if (!await hasPublicKey(fingerprint)) {
        throw requestError(500, 'Public-key enrollment could not be verified');
      }
      return {
        result: alreadyAuthorized || /Key already authorized:/.test(scriptOutput) ? 'already-authorized' : 'added',
        fingerprint
      };
    } finally {
      await rm(tempDir, { recursive: true, force: true }).catch(() => {});
    }
  });
}

async function launchPasswordTerminal() {
  await run(windowsTerminal, [
    'new-tab',
    '--title', 'Change WSL password',
    windowsWsl,
    '-d', '__DISTRO__',
    '--', 'passwd', '__WSL_USER__'
  ], { timeout: 5000 });
}

async function launchPortManager(portValue, disable) {
  const scriptArgs = disable
    ? `'-NoProfile','-ExecutionPolicy','Bypass','-File','${windowsManagerScript}','-Distro','__DISTRO__','-Disable'`
    : `'-NoProfile','-ExecutionPolicy','Bypass','-File','${windowsManagerScript}','-Distro','__DISTRO__','-ListenPort','${portValue}'`;
  const command = [
    `Start-Process -FilePath 'powershell.exe'`,
    `-Verb RunAs`,
    `-ArgumentList @(${scriptArgs})`
  ].join(' ');
  await run(powershell, ['-NoProfile', '-Command', command], { timeout: 5000 });
}

async function serveStatic(request, response, pathname) {
  if (pathname === '/vendor/lucide.js') {
    const content = await readFile(lucideBundle);
    response.writeHead(200, {
      'Cache-Control': 'public, max-age=86400',
      'Content-Type': 'text/javascript; charset=utf-8',
      'X-Content-Type-Options': 'nosniff'
    });
    response.end(content);
    return;
  }
  const relative = pathname === '/' ? 'index.html' : pathname.replace(/^\//, '');
  const filePath = path.resolve(publicRoot, relative);
  if (!filePath.startsWith(`${publicRoot}${path.sep}`)) {
    response.writeHead(403).end('Forbidden');
    return;
  }
  try {
    const content = await readFile(filePath);
    response.writeHead(200, {
      'Cache-Control': 'no-cache',
      'Content-Type': mimeTypes[path.extname(filePath)] || 'application/octet-stream',
      'X-Content-Type-Options': 'nosniff'
    });
    response.end(content);
  } catch {
    response.writeHead(404).end('Not found');
  }
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || host}`);
  try {
    if (request.method === 'GET' && url.pathname === '/api/overview') {
      sendJson(response, 200, await getOverview());
      return;
    }
    if (request.method === 'GET' && url.pathname === '/api/logs') {
      const requestedHours = Number.parseInt(url.searchParams.get('hours') || '24', 10);
      const hours = [1, 6, 24, 168].includes(requestedHours) ? requestedHours : 24;
      sendJson(response, 200, await getLogs(hours));
      return;
    }
    if (request.method === 'GET' && url.pathname === '/api/health') {
      const requestedLimit = Number.parseInt(url.searchParams.get('limit') || '24', 10);
      const limit = Number.isInteger(requestedLimit) ? Math.min(Math.max(requestedLimit, 1), 288) : 24;
      sendJson(response, 200, await getHealthHistory(limit));
      return;
    }
    if (request.method === 'GET' && url.pathname === '/api/keys') {
      sendJson(response, 200, await getPublicKeys());
      return;
    }
    if (request.method === 'POST' && url.pathname.startsWith('/api/actions/')) {
      if (!validActionRequest(request)) {
        sendJson(response, 403, { error: 'Local action confirmation missing' });
        return;
      }
      const isPublicKeyAction = url.pathname === '/api/actions/public-key';
      if (isPublicKeyAction && !/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] || '')) {
        sendJson(response, 415, { error: 'Public-key actions require application/json' });
        return;
      }
      const body = await readJsonBody(request, isPublicKeyAction ? publicKeyRequestMaxBytes : 4096);
      if (isPublicKeyAction) {
        if (!body || typeof body !== 'object' || Array.isArray(body)
          || Object.keys(body).some((key) => !['mode', 'key'].includes(key))
          || !['preview', 'add'].includes(body.mode)
          || typeof body.key !== 'string') {
          throw requestError(400, 'Public-key action requires mode and key');
        }
        const { keyLine, algorithm } = normalizePublicKey(body.key);
        const fingerprint = await fingerprintPublicKey(keyLine);
        if (body.mode === 'preview') {
          sendJson(response, 200, { mode: 'preview', algorithm, fingerprint });
          return;
        }
        let result;
        try {
          result = await enrollPublicKey(keyLine, fingerprint);
        } catch (error) {
          logPublicKeyEnrollment(request, 'failed', algorithm, fingerprint);
          throw error;
        }
        logPublicKeyEnrollment(request, result.result, algorithm, fingerprint);
        sendJson(response, result.result === 'added' ? 201 : 200, { ...result, algorithm });
        return;
      }
      if (url.pathname === '/api/actions/password') {
        await launchPasswordTerminal();
        sendJson(response, 202, { message: 'Password terminal opened' });
        return;
      }
      if (url.pathname === '/api/actions/health-check') {
        sendJson(response, 200, await runHealthCheck());
        return;
      }
      if (url.pathname === '/api/actions/port') {
        const disable = body.mode === 'disable';
        const newPort = Number.parseInt(body.port, 10);
        if (!disable && (!Number.isInteger(newPort) || newPort < 1024 || newPort > 65535)) {
          sendJson(response, 400, { error: 'Port must be between 1024 and 65535' });
          return;
        }
        await launchPortManager(newPort, disable);
        sendJson(response, 202, { message: 'Administrator prompt opened' });
        return;
      }
    }
    if (request.method === 'GET') {
      await serveStatic(request, response, url.pathname);
      return;
    }
    response.writeHead(405).end('Method not allowed');
  } catch (error) {
    const status = Number.isInteger(error.statusCode) ? error.statusCode : 500;
    const message = status >= 500 && url.pathname === '/api/actions/public-key'
      ? 'Public-key enrollment failed; check the workbench log'
      : error.message || 'Unexpected error';
    sendJson(response, status, { error: message });
  }
});

server.listen(port, host, () => {
  console.log(`WSL Server Workbench listening on http://${host}:${port}`);
});
