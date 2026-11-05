# hantuu

This is a proof of concept, built to try the direction before polishing anything. Expect rough edges.

hantuu is a Mac app for running coding agents. Every chat is a real terminal, drawn by Ghostty's own engine (libghostty 1.4.0), running the agent's TUI in a project folder. Around it there's a sidebar of chats grouped by project, and a right panel with terminals, a code viewer and a reader that shows the chat as clean prose with images, PDFs and LaTeX.

## Run it

The first time, build libghostty. It downloads Zig 0.17.0 and the Ghostty v1.4.0 source into `vendor/` and takes a few minutes:

```bash
scripts/build-libghostty.sh
```

Then build and open the app:

```bash
scripts/run.sh
```

After that, `build/hantuu.app` opens from Finder like any app. `scripts/build.sh` builds without opening it.

Your projects and chats are saved in `~/Library/Application Support/hantuu/`. To try things without touching that, pass a scratch data folder:

```bash
scripts/run.sh --data-dir "$PWD/tmp/appdata"
```

## What's in it

- Sidebar: add a project folder (Shift-Cmd-O). Each project lists its chats with a status dot: green while running, amber when the agent rang the bell or sent a notification while you were elsewhere, hollow once it's ended. The chat's name comes from the agent's terminal title.
- New chat (Cmd-N) opens your default agent (Claude Code unless you change it in Settings) in the selected project. Hover the new-chat button for a list of every installed agent. File > New Chat With does the same.
- Chats keep running when you switch between them. Cmd-1 to Cmd-9 jump between them.
- Ended chats stay in the sidebar after you quit. Resume reopens them with `claude --resume` or `codex resume`, and the reader picks up where it was.
- Right panel (Option-Cmd-0):
  - Terminal: tabs of plain shells in the project folder (Cmd-T).
  - Code: read-only tabs with highlighting and line numbers. Markdown has a Source / Preview switch. Cmd-O opens a file.
  - Reader: follows the chat's transcript live. Prompts and answers as prose, tool calls on one line each, thinking hidden, errors and questions highlighted. LaTeX through KaTeX, images and PDFs inline, and every existing file path is a link. Text files open in Code, everything else shows in Finder.
- Cmd-click a link in a terminal: web links open in the browser, file links follow the same rule as the reader.
- Drop files onto a terminal to type their escaped paths into it. Claude Code treats a dropped image as an attachment.
- Keep awake, in the sidebar footer: runs `pmset -a disablesleep 1` (or `0`) through the macOS admin prompt, so the Mac keeps running with the lid shut, and holds a no-sleep assertion while it's on. It reads the real state from `pmset -g` at launch.

The terminals load your normal Ghostty config, so fonts, colours and padding match Ghostty.

## Self test

```bash
scripts/selftest.sh
```

It checks transcript parsing for both agents, path detection and link routing, agent detection, a live libghostty surface (output, title, typing, Cmd-click, drop, exit) and the reader page (KaTeX, highlighting, inline images, scroll behaviour). It never calls `pmset`.

## How it's built

- SwiftPM app, AppKit with SwiftUI for the chrome, macOS 26 or later, dark only.
- `vendor/GhosttyKit.xcframework` is libghostty built from the official source by `scripts/build-libghostty.sh`. One patch (`patches/`) makes Ghostty compile its Metal shaders at runtime, because Xcode 26 doesn't include the Metal Toolchain that its build expects.
- The reader and code viewer are local web pages in `Resources/web/`, with markdown-it, KaTeX and highlight.js bundled. Nothing loads from the network.
- The app icon is a placeholder made with Codex (GPT Astra image generation). The source and prompt are in `Resources/icon/`.

## Not done yet

- The iOS app.
- Light mode.
- Signing with a real identity and notarization. It's signed ad hoc.
- Drag and drop, the hover agent list, the needs-you dot and keep awake haven't been tried by hand yet. The self test covers the pieces underneath them.
