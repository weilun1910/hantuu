// The Changes tab's diff: one file's unified diff with highlighting, two line-number gutters
// and inline comments. Click a line number to comment, Shift-click for a range. Comments are
// stored in Swift; this page draws them and reports what you add or remove.
(function () {
  'use strict';
  const view = document.getElementById('view');
  const empty = document.getElementById('empty');
  const scroller = document.scrollingElement;
  const post = (m) => window.webkit.messageHandlers.hantuu.postMessage(Object.assign({ token: current && current.token, chat: current && current.chat, context: current && current.context }, m));
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  const byExt = {
    js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript',
    py: 'python', rb: 'ruby', rs: 'rust', go: 'go', swift: 'swift', m: 'objectivec', mm: 'objectivec', h: 'c', c: 'c',
    cc: 'cpp', cpp: 'cpp', hpp: 'cpp', java: 'java', kt: 'kotlin', kts: 'kotlin', scala: 'scala', cs: 'csharp',
    php: 'php', lua: 'lua', pl: 'perl', r: 'r', jl: 'julia', dart: 'dart', ex: 'elixir', exs: 'elixir', erl: 'erlang',
    hs: 'haskell', ml: 'ocaml', clj: 'clojure', sql: 'sql', sh: 'bash', bash: 'bash', zsh: 'bash', fish: 'bash',
    ps1: 'powershell', md: 'markdown', markdown: 'markdown', mdx: 'markdown', json: 'json', jsonl: 'json',
    yaml: 'yaml', yml: 'yaml', toml: 'ini', ini: 'ini', cfg: 'ini', conf: 'ini', xml: 'xml', plist: 'xml',
    html: 'xml', htm: 'xml', svg: 'xml', css: 'css', scss: 'scss', less: 'less', tex: 'latex', diff: 'diff',
    patch: 'diff', nix: 'nix', proto: 'protobuf', graphql: 'graphql', gql: 'graphql', mk: 'makefile',
    zon: 'rust', zig: 'rust', ghostty: 'ini',
  };

  function languageFor(path) {
    const name = path.split('/').pop().toLowerCase();
    if (name === 'makefile') return 'makefile';
    if (name === 'dockerfile') return 'dockerfile';
    const ext = name.includes('.') ? name.split('.').pop() : '';
    const lang = byExt[ext];
    return lang && hljs.getLanguage(lang) ? lang : null;
  }

  // Split highlighted HTML into lines, closing and reopening spans at each newline.
  function splitLines(html) {
    const lines = [];
    const open = [];
    let cur = '';
    const re = /(<span[^>]*>)|(<\/span>)|(\n)|([^<\n]+)|(<)/g;
    let m;
    while ((m = re.exec(html))) {
      if (m[1]) { open.push(m[1]); cur += m[1]; }
      else if (m[2]) { open.pop(); cur += m[2]; }
      else if (m[3]) { cur += '</span>'.repeat(open.length); lines.push(cur); cur = open.join(''); }
      else cur += m[0];
    }
    lines.push(cur + '</span>'.repeat(open.length));
    return lines;
  }

  // Highlight each hunk's new side (context and added lines) and old side (context and
  // removed lines) as whole blocks, so strings and comments that span lines stay right.
  function highlightRows(rows, lang) {
    const out = new Array(rows.length);
    if (!lang) return out;
    const hl = (idx) => {
      const text = idx.map((k) => rows[k].s).join('\n');
      try { return splitLines(hljs.highlight(text, { language: lang, ignoreIllegals: true }).value); }
      catch (e) { return idx.map((k) => esc(rows[k].s)); }
    };
    let i = 0;
    while (i < rows.length) {
      if (rows[i].t === 'h') { i++; continue; }
      let j = i;
      while (j < rows.length && rows[j].t !== 'h') j++;
      const newIdx = [], oldIdx = [];
      for (let k = i; k < j; k++) {
        const t = rows[k].t;
        if (t === 'c' || t === 'a') newIdx.push(k);
        if (t === 'c' || t === 'd') oldIdx.push(k);
      }
      hl(newIdx).forEach((h, n) => { out[newIdx[n]] = h; });
      hl(oldIdx).forEach((h, n) => { if (rows[oldIdx[n]].t === 'd') out[oldIdx[n]] = h; });
      i = j;
    }
    return out;
  }

  let current = null;
  let rowEls = [];
  let anchor = null;
  let selection = null;
  let box = null;
  const scrollMemory = {};
  let wrapLines = true;
  let findText = "";
  const drafts = {};
  const draftKey = (p) => p.chat + "|" + p.key;

  window.addEventListener('scroll', () => {
    if (!current) return;
    scrollMemory[current.context + '|' + current.key] = scroller.scrollTop;
    post({ type: 'scroll', context: current.context, key: current.key, top: scroller.scrollTop });
  });

  function isLine(r) { return r && (r.t === 'c' || r.t === 'a' || r.t === 'd'); }

  function render(p) {
    saveDraft();
    current = p;
    anchor = null;
    selection = null;
    box = null;
    view.textContent = '';
    empty.hidden = true;
    rowEls = [];
    if (p.large) {
      const d = document.createElement('div');
      d.className = 'large';
      d.innerHTML = '<div>This diff is large, about ' + p.large.toLocaleString() + ' lines.</div>';
      const b = document.createElement('button');
      b.className = 'primary';
      b.textContent = 'Show Diff';
      b.addEventListener('click', () => { b.disabled = true; b.textContent = 'Loading…'; post({ type: 'showLarge' }); });
      d.appendChild(b);
      view.appendChild(d);
      return;
    }
    if (!p.rows.length) {
      empty.textContent = p.notice || 'No line changes.';
      empty.hidden = false;
      return;
    }
    const html = highlightRows(p.rows, languageFor(p.path));
    const parts = [];
    p.rows.forEach((r, i) => {
      if (r.t === 'h') {
        parts.push('<tr class="hunk"><td class="ln" colspan="2"></td><td class="code">' + esc(r.s) + '</td></tr>');
      } else if (r.t === 'n') {
        parts.push('<tr class="eol"><td class="ln" colspan="2"></td><td class="code">' + esc(r.s) + '</td></tr>');
      } else {
        const cls = r.t === 'a' ? 'add' : r.t === 'd' ? 'del' : 'ctx';
        const sign = r.t === 'a' ? '+' : r.t === 'd' ? '−' : ' ';
        const code = html[i] !== undefined ? html[i] : esc(r.s);
        parts.push('<tr class="' + cls + '" data-i="' + i + '"><td class="ln o" title="Comment on this line. Shift-click for a range.">' + (r.o == null ? '' : r.o) +
          '</td><td class="ln n" title="Comment on this line. Shift-click for a range.">' + (r.n == null ? '' : r.n) +
          '</td><td class="code"><button class="line-comment" aria-label="Add comment on line ' + (r.n || r.o) + '">+</button><span class="sign">' + sign + '</span>' + (code || ' ') + '</td></tr>');
      }
    });
    const table = document.createElement('table');
    table.className = 'diff hljs';
    const tb = document.createElement('tbody');
    tb.innerHTML = parts.join('');
    table.appendChild(tb);
    view.appendChild(table);
    rowEls = Array.from(tb.rows);
    drawTools();
    drawComments();
    restoreDraft();
    scroller.scrollTop = p.scrollTop != null ? p.scrollTop : (p.keepScroll ? scrollMemory[p.context + '|' + p.key] || 0 : 0);
  }

  function drawTools() {
    const tools = document.createElement('div'); tools.className = 'diff-tools';
    const button = (label, action) => {
      const b = document.createElement('button'); b.textContent = label; b.addEventListener('click', action); tools.appendChild(b); return b;
    };
    const move = (direction) => {
      const hunks = Array.from(view.querySelectorAll('tr.hunk'));
      const ordered = direction > 0 ? hunks : hunks.reverse();
      const target = ordered.find(h => direction > 0 ? h.getBoundingClientRect().top > 42 : h.getBoundingClientRect().top < 30) || ordered[0];
      if (target) { target.scrollIntoView({block:'start'}); window.scrollBy(0,-38); }
    };
    button('Previous hunk', () => move(-1));
    button('Next hunk', () => move(1));
    const wrap = button('Wrap', () => { wrapLines = !wrapLines; view.classList.toggle('nowrap', !wrapLines); wrap.setAttribute('aria-pressed', String(wrapLines)); });
    wrap.setAttribute('aria-pressed', String(wrapLines)); view.classList.toggle('nowrap', !wrapLines);
    const input = document.createElement('input'); input.type = 'search'; input.placeholder = 'Find in diff'; input.setAttribute('aria-label','Find in diff'); input.value = findText;
    let nextIndex = -1;
    const find = (backwards = false) => {
      findText = input.value;
      const matches = rowEls.filter(row => findText && row.textContent.toLowerCase().includes(findText.toLowerCase()));
      rowEls.forEach(row => row.classList.remove('find-match'));
      if (!matches.length) { input.setAttribute('aria-description','No matches'); return; }
      nextIndex = (nextIndex + (backwards ? -1 : 1) + matches.length) % matches.length;
      matches[nextIndex].classList.add('find-match'); matches[nextIndex].scrollIntoView({block:'center'});
      input.setAttribute('aria-description', (nextIndex + 1) + ' of ' + matches.length + ' matches');
    };
    input.addEventListener('input', () => { nextIndex = -1; find(); });
    input.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); find(e.shiftKey); } });
    tools.appendChild(input); view.prepend(tools);
  }

  // ---- Selecting lines and the comment box ----

  function describe(from, to) {
    const rs = [];
    for (let k = from; k <= to; k++) if (isLine(current.rows[k])) rs.push(current.rows[k]);
    const news = rs.filter((r) => r.n != null).map((r) => r.n);
    const quoted = rs.map((r) => r.s);
    if (news.length) return { side: 'new', start: Math.min(...news), end: Math.max(...news), quoted };
    const olds = rs.map((r) => r.o);
    return { side: 'old', start: Math.min(...olds), end: Math.max(...olds), quoted };
  }

  function lineLabel(side, start, end) {
    const n = start === end ? 'line ' + start : 'lines ' + start + '-' + end;
    return side === 'old' ? 'Removed ' + n : n.charAt(0).toUpperCase() + n.slice(1);
  }

  function paintSelection() {
    rowEls.forEach((tr, i) => tr.classList.toggle('sel', !!selection && i >= selection.from && i <= selection.to));
  }

  function rowAfterNotes(tr) {
    let after = tr;
    while (after.nextElementSibling && after.nextElementSibling.classList.contains('note')) after = after.nextElementSibling;
    return after;
  }

  function select(i, extend) {
    if (!isLine(current.rows[i])) return;
    if (extend && anchor !== null) {
      selection = { from: Math.min(anchor, i), to: Math.max(anchor, i) };
    } else {
      anchor = i;
      selection = { from: i, to: i };
    }
    paintSelection();
    openBox();
  }

  function closeBox() {
    if (current) { delete drafts[draftKey(current)]; current.draft = null; post({ type: 'commentDraft', draft: null }); }
    if (box) box.remove();
    box = null;
    selection = null;
    anchor = null;
    paintSelection();
  }

  function openBox() {
    const keep = box ? box.querySelector('textarea').value : '';
    if (box) box.remove();
    const d = describe(selection.from, selection.to);
    const tr = document.createElement('tr');
    tr.className = 'cbox';
    tr.innerHTML = '<td colspan="3"><div class="cbox"><div class="cbox-head"></div>' +
      '<textarea rows="3" placeholder="What should the agent change here?"></textarea>' +
      '<div class="cbox-actions"><span class="hint">⌘↩ adds the comment</span>' +
      '<button class="ghost cancel">Cancel</button><button class="primary add" disabled>Add Comment</button></div></div></td>';
    tr.querySelector('.cbox-head').textContent = 'Comment on ' + lineLabel(d.side, d.start, d.end).toLowerCase();
    const ta = tr.querySelector('textarea');
    const add = tr.querySelector('.add');
    ta.value = keep;
    add.disabled = !keep.trim();
    ta.addEventListener('input', () => { add.disabled = !ta.value.trim(); saveDraft(); });
    ta.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); e.stopPropagation(); submit(); }
      else if (e.key === 'Escape') { e.preventDefault(); closeBox(); }
    });
    tr.querySelector('.cancel').addEventListener('click', closeBox);
    add.addEventListener('click', submit);
    const last = rowAfterNotes(rowEls[selection.to]);
    last.parentNode.insertBefore(tr, last.nextSibling);
    box = tr;
    ta.focus();
  }

  function submit() {
    if (!box || !selection) return;
    const body = box.querySelector('textarea').value.trim();
    if (!body) return;
    const d = describe(selection.from, selection.to);
    post({ type: 'addComment', path: current.path, side: d.side, start: d.start, end: d.end, quoted: d.quoted, body });
    closeBox();
  }

  // ---- Saved comments ----

  function matchingRows(c) {
    if (!c.quoted || !c.quoted.length) return [];
    const sideRows = current.rows.map((r, i) => ({r, i})).filter(({r}) => c.side === 'old' ? r.o != null : r.n != null);
    const matches = [];
    for (let i = 0; i <= sideRows.length - c.quoted.length; i++) {
      const run = sideRows.slice(i, i + c.quoted.length);
      if (run.every(({r}, k) => r.s === c.quoted[k] && (!k || (c.side === 'old' ? r.o : r.n) === (c.side === 'old' ? run[k-1].r.o : run[k-1].r.n) + 1))) matches.push(run);
    }
    return matches;
  }

  function anchorRow(c) {
    const matches = matchingRows(c);
    if (c.revision && c.revision === current.revision) {
      const exact = matches.find(run => (c.side === 'old' ? run[0].r.o : run[0].r.n) === c.start);
      if (exact) return exact[exact.length - 1].i;
    }
    return matches.length === 1 ? matches[0][matches[0].length - 1].i : -1;
  }

  function saveDraft() {
    if (!current || !box || !selection) return;
    const draft = { text: box.querySelector('textarea').value, anchor: describe(selection.from, selection.to), revision: current.revision };
    drafts[draftKey(current)] = draft;
    post({ type: 'commentDraft', draft });
  }

  function restoreDraft() {
    const d = drafts[draftKey(current)] || current.draft;
    if (!d || d.editingID) return;
    const matches = matchingRows(d.anchor);
    if (matches.length === 1) {
      const run = matches[0];
      selection = { from: run[0].i, to: run[run.length - 1].i };
      anchor = selection.from;
      paintSelection(); openBox();
      box.querySelector('textarea').value = d.text;
      box.querySelector('.add').disabled = !d.text.trim();
    } else {
      const recovery = document.createElement('div');
      recovery.className = 'outdated draft-recovery';
      const label = document.createElement('div');
      label.textContent = 'Draft on outdated lines. Copy your text or select a new line to attach it.';
      const ta = document.createElement('textarea'); ta.value = d.text;
      ta.addEventListener('input', () => { d.text = ta.value; drafts[draftKey(current)] = d; post({type:'commentDraft', draft:d}); });
      recovery.append(label, ta); view.prepend(recovery);
    }
  }

  function drawComments() {
    if (!current || !rowEls.length) return;
    view.querySelectorAll('tr.note, .outdated:not(.draft-recovery)').forEach((n) => n.remove());
    rowEls.forEach((tr) => tr.classList.remove('commented'));
    const loose = [];
    for (const c of current.comments || []) {
      const at = anchorRow(c);
      if (at < 0) { loose.push(c); continue; }
      const matched = matchingRows(c).find(run => run[run.length - 1].i === at);
      if (matched) matched.forEach(({i}) => rowEls[i].classList.add('commented'));
      const tr = document.createElement('tr');
      tr.className = 'note';
      const td = document.createElement('td');
      td.colSpan = 3;
      td.appendChild(noteEl(c, false));
      tr.appendChild(td);
      const after = rowAfterNotes(rowEls[at]);
      after.parentNode.insertBefore(tr, after.nextSibling);
    }
    if (loose.length) {
      const d = document.createElement('div');
      d.className = 'outdated';
      for (const c of loose) d.appendChild(noteEl(c, true));
      view.insertBefore(d, view.firstChild);
    }
  }

  function noteEl(c, outdated) {
    const n = document.createElement('div');
    n.className = 'note';
    const head = document.createElement('div');
    head.className = 'note-head';
    const label = document.createElement('span');
    label.textContent = lineLabel(c.side, c.start, c.end) + (outdated ? ' - Outdated' : '');
    const rm = document.createElement('button');
    const edit = document.createElement('button');
    edit.textContent = 'Edit';
    const openEdit = () => {
      const ta = document.createElement('textarea');
      const saved = drafts[draftKey(current)] || current.draft;
      ta.value = saved && saved.editingID === c.id ? saved.text : c.body;
      ta.addEventListener('input', () => {
        const draft = {text:ta.value, anchor:{side:c.side,start:c.start,end:c.end,quoted:c.quoted}, revision:c.revision, editingID:c.id};
        drafts[draftKey(current)] = draft; post({type:'commentDraft',draft});
      });
      const save = document.createElement('button'); save.textContent = 'Save';
      const commit = () => { if (ta.value.trim()) { delete drafts[draftKey(current)]; current.draft = null; post({type:'commentDraft',draft:null}); post({ type: 'editComment', id: c.id, body: ta.value.trim() }); } };
      save.addEventListener('click', commit);
      ta.addEventListener('keydown', e => { if (e.metaKey && e.key === 'Enter') commit(); });
      n.replaceChildren(head, ta, save); ta.focus();
    };
    edit.addEventListener('click', openEdit);
    head.appendChild(edit);
    rm.textContent = 'Remove';
    rm.addEventListener('click', (e) => { e.preventDefault(); post({ type: 'removeComment', id: c.id }); });
    head.appendChild(label);
    head.appendChild(rm);
    const body = document.createElement('div');
    body.className = 'note-body';
    body.textContent = c.body;
    n.appendChild(head);
    n.appendChild(body);
    if (outdated && c.quoted) {
      const quote = document.createElement('pre'); quote.textContent = c.quoted.join('\n'); n.appendChild(quote);
    }
    const saved = drafts[draftKey(current)] || current.draft;
    if (saved && saved.editingID === c.id) openEdit();
    return n;
  }

  // ---- Input ----

  view.addEventListener('click', (e) => {
    const plus = e.target.closest('.line-comment');
    if (plus) { select(+plus.closest('tr').dataset.i, e.shiftKey); return; }
    const ln = e.target.closest('td.ln');
    if (ln && ln.parentElement.dataset.i !== undefined) {
      e.preventDefault();
      select(+ln.parentElement.dataset.i, e.shiftKey);
      return;
    }
    if (e.metaKey) {
      const tr = e.target.closest('tr[data-i]');
      if (tr) {
        const r = current.rows[+tr.dataset.i];
        const line = r.n != null ? r.n : r.o;
        if (line) post({ type: 'openLine', line, side: r.n != null ? 'new' : 'old' });
      }
    }
  });
  // Shift-click shouldn't select text in the gutter.
  view.addEventListener('mousedown', (e) => { if (e.shiftKey && e.target.closest('td.ln')) e.preventDefault(); });

  document.addEventListener('keydown', (e) => {
    if (e.key.toLowerCase() === 'f' && e.metaKey) { const input = view.querySelector('.diff-tools input'); if (input) { e.preventDefault(); input.focus(); input.select(); } return; }
    if (e.target && ['TEXTAREA', 'INPUT'].includes(e.target.tagName)) return;
    if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); post({ type: 'send' }); }
    else if (e.key === 'Escape' && box) { closeBox(); }
  });

  window.hantuu = {
    show(p) {
      render(p);
    },
    setComments(list) {
      if (!current) return;
      current.comments = list || [];
      const keepBox = box;
      if (keepBox) keepBox.remove();
      drawComments();
      if (keepBox && selection) {
        const last = rowAfterNotes(rowEls[selection.to]);
        last.parentNode.insertBefore(keepBox, last.nextSibling);
      }
    },
    clear(text) {
      saveDraft();
      current = null;
      rowEls = [];
      box = null;
      view.textContent = '';
      empty.textContent = text || '';
      empty.hidden = !text;
    },
  };

  post({ type: 'ready' });
})();
