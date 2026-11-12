(() => {
  'use strict';
  // The page owns its console. Capture here, then relay untrusted strings into the
  // isolated world. No native message handler is exposed to this world.
  const dispatch = document.dispatchEvent.bind(document);
  const Custom = CustomEvent;
  const stringify = value => {
    if (typeof value === 'string') return value.slice(0,2000);
    try {
      const seen = new WeakSet();
      return JSON.stringify(value, (key, item) => {
        if (/password|token|secret|authorization|cookie/i.test(key)) return '[redacted]';
        if (typeof item === 'string') return item.slice(0,2000);
        if (item && typeof item === 'object') { if (seen.has(item)) return '[circular]'; seen.add(item); }
        return item;
      })?.slice(0,2000) || String(value).slice(0,2000);
    } catch (_) { return '[unserializable]'; }
  };
  function emit(level, args) {
    const text = args.slice(0,20).map(stringify).join(' ').slice(0,2000);
    dispatch(new Custom('__hantuu_page_log', {detail:JSON.stringify({level,text})}));
  }
  for (const level of ['log','info','warn','error']) {
    const original = console[level].bind(console);
    console[level] = (...args) => { try { emit(level,args); } catch (_) {} original(...args); };
  }
  addEventListener('error', e => emit('error',[e.message || 'Resource failed to load', e.filename || '', e.lineno || '']), true);
  addEventListener('unhandledrejection', e => emit('error',['Unhandled rejection:',e.reason]));
})();
