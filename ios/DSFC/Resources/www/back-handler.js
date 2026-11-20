/* 返回键处理：优先关闭最上层弹窗 → 关侧边栏 → 否则交回原生退出 */
(function () {
  'use strict';

  function closestOverlay() {
    // Modal 用 createPortal 挂到 body，直接找可见的 overlay
    var nodes = document.querySelectorAll('div[role="dialog"]');
    if (!nodes.length) return null;
    return nodes[nodes.length - 1];
  }

  function closeTopModal() {
    var dialog = closestOverlay();
    if (!dialog) return false;
    // 弹窗的遮罩是父元素；点遮罩会触发 onMouseDown 关闭
    var overlay = dialog.parentElement;
    if (overlay) {
      overlay.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
      return true;
    }
    // 退回：找关闭按钮
    var btn = dialog.querySelector('button[aria-label]');
    if (btn) { btn.click(); return true; }
    return false;
  }

  function closeDrawer() {
    var mask = document.querySelector('[class*="drawerMask"]');
    if (mask) {
      mask.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      return true;
    }
    return false;
  }

  window.__dsfcBack = function () {
    if (closeTopModal()) return 'overlay';
    if (closeDrawer()) return 'sidebar';
    return 'exit';
  };
})();
