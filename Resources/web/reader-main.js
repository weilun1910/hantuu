// Reader mode: the reader as a chat's main view (reader.html?layout=main). reader.js calls in
// here only in that layout, so the panel's Reader looks the same as before.
//
// What it adds: your messages as quiet bubbles on the right, runs of tool calls folded into one
// line ("Read 2 files and ran a command") that opens on click, small line icons per tool, paths
// inside the chat's folder shown relative to it, a header with the language and Copy on code
// blocks, the time and Copy on hover under each message, and a short fade for new messages.
//
// The layout ideas come from T3 Code's chat view (github.com/pingdotgg/t3code, MIT License):
// right-aligned user bubbles, the folded work log with its summary wording, the code block
// header and the hover row. The code and icons here are hantuu's own.
(function () {
  'use strict';
  const R = window.hantuuRender;
  let base = null;
  const openGroups = new Set();

  // 16 pt line icons, drawn for hantuu.
  const PATHS = {
    command: '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2"/><path d="M4.5 6.25l2 1.75-2 1.75M8.25 10.25h3.25"/>',
    edit: '<path d="M10.6 2.6l2.8 2.8-7.6 7.6H3v-2.8z"/><path d="M9.1 4.1l2.8 2.8"/>',
    read: '<path d="M4 1.75h5.25L12.25 4.75v9.5H4z"/><path d="M9 1.75v3h3.25M6.25 8.25h3.75M6.25 10.75h3.75"/>',
    search: '<circle cx="7" cy="7" r="4.25"/><path d="M10.2 10.2l3.55 3.55"/>',
    web: '<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c1.7 1.7 2.5 3.7 2.5 6S9.7 12.3 8 14C6.3 12.3 5.5 10.3 5.5 8S6.3 3.7 8 2z"/>',
    agent: '<rect x="2" y="5.25" width="8.25" height="8.5" rx="1.75"/><path d="M5.5 2.5h6.75c.7 0 1.25.55 1.25 1.25v6.75"/>',
    plan: '<path d="M2.25 4.5l1.25 1.25 2.25-2.25M2.25 10.5l1.25 1.25 2.25-2.25M8.25 4.75h5.25M8.25 10.75h5.25"/>',
    image: '<rect x="2" y="3" width="12" height="10" rx="1.75"/><path d="M2.5 11.25l3.25-3.25 2.5 2.5 2-2 3.25 3.25"/><circle cx="10.5" cy="6" r="1"/>',
    other: '<circle cx="8" cy="8" r="2.25"/><path d="M8 1.75v2.25M8 12v2.25M1.75 8H4M12 8h2.25"/>',
    chevron: '<path d="M6.25 4l3.75 4-3.75 4"/>',
    copy: '<rect x="5.25" y="5.25" width="8.5" height="8.5" rx="1.75"/><path d="M10.75 5.25V3.5c0-.7-.55-1.25-1.25-1.25H3.5c-.7 0-1.25.55-1.25 1.25v6c0 .7.55 1.25 1.25 1.25h1.75"/>',
    check: '<path d="M3.5 8.5l3 3 6-6.5"/>',
  };
  function svg(name, cls) {
    return '<svg class="' + (cls || 'ticon') + '" viewBox="0 0 16 16" aria-hidden="true">' + (PATHS[name] || PATHS.other) + '</svg>';
  }

  const KINDS = {
    command: ['Bash', 'PowerShell', 'shell', 'exec', 'exec_command', 'local_shell', 'container.exec', 'shell_command', 'unified_exec'],
    edit: ['Edit', 'MultiEdit', 'Write', 'NotebookEdit', 'apply_patch'],
    read: ['Read', 'view_image'],
    search: ['Grep', 'Glob'],
    web: ['WebFetch', 'WebSearch', 'web_search'],
    agent: ['Task', 'Agent'],
    plan: ['TodoWrite', 'TaskCreate', 'TaskUpdate', 'update_plan'],
  };
  function kindOf(e) {
    if (e.images && e.images.length) return 'image';
    for (const k in KINDS) if (KINDS[k].includes(e.tool)) return k;
    return 'other';
  }

  // "a command", "2 files"; "once", "twice", "3 times".
  function n(count, word) {
    if (count === 1) return (/^[aeiou]/.test(word) ? 'an ' : 'a ') + word;
    return count + ' ' + word + 's';
  }
  function times(count) { return count === 1 ? 'once' : count === 2 ? 'twice' : count + ' times'; }
  const PHRASES = {
    command: (c) => 'ran ' + n(c, 'command'),
    edit: (c) => 'edited ' + n(c, 'file'),
    read: (c) => 'read ' + n(c, 'file'),
    search: (c) => 'searched ' + times(c),
    web: (c) => 'looked up ' + n(c, 'page'),
    agent: (c) => 'started ' + n(c, 'agent'),
    plan: () => 'updated the plan',
    image: (c) => 'looked at ' + n(c, 'image'),
    other: (c) => 'used ' + n(c, 'tool'),
  };

  // The two most frequent kinds, then a count of the rest: "Read 3 files, ran 2 commands and
  // 2 more". Ties keep the order they happened in.
  function summary(tools) {
    const counts = new Map();
    for (const t of tools) counts.set(t.dataset.tool, (counts.get(t.dataset.tool) || 0) + 1);
    const kinds = Array.from(counts.keys()).sort((a, b) => counts.get(b) - counts.get(a));
    const parts = kinds.slice(0, 2).map((k) => PHRASES[k](counts.get(k)));
    const rest = kinds.slice(2).reduce((s, k) => s + counts.get(k), 0);
    let text = parts.length === 1 ? parts[0] : parts[0] + (rest ? ', ' : ' and ') + parts[1];
    if (rest) text += ' and ' + rest + ' more';
    return { text: text.charAt(0).toUpperCase() + text.slice(1), icon: kinds[0] };
  }

  function relative(p) {
    if (!base) return p;
    if (p === base) return base.split('/').pop() || p;
    return p.startsWith(base + '/') ? p.slice(base.length + 1) : p;
  }

  function clock(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d)) return '';
    const hm = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const today = new Date().toDateString() === d.toDateString();
    return today ? hm : d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' ' + hm;
  }

  function copyButton(label, getText) {
    const b = document.createElement('button');
    b.className = 'copy';
    b.title = 'Copy';
    b.innerHTML = svg('copy') + (label ? '<span>' + label + '</span>' : '');
    b.addEventListener('click', (ev) => {
      ev.stopPropagation();
      R.post({ type: 'copy', text: getText() });
      b.classList.add('done');
      b.innerHTML = svg('check') + (label ? '<span>Copied</span>' : '');
      setTimeout(() => {
        b.classList.remove('done');
        b.innerHTML = svg('copy') + (label ? '<span>' + label + '</span>' : '');
      }, 1200);
    });
    return b;
  }

  function codeBlocks(el) {
    for (const pre of el.querySelectorAll('.md pre.hljs')) {
      if (pre.parentElement.classList.contains('codeblock')) continue;
      const wrap = document.createElement('div');
      wrap.className = 'codeblock';
      const head = document.createElement('div');
      head.className = 'codehead';
      const lang = document.createElement('span');
      lang.className = 'lang';
      lang.textContent = pre.dataset.lang || '';
      head.appendChild(lang);
      head.appendChild(copyButton('Copy', () => pre.innerText.replace(/\n$/, '')));
      pre.replaceWith(wrap);
      wrap.appendChild(head);
      wrap.appendChild(pre);
    }
  }

  // A new message fades in. Only while the page is on screen, and the class always comes off
  // again, so a page that isn't painting (a hidden view, an offscreen window) never leaves a
  // message stuck half-faded.
  function fadeIn(el) {
    if (document.visibilityState !== 'visible') return;
    el.classList.add('fresh');
    setTimeout(() => el.classList.remove('fresh'), 450);
  }

  function decorate(el, e, fresh) {
    if (fresh) fadeIn(el);
    if (e.kind === 'tool') {
      el.dataset.tool = kindOf(e);
      const line = el.querySelector('.toolline');
      if (line) {
        line.insertAdjacentHTML('afterbegin', svg(el.dataset.tool));
        for (const a of line.querySelectorAll('a.path')) a.textContent = relative(a.textContent);
        const t = line.querySelector('.tooltext');
        if (t && base) {
          for (const node of t.childNodes) {
            if (node.nodeType === Node.TEXT_NODE && node.nodeValue.includes(base)) {
              node.nodeValue = node.nodeValue.split(base + '/').join('').split(base).join(relative(base));
            }
          }
        }
      }
      return;
    }
    codeBlocks(el);
    if (e.kind === 'assistant' || e.kind === 'user') {
      const meta = document.createElement('div');
      meta.className = 'meta';
      const when = clock(e.time);
      if (when) {
        const t = document.createElement('span');
        t.className = 'time';
        t.textContent = when;
        meta.appendChild(t);
      }
      meta.appendChild(copyButton('', () => e.text));
      el.appendChild(meta);
    }
  }

  function isTool(node) {
    return node && ((node.classList.contains('entry') && node.classList.contains('tool')) || node.classList.contains('toolgroup'));
  }

  function toolsIn(nodes) {
    const out = [];
    for (const nd of nodes) {
      if (nd.classList.contains('toolgroup')) out.push(...nd.querySelectorAll(':scope > .toolrows > section.entry.tool'));
      else out.push(nd);
    }
    return out;
  }

  function makeGroup(tools, fresh) {
    const key = tools[0].dataset.id;
    const g = document.createElement('div');
    g.className = 'toolgroup' + (openGroups.has(key) ? ' open' : '');
    if (fresh) fadeIn(g);
    g.dataset.key = key;
    const s = summary(tools);
    const sum = document.createElement('div');
    sum.className = 'toolsum';
    sum.title = 'Show the steps';
    sum.innerHTML = svg(s.icon) + '<span class="sumtext"></span>' + svg('chevron', 'chev');
    sum.querySelector('.sumtext').textContent = s.text;
    sum.addEventListener('click', () => {
      g.classList.toggle('open');
      if (g.classList.contains('open')) openGroups.add(key); else openGroups.delete(key);
    });
    const rows = document.createElement('div');
    rows.className = 'toolrows';
    for (const t of tools) { t.classList.remove('fresh'); rows.appendChild(t); }
    g.appendChild(sum);
    g.appendChild(rows);
    return g;
  }

  // Folds one run of consecutive tool lines (and any group already in it) into a group.
  function fold(run, list, fresh) {
    const tools = toolsIn(run);
    if (tools.length < 2) return;
    const anchor = run[run.length - 1].nextSibling;
    for (const nd of run) if (nd.classList.contains('toolgroup')) nd.remove();
    list.insertBefore(makeGroup(tools, fresh && !run.some((nd) => nd.classList.contains('toolgroup'))), anchor);
  }

  // After a reset: every run. After an append: only the run at the end, which may have grown.
  function settle(list, all) {
    if (all) {
      let run = [];
      for (const nd of Array.from(list.children)) {
        if (isTool(nd)) { run.push(nd); continue; }
        if (run.length) fold(run, list, false);
        run = [];
      }
      if (run.length) fold(run, list, false);
      return;
    }
    const run = [];
    for (let nd = list.lastElementChild; nd && isTool(nd); nd = nd.previousElementSibling) run.unshift(nd);
    if (run.length) fold(run, list, true);
  }

  window.hantuuMain = {
    reset(b) { base = b || null; },
    decorate,
    settle,
  };
})();
