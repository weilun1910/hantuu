// The reader: a calm, readable view of the selected chat's transcript.
(function () {
  'use strict';
  const R = window.hantuuRender;
  const list = document.getElementById('entries');
  const empty = document.getElementById('empty');
  const pill = document.getElementById('newpill');
  const scroller = document.scrollingElement;
  // Reader mode (the chat's main view) loads this page with ?layout=main.
  if (new URLSearchParams(location.search).get('layout') === 'main') document.body.classList.add('main');
  // Reader mode's additions (reader-main.js). Null in the panel's Reader.
  const main = document.body.classList.contains('main') ? window.hantuuMain : null;

  let chatID = null;
  const scrollMemory = {};
  const seen = new Set();

  function atBottom() {
    return scroller.scrollHeight - scroller.scrollTop - window.innerHeight < 48;
  }

  function scrollToBottom() {
    scroller.scrollTop = scroller.scrollHeight;
    pill.hidden = true;
  }

  window.addEventListener('scroll', () => {
    if (chatID) scrollMemory[chatID] = atBottom() ? 'bottom' : scroller.scrollTop;
    if (atBottom()) pill.hidden = true;
  });
  pill.addEventListener('click', scrollToBottom);

  function label(text, cls) {
    const d = document.createElement('div');
    d.className = 'label' + (cls ? ' ' + cls : '');
    d.textContent = text;
    return d;
  }

  function body(markdown, links, breaks) {
    const d = document.createElement('div');
    d.className = 'md';
    d.innerHTML = R.renderMarkdown(markdown, { breaks });
    R.linkifyPaths(d, links);
    return d;
  }

  function images(srcs) {
    if (!srcs || !srcs.length) return null;
    const box = document.createElement('div');
    box.className = 'media';
    for (const src of srcs) {
      const fig = document.createElement('figure');
      const img = document.createElement('img');
      img.src = src.startsWith('/') ? R.fileURL(src) : src;
      img.loading = 'lazy';
      fig.appendChild(img);
      fig.appendChild(R.popoutButton(src));
      box.appendChild(fig);
    }
    return box;
  }

  function renderEntry(e) {
    const el = document.createElement('section');
    el.className = 'entry ' + e.kind;
    el.dataset.id = e.id;
    const shown = new Set();
    switch (e.kind) {
      case 'user':
        el.appendChild(label('You'));
        if (e.text) el.appendChild(body(e.text, e.links, true));
        break;
      case 'assistant':
        el.appendChild(body(e.text, e.links, false));
        break;
      case 'tool': {
        const line = document.createElement('div');
        line.className = 'toolline';
        const t = document.createElement('span');
        t.className = 'tooltext';
        t.textContent = e.text;
        line.appendChild(t);
        if (e.detail) {
          const c = document.createElement('code');
          c.className = 'tooldetail';
          c.textContent = e.detail.split('\n')[0];
          line.appendChild(c);
          line.classList.add('expandable');
          line.title = 'Show the full command';
          line.addEventListener('click', (ev) => {
            if (ev.target.closest('a')) return;
            const open = el.querySelector('pre.full');
            if (open) { open.remove(); return; }
            const pre = document.createElement('pre');
            pre.className = 'full';
            pre.textContent = e.detail;
            el.appendChild(pre);
          });
        }
        el.appendChild(line);
        R.linkifyPaths(line, e.links);
        break;
      }
      case 'question':
        el.appendChild(label('Question for you', 'accent'));
        el.appendChild(body(e.text, e.links, false));
        break;
      case 'attention':
        el.appendChild(label('Needs you', 'accent'));
        el.appendChild(body(e.text, e.links, true));
        break;
      case 'error':
        el.appendChild(label('Error', 'error'));
        el.appendChild(body(e.text, e.links, true));
        if (e.detail) {
          const pre = document.createElement('pre');
          pre.className = 'full';
          pre.textContent = e.detail;
          el.appendChild(pre);
        }
        break;
      case 'plan':
        el.appendChild(label('Plan'));
        el.appendChild(body(e.text, e.links, false));
        break;
      case 'notice':
      default:
        el.textContent = e.text;
        return el;
    }
    const pics = images(e.images);
    if (pics) el.appendChild(pics);
    const media = R.mediaFor(e.links, shown);
    if (media) el.appendChild(media);
    return el;
  }

  function add(entries, fresh) {
    const frag = document.createDocumentFragment();
    for (const e of entries) {
      if (seen.has(e.id)) continue;
      seen.add(e.id);
      const el = renderEntry(e);
      if (main) main.decorate(el, e, fresh);
      frag.appendChild(el);
    }
    list.appendChild(frag);
    if (main) main.settle(list, !fresh);
    empty.hidden = list.childElementCount > 0;
  }

  window.hantuu = {
    // Show a chat from scratch. Restores where you were last time you read it.
    reset(payload) {
      chatID = payload.chatID || null;
      seen.clear();
      list.textContent = '';
      empty.textContent = payload.emptyText || '';
      if (main) main.reset(payload.base);
      add(payload.entries || [], false);
      empty.hidden = list.childElementCount > 0;
      // Scroll synchronously: requestAnimationFrame doesn't run while the panel is hidden.
      const memo = chatID ? scrollMemory[chatID] : undefined;
      if (memo === undefined || memo === 'bottom') scrollToBottom();
      else scroller.scrollTop = memo;
    },
    // Add new entries. Sticks to the bottom only if you were already there.
    append(payload) {
      if (payload.chatID !== chatID) return;
      const stick = atBottom();
      add(payload.entries || [], true);
      if (stick) scrollToBottom();
      else pill.hidden = false;
    },
  };

  R.post({ type: 'ready' });
})();
