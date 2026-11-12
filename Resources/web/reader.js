// The reader: a calm, readable view of the selected chat's transcript.
(function () {
  'use strict';
  const R = window.hantuuRender;
  const parity = window.ReaderParity;
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
  let sideVersions = new Map();

  function atBottom() {
    return scroller.scrollHeight - scroller.scrollTop - window.innerHeight < 48;
  }

  function scrollToBottom() {
    scroller.scrollTop = scroller.scrollHeight;
    pill.hidden = true;
  }

  window.addEventListener('scroll', () => {
    if (chatID) scrollMemory[chatID] = atBottom() ? 'bottom' : scroller.scrollTop;
    pill.hidden = atBottom();
  });
  pill.addEventListener('click', scrollToBottom);
  if (window.ResizeObserver) new ResizeObserver(() => { pill.hidden = atBottom(); }).observe(list);

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

  function updatePending(el, e) {
    let state = el.querySelector('.queued-label');
    if (!state) {
      state = label('', 'queued-label');
      state.setAttribute('aria-live', 'polite');
      el.appendChild(state);
    }
    state.textContent = e.deliveryRequested ? 'Delivering' : 'Queued';
    let button = el.querySelector('.send-now');
    if (!e.pending || !e.sendNowLabel || e.deliveryRequested) {
      if (button) {
        if (document.activeElement === button) R.post({ type: 'focusComposer' });
        button.remove();
      }
      return;
    }
    if (!button) {
      button = document.createElement('button');
      button.type = 'button';
      button.className = 'send-now';
      const owner = chatID;
      button.addEventListener('click', () => R.post({ type: 'sendNow', chatID: owner, id: e.id }));
      button.addEventListener('keydown', (event) => {
        const buttons = Array.from(list.querySelectorAll('.send-now'));
        const boundary = event.shiftKey ? buttons[0] : buttons[buttons.length - 1];
        if (event.key === 'Escape' || (event.key === 'Tab' && boundary === button)) {
          event.preventDefault();
          R.post({ type: 'focusComposer' });
        }
      });
      el.appendChild(button);
    }
    button.textContent = e.sendNowLabel;
    button.title = e.sendNowLabel + ' (may interrupt the current work)';
    button.setAttribute('aria-label', e.sendNowLabel);
  }

  function renderEntry(e) {
    const evidence = parity && parity.renderEntry(e);
    if (evidence) return evidence;
    const el = document.createElement('section');
    el.className = 'entry ' + e.kind;
    el.dataset.id = e.id;
    if (e.pending) el.classList.add('pending');
    const shown = new Set();
    switch (e.kind) {
      case 'user':
        el.appendChild(label(e.author ? 'From ' + e.author : 'You', e.author ? 'sender-label' : ''));
        if (e.pending) updatePending(el, e);
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
          line.tabIndex = 0; line.setAttribute('role', 'button'); line.setAttribute('aria-expanded', 'false');
          line.addEventListener('keydown', ev => { if ((ev.key === 'Enter' || ev.key === ' ') && ev.target === line) { ev.preventDefault(); line.click(); } });
          line.title = 'Show the full command';
          line.addEventListener('click', (ev) => {
            if (ev.target.closest('a')) return;
            const open = el.querySelector('pre.full');
            if (open) { open.remove(); line.setAttribute('aria-expanded', 'false'); return; }
            line.setAttribute('aria-expanded', 'true');
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
          if (e.detailTitle) {
            const disclosure = document.createElement('details');
            disclosure.className = 'parity-disclosure';
            const summary = document.createElement('summary');
            summary.textContent = e.detailTitle;
            disclosure.appendChild(summary);
            disclosure.appendChild(pre);
            el.appendChild(disclosure);
          } else {
            el.appendChild(pre);
          }
        }
        break;
      case 'plan':
        el.appendChild(label('Plan'));
        el.appendChild(body(e.text, e.links, false));
        break;
      case 'notice':
      default:
        el.textContent = e.text;
        if (parity) parity.register(e, el);
        return el;
    }
    const pics = images(e.images);
    if (pics) el.appendChild(pics);
    const media = R.mediaFor(e.links, shown);
    if (media) el.appendChild(media);
    if (parity) parity.register(e, el);
    return el;
  }

  function add(entries, fresh) {
    const frag = document.createDocumentFragment();
    // Unwrap affected groups before reconciling evidence so failures cannot stay hidden.
    const updated = new Set(entries.filter(e => seen.has(e.id)).map(e => e.id));
    if (updated.size) for (const group of Array.from(list.querySelectorAll('.toolgroup'))) {
      if (!Array.from(group.querySelectorAll('.entry')).some(el => updated.has(el.dataset.id))) continue;
      for (const row of Array.from(group.querySelectorAll('.toolrows > .entry'))) list.insertBefore(row, group);
      group.remove();
    }
    const existing = new Map(Array.from(list.querySelectorAll('.entry[data-id]')).map(el => [el.dataset.id, el]));
    for (const e of entries) {
      if (seen.has(e.id)) {
        if (sideVersions.get(e.id) === JSON.stringify(e)) continue;
        sideVersions.set(e.id, JSON.stringify(e));
        const prior = existing.get(e.id);
        if (prior) {
          const replacement = renderEntry(e);
          if (main) main.decorate(replacement, e, false);
          prior.replaceWith(replacement);
          existing.set(e.id, replacement);
        } else {
          const replacement = renderEntry(e);
          if (main) main.decorate(replacement, e, false);
          frag.appendChild(replacement); existing.set(e.id, replacement);
        }
        continue;
      }
      seen.add(e.id);
      for (const id of (e.replacesPendingIDs || [])) {
        const grouped = pendingNodes.get(id);
        if (grouped) {
          if (grouped.contains(document.activeElement)) R.post({ type: 'focusComposer' });
          grouped.remove();
          pendingNodes.delete(id);
        }
      }
      sideVersions.set(e.id, JSON.stringify(e));
      const old = pendingNodes.get(e.replacesPendingID);
      let el;
      if (old && e.kind === 'user') {
        // Keep the bubble and its decoded images while delivery catches up. The next reset
        // renders the canonical transcript text and images.
        el = old;
        pendingNodes.delete(e.replacesPendingID);
        el.dataset.id = e.id;
        el.classList.remove('pending', 'fresh');
        if (parity) parity.register(e, el);
        const queued = el.querySelector('.queued-label');
        if (queued) queued.remove();
        const action = el.querySelector('.send-now');
        if (action) {
          if (document.activeElement === action) R.post({ type: 'focusComposer' });
          action.remove();
        }
      } else {
        if (old) { old.remove(); pendingNodes.delete(e.replacesPendingID); }
        el = renderEntry(e);
        if (main) main.decorate(el, e, fresh && !e.replacesPendingID && !e.replacesPendingIDs);
      }
      frag.appendChild(el);
      existing.set(e.id, el);
    }
    const firstPending = Array.from(list.children).find((el) => el.classList.contains('pending'));
    list.insertBefore(frag, firstPending || null);
    if (main) main.settle(list, !fresh || updated.size > 0);
    if (parity) { parity.prune(); parity.refreshSearch(); }
    empty.hidden = list.childElementCount > 0;
  }

  // Pending sends stay at the end, after every delivered entry. Updating them never
  // rebuilds the transcript or closes an expanded work log or media preview.
  function syncPending(entries) {
    const keep = new Set(entries.map((e) => e.id));
    for (const [id, el] of pendingNodes) {
      if (!keep.has(id)) {
        if (el.contains(document.activeElement)) R.post({ type: 'focusComposer' });
        el.remove();
        pendingNodes.delete(id);
      }
    }
    for (const e of entries) {
      if (pendingNodes.has(e.id)) {
        updatePending(pendingNodes.get(e.id), e);
        continue;
      }
      const el = renderEntry(e);
      if (main) main.decorate(el, e, false);
      pendingNodes.set(e.id, el);
      list.appendChild(el);
    }
    empty.hidden = list.childElementCount > 0;
    if (parity) { parity.prune(); parity.refreshSearch(); }
  }

  window.hantuu = {
    focusQueue() {
      const buttons = list.querySelectorAll('.send-now');
      if (!buttons.length) return false;
      buttons[buttons.length - 1].focus();
      return true;
    },
    readerFind(payload) {
      if (!parity) return;
      if (payload.action === 'close') parity.closeFind();
      else if (payload.action === 'next') parity.nextMatch(payload.backwards);
      else parity.openFind();
    },
    readerHealth(payload) { if (parity) parity.setStatus(payload); },
    readerRequests(payload) { if (parity) parity.setRequests(payload); },
    readerRequestResult(payload) { if (parity) parity.requestResult(payload); },
    readerFileResult(payload) {
      for (const link of list.querySelectorAll('a.parity-file')) if (link.dataset.path === payload.path) {
        link.title = 'This file is unavailable. Its recorded patch and path remain in the conversation.';
        if (!link.nextElementSibling?.classList.contains('parity-unavailable')) {
          const note = document.createElement('span'); note.className = 'parity-note parity-unavailable'; note.textContent = 'File unavailable'; link.after(note);
        }
      }
    },
    // Esc while the message box has the keyboard: shrink an opened-out preview first.
    collapseMedia() { return R.collapseMedia(); },
    pdfInfo(payload) { R.pdfInfo(payload); },
    // Show a chat from scratch. Restores where you were last time you read it.
    reset(payload) {
      chatID = payload.chatID || null;
      if (parity) parity.reset(chatID);
      seen.clear();
      pendingNodes.clear();
      sideVersions.clear();
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
    // Side questions stream into stable entries without rebuilding older answers.
    reconcile(payload) {
      if (payload.chatID !== chatID) {
        this.reset(payload);
        sideVersions = new Map((payload.entries || []).map(e => [e.id, JSON.stringify(e)]));
        return;
      }
      const stick = atBottom();
      const top = scroller.scrollTop;
      const entries = payload.entries || [];
      // Reconcile in transcript order; work groups are a presentation wrapper only.
      for (const group of Array.from(list.querySelectorAll('.toolgroup'))) {
        for (const row of Array.from(group.querySelectorAll('.toolrows > .entry'))) list.insertBefore(row, group);
        group.remove();
      }
      let changed = false;
      const wanted = new Set(entries.map(e => e.id));
      const nodes = new Map(Array.from(list.querySelectorAll('.entry[data-id]')).map(el => [el.dataset.id, el]));
      for (const [id, el] of nodes) {
        if (!wanted.has(id)) { el.remove(); seen.delete(id); sideVersions.delete(id); changed = true; }
      }
      for (const e of entries) {
        const version = JSON.stringify(e);
        if (sideVersions.get(e.id) === version) continue;
        changed = true;
        const node = renderEntry(e);
        if (main) main.decorate(node, e, false);
        const old = nodes.get(e.id);
        if (old && old.isConnected) old.replaceWith(node);
        else list.appendChild(node);
        seen.add(e.id);
        sideVersions.set(e.id, version);
      }
      // A first answer is inserted before its existing streaming status line.
      const ordered = new Map(Array.from(list.children).map(el => [el.dataset.id, el]));
      for (let i = 0; i < entries.length; i++) {
        const node = ordered.get(entries[i].id);
        if (node && list.children[i] !== node) list.insertBefore(node, list.children[i] || null);
      }
      if (main) main.settle(list, true);
      empty.textContent = payload.emptyText || '';
      empty.hidden = list.childElementCount > 0;
      if (parity) { parity.prune(); parity.refreshSearch(); }
      if (stick) scrollToBottom();
      else { scroller.scrollTop = top; if (changed) pill.hidden = false; }
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
