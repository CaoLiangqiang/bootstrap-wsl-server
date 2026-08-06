'use strict';

const path = require('node:path');
const os = require('node:os');
const { mkdir, readFile, rename, writeFile } = require('node:fs/promises');

const workbenchUrl = process.env.WORKBENCH_URL || 'http://127.0.0.1:4173';
const stateRoot = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
const stateDir = path.join(stateRoot, 'wsl-server-workbench');
const historyPath = path.join(stateDir, 'health-history.jsonl');
const currentPath = path.join(stateDir, 'health-current.json');
const maxRecords = 2016;

function check(id, label, ok, level, detail) {
  return { id, label, ok: Boolean(ok), level, detail };
}

function evaluate(overview) {
  const proxy = overview.windows?.portProxy;
  const firewall = overview.windows?.firewall;
  const task = overview.windows?.startupTask;
  const policy = overview.sshPolicy || {};
  const remoteAddresses = firewall?.remoteAddress || [];

  return [
    check('workbench', '工作台 API', true, 'critical', 'Local API responded'),
    check('ssh', 'SSH 服务', overview.services?.ssh === 'active', 'critical', overview.services?.ssh || 'unknown'),
    check('route', 'WSL 默认路由', overview.network?.mode === 'NAT' && overview.network?.defaultRoute, 'critical', overview.network?.defaultRoute || 'missing'),
    check('dns', 'WSL DNS', overview.network?.resolver?.nameservers?.length, 'critical', overview.network?.resolver?.nameservers?.join(', ') || 'missing'),
    check('port-proxy', 'Windows 端口转发', proxy?.enabled && proxy?.listening, 'critical', proxy ? `TCP ${proxy.listenPort}` : 'missing'),
    check('firewall', '局域网防火墙', firewall?.enabled && firewall?.profile?.includes('Private') && remoteAddresses.includes('LocalSubnet'), 'warning', firewall ? `${firewall.profile} / ${remoteAddresses.join(', ')}` : 'missing'),
    check('startup-task', 'Windows 登录任务', task?.exists, 'warning', task?.state || 'missing'),
    check('ssh-policy', 'SSH 安全策略', policy.passwordAuthentication && policy.publicKeyAuthentication && policy.permitRootLogin === 'no' && policy.allowUsers?.includes('__WSL_USER__'), 'warning', 'password + public-key / root denied / user restricted')
  ];
}

function overallStatus(checks) {
  if (checks.some((item) => !item.ok && item.level === 'critical')) return 'critical';
  if (checks.some((item) => !item.ok)) return 'warning';
  return 'healthy';
}

async function fetchOverview() {
  const response = await fetch(`${workbenchUrl}/api/overview`, {
    headers: { Accept: 'application/json' },
    signal: AbortSignal.timeout(25000)
  });
  if (!response.ok) throw new Error(`Workbench returned HTTP ${response.status}`);
  return response.json();
}

async function persist(record) {
  await mkdir(stateDir, { recursive: true, mode: 0o700 });
  let lines = [];
  try {
    lines = (await readFile(historyPath, 'utf8')).split('\n').filter(Boolean);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  lines.push(JSON.stringify(record));
  if (lines.length > maxRecords) lines = lines.slice(-maxRecords);

  const historyTemp = `${historyPath}.tmp`;
  const currentTemp = `${currentPath}.tmp`;
  await writeFile(historyTemp, `${lines.join('\n')}\n`, { mode: 0o600 });
  await writeFile(currentTemp, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
  await rename(historyTemp, historyPath);
  await rename(currentTemp, currentPath);
}

async function main() {
  const startedAt = Date.now();
  let checks;
  try {
    checks = evaluate(await fetchOverview());
  } catch (error) {
    checks = [check('workbench', '工作台 API', false, 'critical', error.message)];
  }

  const record = {
    timestamp: new Date().toISOString(),
    status: overallStatus(checks),
    durationMs: Date.now() - startedAt,
    checks
  };
  await persist(record);
  process.stdout.write(`${JSON.stringify(record)}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
