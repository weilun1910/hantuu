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

  // The pop-out button on a figure: opens its file as a tab in the Code tab. `source` is a
  // file path, or a data: URL for images the transcript holds only as data. The glyph is
  // macOS's arrow.up.forward.square, drawn in the reader's line-icon style.
  const POPOUT_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="2.25" y="2.25" width="11.5" height="11.5" rx="2.6"/><path d="M6.25 9.75l3.5-3.5M6.75 6.25h3v3"/></svg>';
  function popoutButton(source) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'popout';
    b.title = 'Open in a Tab';
    b.setAttribute('aria-label', 'Open in a tab');
    b.innerHTML = POPOUT_ICON;
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (source.startsWith('data:')) post({ type: 'popout', data: source });
      else post({ type: 'popout', path: source });
    });
    return b;
  }

  const SHRINK_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 2.5l4 4M3 6.5h3.5V3M13.5 13.5l-4-4M13 9.5H9.5V13"/></svg>';
  function shrinkButton(fig) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'shrink';
    b.title = 'Shrink preview (Esc)';
    b.setAttribute('aria-label', 'Shrink preview');
    b.innerHTML = SHRINK_ICON;
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      toggleMedia(fig, false);
    });
    return b;
  }

  // A PDF uses the same first-page image in both sizes. Additional pages have measured
  // placeholders and only request pixels when they approach the viewport.
  function thumbURL(path, page, width) {
    const base = 'hantuu://thumb' + path.split('/').map(encodeURIComponent).join('/');
    return base + (width ? '?page=' + page + '&w=' + width : '?h=400');
  }

  let mediaSequence = 0;
  const pdfFigures = new Map();

  function pdfPage(fig, number, size, firstImage) {
    const slot = document.createElement('div');
    slot.className = 'pdf-page';
    slot.dataset.page = number;
    if (size) slot.style.setProperty('--page-ratio', size.width + ' / ' + size.height);
    const label = document.createElement('span');
    label.className = 'pdf-page-label';
    label.textContent = 'Page ' + number;
    const img = firstImage || document.createElement('img');
    img.classList.add('pdf-page-image');
    img.draggable = false;
    img.alt = (fig.dataset.path || 'PDF').split('/').pop() + ', page ' + number;
    if (!firstImage) img.loading = 'lazy';
    img.addEventListener('load', () => {
      if (!img.naturalWidth) return;
      if (number === 1) fig.classList.remove('nothumb');
      slot.classList.add('loaded');
      if (!slot.style.getPropertyValue('--page-ratio')) {
        slot.style.setProperty('--page-ratio', img.naturalWidth + ' / ' + img.naturalHeight);
      }
    });
    slot.append(img, label);
    if (img.complete && img.naturalWidth) {
      slot.classList.add('loaded');
      slot.style.setProperty('--page-ratio', img.naturalWidth + ' / ' + img.naturalHeight);
    }
    return slot;
  }

  function sharpenPDFPage(fig, slot) {
    const state = pdfFigures.get(fig.dataset.mediaID);
    if (!state || !fig.isConnected || !fig.classList.contains('expanded')) return;
    const img = slot.querySelector('img');
    const width = state.width;
    const loaded = +(img.dataset.renderWidth || 0);
    if (!width || (loaded && width < loaded * 1.25) || state.pending.has(slot)) return;
    // Decode offscreen before replacing the visible source, so page one never disappears.
    const sharp = new Image();
    sharp.className = img.className;
    sharp.alt = img.alt;
    sharp.draggable = false;
    state.pending.set(slot, sharp);
    sharp.onload = async () => {
      try { await sharp.decode(); } catch (_) {
        state.pending.delete(slot);
        return;
      }
      if (state.pending.get(slot) !== sharp) return;
      state.pending.delete(slot);
      if (!fig.isConnected || !sharp.naturalWidth) return;
      sharp.onload = sharp.onerror = null;
      sharp.dataset.renderWidth = width;
      // Insert the decoded element itself. Assigning its URL to another image could issue
      // another no-store request and clear that image before the replacement arrives.
      img.replaceWith(sharp);
      slot.classList.add('loaded');
      if (slot.dataset.page === '1') fig.classList.remove('nothumb');
      // The reader might have grown again while this raster was being produced.
      if (state.visible.has(slot)) sharpenPDFPage(fig, slot);
    };
    sharp.onerror = () => {
      state.pending.delete(slot);
      slot.querySelector('.pdf-page-label').textContent = 'Page ' + slot.dataset.page + ' unavailable. Open in a tab.';
    };
    sharp.src = thumbURL(fig.dataset.path, slot.dataset.page, width);
  }

  function updatePDFWidth(fig) {
    const state = pdfFigures.get(fig.dataset.mediaID);
    if (!state || !fig.classList.contains('expanded')) return;
    const pixels = fig.querySelector('.mbody').clientWidth * (window.devicePixelRatio || 1);
    const width = Math.min(3200, Math.max(256, Math.ceil(pixels / 256) * 256));
    if (state.width && width < state.width * 1.25) return;
    state.width = width;
    state.visible.forEach((slot) => sharpenPDFPage(fig, slot));
  }

  function observePDFPages(fig) {
    const state = pdfFigures.get(fig.dataset.mediaID);
    if (!state || !fig.classList.contains('expanded')) return;
    const slots = fig.querySelectorAll('.pdf-page');
    slots.forEach((slot) => state.intersections.observe(slot));
    // Page one already has its compact image. Request the sharper version immediately.
    if (slots[0]) sharpenPDFPage(fig, slots[0]);
  }

  function preparePDF(fig) {
    if (!fig.dataset.mediaID) {
      fig.dataset.mediaID = 'pdf-' + (++mediaSequence);
      const state = { fig, width: 0, pending: new Map(), visible: new Set(), requested: false };
      state.intersections = new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            state.visible.add(entry.target);
            sharpenPDFPage(fig, entry.target);
          } else state.visible.delete(entry.target);
        }
      }, { rootMargin: '300px 0px' });
      state.resize = new ResizeObserver(() => updatePDFWidth(fig));
      state.resize.observe(fig.querySelector('.mbody'));
      pdfFigures.set(fig.dataset.mediaID, state);
    }
    const state = pdfFigures.get(fig.dataset.mediaID);
    updatePDFWidth(fig);
    observePDFPages(fig);
    if (!state.requested) {
      state.requested = true;
      post({ type: 'pdfInfo', id: fig.dataset.mediaID, path: fig.dataset.path });
    }
  }

  // Metadata comes through Swift's bridge rather than a cross-origin custom-scheme fetch.
  function pdfInfo(payload) {
    const state = pdfFigures.get(payload.id);
    if (!state || !state.fig.isConnected || state.fig.dataset.path !== payload.path) return;
    const fig = state.fig;
    if (!Array.isArray(payload.pages) || !payload.pages.length) {
      state.requested = false;
      return;
    }
    const body = fig.querySelector('.mbody');
    payload.pages.forEach((size, index) => {
      if (!(size.width > 0 && size.height > 0)) return;
      if (!index) body.firstElementChild.style.setProperty('--page-ratio', size.width + ' / ' + size.height);
      else body.appendChild(pdfPage(fig, index + 1, size));
    });
    fig.dataset.pageCount = payload.pages.length;
    observePDFPages(fig);
  }

  function disposeMedia() {
    for (const state of pdfFigures.values()) {
      state.resize.disconnect();
      state.intersections.disconnect();
      for (const image of state.pending.values()) {
        image.onload = image.onerror = null;
        image.removeAttribute('src');
      }
      state.pending.clear();
    }
    pdfFigures.clear();
  }

  // `attached` marks images that came with the message itself (pasted, or a tool's result)
  // rather than from a path the text mentions.
  function mediaFigure(kind, src, path, attached) {
    const fig = document.createElement('figure');
    fig.className = 'mfig ' + kind;
    if (path) fig.dataset.path = path;
    fig.dataset.src = src;
    const body = document.createElement('div');
    body.className = 'mbody';
    body.title = 'Click to enlarge';
    const img = document.createElement('img');
    img.loading = 'lazy';
    img.draggable = false;
    if (kind === 'pdf') {
      img.className = 'pdf-thumb';
      img.src = thumbURL(path);
      img.alt = path.split('/').pop();
      img.addEventListener('error', () => fig.classList.add('nothumb'));
    } else {
      img.className = attached ? 'attached-image' : 'inline-image';
      img.src = src;
      if (path) img.dataset.path = path;
    }
    body.appendChild(kind === 'pdf' ? pdfPage(fig, 1, null, img) : img);
    fig.appendChild(body);
    fig.appendChild(popoutButton(path || src));
    fig.appendChild(shrinkButton(fig));
    if (path) {
      const cap = document.createElement('figcaption');
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'media-caption';
      b.textContent = path.split('/').pop();
      b.title = path;
      b.setAttribute('aria-expanded', 'false');
      cap.appendChild(b);
      fig.appendChild(cap);
    }
    return fig;
  }

  // Images and PDFs a message points at, shown below it.
  function mediaFor(links, already) {
    const box = document.createElement('div');
    box.className = 'media';
    const seen = already || new Set();
    for (const l of links || []) {
      if (seen.has(l.path) || (l.kind !== 'image' && l.kind !== 'pdf')) continue;
      seen.add(l.path);
      box.appendChild(mediaFigure(l.kind, fileURL(l.path), l.path));
    }
    return box.childNodes.length ? box : null;
  }

  function expandedCount() { return document.querySelectorAll('figure.mfig.expanded').length; }

  // Opens a preview out to full width, or shrinks it back, keeping the figure where it was
  // on screen so the page doesn't jump under you.
  function toggleMedia(fig, open) {
    const want = open === undefined ? !fig.classList.contains('expanded') : open;
    if (want === fig.classList.contains('expanded')) return;
    const body = fig.querySelector('.mbody');
    const top = fig.getBoundingClientRect().top;
    fig.classList.toggle('expanded', want);
    body.title = want ? 'Click to shrink' : 'Click to enlarge';
    const caption = fig.querySelector('.media-caption');
    if (caption) caption.setAttribute('aria-expanded', String(want));
    if (fig.classList.contains('pdf')) {
      if (want) preparePDF(fig);
      else {
        const state = pdfFigures.get(fig.dataset.mediaID);
        if (state) {
          state.intersections.disconnect();
          state.visible.clear();
        }
      }
    }
    const scroller = document.scrollingElement;
    scroller.scrollTop += fig.getBoundingClientRect().top - top;
    post({ type: 'mediaExpanded', count: expandedCount() });
  }

  // Shrinks every opened-out preview. True if there was one. Swift calls this for Esc while
  // the message box has the keyboard.
  function collapseMedia() {
    const open = Array.from(document.querySelectorAll('figure.mfig.expanded'));
    open.forEach((f) => toggleMedia(f, false));
    return open.length > 0;
  }

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && expandedCount() && collapseMedia()) e.preventDefault();
  });

  // One click handler for every link: file paths go to Swift's router, web links to the
  // browser, relative Markdown links are resolved by Swift against the base folder.
  document.addEventListener('click', (e) => {
    const fig = e.target.closest('figure.mfig');
    if (fig && !e.target.closest('button.popout, button.shrink')) {
      e.preventDefault();
      toggleMedia(fig);
      return;
    }
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
  });

  window.hantuuRender = { renderMarkdown, linkifyPaths, mediaFor, mediaFigure, toggleMedia, collapseMedia, pdfInfo, disposeMedia, popoutButton, escapeHTML, fileURL, highlightBlock, post };
})();
