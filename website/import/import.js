import { importLinks } from './links.js?v=5';
const feedback = document.querySelector('#feedback');
function initialize() {
  document.querySelector('#guide').hidden = true;
  document.querySelector('#missing').hidden = false;
  document.querySelector('#add-nodes').removeAttribute('href');
  document.querySelector('#add-module').removeAttribute('href');
  feedback.textContent = '';
  try {
    const links = importLinks(location.hash);
    history.replaceState(null, '', location.pathname);
    document.querySelector('#profile').textContent = links.name;
    document.querySelector('#chain-step').hidden = !links.standalone;
    document.querySelector('#module-description').textContent = links.standalone ? '只添加 Claude 域名规则，保留现有网站分流。如果已启用旧的 Claude 模块，请先停用旧模块，再启用这一份，避免重复规则。' : '只添加 Claude 相关域名的规则；现有网站分流、DNS 和兜底策略继续保留。';
    document.querySelector('#node-description').textContent = links.standalone ? '只添加你配置的静态出口，不需要源 Clash 订阅。' : '仅导入所需出口与链式前置，不复制原订阅的其他分组。';
    document.querySelector('#chain-description').textContent = links.standalone ? '需要链式代理时，先完成上面的“代理通过”设置。日常切换首页节点不会改变这里指定的前置。修改静态出口后更新订阅，请重新检查“代理通过”。' : '多出口组默认使用首个已选出口。链式前置分组展开后使用首个明确节点；要更换前置，可在固定出口节点的“代理通过”中选择其他节点。请勿选择固定出口自身。';
    document.querySelector('#add-nodes').href = links.addNodes;
    document.querySelector('#add-module').href = links.addModule;
    document.querySelector('#guide').hidden = false;
    document.querySelector('#missing').hidden = true;
    document.querySelectorAll('[data-copy]').forEach((button) => {
      button.onclick = async () => {
        try {
          await navigator.clipboard.writeText(button.dataset.copy === 'nodes' ? links.nodes : links.module);
          feedback.textContent = '已复制对应地址，请回到小火箭粘贴。';
        } catch { feedback.textContent = '浏览器未允许复制，请用 Safari 打开此页再试。'; }
      };
    });
  } catch {
    history.replaceState(null, '', location.pathname);
    document.querySelector('#missing').textContent = '请在 cc助手的线路卡片里点击“手机扫码”，选择“小火箭导入向导”，再用手机系统相机扫码打开此页。';
  }
}
initialize();
window.addEventListener('hashchange', initialize);
