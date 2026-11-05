// Shared rendering for the reader and the code viewer: Markdown (markdown-it), LaTeX
// (KaTeX), code highlighting (highlight.js) and linking of file paths that exist on disk.
// Everything is bundled; nothing is fetched from the network.
(function () {
  'use strict';

  const post = (msg) => window.webkit.messageHandlers.hantuu.postMessage(msg);

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function fileURL(path) {
    return 'hantuu://file' + path.split('/').map(encodeURIComponent).join('/');
  }

  const md = window.markdownit({
    html: false,
    linkify: true,
    breaks: false,
    typographer: false,
    highlight: (str, lang) => highlightBlock(str, lang),
  });
  const mdBreaks = window.markdownit({ html: false, linkify: true, breaks: true, highlight: (s, l) => highlightBlock(s, l) });
  // Only link real URLs. Fuzzy matching turns file names like app.swift into web links.
  for (const m of [md, mdBreaks]) m.linkify.set({ fuzzyLink: false, fuzzyEmail: false, fuzzyIP: false });

  function highlightBlock(str, lang) {
    try {
      if (lang && hljs.getLanguage(lang)) {
        return '<pre class="hljs" data-lang="' + escapeHTML(lang) + '"><code>' + hljs.highlight(str, { language: lang, ignoreIllegals: true }).value + '</code></pre>';
      }
      // Unlabeled blocks are usually output, paths or prose: keep them plain so file
      // paths stay in one text node and can be linked.
    } catch (e) {}
    return '<pre class="hljs"><code>' + escapeHTML(str) + '</code></pre>';
  }

  // Pull math out before Markdown sees it (markdown-it would eat the backslashes in \( \)),
  // leaving code spans and fenced blocks alone. Returns text with placeholders.
  function extractMath(src) {
    const math = [];
    const out = [];
    // Split on fenced code blocks and inline code; only odd segments are code.
    const parts = src.split(/(```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`)/g);
    for (let i = 0; i < parts.length; i++) {
      let p = parts[i];
      if (i % 2 === 1) { out.push(p); continue; }
      const stash = (tex, display) => {
        math.push({ tex, display });
        const token = 'HANTUUMATH' + (math.length - 1) + 'X';
        return display ? '\n\n' + token + '\n\n' : token;
      };
      p = p.replace(/\$\$([\s\S]+?)\$\$/g, (_, t) => stash(t, true));
      p = p.replace(/\\\[([\s\S]+?)\\\]/g, (_, t) => stash(t, true));
      p = p.replace(/\\\(([\s\S]+?)\\\)/g, (_, t) => stash(t, false));
      // $...$: no space just inside the delimiters, no digit right after the closing $,
      // so prices like "$5 and $10" stay as text.
      p = p.replace(/(^|[^\\$\w])\$(?=\S)((?:\\\$|[^$\n])+?)(?<=\S)\$(?!\d)/g, (m, pre, t) => pre + stash(t, false));
      out.push(p);
    }
    return { text: out.join(''), math };
  }

  function restoreMath(html, math) {
    return html.replace(/(<p>)?HANTUUMATH(\d+)X(<\/p>)?/g, (m, open, idx, close) => {
      const item = math[+idx];
      if (!item) return m;
      let rendered;
      try {
        rendered = katex.renderToString(item.tex, { displayMode: item.display, throwOnError: false, output: 'html' });
      } catch (e) {
        rendered = '<code>' + escapeHTML(item.tex) + '</code>';
      }
      if (item.display) return '<div class="math-display">' + rendered + '</div>';
      return (open || '') + rendered + (close || '');
    });
  }

  function renderMarkdown(text, opts) {
    const { text: t, math } = extractMath(text || '');
    const engine = opts && opts.breaks ? mdBreaks : md;
    return restoreMath(engine.render(t), math);
  }

  // Wrap occurrences of known paths in links. `links` comes from Swift and only contains
  // paths that exist on disk.
  function linkifyPaths(root, links) {
    if (!links || !links.length) return;
    const sorted = links.slice().sort((a, b) => b.match.length - a.match.length);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        let p = n.parentNode;
        while (p && p !== root) {
          if (p.nodeName === 'A' || (p.classList && (p.classList.contains('katex') || p.classList.contains('path')))) return NodeFilter.FILTER_REJECT;
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) {
      let text = node.nodeValue;
      let hits = [];
      for (const l of sorted) {
        let from = 0;
        while (true) {
          const i = text.indexOf(l.match, from);
          if (i < 0) break;
          if (!hits.some((h) => i < h.end && i + l.match.length > h.start)) hits.push({ start: i, end: i + l.match.length, link: l });
          from = i + l.match.length;
        }
      }
      if (!hits.length) continue;
      hits.sort((a, b) => a.start - b.start);
      const frag = document.createDocumentFragment();
      let pos = 0;
      for (const h of hits) {
        if (h.start > pos) frag.appendChild(document.createTextNode(text.slice(pos, h.start)));
        const a = document.createElement('a');
        a.className = 'path';
        a.textContent = text.slice(h.start, h.end);
        a.dataset.path = h.link.path;
        if (h.link.line) a.dataset.line = h.link.line;
        a.title = h.link.path;
        frag.appendChild(a);
        pos = h.end;
      }
      if (pos < text.length) frag.appendChild(document.createTextNode(text.slice(pos)));
      node.parentNode.replaceChild(frag, node);
    }
  }

  // Images and PDFs a message points at, shown below it.
  function mediaFor(links, already) {
    const box = document.createElement('div');
    box.className = 'media';
    const seen = already || new Set();
    for (const l of links || []) {
      if (seen.has(l.path)) continue;
      if (l.kind === 'image') {
        seen.add(l.path);
        const fig = document.createElement('figure');
        const img = document.createElement('img');
        img.loading = 'lazy';
        img.src = fileURL(l.path);
        img.dataset.path = l.path;
        img.className = 'inline-image';
        const cap = document.createElement('figcaption');
        cap.textContent = l.path.split('/').pop();
        fig.appendChild(img);
        fig.appendChild(cap);
        box.appendChild(fig);
      } else if (l.kind === 'pdf') {
        seen.add(l.path);
        const fig = document.createElement('figure');
        fig.className = 'pdf';
        const frame = document.createElement('iframe');
        frame.src = fileURL(l.path);
        frame.loading = 'lazy';
        const cap = document.createElement('figcaption');
        const a = document.createElement('a');
        a.className = 'path';
        a.dataset.path = l.path;
        a.textContent = l.path.split('/').pop();
        cap.appendChild(a);
        fig.appendChild(frame);
        fig.appendChild(cap);
        box.appendChild(fig);
      }
    }
    return box.childNodes.length ? box : null;
  }

  // One click handler for every link: file paths go to Swift's router, web links to the
  // browser, relative Markdown links are resolved by Swift against the base folder.
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a');
    if (a) {
      e.preventDefault();
      if (a.dataset.path) {
        post({ type: 'open', path: a.dataset.path, line: a.dataset.line ? +a.dataset.line : null });
      } else if (a.getAttribute('href')) {
        post({ type: 'link', href: a.getAttribute('href'), base: a.dataset.base || null });
      }
      return;
    }
    const img = e.target.closest('img.inline-image');
    if (img && img.dataset.path) post({ type: 'open', path: img.dataset.path });
  });

  window.hantuuRender = { renderMarkdown, linkifyPaths, mediaFor, escapeHTML, fileURL, highlightBlock, post };
})();
