// The Changes tab's diff: one file's unified diff with highlighting, two line-number gutters
// and inline comments. Click a line number to comment, Shift-click for a range. Comments are
// stored in Swift; this page draws them and reports what you add or remove.
(function () {
  'use strict';
  const view = document.getElementById('view');
  const empty = document.getElementById('empty');
  const scroller = document.scrollingElement;
  const post = (m) => window.webkit.messageHandlers.hantuu.postMessage(m);
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

  window.addEventListener('scroll', () => {
    if (!current) return;
    scrollMemory[current.context + '|' + current.key] = scroller.scrollTop;
    post({ type: 'scroll', context: current.context, key: current.key, top: scroller.scrollTop });
  });

  function isLine(r) { return r && (r.t === 'c' || r.t === 'a' || r.t === 'd'); }

  function render(p) {
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
          '</td><td class="code"><span class="sign">' + sign + '</span>' + (code || ' ') + '</td></tr>');
      }
    });
    const table = document.createElement('table');
    table.className = 'diff hljs';
    const tb = document.createElement('tbody');
    tb.innerHTML = parts.join('');
    table.appendChild(tb);
    view.appendChild(table);
    rowEls = Array.from(tb.rows);
    drawComments();
    scroller.scrollTop = p.scrollTop != null ? p.scrollTop : (p.keepScroll ? scrollMemory[p.context + '|' + p.key] || 0 : 0);
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
    ta.addEventListener('input', () => { add.disabled = !ta.value.trim(); });
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

  function anchorRow(c) {
    let found = -1;
    current.rows.forEach((r, i) => {
      if (c.side === 'old' ? (r.t === 'd' && r.o === c.end) : (r.n === c.end && r.t !== 'd')) found = i;
    });
    return found;
  }

  function drawComments() {
    if (!current || !rowEls.length) return;
    view.querySelectorAll('tr.note, .outdated').forEach((n) => n.remove());
    rowEls.forEach((tr) => tr.classList.remove('commented'));
    const loose = [];
    for (const c of current.comments || []) {
      const at = anchorRow(c);
      if (at < 0) { loose.push(c); continue; }
      current.rows.forEach((r, i) => {
        const line = c.side === 'old' ? (r.t === 'd' ? r.o : null) : (r.t !== 'd' ? r.n : null);
        if (line != null && line >= c.start && line <= c.end) rowEls[i].classList.add('commented');
      });
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
    label.textContent = lineLabel(c.side, c.start, c.end) + (outdated ? ', no longer in the diff' : '');
    const rm = document.createElement('a');
    rm.textContent = 'Remove';
    rm.addEventListener('click', (e) => { e.preventDefault(); post({ type: 'removeComment', id: c.id }); });
    head.appendChild(label);
    head.appendChild(rm);
    const body = document.createElement('div');
    body.className = 'note-body';
    body.textContent = c.body;
    n.appendChild(head);
    n.appendChild(body);
    return n;
  }

  // ---- Input ----

  view.addEventListener('click', (e) => {
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
        if (line) post({ type: 'openLine', line });
      }
    }
  });
  // Shift-click shouldn't select text in the gutter.
  view.addEventListener('mousedown', (e) => { if (e.shiftKey && e.target.closest('td.ln')) e.preventDefault(); });

  document.addEventListener('keydown', (e) => {
    if (e.target && e.target.tagName === 'TEXTAREA') return;
    if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); post({ type: 'send' }); }
    else if (e.key === 'Escape' && box) { closeBox(); }
  });

  window.hantuu = {
    show(p) {
      // A live refresh of the same file keeps an open comment box if the lines are unchanged.
      const pending = box && current && current.key === p.key ? { text: box.querySelector('textarea').value, sel: selection, anchor } : null;
      const sameRows = pending && JSON.stringify(current.rows) === JSON.stringify(p.rows);
      render(p);
      if (pending && sameRows && pending.sel) {
        anchor = pending.anchor;
        selection = pending.sel;
        paintSelection();
        openBox();
        box.querySelector('textarea').value = pending.text;
        box.querySelector('.add').disabled = !pending.text.trim();
      }
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
