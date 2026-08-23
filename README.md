<div align="center">

# 🎓 StudyBar

**A free, open-source menu-bar study companion for macOS.**

Your whole study life one click away — assignments, notes, flashcards, focus timers,
schedule, citations, and an AI that *organizes* (never does your homework).
Local-first: no account, no paywall, no cloud required.

Native SwiftUI · macOS 14+ · single `.app` · MIT licensed

</div>

---

## Install

### Homebrew (recommended — no Gatekeeper warning)

```bash
brew install --cask hqn07/studybar/studybar
```

### Download

Grab `StudyBar-1.0.0.dmg` from the [latest release](https://github.com/hqn07/studybar/releases/latest),
open it, and drag **StudyBar** to Applications.

> The app is **not** notarized with an Apple Developer ID (that costs $99/yr — this is
> a free project). So on first launch macOS may warn it "can't be checked". To open it:
> **right-click the app → Open**, or run once:
> ```bash
> xattr -dr com.apple.quarantine /Applications/StudyBar.app
> ```
> The Homebrew install above handles this for you automatically.

### Build from source

```bash
brew install xcodegen        # one-time
git clone https://github.com/hqn07/studybar.git && cd studybar
./scripts/run.sh             # build + install to /Applications + launch
```

Look for the graduation-cap in your menu bar. **Left-click** for the popover,
**right-click** for a quick menu, or press **⌘O** for a resizable window.

---

## What's inside

48 modules across study, capture, focus, schedule, research and organization —
everything hangs off your **Courses**.

- **Overview** — Today dashboard (streak, due-today, next class, quick-add) · Insights (7-day chart, time by course) · **AI Assistant**.
- **Assignments** — tracker, due badge + countdown, checklists, recurring, notifications with Complete/Snooze, AI urgency ranking.
- **Capture** — Notes (Markdown, screenshot-to-note) · Scratchpad · **Voice Note** (on-device transcription) · Clipboard history · Snippets.
- **Time & Focus** — Pomodoro (course-linked, cycles) · Stopwatch · Focus (hide apps + ambient noise) · Sessions.
- **Schedule** — weekly class schedule · unified Calendar (EventKit + iCal feeds + assignments).
- **Links & Resources** — Quick Links · Reading List · Files (PDF search) · **News** (RSS/Atom reader).
- **Research** — Citations (Crossref/DOI, APA/MLA/Chicago/BibTeX) · Word Count · Dictionary · **Lookup** (Wikipedia + arXiv + DOI→open-access PDF).
- **Study** — Flashcards (SM-2, cloze, retention %) · Reading tracker (ISBN covers, chapters, highlights).
- **Organize** — To-Do · Kanban Board · Semester (GPA) · **Grade Calc** (what-if) · Courses.

### The AI Assistant

An assistant that **organizes your study data — it does not tutor.** It turns plain
English into StudyBar actions (rank assignments by urgency, plan focus sessions, make
flashcards from your own notes, triage a pasted syllabus). Every action is confirmed
before it's applied. Runs on:

- **On-device** (Apple Foundation Models, macOS 26+) — free, private, offline. Default.
- **Ollama** — free local models, any Mac. No key.
- **Claude or ChatGPT** — bring your own developer API key (stored in the Keychain).

### System integration

Global hotkeys · floating command palette · quick-capture panel · `studybar://` URL
scheme · Services menu · Shortcuts.app actions · Reminders push · Canvas LMS sync ·
Spotlight indexing · Focus/DND automation · daily backups · optional iCloud Drive sync.

---

## Privacy

Local-first by design. Your data is a single JSON file on your Mac
(`~/Library/Application Support/StudyBar/data.json`, or iCloud Drive if you enable sync).
No telemetry, no analytics, no account.

Network is used **only** for features you opt into: Canvas sync, the Lookup/News feeds,
auto-fetching book covers and link titles, and cloud AI **if** you choose Claude/ChatGPT.
The on-device and Ollama AI engines send nothing off your Mac.

---

## Architecture

- `Core/` — data models, JSON store, engines & services (Pomodoro, AI, Canvas, RSS, Spotlight, …), module registry.
- `Shell/` — menu-bar status item, root split view, command palette, shared components.
- `Modules/` — one file per feature. Add a module = a view + a line in `Core/ModuleRegistry.swift`.

The menu-bar popover auto-dismisses on focus loss, so there are **no** sheets/alerts —
editors push inline and confirmations are in-popover overlay cards.

```bash
./scripts/run.sh            # build (Debug) + install + relaunch
./scripts/run.sh release    # optimized
./scripts/package.sh        # dist/StudyBar-x.y.z.dmg + Homebrew cask
```

---

## License

[MIT](LICENSE) © 2026 hqn07. Free to use, modify and share.
