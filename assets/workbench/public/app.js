'use strict';

const state = { hours: 24, overview: null, toastTimer: null };

const elements = {
  accessBody: document.querySelector('#access-body'),
  allowedUsers: document.querySelector('#allowed-users'),
  authMode: document.querySelector('#auth-mode'),
  blockedCount: document.querySelector('#blocked-count'),
  defaultRoute: document.querySelector('#default-route'),
  disableButton: document.querySelector('#disable-button'),
  dnsAddress: document.querySelector('#dns-address'),
  dockerStatus: document.querySelector('#docker-status'),
  endpointList: document.querySelector('#endpoint-list'),
  failedCount: document.querySelector('#failed-count'),
  firewallScope: document.querySelector('#firewall-scope'),
  healthCheckButton: document.querySelector('#health-check-button'),
  healthChecks: document.querySelector('#health-checks'),
  healthHistory: document.querySelector('#health-history'),
  healthIndicator: document.querySelector('#health-indicator'),
  healthState: document.querySelector('#health-state'),
  healthTime: document.querySelector('#health-time'),
  hostLabel: document.querySelector('#host-label'),
  keyPolicy: document.querySelector('#key-policy'),
  liveState: document.querySelector('#live-state'),
  networkMode: document.querySelector('#network-mode'),
  passwordButton: document.querySelector('#password-button'),
  passwordPolicy: document.querySelector('#password-policy'),
  portButton: document.querySelector('#port-button'),
  portInput: document.querySelector('#port-input'),
  proxyPill: document.querySelector('#proxy-pill'),
  publicPort: document.querySelector('#public-port'),
  refreshButton: document.querySelector('#refresh-button'),
  rootPolicy: document.querySelector('#root-policy'),
  sshStatus: document.querySelector('#ssh-status'),
  startupTask: document.querySelector('#startup-task'),
  successCount: document.querySelector('#success-count'),
  toast: document.querySelector('#toast'),
  wslAddress: document.querySelector('#wsl-address')
};

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function showToast(message, error = false) {
  clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.toggle('error', error);
  elements.toast.classList.add('show');
  state.toastTimer = setTimeout(() => elements.toast.classList.remove('show'), 3400);
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
  return payload;
}

function renderEndpoints(overview) {
  const port = overview.windows.portProxy?.listenPort;
  const interfaces = overview.windows.interfaces || [];
  if (!port || !interfaces.length) {
    elements.endpointList.innerHTML = '<div class="empty-cell">当前没有可用的局域网入口</div>';
    return;
  }
  elements.endpointList.innerHTML = interfaces.map((item) => {
    const command = `ssh -p ${port} __WSL_USER__@${item.address}`;
    return `
      <div class="endpoint">
        <span class="endpoint-icon"><i data-lucide="${item.name === 'WLAN' ? 'wifi' : 'cable'}"></i></span>
        <div><span>${escapeHtml(item.name)}</span><code>${escapeHtml(command)}</code></div>
        <button class="copy-button" data-copy="${escapeHtml(command)}" title="复制连接命令" aria-label="复制连接命令"><i data-lucide="copy"></i></button>
      </div>`;
  }).join('');
}

function renderOverview(overview) {
  state.overview = overview;
  const proxy = overview.windows.portProxy;
  const firewall = overview.windows.firewall;
  const policy = overview.sshPolicy;
  const sshOnline = overview.services.ssh === 'active';
  const proxyOnline = Boolean(proxy?.enabled && proxy?.listening);

  elements.hostLabel.textContent = `${overview.hostname} · __DISTRO__ · ${new Date(overview.generatedAt).toLocaleTimeString('zh-CN', { hour12: false })}`;
  elements.sshStatus.textContent = sshOnline ? '运行中' : overview.services.ssh;
  elements.networkMode.textContent = overview.network.mode === 'NAT' ? '默认 NAT' : '网络离线';
  elements.authMode.textContent = policy.passwordAuthentication && !policy.publicKeyAuthentication ? '仅密码' : policy.passwordAuthentication ? '密码 + 密钥' : '仅密钥';
  elements.publicPort.textContent = proxy ? `TCP ${proxy.listenPort}` : '未开放';
  elements.portInput.value = proxy?.listenPort || elements.portInput.value;

  elements.proxyPill.textContent = proxyOnline ? '转发正常' : proxy ? '监听异常' : '未开放';
  elements.proxyPill.className = `status-pill ${proxyOnline ? 'good' : 'bad'}`;
  elements.liveState.innerHTML = `<span class="pulse"></span> ${sshOnline && proxyOnline ? '服务正常' : '需要关注'}`;

  elements.allowedUsers.textContent = policy.allowUsers.join(', ') || '未限制';
  elements.passwordPolicy.textContent = policy.passwordAuthentication ? '已启用' : '已关闭';
  elements.keyPolicy.textContent = policy.publicKeyAuthentication ? '已启用' : '已关闭';
  elements.rootPolicy.textContent = policy.permitRootLogin === 'no' ? '已禁止' : policy.permitRootLogin;
  elements.firewallScope.textContent = firewall ? `${firewall.profile} / ${firewall.remoteAddress.join(', ')}` : '未配置';

  const wslAddresses = overview.network.ipv4.map((item) => `${item.address}/${item.prefix}`);
  elements.wslAddress.textContent = wslAddresses.join(', ') || '—';
  elements.defaultRoute.textContent = overview.network.defaultRoute || '—';
  elements.dnsAddress.textContent = overview.network.resolver.nameservers.join(', ') || '—';
  elements.dockerStatus.textContent = overview.services.docker === 'active' ? '运行中' : overview.services.docker;
  elements.startupTask.textContent = overview.windows.startupTask?.exists ? overview.windows.startupTask.state : '缺失';

  renderEndpoints(overview);
  window.lucide.createIcons();
}

function statusBadge(status) {
  const labels = { success: '成功', failed: '失败', blocked: '拦截' };
  const icons = { success: 'check-circle-2', failed: 'x-circle', blocked: 'shield-alert' };
  return `<span class="event-badge ${status}"><i data-lucide="${icons[status]}"></i>${labels[status]}</span>`;
}

function renderLogs(data) {
  elements.successCount.textContent = data.summary.success;
  elements.failedCount.textContent = data.summary.failed;
  elements.blockedCount.textContent = data.summary.blocked;
  if (!data.events.length) {
    elements.accessBody.innerHTML = '<tr><td colspan="5" class="empty-cell">当前时间范围内没有认证事件</td></tr>';
    return;
  }
  elements.accessBody.innerHTML = data.events.map((event) => {
    const date = new Date(event.timestamp);
    const time = date.toLocaleString('zh-CN', { hour12: false });
    return `<tr>
      <td>${statusBadge(event.status)}</td>
      <td>${escapeHtml(time)}</td>
      <td class="mono">${escapeHtml(event.user)}</td>
      <td class="mono">${escapeHtml(event.address)}${event.port ? `:${event.port}` : ''}</td>
      <td>${escapeHtml(event.method)}</td>
    </tr>`;
  }).join('');
  window.lucide.createIcons();
}

function renderHealth(data) {
  const latest = data.entries[0];
  if (!latest) {
    elements.healthState.textContent = '尚未检查';
    elements.healthTime.textContent = '等待第一次定时检查';
    elements.healthChecks.innerHTML = '<li class="muted-row">暂无检查记录</li>';
    elements.healthHistory.innerHTML = '';
    return;
  }
  const statusLabels = { healthy: '运行健康', warning: '需要关注', critical: '严重异常' };
  const checkLabels = { healthy: '正常', warning: '警告', critical: '失败' };
  elements.healthState.textContent = statusLabels[latest.status] || latest.status;
  elements.healthState.className = `health-${latest.status}`;
  elements.healthTime.textContent = `${new Date(latest.timestamp).toLocaleString('zh-CN', { hour12: false })} · ${latest.durationMs}ms`;
  elements.healthIndicator.className = `health-indicator health-${latest.status}`;
  elements.healthChecks.innerHTML = latest.checks.map((item) => `
    <li><span class="check-dot health-${item.ok ? 'healthy' : item.level}"></span><span>${escapeHtml(item.label)}</span><strong class="health-${item.ok ? 'healthy' : item.level}">${item.ok ? checkLabels.healthy : checkLabels[item.level]}</strong><small>${escapeHtml(item.detail)}</small></li>
  `).join('');
  elements.healthHistory.innerHTML = data.entries.slice(0, 24).reverse().map((entry) => `<span class="history-dot health-${entry.status}" title="${escapeHtml(new Date(entry.timestamp).toLocaleString('zh-CN', { hour12: false }))}"></span>`).join('');
}

async function loadOverview() {
  renderOverview(await fetchJson('/api/overview'));
}

async function loadLogs() {
  renderLogs(await fetchJson(`/api/logs?hours=${state.hours}`));
}

async function loadHealth() {
  renderHealth(await fetchJson('/api/health?limit=24'));
}

async function refreshAll(showMessage = false) {
  elements.refreshButton.classList.add('loading');
  try {
    await Promise.all([loadOverview(), loadLogs(), loadHealth()]);
    if (showMessage) showToast('状态已刷新');
  } catch (error) {
    showToast(`刷新失败：${error.message}`, true);
  } finally {
    elements.refreshButton.classList.remove('loading');
  }
}

async function runAction(path, body = {}) {
  return fetchJson(path, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Workbench-Action': 'confirm'
    },
    body: JSON.stringify(body)
  });
}

elements.refreshButton.addEventListener('click', () => refreshAll(true));
elements.healthCheckButton.addEventListener('click', async () => {
  elements.healthCheckButton.classList.add('loading');
  try {
    await runAction('/api/actions/health-check');
    await loadHealth();
    showToast('自检完成');
  } catch (error) {
    showToast(`自检失败：${error.message}`, true);
  } finally {
    elements.healthCheckButton.classList.remove('loading');
  }
});
elements.passwordButton.addEventListener('click', async () => {
  try {
    const result = await runAction('/api/actions/password');
    showToast(result.message);
  } catch (error) {
    showToast(error.message, true);
  }
});
elements.portButton.addEventListener('click', async () => {
  const newPort = Number.parseInt(elements.portInput.value, 10);
  if (!Number.isInteger(newPort) || newPort < 1024 || newPort > 65535) {
    showToast('端口必须在 1024 到 65535 之间', true);
    return;
  }
  try {
    const result = await runAction('/api/actions/port', { port: newPort });
    showToast(`${result.message}，请确认 UAC`);
    setTimeout(() => refreshAll(), 6000);
  } catch (error) {
    showToast(error.message, true);
  }
});
elements.disableButton.addEventListener('click', async () => {
  if (!window.confirm('停止局域网 SSH 入口？本机 WSL 的 SSH 服务不会被关闭。')) return;
  try {
    const result = await runAction('/api/actions/port', { mode: 'disable' });
    showToast(`${result.message}，请确认 UAC`);
    setTimeout(() => refreshAll(), 5000);
  } catch (error) {
    showToast(error.message, true);
  }
});

document.querySelectorAll('[data-hours]').forEach((button) => {
  button.addEventListener('click', async () => {
    document.querySelectorAll('[data-hours]').forEach((item) => item.classList.remove('active'));
    button.classList.add('active');
    state.hours = Number(button.dataset.hours);
    try {
      await loadLogs();
    } catch (error) {
      showToast(`日志加载失败：${error.message}`, true);
    }
  });
});

elements.endpointList.addEventListener('click', async (event) => {
  const button = event.target.closest('[data-copy]');
  if (!button) return;
  await navigator.clipboard.writeText(button.dataset.copy);
  showToast('连接命令已复制');
});

window.lucide.createIcons();
refreshAll();
setInterval(() => refreshAll(), 30000);
