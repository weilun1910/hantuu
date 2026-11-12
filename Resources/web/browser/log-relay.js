(() => {
  'use strict';
  // DOM events are page data. This relay never forwards picker actions or commands.
  let pending = [], scheduled = false;
  document.addEventListener('__hantuu_page_log', event => {
    if (typeof event.detail !== 'string' || event.detail.length > 12000) return;
    let item; try { item = JSON.parse(event.detail); } catch (_) { return; }
    if (!item || !['log','info','warn','error'].includes(item.level) || typeof item.text !== 'string') return;
    pending.push({level:item.level, text:item.text.slice(0,2000)});
    if (pending.length > 500) pending.shift();
    if (!scheduled) {
      scheduled = true;
      setTimeout(() => {
        const entries = pending; pending = []; scheduled = false;
        window.webkit.messageHandlers.browserLogs.postMessage({kind:'logs', entries});
      }, 100);
    }
  }, true);
})();
