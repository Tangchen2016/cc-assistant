export const storageKey = 'cc-account-pool-v1';
export const statuses = ['备用', '使用中', '需处理', '已停用'];
export const fileLimit = 4 * 1024 * 1024;
const iso = (value) => new Date(value).toISOString().replace(/\.\d{3}Z$/, 'Z');

function date(value, optional = false) {
  if (optional && (value === null || value === undefined)) return null;
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value) || !Number.isFinite(Date.parse(value))) throw new Error('记录中的日期无效。');
  return iso(value);
}
function text(value, limit) {
  if (typeof value !== 'string' || value.length > limit) throw new Error('记录格式不正确，或文字超过长度限制。');
  return value;
}
export function validateState(value) {
  if (!value || value.version !== 1 || !Array.isArray(value.accounts) || value.accounts.length > 5000) throw new Error('号池文件格式或版本不受支持。');
  const ids = new Set(), emails = new Set();
  const accounts = value.accounts.map((row) => {
    if (!row || typeof row.id !== 'string' || !/^[\da-f]{8}(-[\da-f]{4}){3}-[\da-f]{12}$/i.test(row.id) || !statuses.includes(row.status)) throw new Error('账号标识或状态无效。');
    const email = text(row.email, 254).trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || /[\u0000-\u001f\u007f]/.test(email)) throw new Error('请填写有效的账号邮箱。');
    const id = row.id.toLowerCase(), deletedAt = date(row.deletedAt, true);
    if (ids.has(id) || (!deletedAt && emails.has(email))) throw new Error('存在重复账号，请先处理同邮箱或相同标识的记录。');
    ids.add(id); if (!deletedAt) emails.add(email);
    return { id, email, label: text(row.label, 100).trim(), status: row.status, subscription: text(row.subscription, 100).trim(),
      expiresAt: date(row.expiresAt, true), createdAt: date(row.createdAt), notes: text(row.notes, 4000), updatedAt: date(row.updatedAt), deletedAt };
  });
  return { version: 1, accounts };
}
export function parseState(raw) {
  if (typeof raw !== 'string' || new Blob([raw]).size > fileLimit) throw new Error('文件超过 4 MiB，未读取。');
  return validateState(JSON.parse(raw));
}
export function readState(storage) {
  const raw = storage.getItem(storageKey);
  return raw === null ? { version: 1, accounts: [] } : parseState(raw);
}
export function writeState(storage, value) {
  const valid = validateState(value), raw = JSON.stringify(valid);
  if (new Blob([raw]).size > fileLimit) throw new Error('资料超过 4 MiB，本次未保存。');
  storage.setItem(storageKey, raw);
  return valid;
}
/** @param {string|null} id */
export function saveAccount(state, fields, id = null, now = new Date()) {
  const existing = id ? state.accounts.find((row) => row.id === id && !row.deletedAt) : null;
  if (id && !existing) throw new Error('账号已不存在，请重新打开记录。');
  const row = { ...fields, id: existing?.id ?? crypto.randomUUID(), updatedAt: iso(now), deletedAt: null };
  return validateState({ version: 1, accounts: existing ? state.accounts.map((item) => item.id === id ? row : item) : [...state.accounts, row] });
}
export function changeDeleted(state, id, deleted, now = new Date()) {
  const row = state.accounts.find((item) => item.id === id);
  if (!row || Boolean(row.deletedAt) === deleted) throw new Error('账号状态已改变，请重新打开记录。');
  return validateState({ version: 1, accounts: state.accounts.map((item) => item.id === id ? { ...item, deletedAt: deleted ? iso(now) : null, updatedAt: iso(now) } : item) });
}
export function mergeState(state, incoming) {
  const valid = validateState(incoming), next = [...state.accounts];
  for (const row of valid.accounts) {
    const previous = next.find((item) => item.id.toLowerCase() === row.id);
    if (!previous) next.push(row);
    else if (JSON.stringify(validateState({ version: 1, accounts: [previous] }).accounts[0]) !== JSON.stringify(row)) throw new Error('文件含同一账号的不同版本，未导入。请先在原设备确认记录。');
  }
  return validateState({ version: 1, accounts: next });
}
export function daysUntilExpiry(value, now = new Date()) {
  if (!value) return null;
  const day = (d) => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
  return Math.round((day(new Date(value)) - day(now)) / 86400000);
}
