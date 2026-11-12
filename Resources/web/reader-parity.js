// Retained transcript evidence. Never infers completion from a requested tool call.
(function () {
  'use strict';
  const R = window.hantuuRender;
  const expanded = new Map();
  const records = new Map();
  let chat = null, query = '', matches = [], current = -1, previousFocus = null;
  let findbar, field, counter;
  const states = { requested: 'Requested', running: 'Running', completed: 'Completed', failed: 'Failed', interrupted: 'Interrupted', declined: 'Declined', unknown: 'Outcome unknown' };
  function node(tag, cls, text) {
    const el = document.createElement(tag); el.className = cls || '';
    if (text !== undefined) el.textContent = text;
    return el;
  }
  function button(text, action) {
    const b = node('button', 'parity-action', text); b.type = 'button'; b.addEventListener('click', action); return b;
  }
  function copy(text, label) {
    return button(label, ev => { R.post({ type: 'copy', text }); ev.currentTarget.textContent = 'Copied'; });
  }
  function disclosure(key, title, open) {
    const d = node('details', 'parity-disclosure'); d.dataset.disclosure = key;
    d.open = expanded.has(key) ? expanded.get(key) : !!open;
    d.appendChild(node('summary', '', title));
    d.addEventListener('toggle', () => {
      // Search expansion is temporary. Only clicks/keys below save a preference.
      if (!query) expanded.set(key, d.open);
    });
    d.firstChild.addEventListener('click', () => expanded.set(key, !d.open));
    return d;
  }
  function retained(parent, text, key, label) {
    if (text == null || text === '') return;
    text = typeof text === 'string' ? text : JSON.stringify(text, null, 2);
    const wrap = node('div', 'parity-retained');
    const head = node('div', 'parity-output-head'); head.appendChild(node('span', '', label)); head.appendChild(copy(text, 'Copy ' + label.toLowerCase()));
    wrap.appendChild(head);
    const pre = node('pre', 'parity-output');
    const more = text.length > 6000;
    const showFull = !!expanded.get(key);
    pre.textContent = more && !showFull ? text.slice(0, 6000) : text;
    wrap.dataset.fullText = text; wrap.dataset.contentKey = key;
    wrap.appendChild(pre);
    if (more) {
      const b = button(showFull ? 'Show less' : 'Show more (' + text.length.toLocaleString() + ' characters)', () => {
        const full = pre.textContent.length !== text.length;
        expanded.set(key, full); pre.textContent = full ? text : text.slice(0, 6000);
        b.textContent = full ? 'Show less' : 'Show more (' + text.length.toLocaleString() + ' characters)';
      });
      b.classList.add('parity-more'); wrap.appendChild(b);
    }
    parent.appendChild(wrap);
  }
  function renderPatch(parent, patch, key, files) {
    if (!patch) return;
    const text = typeof patch === 'string' ? patch : patch.text || patch.diff || '';
    const lines = text.split('\n');
    const added = typeof patch.additions === 'number' ? patch.additions : lines.filter(l => l.startsWith('+') && !l.startsWith('+++')).length;
    const removed = typeof patch.deletions === 'number' ? patch.deletions : lines.filter(l => l.startsWith('-') && !l.startsWith('---')).length;
    const box = node('div', 'parity-patch');
    box.appendChild(node('div', 'parity-note', 'Historical patch | +' + added + ' / -' + removed));
    const paths = typeof patch === 'object' && patch.path ? [patch.path] : lines.flatMap(l => {
      const m = l.match(/^(?:\*\*\* (?:Update|Add|Delete) File: |\+\+\+ b\/)(.+)$/); return m ? [m[1]] : [];
    });
    for (const path of new Set(paths.concat((files || []).map(f => typeof f === 'string' ? f : f.path).filter(Boolean)))) box.appendChild(button(path, () => R.post({ type: 'open', path })));
    retained(box, text, key + ':patch', 'Patch'); parent.appendChild(box);
  }
  function renderEntry(e) {
    if (!e.operation && !e.checklist && e.kind !== 'reasoning') return null;
    const el = node('section', 'entry ' + e.kind + ' parity-entry'); el.dataset.id = e.id;
    if (['plan', 'question', 'attention'].includes(e.kind)) {
      el.appendChild(node('div', 'label', e.kind === 'plan' ? 'Plan' : e.kind === 'question' ? 'Question for you' : 'Needs you'));
      const body = node('div', 'md'); body.innerHTML = R.renderMarkdown(e.text || '', { breaks: false }); R.linkifyPaths(body, e.links); el.appendChild(body);
      if (e.kind !== 'plan') el.appendChild(button('Show Terminal', () => R.post({ type: 'showTerminal' })));
    }
    if (e.kind === 'reasoning') {
      const d = disclosure(e.id + ':reasoning', e.redacted ? 'Reasoning unavailable' : 'Reasoning', false);
      retained(d, e.text || e.detail, e.id + ':reasoning-text', 'Reasoning'); el.appendChild(d);
    }
    if (e.operation) {
      const op = e.operation, state = op.state || 'unknown';
      el.dataset.operationState = state;
      if (['failed', 'interrupted', 'declined'].includes(state)) el.classList.add('parity-failure');
      if (op.childID || op.report) el.classList.add('parity-delegated');
      const title = (op.name || e.tool || 'Operation') + ' | ' + (states[state] || states.unknown) + (op.exitCode != null ? ' | Exit ' + op.exitCode : '');
      const d = disclosure(e.id + ':operation', title, ['failed', 'declined'].includes(state));
      if (e.text && !['plan', 'question', 'attention'].includes(e.kind)) d.appendChild(node('div', 'parity-note', e.text));
      retained(d, op.command, e.id + ':command', 'Command');
      if (!op.command) retained(d, op.arguments, e.id + ':arguments', 'Arguments');
      retained(d, op.output, e.id + ':output', 'Output');
      if (op.truncated) d.appendChild(node('div', 'parity-note', 'The provider retained only part of this output.'));
      renderPatch(d, op.patch, e.id, e.files);
      if (op.patchNote) d.appendChild(node('div', 'parity-note', op.patchNote));
      if (op.outputFile) d.appendChild(button('Open retained output', () => R.post({ type: 'open', path: op.outputFile })));
      if (op.duration != null && state !== 'running') d.appendChild(node('div', 'parity-note', 'Duration ' + op.duration.toFixed(1) + ' seconds'));
      if (state === 'running' && op.startedAt) {
        const elapsed = node('div', 'parity-note parity-elapsed'); elapsed.dataset.startedAt = op.startedAt; d.appendChild(elapsed);
      }
      retained(d, op.report, e.id + ':report', 'Report');
      if (op.childID) d.appendChild(button('Open agent conversation', () => R.post({ type: 'selectAgent', id: op.childID })));
      if (op.activity) d.appendChild(node('div', 'parity-note', op.activity));
      const fileLinks = node('div', 'parity-files');
      for (const path of new Set(e.files || [])) {
        const link = node('a', 'path parity-file', path); link.href = '#'; link.dataset.path = path;
        link.addEventListener('click', ev => { ev.preventDefault(); R.post({ type: 'open', path }); });
        fileLinks.append(link, copy(path, 'Copy path'));
      }
      if (fileLinks.childElementCount) el.appendChild(fileLinks);
      if (op.startedAt || op.finishedAt) d.appendChild(node('div', 'parity-note', [op.startedAt && 'Started ' + op.startedAt, op.finishedAt && 'Finished ' + op.finishedAt].filter(Boolean).join(' | ')));
      el.appendChild(d);
    }
    if (e.checklist) {
      el.classList.add('parity-checklist');
      const items = e.checklist.items || [];
      const done = items.filter(i => ['completed', 'done'].includes(i.status)).length;
      el.appendChild(node('div', 'parity-checklist-title', 'Checklist | ' + done + ' of ' + items.length + ' done'));
      if (e.checklist.state && e.checklist.state !== 'completed') el.appendChild(node('div', 'parity-note', states[e.checklist.state] || e.checklist.state));
      const ul = node('ul', 'parity-tasks');
      for (const item of items) {
        const li = node('li', '', item.text); li.dataset.status = item.status;
        li.prepend(node('span', 'parity-task-state', (item.status || 'pending').replaceAll('_', ' ') + ': ')); ul.appendChild(li);
      }
      el.appendChild(ul);
    }
    if (e.images && e.images.length) {
      const media = node('div', 'media');
      for (const src of e.images) { const path = src.startsWith('/') ? src : null; media.appendChild(R.mediaFigure('image', path ? R.fileURL(path) : src, path, true)); }
      el.appendChild(media);
    }
    const media = R.mediaFor(e.links, new Set()); if (media) el.appendChild(media);
    register(e, el); return el;
  }
  let pinnedChecklist;
  function pinChecklist(e) {
    if (!pinnedChecklist) {
      pinnedChecklist = node('aside', 'reader-checklist-pin'); pinnedChecklist.setAttribute('aria-label', 'Current checklist'); document.body.appendChild(pinnedChecklist);
      if (window.ResizeObserver) new ResizeObserver(() => { document.documentElement.style.setProperty('--reader-checklist-height', pinnedChecklist.hidden ? '0px' : pinnedChecklist.offsetHeight + 'px'); }).observe(pinnedChecklist);
    }
    pinnedChecklist.replaceChildren(); pinnedChecklist.hidden = !e;
    if (!e) { document.documentElement.style.setProperty('--reader-checklist-height', '0px'); return; }
    const checklist = e.checklist, items = checklist.items || [];
    const done = items.filter(i => i.status === 'completed').length;
    const current = items.find(i => ['in_progress', 'running'].includes(i.status));
    const state = { unconfirmed: 'Update unconfirmed', stale: 'Earlier checklist', interrupted: 'Interrupted', active: 'In progress', completed: 'Completed' }[checklist.state] || checklist.state;
    const title = done + ' of ' + items.length + ' complete | ' + (state || 'Checklist') + (current ? ' | ' + current.text : '');
    const details = disclosure('pinned-checklist', title, false);
    const ul = node('ul', 'parity-tasks');
    for (const item of items) { const li = node('li', '', item.text); li.prepend(node('span', 'parity-task-state', (item.status || 'pending').replaceAll('_', ' ') + ': ')); ul.appendChild(li); }
    if (!items.length) ul.appendChild(node('li', '', 'Waiting for a confirmed checklist.'));
    details.appendChild(ul); pinnedChecklist.appendChild(details);
  }
  function register(e, el) { records.set(e.id, { e, el }); if (e.checklist) pinChecklist(e); }
  function prune() {
    for (const [id, record] of records) if (!record.el.isConnected || record.el.dataset.id !== id) records.delete(id);
    if (![...records.values()].some(r => r.e.checklist)) pinChecklist(null);
  }
  function ensureFind() {
    if (findbar) return;
    findbar = node('div', 'reader-find'); findbar.hidden = true; findbar.setAttribute('role', 'search');
    field = node('input'); field.type = 'search'; field.placeholder = 'Find in conversation'; field.setAttribute('aria-label', 'Find in conversation');
    counter = node('span', 'reader-find-count', '0 matches'); counter.setAttribute('aria-live', 'polite');
    field.addEventListener('input', () => { query = field.value.trim().toLocaleLowerCase(); refreshSearch(true); });
    field.addEventListener('keydown', ev => { if (ev.key === 'Enter') { ev.preventDefault(); move(ev.shiftKey ? -1 : 1); } });
    findbar.append(field, counter, button('Previous', () => move(-1)), button('Next', () => move(1)), button('Close', closeSearch));
    document.body.prepend(findbar);
  }
  function restore() {
    document.querySelectorAll('.reader-search-hit').forEach(el => el.classList.remove('reader-search-hit'));
    for (const d of document.querySelectorAll('details[data-search-open]')) {
      d.open = d.dataset.searchOpen === 'true'; delete d.dataset.searchOpen;
    }
    for (const g of document.querySelectorAll('.toolgroup[data-search-open]')) {
      g.classList.toggle('open', g.dataset.searchOpen === 'true');
      g.querySelector('.toolsum')?.setAttribute('aria-expanded', g.dataset.searchOpen); delete g.dataset.searchOpen;
    }
    for (const wrap of document.querySelectorAll('[data-search-full]')) {
      const full = expanded.get(wrap.dataset.contentKey);
      wrap.querySelector('pre').textContent = full ? wrap.dataset.fullText : wrap.dataset.fullText.slice(0, 6000);
      delete wrap.dataset.searchFull;
    }
  }
  function searchText(e) {
    // IDs and bookkeeping are excluded; all retained user-visible evidence is indexed.
    const op = e.operation || {};
    return [e.text, e.detail, e.tool, op.name, op.command, op.arguments, op.output, op.patch, op.report, e.checklist].map(x => typeof x === 'string' ? x : x ? JSON.stringify(x) : '').join('\n').toLocaleLowerCase();
  }
  function refreshSearch(scroll) {
    if (!findbar || findbar.hidden) return;
    const previousID = matches[current]?.e.id;
    restore(); matches = [];
    if (query) for (const record of records.values()) {
      if (!record.el.isConnected || !searchText(record.e).includes(query)) continue;
      matches.push(record);
    }
    current = Math.max(0, matches.findIndex(r => r.e.id === previousID));
    if (!matches.length) current = -1;
    reveal(!!scroll);
  }
  function reveal(scroll = true) {
    restore(); counter.textContent = matches.length ? (current + 1) + ' of ' + matches.length + ' matching entries' : '0 matches';
    const record = matches[current]; if (!record) return;
    const el = record.el; el.classList.add('reader-search-hit');
    const group = el.closest('.toolgroup');
    if (group) { group.dataset.searchOpen = String(group.classList.contains('open')); group.classList.add('open'); group.querySelector('.toolsum')?.setAttribute('aria-expanded', 'true'); }
    for (const d of el.querySelectorAll('details')) { d.dataset.searchOpen = String(d.open); d.open = true; }
    for (const wrap of el.querySelectorAll('[data-full-text]')) {
      wrap.dataset.searchFull = 'true'; wrap.querySelector('pre').textContent = wrap.dataset.fullText;
    }
    if (scroll) el.scrollIntoView({ block: 'center' });
  }
  function move(delta) { if (!matches.length) return; current = (current + delta + matches.length) % matches.length; reveal(); }
  function openSearch() { ensureFind(); if (findbar.hidden) previousFocus = document.activeElement; R.post({ type: 'findState', open: true }); R.post({ type: 'focusRequested' }); findbar.hidden = false; field.focus(); field.select(); refreshSearch(true); }
  function closeSearch() { if (!findbar || findbar.hidden) return; restore(); query = ''; field.value = ''; findbar.hidden = true; matches = []; current = -1; R.post({ type: 'findState', open: false }); previousFocus?.focus(); R.post({ type: 'composerFocus' }); }
  document.addEventListener('keydown', ev => {
    if ((ev.metaKey || ev.ctrlKey) && ['f', 'g'].includes(ev.key.toLowerCase())) {
      ev.preventDefault(); ev.stopImmediatePropagation();
      if (ev.key.toLowerCase() === 'f' || !findbar || findbar.hidden) openSearch(); else move(ev.shiftKey ? -1 : 1);
    } else if (ev.key === 'Escape' && findbar && !findbar.hidden) { ev.preventDefault(); ev.stopImmediatePropagation(); closeSearch(); }
  }, true);
  setInterval(() => {
    for (const label of document.querySelectorAll('.parity-elapsed')) {
      const start = Date.parse(label.dataset.startedAt);
      if (Number.isFinite(start)) label.textContent = 'Running for ' + Math.max(0, Math.floor((Date.now() - start) / 1000)) + ' seconds';
    }
  }, 1000);
  const requestCards = new Map();
  let requestHost;
  function setRequests(requests) {
    if (!requestHost) { requestHost = node('aside', 'reader-requests'); requestHost.setAttribute('aria-label', 'Requests needing a response'); document.body.prepend(requestHost); }
    const keep = new Set((requests || []).map(r => r.id));
    for (const [id, card] of requestCards) if (!keep.has(id)) { card.remove(); requestCards.delete(id); }
    for (const request of requests || []) {
      if (requestCards.has(request.id)) continue;
      const card = node('section', 'reader-request'); card.dataset.requestId = request.id;
      const title = node('h3', '', request.tool === 'AskUserQuestion' ? 'Question for you' : 'Permission requested'); card.appendChild(title);
      if (request.cwd) card.appendChild(node('div', 'parity-note', 'Directory: ' + request.cwd));
      const feedback = node('div', 'parity-note'); feedback.setAttribute('role', 'status');
      const controls = [], answers = [];
      let input = {}; try { input = JSON.parse(request.inputJSON || '{}'); } catch (_) { /* Raw input is still displayed below. */ }
      const questions = request.tool === 'AskUserQuestion' && Array.isArray(input.questions) ? input.questions : [];
      function respond(action) {
        const response = {};
        if (action === 'answer') {
          for (const answer of answers) {
            const selected = answer.options.filter(o => o.control.checked).map(o => o.label);
            if (answer.other.value.trim()) selected.push(answer.other.value.trim());
            if (!selected.length) { feedback.textContent = 'Answer each question before submitting.'; answer.other.focus(); return; }
            response[answer.question] = selected.join(', ');
          }
        }
        controls.forEach(c => { c.disabled = true; }); feedback.textContent = 'Response requested';
        R.post({ type: 'readerRequest', requestID: request.id, action, answers: response });
      }
      if (questions.length) {
        questions.forEach((q, index) => {
          const fieldset = node('fieldset', 'reader-question'); fieldset.appendChild(node('legend', '', q.question));
          const options = [];
          for (const option of q.options || []) {
            const label = node('label', 'reader-option'), control = node('input');
            control.type = q.multiSelect ? 'checkbox' : 'radio'; control.name = request.id + ':' + index;
            label.append(control, node('span', '', option.label));
            if (option.description) label.appendChild(node('small', '', option.description));
            fieldset.appendChild(label); options.push({ control, label: option.label }); controls.push(control);
          }
          const other = node('input', 'reader-other'); other.type = 'text'; other.placeholder = 'Other answer'; other.setAttribute('aria-label', 'Other answer for ' + q.question);
          if (!q.multiSelect) {
            other.addEventListener('input', () => { if (other.value) options.forEach(o => { o.control.checked = false; }); });
            options.forEach(o => o.control.addEventListener('change', () => { other.value = ''; }));
          }
          fieldset.appendChild(other); controls.push(other); card.appendChild(fieldset); answers.push({ question: q.question, options, other });
        });
        const submit = button('Submit answer', () => respond('answer')); controls.push(submit); card.appendChild(submit);
      } else {
        retained(card, request.inputJSON, request.id + ':request', request.tool || 'Request');
        // Unsupported question shapes stay in the provider's terminal.
        if (request.tool !== 'AskUserQuestion') for (const [label, action] of [['Approve once', 'allow'], ['Deny', 'deny']]) {
          const b = button(label, () => respond(action)); controls.push(b); card.appendChild(b);
        }
      }
      const terminal = button('Show Terminal', () => respond('terminal')); controls.push(terminal); card.append(terminal, feedback);
      card._requestControls = controls; card._requestFeedback = feedback;
      requestCards.set(request.id, card); requestHost.appendChild(card);
    }
    requestHost.hidden = !requestCards.size;
  }
  function requestResult(payload) {
    const card = requestCards.get(payload.requestID); if (!card) return;
    card._requestFeedback.textContent = payload.message || (payload.accepted ? 'Response requested' : 'Response could not be delivered. Try the terminal.');
    // The native bridge remains the authority on whether the request is live.
    if (!payload.accepted) card._requestControls.forEach(c => { c.disabled = false; });
  }
  function setStatus(payload) {
    let banner = document.getElementById('reader-status');
    if (!banner) { banner = node('div', 'reader-status'); banner.id = 'reader-status'; banner.setAttribute('role', 'status'); document.body.prepend(banner); }
    banner.replaceChildren(); banner.hidden = !payload || ['ready', 'ok'].includes(payload.state);
    if (banner.hidden) return;
    banner.append(node('span', '', payload.message || 'The conversation could not be refreshed.'), button('Retry', () => R.post({ type: 'retryReader' })), button('Show Terminal', () => R.post({ type: 'showTerminal' })));
  }
  document.addEventListener('pointerdown', ev => { if (ev.target.closest('button, summary, input')) R.post({ type: 'focusRequested' }); }, true);
  window.ReaderParity = { setRequests, requestResult, openFind: openSearch, nextMatch: backwards => { if (!findbar || findbar.hidden) openSearch(); else move(backwards === true || backwards === -1 ? -1 : 1); }, closeFind: closeSearch, renderEntry, register, prune, refreshSearch, openSearch, closeSearch, setStatus,
    reset(id) { restore(); records.clear(); pinChecklist(null); if (chat !== id) { setRequests([]); expanded.clear(); closeSearch(); chat = id; } },
    searchText,
  };
})();
