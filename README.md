<p align="center">
  <img src="Resources/icon/source-1024.png" width="128" alt="hantuu icon">
</p>

# hantuu

hantuu is a native Mac app for running coding agents like Claude Code and Codex. Every chat is a real terminal powered by Ghostty, and next to it sits a reader that turns the conversation into something easy to read, with images, PDFs and LaTeX rendered properly.

The name comes from "hantu", the Malay word for ghost, made a little cuter the same way Ghostty did with "ghost".

![A Claude Code chat on the left and the reader on the right, showing an inline image and a rendered formula](docs/screenshots/chat-and-reader.jpg)

## Why I built this

I use coding agents like Claude Code and Codex for my own projects, and I also use Claude to study. A few things kept getting in my way.

- Terminal chats are hard to read. When the agent points at an image or a PDF, all I see is a file path, and maths shows up as raw LaTeX. That's fine for code, but it gets painful when I'm studying for an exam and having Claude teach me.
- Once I have a few agents going across different projects, they end up spread over a pile of terminal tabs, and it's hard to keep track of them all.
- Starting a chat meant opening a terminal, going to the right folder and launching the agent myself, every single time.
- I wanted agents to keep working after I close my MacBook's lid.

I also wanted it to feel like a proper Mac app. hantuu is written in Swift and built on Ghostty, the terminal I already use, so each agent's own interface works exactly the way it does there.

## What it does

### All your agents in one sidebar

Add a project folder and its chats show up underneath it. Each chat has a small dot that tells you whether the agent is running, needs you, or has ended, and it takes its name from the title the agent gives it. Chats keep running in the background when you switch between them, and Cmd-1 to Cmd-9 jump straight to one. Ended chats stay in the list after you quit, and Resume picks the conversation back up.

### New chat opens straight into your agent

Cmd-N opens your default agent in the selected project, so you're talking to it right away. Hover the new chat button to pick a different agent. hantuu finds the agents you have installed through your login shell, so they run with the same setup they have in your normal terminal. It never adds flags that skip an agent's permission prompts.

### A reader for the chat

Open the right panel and the Reader follows the conversation as it happens. Your prompts and the agent's answers read like a normal document. Tool calls fold down to one line each and the agent's thinking is hidden, but permission requests, errors and questions to you always stay visible.

Images and PDFs that come up in the chat appear inline instead of as paths. LaTeX is rendered with KaTeX and code blocks are highlighted, which is what makes it usable for studying.

### File links that open somewhere useful

Every file path in the chat becomes a link. Text and code files open in the Code tab with syntax highlighting and line numbers, and Markdown files also get a rendered preview. Anything else, like a PDF, is shown in Finder so you can open it with the app you normally use. Cmd-click works on links in the terminal too.

![A Markdown file opened from a link in the chat, shown as a rendered preview with formulas](docs/screenshots/markdown-preview.jpg)

### Terminals right next to the chat

The Terminal tab holds as many plain shells as you want, already open in the project folder. Dropping a file onto a chat or a shell types in its path, which is the quickest way to hand the agent a screenshot or a PDF.

### Keep your Mac awake

One switch at the bottom of the sidebar keeps your Mac running even with the lid shut, so long agent runs don't stop when you close it. It uses macOS's own `pmset disablesleep` setting, asks for your password through the normal system prompt, and shows the real state even if you change it somewhere else.

### Feels like part of your Mac

hantuu is dark and minimal, and it uses native Mac controls throughout. The terminals load your own Ghostty config, so your font, colours and padding carry over without any setup.

## Get started

You'll need:

- A Mac with Apple silicon on macOS 26 or later
- Xcode 26
- About 2.5 GB of free space for the Ghostty build
- At least one agent installed, like [Claude Code](https://docs.claude.com/en/docs/claude-code) or [Codex](https://github.com/openai/codex)

Clone the repo and build Ghostty's terminal library. This downloads Zig and the Ghostty 1.4.0 source into `vendor/` and takes a few minutes the first time.

```bash
git clone https://github.com/weilun1910/hantuu.git
cd hantuu
scripts/build-libghostty.sh
```

Then build and open the app:

```bash
scripts/run.sh
```

After that, `build/hantuu.app` opens from Finder like any other app. Your projects and chats are saved in `~/Library/Application Support/hantuu/`. To try things without touching them, point it at a scratch folder:

```bash
scripts/run.sh --data-dir "$PWD/tmp/appdata"
```

### Shortcuts

| Shortcut | What it does |
| --- | --- |
| Cmd-N | New chat with your default agent |
| Shift-Cmd-O | Add a project folder |
| Cmd-1 to Cmd-9 | Jump to a chat |
| Option-Cmd-0 | Show or hide the right panel |
| Option-Cmd-1, 2, 3 | Terminal, Code or Reader tab |
| Cmd-T | New shell tab |
| Cmd-O | Open a file in the Code tab |
| Cmd-0 | Show or hide the sidebar |

## How it works

- The app is written in Swift, with AppKit for the window and SwiftUI for the sidebar and panels.
- The terminals are libghostty, built from the official Ghostty 1.4.0 source by `scripts/build-libghostty.sh`. One small patch in `patches/` compiles Ghostty's Metal shaders when the app starts, because Xcode 26 doesn't include the Metal toolchain that Ghostty's build expects.
- The reader reads the transcript files the agents already write, in `~/.claude/projects/` for Claude Code and `~/.codex/sessions/` for Codex. It only ever reads them.
- The reader and code viewer are local web pages bundled with markdown-it, KaTeX and highlight.js, so nothing loads from the internet.
- `scripts/selftest.sh` runs 77 checks covering transcript parsing, link handling, a live Ghostty terminal and the reader page.

## Status

This is v1, the first version I built to try out the idea, so expect some rough edges. A companion iOS app for checking on chats from my phone is planned once the desktop app settles. Light mode and a signed, notarized download aren't there yet.

## License

hantuu is released under the [MIT License](LICENSE).

## Credits

hantuu is built on [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and the Ghostty contributors. The terminal hosting code is adapted from Ghostty's own macOS app. Licenses for Ghostty and the bundled libraries are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The icon is a placeholder generated with Codex.
