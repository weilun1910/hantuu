(() => {
  'use strict';
  let enabled = false, overlay = null, target = null;
  const post = body => window.webkit.messageHandlers.browserPicker.postMessage(body);
  const trim = (value, limit) => String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit);
  function selector(el) {
    const unique = s => { try { return document.querySelectorAll(s).length === 1; } catch (_) { return false; } };
    if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);
    for (const key of ['data-testid', 'data-test', 'name', 'aria-label']) {
      const value = el.getAttribute(key);
      if (value && value.length < 160) {
        const s = el.localName + '[' + key + '=' + JSON.stringify(value) + ']';
        if (unique(s)) return s;
      }
    }
    const parts = [];
    for (let node = el; node && parts.length < 12; node = node.parentElement) {
      let part = node.localName;
      if (node.id) part = '#' + CSS.escape(node.id);
      else if (node.parentElement) {
        const peers = [...node.parentElement.children].filter(n => n.localName === node.localName);
        if (peers.length > 1) part += ':nth-of-type(' + (peers.indexOf(node) + 1) + ')';
      }
      parts.unshift(part);
      if (unique(parts.join(' > '))) break;
    }
    return parts.join(' > ');
  }
  function payload(el) {
    const r = el.getBoundingClientRect(), css = getComputedStyle(el);
    const secret = el.matches('input[type=password]') || !!el.closest('input[type=password]');
    const labelled = (el.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.textContent || '').join(' ');
    const name = labelled || el.getAttribute('aria-label') || [...(el.labels || [])].map(l => l.textContent).join(' ') || el.getAttribute('alt') || el.getAttribute('title') || el.innerText;
    const roles = {button:'button', a:el.hasAttribute('href') ? 'link' : 'generic', textarea:'textbox', select:'combobox', img:'img', h1:'heading', h2:'heading', h3:'heading'};
    const role = el.getAttribute('role') || roles[el.localName] || (el.localName === 'input' ? ({checkbox:'checkbox', radio:'radio', range:'slider', button:'button', submit:'button'}[el.type] || 'textbox') : 'generic');
    const clone = el.cloneNode(true);
    for (const n of [clone, ...clone.querySelectorAll('*')]) {
      for (const a of [...n.attributes]) if (/^(value|srcdoc)$/i.test(a.name) || /token|secret|password|authorization|cookie/i.test(a.name)) n.removeAttribute(a.name);
      if (n.matches('script,style,textarea,input[type=password]')) n.textContent = '';
    }
    const walker = document.createTreeWalker(clone, NodeFilter.SHOW_TEXT);
    let text; while ((text = walker.nextNode())) text.textContent = trim(text.textContent, 80);
    const styles = {};
    for (const key of ['display','position','width','height','margin','padding','font','color','background-color']) styles[key] = trim(css.getPropertyValue(key), 200);
    return {selector: selector(el), role: trim(role, 80), name: secret ? '[redacted]' : trim(name, 240), text: secret ? '[redacted]' : trim(el.innerText, 1000), html: clone.outerHTML.slice(0,600), styles, bounds:{x:r.x,y:r.y,width:r.width,height:r.height}, viewport:{width:innerWidth,height:innerHeight}};
  }
  function hide() { overlay?.remove(); overlay = null; target = null; }
  function outline(el) {
    if (!enabled || !el || el === overlay) return;
    target = el;
    const r = el.getBoundingClientRect();
    if (!overlay) {
      overlay = document.createElement('div');
      overlay.setAttribute('data-hantuu-picker-outline', '');
      document.documentElement.appendChild(overlay);
    }
    overlay.style.cssText = `all:initial!important;position:fixed!important;pointer-events:none!important;z-index:2147483647!important;box-sizing:border-box!important;border:1px solid #4c93ff!important;background:rgba(76,147,255,.10)!important;left:${r.x}px!important;top:${r.y}px!important;width:${r.width}px!important;height:${r.height}px!important;`;
  }
  function setEnabled(value) { enabled = !!value; if (!enabled) hide(); }
  document.addEventListener('mousemove', event => {
    if (!enabled || !event.isTrusted) return;
    outline(event.target instanceof Element ? event.target : null);
  }, true);
  document.addEventListener('click', event => {
    if (!enabled || !event.isTrusted || !(event.target instanceof Element)) return;
    event.preventDefault(); event.stopImmediatePropagation();
    const data = payload(event.target);
    setEnabled(false);
    post({kind:'pick', payload:data});
  }, true);
  document.addEventListener('keydown', event => {
    if (!enabled || !event.isTrusted || event.key !== 'Escape') return;
    event.preventDefault(); event.stopImmediatePropagation(); setEnabled(false); post({kind:'cancel'});
  }, true);
  // Only native evaluation in this content world can call these functions.
  Object.defineProperty(window, '__hantuuPicker', {value: Object.freeze({setEnabled, payload, outline}), writable:false});
})();
