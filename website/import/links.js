export function importLinks(fragment) {
  if (fragment.length > 8192) throw new Error('导入信息过长，请从 App 重新扫码。');
  const values = new URLSearchParams(fragment.replace(/^#/, ''));
  const base = new URL(values.get('url') || '');
  if (base.origin !== 'https://node.tangchen02.top' || base.username || base.password || base.search || base.hash || !/^\/remote-sub\/[a-f0-9]{32}\/[a-f0-9]{64}(?:\/[^/]+)?$/.test(base.pathname)) {
    throw new Error('导入地址无效，请使用 App 中当前远程订阅的二维码。');
  }
  const name = (values.get('name') || 'Claude 专用').replace(/[\u0000-\u001f\u007f\u0085\u2028\u2029]/g, ' ').slice(0, 120);
  const exportPath = '/' + base.pathname.split('/').filter(Boolean).slice(0, 3).join('/');
  const nodes = new URL(base); nodes.pathname = exportPath + '/claude-nodes.txt'; nodes.searchParams.set('format', 'shadowrocket-nodes');
  const moduleURL = new URL(base); moduleURL.pathname = exportPath + '/claude.module'; moduleURL.searchParams.set('format', 'shadowrocket-module');
  const title = name + ' · Claude 节点';
  const wrapped = 'sub://' + btoa(String.fromCharCode(...new TextEncoder().encode(nodes.href))) + '?remark=' + encodeURIComponent(title);
  return { name, standalone: values.get('mode') === 'shadowrocket', nodes: nodes.href, module: moduleURL.href, addNodes: 'shadowrocket://add/' + wrapped, addModule: 'shadowrocket://install?module=' + encodeURIComponent(moduleURL.href) };
}
