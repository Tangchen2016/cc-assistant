import { buildAIPrompt, clearMarkedIP, compareMarkedIP, normalizeIP, parseTrace, readBrowserTimeZone, readMarkedIP, saveMarkedIP } from './check-core.js?v=4';

const targets = [
  { name: 'Anthropic API', host: 'api.anthropic.com', claude: true },
  { name: 'Claude 网页', host: 'claude.ai', claude: true },
  { name: 'Claude 登录 / 授权', host: 'claude.com', claude: true },
  { name: 'Claude 开发平台', host: 'platform.claude.com', claude: true },
  // Other Cloudflare-fronted hosts from the recommended rules; each must exit via the same IP.
  { name: 'Anthropic 官网', host: 'anthropic.com', claude: true },
  { name: 'Artifacts 内容', host: 'claudeusercontent.com', claude: true },
  { name: 'Claude 短链接', host: 'clau.de', claude: true },
  { name: '登录认证 Auth0', host: 'anthropic.auth0.com', claude: true },
];
const expectedCount = targets.filter((target) => target.claude).length;
// Recommended-rule hosts that do not expose an exit IP to web pages: only reachability can be checked here.
const dependencies = [
  { name: '官网 CDN', host: 'servd-anthropic-website.b-cdn.net' },
  // Paths that answer on the same host: a redirect to another origin would be blocked by the page CSP.
  { name: '访问统计 Fathom', host: 'cdn.usefathom.com', path: '/script.js' },
  { name: '博客内容 Ghost', host: 'anthropic-com.ghost.io' },
  { name: 'Datadog 遥测', host: 'browser-intake-us5-datadoghq.com' },
  { name: 'Intercom 客服', host: 'api-iam.intercom.io', path: '/messenger/web/ping' },
  { name: 'Intercom 资源', host: 'js.intercomcdn.com' },
  { name: 'Statsig 功能开关', host: 'statsigapi.net' },
  { name: 'Sentry 错误上报', host: 'sentry.io' },
  { name: 'Sift 反欺诈', host: 'cdn.sift.com' },
  { name: 'Google 图标', host: 't0.gstatic.com' },
];
let reach = [];
async function probe(target) {
  const before = performance.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 7500);
  try {
    // no-cors: the response is opaque, but resolving at all proves the host was reached.
    await fetch(`https://${target.host}${target.path || '/'}?_cc=${Date.now()}`, { method: 'HEAD', mode: 'no-cors', credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer', signal: controller.signal });
    return { host: target.host, ok: true, elapsed: Math.round(performance.now() - before) };
  } catch {
    return { host: target.host, ok: false, error: controller.signal.aborted ? '连接超时' : '无法连接' };
  } finally { clearTimeout(timer); }
}
function renderDependencies() {
  const root = document.querySelector('#dependencies');
  if (!root) return;
  root.replaceChildren();
  dependencies.forEach((target) => {
    const result = reach.find((item) => item.host === target.host);
    const card = element('article', '', `dep ${result ? (result.ok ? 'is-ok' : 'is-fail') : start.disabled ? 'is-running' : 'is-pending'}`);
    const main = element('div', '');
    main.append(element('h3', target.name), element('div', target.host, 'host'));
    card.append(main, element('span', result ? (result.ok ? `${result.elapsed} ms` : result.error) : start.disabled ? '检测中…' : '未检测', 'dep-state'));
    root.append(card);
  });
  const done = reach.filter((item) => item.ok).length;
  document.querySelector('#dependencies-count').textContent = reach.length ? `${done} / ${dependencies.length} 可连接` : `${dependencies.length} 个域名`;
}
const start = document.querySelector('#start');
const copy = document.querySelector('#copy');
const copyAI = document.querySelector('#copy-ai');
const save = document.querySelector('#save');
const clear = document.querySelector('#clear');
const feedback = document.querySelector('#feedback');
let latest = [];
let marker = null;
let checkedAt = '';
let timeZone = null;
try { marker = readMarkedIP(localStorage); } catch { /* Storage may be unavailable in private browsing. */ }
const regions = typeof Intl.DisplayNames === 'function' ? new Intl.DisplayNames(['zh-CN'], { type: 'region' }) : null;
function element(tag, text, className) {
  const node = document.createElement(tag);
  node.textContent = text;
  if (className) node.className = className;
  return node;
}
function render() {
  document.querySelector('#timezone-value').textContent = timeZone ? `${timeZone.identifier} · ${timeZone.offsetText}` : checkedAt ? '浏览器未提供有效时区' : '尚未检测';
  renderMarker();
  const exits = document.querySelector('#summary-ips');
  exits.replaceChildren();
  const readings = latest.filter((item) => item.ip);
  const addresses = [...new Set(readings.map((item) => item.ip))];
  exits.hidden = addresses.length === 0;
  addresses.forEach((ip) => {
    const matches = readings.filter((item) => item.ip === ip);
    const row = element('div', '', 'exit-reading');
    row.append(element('span', ip, 'exit-address'));
    const countries = [...new Set(matches.map((item) => `${regions?.of(item.country) || item.country} ${item.country}`))];
    row.append(element('span', countries.join(' / '), 'exit-region'));
    if (addresses.length > 1) row.append(element('span', matches.map((item) => item.host).join(' · '), 'exit-hosts'));
    exits.append(row);
  });
  document.querySelector('#details-count').textContent = latest.length ? `${latest.length} / ${targets.length} 已完成` : `${targets.length} 个域名`;
  const root = document.querySelector('#results');
  root.replaceChildren();
  targets.forEach((target) => {
    const result = latest.find((item) => item.host === target.host);
    const card = element('article', '', `result ${result?.ip ? 'is-ok' : result ? 'is-fail' : start.disabled ? 'is-running' : 'is-pending'}`);
    const main = element('div', '', 'result-main');
    main.append(element('h3', target.name), element('div', target.host, 'host'));
    const value = element('div', '', 'result-value');
    value.append(element('div', result?.ip || (result ? '无法读取' : start.disabled ? '检测中…' : '等待检测'), 'ip'));
    if (result?.ip) {
      const region = regions?.of(result.country) || result.country;
      const how = result.manual ? ' · 手动核对' : ` · ${result.elapsed} ms${result.attempts > 1 ? ' · 重试后成功' : ''}`;
      value.append(element('div', `${region} ${result.country}${how}`, 'meta'));
      if (marker) {
        const state = element('span', marker.ip === result.ip ? '与标记一致' : 'IP 已变更', 'state');
        state.classList.toggle('changed', marker.ip !== result.ip);
        value.append(state);
      }
    } else if (result) value.append(element('div', result.error, 'meta'));
    card.append(main, value);
    const link = element('a', '↗', 'manual');
    link.title = '打开检测地址';
    link.setAttribute('aria-label', `打开 ${target.host} 检测地址`);
    link.href = `https://${target.host}/cdn-cgi/trace`;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    card.append(link);
    if (result && !result.ip && !start.disabled) {
      const manual = element('details', '', 'manual-check');
      manual.append(element('summary', '自动读取失败？手动核对'));
      manual.append(element('p', '点 ↗ 打开检测地址，复制完整文本并粘贴到这里。仅在本机解析，不会上传。', 'meta'));
      const label = element('label', '该域名的检测文本');
      const input = document.createElement('textarea');
      input.id = `trace-${target.host.replaceAll('.', '-')}`;
      input.rows = 5;
      input.placeholder = `h=${target.host}\nip=…\nloc=US`;
      input.autocomplete = 'off';
      input.spellcheck = false;
      label.htmlFor = input.id;
      const apply = element('button', '核对这份结果');
      apply.type = 'button';
      const error = element('p', '', 'meta');
      error.setAttribute('role', 'status');
      apply.addEventListener('click', () => {
        try {
          const value = { ...parseTrace(input.value, target.host), manual: true };
          latest = latest.map((item) => item.host === target.host ? value : item);
          checkedAt = new Date().toLocaleString('zh-CN');
          timeZone = readBrowserTimeZone();
          render(); renderSummary();
        } catch (failure) { error.textContent = failure.message; }
      });
      manual.append(label, input, apply, error);
      card.append(manual);
    }
    root.append(card);
  });
}
function renderMarker() {
  const addresses = [...new Set(latest.map((item) => item.ip).filter(Boolean))];
  const select = document.querySelector('#mark-choice');
  const selected = select.value;
  select.replaceChildren();
  if (addresses.length !== 1) {
    const placeholder = element('option', addresses.length ? '选择要标记的 IP' : '检测后可选择 IP');
    placeholder.value = ''; select.append(placeholder);
  }
  addresses.forEach((ip) => { const option = element('option', ip); option.value = ip; select.append(option); });
  if (addresses.includes(selected)) select.value = selected;
  select.disabled = start.disabled || addresses.length < 2;
  clear.hidden = !marker;
  clear.disabled = start.disabled;
  document.querySelector('#marked-ip').textContent = marker?.ip || '尚未标记';
  const comparison = compareMarkedIP(latest, marker);
  const detail = document.querySelector('#marked-detail');
  detail.textContent = !marker ? '只保留一个标记，新标记会替换旧标记；仅保存在当前浏览器。'
    : start.disabled ? '正在检测，完成后与这个 IP 对比。'
      : comparison === 'changed' ? 'IP 已变更：有检测结果与标记不同，请核对线路。'
        : comparison === 'same' ? `已读取的 IP 与标记一致${latest.some((item) => !item.ip) ? '，仍有未核对项。' : '。'}`
          : '后续检测将与这个 IP 对比。';
  detail.classList.toggle('changed', comparison === 'changed');
  const sameSelection = marker && select.value === marker.ip;
  save.textContent = sameSelection ? '已标记此 IP' : marker ? '替换标记 IP' : '标记此 IP';
  save.disabled = start.disabled || !select.value || Boolean(sameSelection);
}
function renderSummary() {
  const successful = latest.filter((item) => item.ip);
  const ips = new Set(successful.map((item) => item.ip));
  const comparison = compareMarkedIP(latest, marker);
  const changed = comparison === 'changed';
  const consistent = successful.length === expectedCount && ips.size === 1;
  const manualCount = successful.filter((item) => item.manual).length;
  const status = document.querySelector('#summary-status');
  status.textContent = changed ? 'IP 已变更' : consistent ? marker ? '✓ 与标记一致' : '✓ 检测成功' : ips.size > 1 ? '出口存在差异' : '部分结果未核对';
  status.classList.toggle('success', consistent && !changed);
  status.hidden = false;
  document.querySelector('.summary').classList.toggle('verified', consistent && !changed);
  document.querySelector('#summary-label').textContent = checkedAt;
  document.querySelector('#summary-title').textContent = changed ? '出口 IP 与标记不同' : consistent ? `${expectedCount} 个 Claude 域名出口一致` : ips.size > 1 ? 'Claude 域名出口存在差异' : `Claude 出口已核对 ${successful.length} / ${expectedCount}`;
  document.querySelector('#summary-detail').textContent = (changed ? `标记 IP：${marker.ip}。请对照当前出口，确认是否切换了线路。` : consistent ? '请对照自己的期望 IP 和地区；出口一致不代表账号或服务可用性保证。' : '部分结果未自动读取，可展开下方检测详情，点 ↗ 打开原始地址并手动核对。') + (manualCount ? ` 含 ${manualCount} 项手动核对。` : '');
}
async function check(target) {
  const before = performance.now();
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 7500);
    try {
      const response = await fetch(`https://${target.host}/cdn-cgi/trace?_cc=${Date.now()}-${attempt}`, {
        signal: controller.signal, credentials: 'omit', headers: { Accept: 'text/plain' }, referrerPolicy: 'no-referrer',
      });
      if (!response.ok) {
        const error = new Error(`HTTP ${response.status}`);
        error.retryable = response.status === 408 || response.status === 429 || response.status >= 500;
        throw error;
      }
      return { ...parseTrace(await response.text(), target.host), elapsed: Math.round(performance.now() - before), attempts: attempt };
    } catch (error) {
      if (attempt < 2 && (controller.signal.aborted || error instanceof TypeError || error.retryable)) {
        await new Promise((resolve) => setTimeout(resolve, 250));
        continue;
      }
      return { host: target.host, attempts: attempt, error: controller.signal.aborted ? '请求超时，可打开原始地址手动核对' : error instanceof TypeError ? '跨站读取或网络请求受限；可打开原始地址手动核对' : error.message };
    } finally { clearTimeout(timer); }
  }
}
start.addEventListener('click', async () => {
  if (start.disabled) return;
  start.disabled = true; copy.disabled = true; copyAI.disabled = true; save.disabled = true;
  start.textContent = `0 / ${targets.length}`;
  start.setAttribute('aria-label', `正在检测 0 / ${targets.length}`);
  start.style.setProperty('--check-progress', '0');
  start.setAttribute('aria-busy', 'true');
  document.body.classList.add('running');
  document.body.classList.remove('completed');
  const status = document.querySelector('#summary-status');
  status.hidden = true;
  document.querySelector('.summary').classList.remove('verified');
  feedback.textContent = '';
  timeZone = readBrowserTimeZone();
  latest = [];
  render();
  document.querySelector('#summary-label').textContent = '正在检测';
  document.querySelector('#summary-title').textContent = '从当前设备发起请求';
  document.querySelector('#summary-detail').textContent = '分别访问检测目标，失败项会自动重试一次，最多约 16 秒。';
  reach = [];
  renderDependencies();
  const reachability = Promise.allSettled(dependencies.map(async (target) => { reach.push(await probe(target)); renderDependencies(); }));
  await Promise.allSettled(targets.map(async (target) => {
    latest.push(await check(target));
    start.textContent = `${latest.length} / ${targets.length}`;
    start.setAttribute('aria-label', `正在检测 ${latest.length} / ${targets.length}`);
    start.style.setProperty('--check-progress', String(latest.length / targets.length));
    render();
  }));
  await reachability;
  checkedAt = new Date().toLocaleString('zh-CN');
  start.textContent = '重新检测'; start.disabled = false; copy.disabled = false; copyAI.disabled = false;
  start.setAttribute('aria-label', '重新检测');
  start.setAttribute('aria-busy', 'false');
  render(); renderSummary();
  document.body.classList.remove('running');
  document.body.classList.add('completed');
  continueToClaude();
});
// ?then=claude (set by the desktop app): go on to Claude only when every Claude host exits through one unchanged IP.
// Fixed destination, never a caller-supplied URL.
const thenClaude = new URLSearchParams(window.location.search).get('then') === 'claude';
const claudeURL = 'https://claude.ai/';
let continueTimer = null;
function continueToClaude() {
  if (!thenClaude) return;
  clearInterval(continueTimer);
  const ips = new Set(latest.filter((item) => item.ip).map((item) => item.ip));
  const passed = latest.filter((item) => item.ip).length === expectedCount && ips.size === 1 && compareMarkedIP(latest, marker) !== 'changed';
  const root = document.querySelector('#continue');
  root.hidden = false;
  root.classList.toggle('is-ok', passed);
  const text = root.querySelector('span'), go = root.querySelector('#continue-go'), stop = root.querySelector('#continue-stop');
  // A new tab keeps this check page around; Chrome may block it without a click, then the button stays as fallback.
  go.onclick = () => { window.open(claudeURL, '_blank', 'noopener'); text.textContent = '已在新页签打开 Claude。'; stop.hidden = true; };
  if (!passed) {
    text.textContent = '检测未通过，已暂停打开 Claude。请先排查出口，或确认后继续。';
    go.textContent = '仍要打开 Claude'; stop.hidden = true; return;
  }
  let left = 3;
  const tick = () => { text.textContent = `检测通过，${left} 秒后在新页签打开 Claude`; };
  go.textContent = '立即打开'; stop.hidden = false; tick();
  stop.onclick = () => { clearInterval(continueTimer); text.textContent = '已取消自动打开。'; stop.hidden = true; };
  continueTimer = setInterval(() => {
    left -= 1; if (left > 0) return tick();
    clearInterval(continueTimer); stop.hidden = true;
    window.open(claudeURL, '_blank', 'noopener');
    text.textContent = '检测通过，已尝试在新页签打开 Claude；未弹出时请点按钮。';
    go.textContent = '在新页签打开';
  }, 1000);
}
start.addEventListener('click', () => { clearInterval(continueTimer); const root = document.querySelector('#continue'); if (root) root.hidden = true; });
copy.addEventListener('click', async () => {
  const text = [`cc助手浏览器出口检测 · ${checkedAt}`, `当前浏览器时区：${timeZone ? `${timeZone.identifier} ${timeZone.offsetText}` : '未验证'}`, `标记 IP：${marker?.ip || "未标记"}`, ...targets.map((target) => {
    const item = latest.find((result) => result.host === target.host);
    return `${target.host}: ${item?.ip ? `${item.ip} ${item.country}${item.manual ? " 手动核对" : ` ${item.elapsed}ms`}` : item?.error || '未检测'}`;
  }), '依赖域名（仅可达性）：', ...dependencies.map((target) => {
    const item = reach.find((result) => result.host === target.host);
    return `${target.host}: ${item ? (item.ok ? `可连接 ${item.elapsed}ms` : item.error) : '未检测'}`;
  })].join('\n');
  try { await navigator.clipboard.writeText(text); feedback.textContent = '检测结果已复制，包含出口 IP。'; }
  catch { feedback.textContent = '浏览器未允许复制，请直接查看检测结果。'; }
});
copyAI.addEventListener('click', async () => {
  const ua = navigator.userAgent;
  const browser = /Edg/.test(ua) ? 'Edge' : /CriOS|Chrome/.test(ua) ? 'Chrome' : /FxiOS|Firefox/.test(ua) ? 'Firefox' : /Safari/.test(ua) ? 'Safari' : '未识别';
  try {
    await navigator.clipboard.writeText(buildAIPrompt(targets, latest, marker, checkedAt, browser, timeZone));
    feedback.textContent = 'AI 排查提示词已复制，可粘贴到你使用的 AI。出口已脱敏编号。';
  } catch { feedback.textContent = '浏览器未允许复制，请允许此页面使用剪贴板后重试。'; }
});
document.querySelector('#mark-choice').addEventListener('change', renderMarker);
save.addEventListener('click', () => {
  const ip = normalizeIP(document.querySelector('#mark-choice').value);
  if (!ip || !latest.some((item) => item.ip === ip)) return;
  try {
    const previous = marker;
    marker = saveMarkedIP(localStorage, ip);
    feedback.textContent = previous ? `标记已替换：${previous.ip} → ${marker.ip}。` : `已标记 ${marker.ip}，以后会与它对比。`;
    render(); renderSummary();
  } catch { feedback.textContent = '浏览器未允许本地存储，标记未保存。'; }
});
clear.addEventListener('click', () => {
  if (start.disabled) return;
  try {
    clearMarkedIP(localStorage); marker = null; feedback.textContent = '已取消 IP 标记。';
    render(); if (latest.length) renderSummary();
  } catch { feedback.textContent = '取消失败，请检查浏览器存储权限。'; }
});
render();
renderDependencies();

// App launch requests one check in this actual browser context.
if (new URLSearchParams(window.location.search).get('autostart') === '1') start.click();
