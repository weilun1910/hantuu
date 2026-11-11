// The pieces of CodeMirror 6 that hantuu's Code tab uses, bundled into one file that sets
// window.CM. The editor itself lives in Resources/web/code.js. Build with ./build.sh.
import * as state from '@codemirror/state';
import * as view from '@codemirror/view';
import * as commands from '@codemirror/commands';
import * as language from '@codemirror/language';
import * as search from '@codemirror/search';
import { tags } from '@lezer/highlight';

import { javascript } from '@codemirror/lang-javascript';
import { python } from '@codemirror/lang-python';
import { rust } from '@codemirror/lang-rust';
import { cpp } from '@codemirror/lang-cpp';
import { java } from '@codemirror/lang-java';
import { json } from '@codemirror/lang-json';
import { html } from '@codemirror/lang-html';
import { css } from '@codemirror/lang-css';
import { markdown } from '@codemirror/lang-markdown';
import { xml } from '@codemirror/lang-xml';
import { sql } from '@codemirror/lang-sql';
import { go } from '@codemirror/lang-go';
import { yaml } from '@codemirror/lang-yaml';
import { php } from '@codemirror/lang-php';

import { swift } from '@codemirror/legacy-modes/mode/swift';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { ruby } from '@codemirror/legacy-modes/mode/ruby';
import { toml } from '@codemirror/legacy-modes/mode/toml';
import { lua } from '@codemirror/legacy-modes/mode/lua';
import { perl } from '@codemirror/legacy-modes/mode/perl';
import { r } from '@codemirror/legacy-modes/mode/r';
import { julia } from '@codemirror/legacy-modes/mode/julia';
import { haskell } from '@codemirror/legacy-modes/mode/haskell';
import { clojure } from '@codemirror/legacy-modes/mode/clojure';
import { erlang } from '@codemirror/legacy-modes/mode/erlang';
import { dockerFile } from '@codemirror/legacy-modes/mode/dockerfile';
import { diff } from '@codemirror/legacy-modes/mode/diff';
import { properties } from '@codemirror/legacy-modes/mode/properties';
import { cmake } from '@codemirror/legacy-modes/mode/cmake';
import { protobuf } from '@codemirror/legacy-modes/mode/protobuf';
import { kotlin, scala, csharp, dart, objectiveC, objectiveCpp } from '@codemirror/legacy-modes/mode/clike';
import { oCaml } from '@codemirror/legacy-modes/mode/mllike';
import { powerShell } from '@codemirror/legacy-modes/mode/powershell';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { groovy } from '@codemirror/legacy-modes/mode/groovy';
import { nginx } from '@codemirror/legacy-modes/mode/nginx';
import { sass } from '@codemirror/legacy-modes/mode/sass';
import { elm } from '@codemirror/legacy-modes/mode/elm';
import { commonLisp } from '@codemirror/legacy-modes/mode/commonlisp';
import { vb } from '@codemirror/legacy-modes/mode/vb';
import { fortran } from '@codemirror/legacy-modes/mode/fortran';
import { verilog } from '@codemirror/legacy-modes/mode/verilog';

const legacy = (mode) => () => language.StreamLanguage.define(mode);

// Language name to a function that makes its support. code.js maps file names to these names.
const languages = {
  javascript: () => javascript({ jsx: true }),
  typescript: () => javascript({ typescript: true }),
  tsx: () => javascript({ typescript: true, jsx: true }),
  python: () => python(),
  rust: () => rust(),
  cpp: () => cpp(),
  java: () => java(),
  json: () => json(),
  html: () => html(),
  css: () => css(),
  xml: () => xml(),
  sql: () => sql(),
  go: () => go(),
  yaml: () => yaml(),
  php: () => php(),
  swift: legacy(swift),
  shell: legacy(shell),
  ruby: legacy(ruby),
  toml: legacy(toml),
  lua: legacy(lua),
  perl: legacy(perl),
  r: legacy(r),
  julia: legacy(julia),
  haskell: legacy(haskell),
  clojure: legacy(clojure),
  erlang: legacy(erlang),
  dockerfile: legacy(dockerFile),
  diff: legacy(diff),
  properties: legacy(properties),
  cmake: legacy(cmake),
  protobuf: legacy(protobuf),
  kotlin: legacy(kotlin),
  scala: legacy(scala),
  csharp: legacy(csharp),
  dart: legacy(dart),
  objectivec: legacy(objectiveC),
  objectivecpp: legacy(objectiveCpp),
  ocaml: legacy(oCaml),
  powershell: legacy(powerShell),
  latex: legacy(stex),
  groovy: legacy(groovy),
  nginx: legacy(nginx),
  sass: legacy(sass),
  elm: legacy(elm),
  lisp: legacy(commonLisp),
  vb: legacy(vb),
  fortran: legacy(fortran),
  verilog: legacy(verilog),
};

// Fenced code in Markdown is highlighted with the same languages.
const aliases = { js: 'javascript', ts: 'typescript', py: 'python', rs: 'rust', c: 'cpp', 'c++': 'cpp', sh: 'shell', bash: 'shell', zsh: 'shell',
  rb: 'ruby', yml: 'yaml', kt: 'kotlin', cs: 'csharp', objc: 'objectivec', tex: 'latex', dockerfile: 'dockerfile', docker: 'dockerfile' };
function fencedLanguage(info) {
  const name = (info || '').trim().toLowerCase().split(/\s+/)[0];
  const make = languages[aliases[name] || name];
  if (!make) return null;
  const support = make();
  return support.language || support;
}
languages.markdown = () => markdown({ codeLanguages: fencedLanguage });

window.CM = { state, view, commands, language, search, tags, languages };
