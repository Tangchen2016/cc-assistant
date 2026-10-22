import { changeDeleted, daysUntilExpiry, fileLimit, mergeState, parseState, readState, saveAccount, writeState } from './accounts-core.js?v=1';

const $ = (id) => document.getElementById(id);
const form = $('account-form'), editor = $('editor');
let state = { version: 1, accounts: [] }, storage, readOnly = false, showDeleted = false, editingID = null, originalForm = '', lastRaw;
try { storage = window.localStorage; state = readState(storage); lastRaw = storage.getItem('cc-account-pool-v1'); }
catch {
  readOnly = true; $('load-error').hidden = false;
  $('load-error').textContent = '无法读取本地资料，已停止写入以保留原数据。请检查浏览器存储权限，或在原设备导出备份。';
}
const formatDate = (value, time = false) => value ? new Date(value).toLocaleString('zh-CN', time
  ? { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }
  : { year: 'numeric', month: '2-digit', day: '2-digit' }) : '未记录';
const localInput = (value) => {
  const date = new Date(value), pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
};
const snapshot = () => JSON.stringify([...new FormData(form)]);
function feedback(message) { $('feedback').textContent = message; }
function commit(next, message) {
  if (readOnly) throw new Error('当前资料只读，未保存。');
  try {
    if (storage.getItem('cc-account-pool-v1') !== lastRaw) throw new Error('资料已在其他页面更改，本次未保存。请先复制未保存的内容，再刷新此页。');
    state = writeState(storage, next); lastRaw = JSON.stringify(state);
  }
  catch (error) {
    if (error?.name === 'QuotaExceededError' || error?.name === 'SecurityError') throw new Error('浏览器未能保存，可能是存储空间或权限限制。本次修改未保存，请先导出已有资料。');
    throw error;
  }
  render(); feedback(message);
}
function render() {
  const active = state.accounts.filter((row) => !row.deletedAt);
  const query = $('search').value.trim().toLocaleLowerCase(), filter = $('filter').value;
  const rows = state.accounts.filter((row) => Boolean(row.deletedAt) === showDeleted && (!filter || row.status === filter)
    && [row.email, row.label, row.subscription, row.notes].some((text) => text.toLocaleLowerCase().includes(query)))
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt) || a.id.localeCompare(b.id));
  $('account-count').textContent = active.length;
  $('expiry-count').textContent = active.filter((row) => { const days = daysUntilExpiry(row.expiresAt); return days !== null && days >= 0 && days <= 7; }).length;
  $('trash-count').textContent = state.accounts.length - active.length;
  $('trash-count').hidden = showDeleted;
  $('trash').firstChild.textContent = showDeleted ? '返回号池 ' : '回收站 ';
  $('page-title').textContent = showDeleted ? '账号回收站' : '号池管理';
  $('result-count').textContent = `${rows.length} 条记录`;
  $('add').hidden = showDeleted;
  $('add').disabled = $('empty-add').disabled = $('export').disabled = readOnly;
  $('import').disabled = readOnly;
  $('accounts').replaceChildren();
  for (const row of rows) {
    const card = $('account-template').content.firstElementChild.cloneNode(true);
    card.querySelector('.account-name').textContent = row.label || row.email;
    card.querySelector('.email').textContent = row.email;
    const status = card.querySelector('.status'); status.textContent = row.status; status.dataset.status = row.status;
    card.querySelector('.subscription').textContent = row.subscription || '未记录';
    card.querySelector('.expiry').textContent = formatDate(row.expiresAt);
    const days = daysUntilExpiry(row.expiresAt);
    card.querySelector('.expiry-hint').textContent = days === null || days > 7 ? '' : days < 0 ? '已到期' : days === 0 ? '今日到期' : `${days} 天后到期`;
    card.querySelector('.created').textContent = `创建于 ${formatDate(row.createdAt, true)}`;
    card.querySelector('.notes').hidden = !row.notes;
    card.querySelector('.notes p').textContent = row.notes;
    const edit = card.querySelector('.edit'), remove = card.querySelector('.remove'), restore = card.querySelector('.restore');
    edit.hidden = remove.hidden = showDeleted; restore.hidden = !showDeleted;
    edit.addEventListener('click', () => openEditor(row));
    remove.addEventListener('click', () => { try { commit(changeDeleted(state, row.id, true), '已移入回收站，可随时还原。'); } catch (error) { feedback(error.message); } });
    restore.addEventListener('click', () => { try { commit(changeDeleted(state, row.id, false), '账号记录已还原。'); } catch (error) { feedback(error.message); } });
    $('accounts').append(card);
  }
  $('empty').hidden = rows.length > 0 || readOnly;
  $('empty').querySelector('h2').textContent = showDeleted ? '回收站中没有匹配的账号' : active.length ? '没有匹配的账号' : '从第一个账号开始';
  $('empty').querySelector('p').textContent = showDeleted ? '删除的记录可以在这里还原。' : active.length ? '试试其他关键词或状态。' : '邮箱、订阅和到期日，放在一起看。';
  $('empty-add').hidden = showDeleted || active.length > 0;
}
function openEditor(row = null) {
  if (readOnly) return;
  editingID = row?.id ?? null; form.reset();
  $('editor-title').textContent = row ? '编辑账号' : '新增账号';
  for (const name of ['email', 'label', 'status', 'subscription', 'notes']) form.elements.namedItem(name).value = row?.[name] ?? (name === 'status' ? '备用' : '');
  form.elements.namedItem('expiresAt').value = row?.expiresAt ? localInput(row.expiresAt).slice(0, 10) : '';
  form.elements.namedItem('createdAt').value = localInput(row?.createdAt ?? new Date());
  $('editor-error').hidden = true; originalForm = snapshot();
  editor.showModal();
}
function cancelEditor() {
  if (snapshot() !== originalForm && !window.confirm('放弃尚未保存的账号修改？')) return;
  editor.close();
}
$('add').addEventListener('click', () => openEditor());
$('empty-add').addEventListener('click', () => openEditor());
$('cancel').addEventListener('click', cancelEditor);
editor.addEventListener('cancel', (event) => { event.preventDefault(); cancelEditor(); });
form.addEventListener('submit', (event) => {
  event.preventDefault();
  try {
    const values = Object.fromEntries(new FormData(form));
    values.createdAt = new Date(values.createdAt).toISOString();
    values.expiresAt = values.expiresAt ? new Date(`${values.expiresAt}T12:00:00`).toISOString() : null;
    commit(saveAccount(state, values, editingID), '账号记录已保存在当前浏览器。');
    editor.close();
  } catch (error) { $('editor-error').textContent = error.message; $('editor-error').hidden = false; }
});
$('search').addEventListener('input', render);
$('filter').addEventListener('change', render);
$('trash').addEventListener('click', () => { showDeleted = !showDeleted; $('search').value = ''; $('filter').value = ''; feedback(''); render(); });
$('export').addEventListener('click', () => {
  const blob = new Blob([JSON.stringify(state, null, 2)], { type: 'application/json' }), url = URL.createObjectURL(blob);
  const link = document.createElement('a'); link.href = url; link.download = `cc-accounts-${localInput(new Date()).slice(0, 10)}.json`;
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
  feedback('已生成本地备份，请保存到“文件”或浏览器下载目录。');
});
$('import').addEventListener('change', async (event) => {
  const file = event.target.files?.[0]; if (!file) return;
  try {
    if (file.size > fileLimit) throw new Error('文件超过 4 MiB，未读取。');
    const incoming = parseState(await file.text()), next = mergeState(state, incoming), count = next.accounts.length - state.accounts.length;
    commit(next, `导入完成，新增 ${count} 条记录。`);
  } catch (error) { feedback(`未导入：${error.message}`); }
  finally { event.target.value = ''; }
});
window.addEventListener('beforeunload', (event) => { if (editor.open && snapshot() !== originalForm) { event.preventDefault(); event.returnValue = ''; } });
render();
