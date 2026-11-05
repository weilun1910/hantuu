// The read-only code viewer: highlighted source with line numbers, or a Markdown preview.
(function () {
  'use strict';
  const R = window.hantuuRender;
  const view = document.getElementById('view');
  const empty = document.getElementById('empty');

  const byExt = {
    js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript',
    py: 'python', rb: 'ruby', rs: 'rust', go: 'go', swift: 'swift', m: 'objectivec', mm: 'objectivec', h: 'c', c: 'c',
    cc: 'cpp', cpp: 'cpp', hpp: 'cpp', java: 'java', kt: 'kotlin', kts: 'kotlin', scala: 'scala', cs: 'csharp',
    php: 'php', lua: 'lua', pl: 'perl', r: 'r', jl: 'julia', dart: 'dart', ex: 'elixir', exs: 'elixir', erl: 'erlang',
    hs: 'haskell', ml: 'ocaml', clj: 'clojure', sql: 'sql', sh: 'bash', bash: 'bash', zsh: 'bash', fish: 'bash',
    ps1: 'powershell', md: 'markdown', markdown: 'markdown', mdx: 'markdown', json: 'json', jsonl: 'json',
    yaml: 'yaml', yml: 'yaml', toml: 'ini', ini: 'ini', cfg: 'ini', conf: 'ini', xml: 'xml', plist: 'xml',
    html: 'xml', htm: 'xml', svg: 'xml', css: 'css', scss: 'scss', less: 'less', tex: 'latex', diff: 'diff',
    patch: 'diff', nix: 'nix', proto: 'protobuf', graphql: 'graphql', gql: 'graphql', makefile: 'makefile',
    mk: 'makefile', dockerfile: 'dockerfile', zon: 'rust', zig: 'rust', ghostty: 'ini',
  };

  function languageFor(name) {
    const lower = name.toLowerCase();
    if (lower === 'makefile') return 'makefile';
    if (lower === 'dockerfile') return 'dockerfile';
    const ext = lower.includes('.') ? lower.split('.').pop() : '';
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

  function showSource(p) {
    const lang = languageFor(p.name);
    let html;
    try {
      if (lang) html = hljs.highlight(p.text, { language: lang, ignoreIllegals: true }).value;
      else if (p.text.length < 60000) html = hljs.highlightAuto(p.text).value;
      else html = R.escapeHTML(p.text);
    } catch (e) {
      html = R.escapeHTML(p.text);
    }
    const lines = splitLines(html);
    if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
    const table = document.createElement('table');
    table.className = 'source hljs';
    const rows = [];
    for (let i = 0; i < lines.length; i++) {
      rows.push('<tr id="L' + (i + 1) + '"><td class="ln">' + (i + 1) + '</td><td class="src">' + (lines[i] || ' ') + '</td></tr>');
    }
    table.innerHTML = '<tbody>' + rows.join('') + '</tbody>';
    view.appendChild(table);
    if (p.line) {
      const row = document.getElementById('L' + p.line);
      if (row) {
        row.classList.add('target');
        requestAnimationFrame(() => row.scrollIntoView({ block: 'center' }));
      }
    }
  }

  function showPreview(p) {
    const art = document.createElement('article');
    art.className = 'md preview';
    art.innerHTML = R.renderMarkdown(p.text, {});
    // Relative images and links resolve against the file's folder.
    art.querySelectorAll('img').forEach((img) => {
      const src = img.getAttribute('src') || '';
      if (!/^[a-z]+:/i.test(src)) {
        const abs = src.startsWith('/') ? src : p.base + '/' + src;
        img.src = R.fileURL(abs.replace(/\/\.\//g, '/'));
      }
    });
    art.querySelectorAll('a[href]').forEach((a) => { a.dataset.base = p.base; });
    R.linkifyPaths(art, p.links || []);
    view.appendChild(art);
  }

  window.hantuu = {
    show(p) {
      view.textContent = '';
      empty.hidden = true;
      document.body.classList.toggle('previewing', !!p.preview);
      if (p.error) {
        empty.textContent = p.error;
        empty.hidden = false;
        return;
      }
      if (p.preview) showPreview(p);
      else showSource(p);
      if (!p.line) document.scrollingElement.scrollTop = 0;
      if (p.truncated) {
        const n = document.createElement('div');
        n.className = 'truncated';
        n.textContent = 'Showing the first part of a large file.';
        view.appendChild(n);
      }
    },
    clear() {
      view.textContent = '';
      empty.textContent = 'Cmd-click a file path in a chat or the reader to open it here.';
      empty.hidden = false;
    },
  };

  R.post({ type: 'ready' });
})();
