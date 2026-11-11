// The Code tab's page: a CodeMirror 6 editor for text and code files, and rendered previews
// for Markdown, SVG and CSV. Swift owns the files (reading, saving, watching the disk) and
// this page owns the editing. Every open tab keeps its own editor state here, so switching
// tabs keeps its undo history, selection and scroll position.
(function () {
  'use strict';
  const R = window.hantuuRender;
  const { state: S, view: V, commands: C, language: L, search: F, tags: t, languages } = window.CM;
  const host = document.getElementById('editor');
  const previewEl = document.getElementById('preview');
  const empty = document.getElementById('empty');
  const EMPTY = 'Cmd-click a file path in a chat or the reader to open it here.';

  // ---- Languages ----

  const byExt = {
    js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript', ts: 'typescript', mts: 'typescript',
    cts: 'typescript', tsx: 'tsx', py: 'python', pyi: 'python', rb: 'ruby', rs: 'rust', go: 'go', swift: 'swift',
    m: 'objectivec', mm: 'objectivecpp', h: 'cpp', c: 'cpp', cc: 'cpp', cpp: 'cpp', cxx: 'cpp', hpp: 'cpp', hh: 'cpp',
    java: 'java', kt: 'kotlin', kts: 'kotlin', scala: 'scala', cs: 'csharp', php: 'php', lua: 'lua', pl: 'perl',
    pm: 'perl', r: 'r', jl: 'julia', dart: 'dart', erl: 'erlang', hrl: 'erlang', hs: 'haskell', ml: 'ocaml',
    mli: 'ocaml', clj: 'clojure', cljs: 'clojure', edn: 'clojure', sql: 'sql', sh: 'shell', bash: 'shell',
    zsh: 'shell', fish: 'shell', command: 'shell', ps1: 'powershell', md: 'markdown', markdown: 'markdown',
    mdx: 'markdown', json: 'json', jsonc: 'json', jsonl: 'json', ipynb: 'json', yaml: 'yaml', yml: 'yaml',
    toml: 'toml', ini: 'properties', cfg: 'properties', conf: 'properties', properties: 'properties',
    env: 'properties', ghostty: 'properties', xcconfig: 'properties', xml: 'xml', plist: 'xml', svg: 'xml',
    xib: 'xml', storyboard: 'xml', entitlements: 'xml', html: 'html', htm: 'html', vue: 'html', svelte: 'html',
    css: 'css', scss: 'css', less: 'css', sass: 'sass', tex: 'latex', sty: 'latex', cls: 'latex', diff: 'diff',
    patch: 'diff', proto: 'protobuf', cmake: 'cmake', gradle: 'groovy', groovy: 'groovy', el: 'lisp',
    lisp: 'lisp', f90: 'fortran', v: 'verilog', sv: 'verilog', elm: 'elm', vb: 'vb', dockerfile: 'dockerfile',
  };
  const byName = {
    dockerfile: 'dockerfile', 'cmakelists.txt': 'cmake', '.zshrc': 'shell', '.bashrc': 'shell', '.zprofile': 'shell',
    '.bash_profile': 'shell', '.profile': 'shell', '.env': 'properties', 'package.resolved': 'json',
    '.gitconfig': 'properties', 'nginx.conf': 'nginx', gemfile: 'ruby', rakefile: 'ruby', podfile: 'ruby',
  };

  function languageName(name) {
    const lower = name.toLowerCase();
    if (byName[lower]) return byName[lower];
    const ext = lower.includes('.') ? lower.split('.').pop() : '';
    return byExt[ext] || null;
  }

  function languageSupport(name) {
    const make = name && languages[name];
    try { return make ? make() : []; } catch (e) { return []; }
  }

  // Syntax colours: the same restrained palette as the reader's highlighted code blocks.
  const colours = L.HighlightStyle.define([
    { tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword, t.definitionKeyword, t.modifier], color: 'var(--hl-keyword)' },
    { tag: [t.string, t.special(t.string), t.regexp, t.character], color: 'var(--hl-string)' },
    { tag: [t.number, t.bool, t.null, t.atom, t.unit], color: 'var(--hl-number)' },
    { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: 'var(--hl-comment)', fontStyle: 'italic' },
    { tag: [t.function(t.variableName), t.function(t.propertyName), t.function(t.definition(t.variableName))], color: 'var(--hl-title)' },
    { tag: [t.typeName, t.className, t.namespace, t.standard(t.variableName), t.self], color: 'var(--hl-type)' },
    { tag: [t.propertyName, t.attributeName, t.labelName, t.special(t.variableName)], color: 'var(--hl-attr)' },
    { tag: [t.meta, t.processingInstruction, t.annotation, t.documentMeta], color: 'var(--hl-meta)' },
    { tag: [t.tagName, t.angleBracket], color: 'var(--hl-tag)' },
    { tag: t.heading, color: 'var(--hl-title)', fontWeight: '600' },
    { tag: [t.link, t.url], color: 'var(--link)' },
    { tag: t.emphasis, fontStyle: 'italic' },
    { tag: t.strong, fontWeight: '600' },
    { tag: t.strikethrough, textDecoration: 'line-through' },
    { tag: t.inserted, color: 'var(--hl-add)' },
    { tag: t.deleted, color: 'var(--hl-del)' },
    { tag: t.invalid, color: 'var(--error)' },
    { tag: [t.quote, t.monospace], color: 'var(--secondary)' },
  ]);

  const theme = V.EditorView.theme({
    '&': { height: '100%', fontSize: '12.5px', color: 'var(--hl-base)', backgroundColor: 'transparent' },
    '&.cm-focused': { outline: 'none' },
    '.cm-scroller': { fontFamily: 'var(--mono)', lineHeight: '1.6' },
    '.cm-content': { padding: '8px 0 40px', caretColor: 'var(--text)' },
    '.cm-line': { padding: '0 24px 0 2px' },
    '.cm-gutters': { backgroundColor: 'transparent', border: 'none', color: 'var(--tertiary)' },
    '.cm-lineNumbers .cm-gutterElement': { padding: '0 14px 0 12px' },
    '.cm-activeLine': { backgroundColor: 'transparent' },
    '&.cm-focused .cm-activeLine': { backgroundColor: 'var(--active-line)' },
    '.cm-activeLineGutter': { backgroundColor: 'transparent' },
    '&.cm-focused .cm-activeLineGutter': { color: 'var(--secondary)' },
    '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--text)', borderLeftWidth: '1.5px' },
    '.cm-selectionBackground': { backgroundColor: 'var(--selection-dim) !important' },
    '&.cm-focused .cm-selectionBackground': { backgroundColor: 'var(--selection) !important' },
    '.cm-content ::selection': { backgroundColor: 'transparent' },
    '.cm-matchingBracket, &.cm-focused .cm-matchingBracket': { backgroundColor: 'var(--fill-strong)', outline: '1px solid var(--rule)' },
    '.cm-nonmatchingBracket': { color: 'var(--error)' },
    '.cm-selectionMatch': { backgroundColor: 'var(--fill-strong)' },
    '.cm-searchMatch': { backgroundColor: 'var(--match)', borderRadius: '2px' },
    '.cm-searchMatch.cm-searchMatch-selected': { backgroundColor: 'var(--match-current)' },
    '.cm-target': { backgroundColor: 'var(--target)' },
    '.cm-specialChar': { color: 'var(--error)' },
    '.cm-panels': { backgroundColor: 'transparent', color: 'var(--text)' },
    '.cm-panels.cm-panels-top': { borderBottom: '1px solid var(--rule)' },
    '.cm-panels.cm-panels-bottom': { borderTop: '1px solid var(--rule)' },
  });

  // ---- The line a link pointed at ----

  const setTarget = S.StateEffect.define();
  const targetLine = S.StateField.define({
    create: () => V.Decoration.none,
    update(deco, tr) {
      deco = deco.map(tr.changes);
      for (const e of tr.effects) {
        if (e.is(setTarget)) deco = e.value == null ? V.Decoration.none : V.Decoration.set([V.Decoration.line({ class: 'cm-target' }).range(e.value)]);
      }
      if (tr.isUserEvent('input') || tr.isUserEvent('delete')) deco = V.Decoration.none;
      return deco;
    },
    provide: (f) => V.EditorView.decorations.from(f),
  });

  function targetEffects(state, line) {
    if (!line) return [];
    const n = Math.max(1, Math.min(line, state.doc.lines));
    const pos = state.doc.line(n).from;
    return [setTarget.of(pos), V.EditorView.scrollIntoView(pos, { y: 'center' })];
  }

  // ---- Find (Cmd-F) and replace (Option-Cmd-F) ----

  let wantReplace = false;
  const ICON = {
    up: '<path d="M4 10l4-4 4 4"/>',
    down: '<path d="M4 6l4 4 4-4"/>',
    close: '<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>',
    replace: '<path d="M6 4.5l3.5 3.5L6 11.5"/>',
  };
  function iconButton(name, title, onClick) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'fb-icon fb-' + name;
    b.title = title;
    b.setAttribute('aria-label', title);
    b.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true">' + ICON[name] + '</svg>';
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', onClick);
    return b;
  }
  function textButton(label, onClick) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'fb-text';
    b.textContent = label;
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', onClick);
    return b;
  }

  function countMatches(state, query) {
    if (!query.valid || !query.search) return null;
    const sel = state.selection.main;
    const cursor = query.getCursor(state);
    let total = 0;
    let current = 0;
    for (let m = cursor.next(); !m.done && total < 10000; m = cursor.next()) {
      total++;
      if (m.value.from === sel.from && m.value.to === sel.to) current = total;
    }
    return { total, current, capped: total >= 10000 };
  }

  function findBar(view) {
    const dom = document.createElement('div');
    dom.className = 'findbar';
    const row = document.createElement('div');
    row.className = 'fb-row';
    const toggle = iconButton('replace', 'Replace', () => setReplace(!dom.classList.contains('replacing')));
    const find = document.createElement('input');
    find.className = 'fb-field';
    find.placeholder = 'Find';
    find.setAttribute('main-field', 'true');
    find.spellcheck = false;
    const count = document.createElement('span');
    count.className = 'fb-count';
    row.append(toggle, find, count,
      iconButton('up', 'Previous match  Shift-Return', () => { F.findPrevious(view); }),
      iconButton('down', 'Next match  Return', () => { F.findNext(view); }),
      iconButton('close', 'Done  Esc', () => { F.closeSearchPanel(view); view.focus(); }));
    const row2 = document.createElement('div');
    row2.className = 'fb-row fb-replace';
    const spacer = document.createElement('span');
    spacer.className = 'fb-spacer';
    const rep = document.createElement('input');
    rep.className = 'fb-field';
    rep.placeholder = 'Replace';
    rep.spellcheck = false;
    row2.append(spacer, rep, textButton('Replace', () => F.replaceNext(view)), textButton('All', () => F.replaceAll(view)));
    dom.append(row, row2);

    function setReplace(on) {
      dom.classList.toggle('replacing', on);
      toggle.classList.toggle('on', on);
      if (on) rep.focus(); else find.focus();
    }
    function commit() {
      const q = new F.SearchQuery({ search: find.value, replace: rep.value, caseSensitive: false });
      if (!q.eq(F.getSearchQuery(view.state))) view.dispatch({ effects: F.setSearchQuery.of(q) });
    }
    function refresh(state) {
      const q = F.getSearchQuery(state);
      const c = countMatches(state, q);
      count.textContent = c == null ? '' : c.total === 0 ? 'No results' : (c.current ? c.current + ' of ' : '') + c.total + (c.capped ? '+' : '');
      count.classList.toggle('none', !!c && c.total === 0);
    }
    find.addEventListener('input', () => { commit(); });
    rep.addEventListener('input', commit);
    const keys = (e, field) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (field === rep) F.replaceNext(view);
        else if (e.shiftKey) F.findPrevious(view);
        else F.findNext(view);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        F.closeSearchPanel(view);
        view.focus();
      }
    };
    find.addEventListener('keydown', (e) => keys(e, find));
    rep.addEventListener('keydown', (e) => keys(e, rep));

    const q = F.getSearchQuery(view.state);
    find.value = q.search;
    rep.value = q.replace;
    return {
      dom,
      top: true,
      mount() {
        if (wantReplace) { wantReplace = false; setReplace(true); } else { find.focus(); find.select(); }
        refresh(view.state);
      },
      update(u) {
        for (const tr of u.transactions) {
          for (const e of tr.effects) {
            if (e.is(F.setSearchQuery) && e.value.search !== find.value) { find.value = e.value.search; }
          }
        }
        if (u.docChanged || u.selectionSet || u.transactions.some((tr) => tr.effects.some((e) => e.is(F.setSearchQuery)))) refresh(u.state);
      },
    };
  }

  const findKeys = [
    { key: 'Mod-f', run: (v) => { if (F.searchPanelOpen(v.state)) { const f = v.dom.querySelector('.findbar .fb-field'); if (f) { f.focus(); f.select(); } return true; } return F.openSearchPanel(v); }, scope: 'editor search-panel' },
    { key: 'Mod-Alt-f', run: (v) => { wantReplace = true; if (F.searchPanelOpen(v.state)) { v.dom.querySelector('.findbar').classList.add('replacing'); const r = v.dom.querySelector('.fb-replace .fb-field'); if (r) r.focus(); wantReplace = false; return true; } return F.openSearchPanel(v); }, scope: 'editor search-panel' },
  ];

  // ---- Documents ----

  // id -> { meta, state, baseline, dirty, mode, saves: Map(token -> Text) }
  const docs = new Map();
  let currentID = null;
  let view = null;
  // The tab whose state the editor view holds right now.
  let viewID = null;
  let token = 0;

  let positionTimer = null;
  function schedulePosition() {
    clearTimeout(positionTimer);
    positionTimer = setTimeout(reportPosition, 120);
  }
  function reportPosition() {
    clearTimeout(positionTimer);
    const d = docs.get(currentID);
    const st = stateOf(currentID);
    if (!d || !st) return;
    const previous = d.savedPosition || d.meta.position || {};
    const position = {
      ranges: st.selection.ranges.map((r) => ({ anchor: r.anchor, head: r.head })),
      mainIndex: st.selection.mainIndex,
      top: viewID === currentID && !host.hidden ? view.scrollDOM.scrollTop : previous.top || 0,
      left: viewID === currentID && !host.hidden ? view.scrollDOM.scrollLeft : previous.left || 0,
      previewTop: d.previewScroll || 0,
    };
    d.savedPosition = position;
    R.post({ type: 'position', id: currentID, position });
  }

  function detectIndent(text) {
    const lines = text.split('\n', 400);
    let tabs = 0;
    const widths = {};
    for (const l of lines) {
      if (l.startsWith('\t')) tabs++;
      else {
        const m = /^( +)\S/.exec(l);
        if (m && m[1].length <= 8) widths[m[1].length] = (widths[m[1].length] || 0) + 1;
      }
    }
    const spaced = Object.values(widths).reduce((a, b) => a + b, 0);
    if (tabs > spaced) return '\t';
    if (!spaced) return '    ';
    // The smallest indent that's common is the unit.
    const unit = [2, 4, 3, 8].find((w) => (widths[w] || 0) >= spaced * 0.15) || 4;
    return ' '.repeat(unit);
  }

  function makeState(meta, text) {
    const lang = meta.lang || languageName(meta.name);
    const readOnly = !!meta.readOnly;
    const extensions = [
      V.lineNumbers(),
      V.highlightActiveLineGutter(),
      V.highlightSpecialChars(),
      C.history(),
      V.drawSelection(),
      V.dropCursor(),
      S.EditorState.allowMultipleSelections.of(true),
      L.indentOnInput(),
      L.syntaxHighlighting(colours, { fallback: true }),
      L.bracketMatching(),
      V.rectangularSelection(),
      V.highlightActiveLine(),
      F.highlightSelectionMatches(),
      F.search({ top: true, createPanel: findBar }),
      V.keymap.of([...findKeys, ...F.searchKeymap, ...C.defaultKeymap, ...C.historyKeymap, C.indentWithTab]),
      languageSupport(lang),
      L.indentUnit.of(detectIndent(text)),
      S.EditorState.tabSize.of(4),
      S.EditorState.readOnly.of(readOnly),
      meta.eol === '\r\n' ? S.EditorState.lineSeparator.of('\r\n') : [],
      meta.wrap ? V.EditorView.lineWrapping : [],
      V.EditorView.contentAttributes.of({ 'aria-label': meta.name, spellcheck: 'false', autocorrect: 'off', autocapitalize: 'off' }),
      targetLine,
      theme,
      changes,
    ];
    return S.EditorState.create({ doc: text, extensions });
  }

  // Reports unsaved changes to Swift whenever they come or go. Undoing back to the saved text
  // counts as no changes.
  const changes = V.EditorView.updateListener.of((u) => {
    if (u.selectionSet || u.docChanged) schedulePosition();
    if (!u.docChanged || viewID == null) return;
    const d = docs.get(viewID);
    if (!d) return;
    setDirty(viewID, d, !u.state.doc.eq(d.baseline));
  });

  function setDirty(id, d, dirty) {
    if (dirty === d.dirty) return;
    d.dirty = dirty;
    R.post({ type: 'dirty', id, dirty });
  }

  function stateOf(id) {
    if (view && id === viewID) return view.state;
    const d = docs.get(id);
    return d ? d.state : null;
  }

  // Keeps the editor's state (and where it was scrolled) with its tab before the view moves on.
  function park() {
    reportPosition();
    if (viewID == null || !view) return;
    const d = docs.get(viewID);
    if (d) {
      d.state = view.state;
      if (!host.hidden) d.scroll = view.scrollSnapshot();
    }
  }

  function ensureView(id, d) {
    if (!view) {
      view = new V.EditorView({ state: d.state, parent: host });
      view.scrollDOM.addEventListener('scroll', schedulePosition);
    } else if (viewID !== id || view.state !== d.state) {
      view.setState(d.state);
    }
    viewID = id;
  }

  // CodeMirror measures lines in an animation frame, and a page that isn't on screen gets
  // none, which leaves the line numbers out of step with the lines. Measure right away.
  function settle() {
    if (!view || host.hidden) return;
    try { view.measure(); } catch (e) { view.requestMeasure(); }
  }

  function render(id, line) {
    const d = docs.get(id);
    if (!d) return;
    empty.hidden = true;
    const previewing = d.mode === 'preview' && !!d.meta.preview;
    document.body.classList.toggle('previewing', previewing);
    if (previewing) {
      host.hidden = true;
      previewEl.hidden = false;
      showPreview(d, stateOf(id).doc.toString());
      R.post({ type: 'shown', id });
      return;
    }
    previewEl.hidden = true;
    previewEl.textContent = '';
    host.hidden = false;
    ensureView(id, d);
    const effects = targetEffects(view.state, line);
    if (effects.length) {
      view.dispatch({ selection: { anchor: view.state.doc.line(Math.max(1, Math.min(line, view.state.doc.lines))).from }, effects });
    } else if (d.scroll) {
      view.dispatch({ effects: d.scroll });
    }
    d.scroll = null;
    settle();
    if (effects.length) { settle(); view.dispatch({ effects: V.EditorView.scrollIntoView(view.state.selection.main.head, { y: 'center' }) }); settle(); }
    else if (d.position) {
      view.scrollDOM.scrollTop = d.position.top || 0;
      view.scrollDOM.scrollLeft = d.position.left || 0;
    }
    d.position = null;
    R.post({ type: 'shown', id });
  }

  // ---- Previews ----

  function showPreview(d, text) {
    previewEl.textContent = '';
    previewEl.className = 'preview-' + d.meta.preview;
    if (d.meta.preview === 'markdown') previewMarkdown(d, text);
    else if (d.meta.preview === 'svg') previewSVG(d, text);
    else if (d.meta.preview === 'csv') previewCSV(d, text);
    previewEl.scrollTop = d.previewScroll || 0;
  }

  function previewMarkdown(d, text) {
    const art = document.createElement('article');
    art.className = 'md preview';
    art.innerHTML = R.renderMarkdown(text, {});
    // Relative images and links resolve against the file's folder.
    art.querySelectorAll('img').forEach((img) => {
      const src = img.getAttribute('src') || '';
      if (!/^[a-z]+:/i.test(src)) {
        const abs = src.startsWith('/') ? src : d.meta.base + '/' + src;
        img.src = R.fileURL(abs.replace(/\/\.\//g, '/'));
      }
    });
    art.querySelectorAll('a[href]').forEach((a) => { a.dataset.base = d.meta.base; });
    R.linkifyPaths(art, d.meta.links || []);
    previewEl.appendChild(art);
  }

  function previewSVG(d, text) {
    const stage = document.createElement('div');
    stage.className = 'svgstage';
    const img = document.createElement('img');
    // An SVG in an img never runs its scripts. Unsaved edits show too.
    img.src = 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(text)));
    img.alt = d.meta.name;
    img.addEventListener('error', () => {
      stage.textContent = '';
      stage.className = 'empty';
      stage.textContent = d.meta.name + " isn't a valid SVG. Switch to Source to fix it.";
    });
    stage.appendChild(img);
    previewEl.appendChild(stage);
  }

  // RFC 4180 CSV, or tab-separated for .tsv.
  function parseCSV(text, sep, maxRows) {
    const rows = [];
    let row = [];
    let field = '';
    let quoted = false;
    let i = 0;
    while (i < text.length && rows.length < maxRows) {
      const c = text[i];
      if (quoted) {
        if (c === '"') {
          if (text[i + 1] === '"') { field += '"'; i += 2; continue; }
          quoted = false; i++; continue;
        }
        field += c; i++; continue;
      }
      if (c === '"' && field === '') { quoted = true; i++; continue; }
      if (c === sep) { row.push(field); field = ''; i++; continue; }
      if (c === '\r' || c === '\n') {
        row.push(field); field = '';
        rows.push(row); row = [];
        if (c === '\r' && text[i + 1] === '\n') i++;
        i++; continue;
      }
      field += c; i++;
    }
    if (rows.length < maxRows && (field !== '' || row.length)) { row.push(field); rows.push(row); }
    return { rows, more: i < text.length };
  }

  function previewCSV(d, text) {
    const sep = /\.tsv$/i.test(d.meta.name) ? '\t' : ',';
    const { rows, more } = parseCSV(text, sep, 2001);
    const wrap = document.createElement('div');
    wrap.className = 'csvwrap';
    if (!rows.length) {
      wrap.className = 'empty';
      wrap.textContent = d.meta.name + ' is empty.';
      previewEl.appendChild(wrap);
      return;
    }
    const table = document.createElement('table');
    table.className = 'csv';
    const width = Math.min(200, rows.reduce((m, r) => Math.max(m, r.length), 0));
    const head = document.createElement('thead');
    const body = document.createElement('tbody');
    const parts = [];
    rows.forEach((r, i) => {
      const cells = [];
      for (let j = 0; j < width; j++) {
        const v = r[j] == null ? '' : r[j];
        const numeric = /^-?[\d,]*\.?\d+(e[+-]?\d+)?%?$/i.test(v.trim());
        cells.push((i === 0 ? '<th' : '<td') + (numeric && i > 0 ? ' class="num"' : '') + '>' + R.escapeHTML(v) + (i === 0 ? '</th>' : '</td>'));
      }
      const tr = '<tr><td class="rn">' + (i === 0 ? '' : i) + '</td>' + cells.join('') + '</tr>';
      if (i === 0) head.innerHTML = tr.replace('<td class="rn">', '<th class="rn">').replace('</td>', '</th>');
      else parts.push(tr);
    });
    body.innerHTML = parts.join('');
    table.append(head, body);
    wrap.appendChild(table);
    if (more || rows.length > 2000) {
      const n = document.createElement('div');
      n.className = 'truncated';
      n.textContent = 'Showing the first 2,000 rows. Switch to Source to see everything.';
      wrap.appendChild(n);
    }
    previewEl.appendChild(wrap);
  }

  previewEl.addEventListener('scroll', () => {
    const d = docs.get(currentID);
    if (d && d.mode === 'preview') { d.previewScroll = previewEl.scrollTop; schedulePosition(); }
  });

  // ---- Swift's API ----

  // Smallest single change that turns `a` into `b`, so a reload keeps the selection, the
  // scroll position and the undo history around the part that didn't change.
  function minimalChange(a, b) {
    let start = 0;
    const max = Math.min(a.length, b.length);
    while (start < max && a.charCodeAt(start) === b.charCodeAt(start)) start++;
    let endA = a.length;
    let endB = b.length;
    while (endA > start && endB > start && a.charCodeAt(endA - 1) === b.charCodeAt(endB - 1)) { endA--; endB--; }
    return { from: start, to: endA, insert: b.slice(start, endB) };
  }

  window.hantuu = {
    // A tab's file, freshly read from disk. Showing it makes it the current tab.
    open(p) {
      park();
      const old = docs.get(p.id);
      let state = makeState(p, p.text);
      if (p.position && p.position.ranges && p.position.ranges.length) {
        const clamp = (n) => Math.max(0, Math.min(state.doc.length, n || 0));
        const ranges = p.position.ranges.map((r) => S.EditorSelection.range(clamp(r.anchor), clamp(r.head)));
        state = state.update({ selection: S.EditorSelection.create(ranges, Math.max(0, Math.min(p.position.mainIndex || 0, ranges.length - 1))) }).state;
      }
      const d = { meta: p, state, baseline: state.doc, dirty: false, mode: p.mode || 'source', saves: new Map(), previewScroll: p.position ? p.position.previewTop || 0 : 0, position: p.position };
      docs.set(p.id, d);
      if (old && old.dirty) R.post({ type: 'dirty', id: p.id, dirty: false });
      if (viewID === p.id) viewID = null;
      currentID = p.id;
      render(p.id, p.line);
    },
    // Show a tab that's already open, at a line if a link asked for one.
    show(p) {
      if (!docs.has(p.id)) return false;
      park();
      currentID = p.id;
      const d = docs.get(p.id);
      if (p.mode) d.mode = p.mode;
      render(p.id, p.line);
      return true;
    },
    has(id) { return docs.has(id); },
    setMode(p) {
      const d = docs.get(p.id);
      if (!d) return;
      park();
      d.mode = p.mode;
      if (p.id === currentID) render(p.id, null);
    },
    // The file changed on disk and this tab had no unsaved changes, or you chose Reload.
    reload(p) {
      const d = docs.get(p.id);
      if (!d) return;
      // Typed something since Swift last heard? Keep it, and let Swift show the bar.
      if (!p.force && d.dirty) { R.post({ type: 'conflict', id: p.id }); return; }
      if (p.links) d.meta.links = p.links;
      const inView = view && p.id === viewID;
      const st = inView ? view.state : d.state;
      const change = minimalChange(st.doc.toString(), p.text);
      const tr = { changes: change, annotations: [S.Transaction.addToHistory.of(false), S.Transaction.remote.of(true)] };
      d.baseline = st.toText(p.text);
      if (inView) { view.dispatch(tr); settle(); }
      else d.state = d.state.update(tr).state;
      setDirty(p.id, d, false);
      if (p.id === currentID && d.mode === 'preview' && d.meta.preview) showPreview(d, p.text);
    },
    // The text to save, with a token that `saved` hands back once it's on disk.
    snapshot(id) {
      const st = stateOf(id);
      const d = docs.get(id);
      if (!st || !d) return null;
      const n = ++token;
      d.saves.set(n, st.doc);
      return { text: st.doc.toString(), token: n };
    },
    saved(p) {
      const d = docs.get(p.id);
      if (!d) return;
      const doc = d.saves.get(p.token);
      d.saves.delete(p.token);
      if (!doc) return;
      d.baseline = doc;
      if (p.links) d.meta.links = p.links;
      setDirty(p.id, d, !stateOf(p.id).doc.eq(doc));
    },
    // Keep Mine: what's on disk becomes what your text is compared against.
    rebase(p) {
      const d = docs.get(p.id);
      if (!d) return;
      const st = stateOf(p.id);
      d.baseline = st.toText(p.text);
      setDirty(p.id, d, !st.doc.eq(d.baseline));
    },
    dirty(id) { const d = docs.get(id); return !!(d && d.dirty); },
    close(id) {
      docs.delete(id);
      if (id === viewID) viewID = null;
      if (id === currentID) {
        currentID = null;
        host.hidden = true;
        previewEl.hidden = true;
        previewEl.textContent = '';
      }
    },
    focus() { if (view && !host.hidden) view.focus(); },
    // The panel came back on screen.
    relayout() { settle(); },
    // The editor's own scroll offset and first visible line, for the self test.
    scrollInfo() {
      if (!view) return null;
      const top = view.scrollDOM.scrollTop;
      return { top, line: view.state.doc.lineAt(view.lineBlockAtHeight(top).from).number };
    },
    clear() {
      park();
      currentID = null;
      host.hidden = true;
      previewEl.hidden = true;
      previewEl.textContent = '';
      document.body.classList.remove('previewing');
      empty.textContent = EMPTY;
      empty.hidden = false;
      R.post({ type: 'shown', id: null });
    },
    // Native viewers cover the page for images, PDFs and the rest. This keeps it quiet
    // underneath them.
    blank() {
      park();
      currentID = null;
      host.hidden = true;
      previewEl.hidden = true;
      empty.hidden = true;
    },
    // For the self test.
    _view: () => view,
    _CM: window.CM,
  };

  R.post({ type: 'ready' });
})();
