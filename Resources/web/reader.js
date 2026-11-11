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
  const pendingNodes = new Map();

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

  // Images attached to a message: pasted ones arrive as data: URLs, others as paths.
  function images(srcs) {
    if (!srcs || !srcs.length) return null;
    const box = document.createElement('div');
    box.className = 'media';
    for (const src of srcs) {
      const path = src.startsWith('/') ? src : null;
      box.appendChild(R.mediaFigure('image', path ? R.fileURL(path) : src, path, true));
    }
    return box;
  }

  function renderEntry(e) {
    const el = document.createElement('section');
    el.className = 'entry ' + e.kind;
    el.dataset.id = e.id;
    if (e.pending) el.classList.add('pending');
    const shown = new Set();
    switch (e.kind) {
      case 'user':
        el.appendChild(label('You'));
        if (e.pending) el.appendChild(label('Queued', 'queued-label'));
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
      const old = pendingNodes.get(e.replacesPendingID);
      let el;
      if (old && e.kind === 'user') {
        // Keep the bubble and its decoded images while delivery catches up. The next reset
        // renders the canonical transcript text and images.
        el = old;
        pendingNodes.delete(e.replacesPendingID);
        el.dataset.id = e.id;
        el.classList.remove('pending', 'fresh');
        const queued = el.querySelector('.queued-label');
        if (queued) queued.remove();
      } else {
        if (old) { old.remove(); pendingNodes.delete(e.replacesPendingID); }
        el = renderEntry(e);
        if (main) main.decorate(el, e, fresh && !e.replacesPendingID);
      }
      frag.appendChild(el);
    }
    const firstPending = Array.from(list.children).find((el) => el.classList.contains('pending'));
    list.insertBefore(frag, firstPending || null);
    if (main) main.settle(list, !fresh);
    empty.hidden = list.childElementCount > 0;
  }

  // Pending sends stay at the end, after every delivered entry. Updating them never
  // rebuilds the transcript or closes an expanded work log or media preview.
  function syncPending(entries) {
    const keep = new Set(entries.map((e) => e.id));
    for (const [id, el] of pendingNodes) {
      if (!keep.has(id)) { el.remove(); pendingNodes.delete(id); }
    }
    for (const e of entries) {
      if (pendingNodes.has(e.id)) continue;
      const el = renderEntry(e);
      if (main) main.decorate(el, e, false);
      pendingNodes.set(e.id, el);
      list.appendChild(el);
    }
    empty.hidden = list.childElementCount > 0;
  }

  window.hantuu = {
    // Esc while the message box has the keyboard: shrink an opened-out preview first.
    collapseMedia() { return R.collapseMedia(); },
    pdfInfo(payload) { R.pdfInfo(payload); },
    // Show a chat from scratch. Restores where you were last time you read it.
    reset(payload) {
      chatID = payload.chatID || null;
      seen.clear();
      pendingNodes.clear();
      R.disposeMedia();
      list.textContent = '';
      R.post({ type: 'mediaExpanded', count: 0 });
      empty.textContent = payload.emptyText || '';
      if (main) main.reset(payload.base);
      add(payload.entries || [], false);
      syncPending(payload.pending || []);
      empty.hidden = list.childElementCount > 0;
      // Scroll synchronously: requestAnimationFrame doesn't run while the panel is hidden.
      const memo = chatID ? scrollMemory[chatID] : undefined;
      if (memo === undefined || memo === 'bottom') scrollToBottom();
      else scroller.scrollTop = memo;
    },
    pending(payload) {
      if (payload.chatID !== chatID) return;
      const stick = atBottom();
      const top = scroller.scrollTop;
      syncPending(payload.pending || []);
      if (stick) scrollToBottom();
      else scroller.scrollTop = top;
    },
    // Add new entries. Sticks to the bottom only if you were already there.
    append(payload) {
      if (payload.chatID !== chatID) return;
      const stick = atBottom();
      add(payload.entries || [], true);
      syncPending(payload.pending || []);
      if (stick) scrollToBottom();
      else pill.hidden = false;
    },
  };

  R.post({ type: 'ready' });
})();
