# Changelog

All notable changes to StudyBar. Format follows [Keep a Changelog](https://keepachangelog.com);
this project uses [semantic versioning](https://semver.org).

## [Unreleased]

- **Time blocking** — a new day-timeline module (Schedule & Calendar): plan *when* you'll do your work. Your classes show as faint context bands so you plan around them; drag a planned block to reschedule it or drag its bottom edge to resize, snapped to 15 minutes. A "Plan" strip lists your open assignments and to-dos — drag one onto the timeline to drop it at a precise time (or tap to drop it at the next free hour); the block links back to the item and carries its course. Deletes are undoable and land in Trash, and blocks sync with the same conflict-safe 3-way merge as everything else.

## [1.5.0] — 2026-08-26

- **Resizable window** — StudyBar is now a full windowed app with the menu bar as a quick-glance companion. The popover shows Today plus a module launcher; open the window (click the app icon, or pick a module) for the full workspace. It remembers your last module and titles itself for the current one, and you can add a Dock icon in Settings ▸ General ▸ Window.
- **Settings redesigned** — a vertical, grouped sidebar; Appearance now has accent presets, a Light / Dark / Device toggle, and density, with the status colors kept fixed.
- **Assistant replies stream** — local (Ollama) answers type out live instead of appearing all at once.
- **Assistant sees your whole study life** — it can now read your study time (today, this week, by course), a full per-course rollup, term progress, snippets and scratchpad, and its always-on context carries your effort, projected GPA and term week — so it plans from the real picture.
- **Smarter "Plan my day"** — prioritizes by risk (overdue first, then soonest), weighted toward courses where your grade is lower or you've studied less this week, and the urgency ranking factors the same signals.
- **Course pages pull everything together** — a course now shows its time logged and grade breakdown alongside its assignments, classes, reading, notes and links, with a Focus button that logs a session straight back to the course.
- **Never-lose-data saves** — when the same file was edited on two devices, StudyBar now does a true 3-way merge so edits from both sides survive, instead of keeping one and setting the other aside.
- **Calendar sources** — hover any event to see where it came from (macOS Calendar, a subscribed feed, an assignment, or a class).
- **Fixes** — clicking the menu bar shows only the popover, not the window; switching the theme to Device follows the system immediately; the popover is opaque (no desktop showing through); clicking the app icon opens the window.

## [1.4.0] — 2026-08-26

- **Courses redesign** — a term hub: GPA hero, grade-ring cards (live grade from your components), and collapsible past-term shelves with per-term GPA. Archive a term and add past courses.
- **Canvas classification** — imported assignments auto-create their courses from the feed's course codes; a Classify page groups the rest so you can verify and assign in a tap.
- **Minimizable sidebar** — collapse it to an icon rail (⌘\\ or the chevron); auto-rails in the compact popover.
- **Data safety** — conflict-safe saves: StudyBar reloads external changes on activation and never overwrites a newer file (keeps a conflict copy). Fixes a case where data could be clobbered.
- **Time & Focus** redesigned around a shared tick-dial clock hero (Timer, Stopwatch, Focus); live-session banner across tabs; session-complete toast; tidier Focus setup.
- **Natural-language quick-add** — typing "essay due friday for chem" on Today or in the Quick Task panel creates a real assignment with course + due date, offline.
- **Projected GPA** — Grade Calc rolls each course's graded components into a credit-weighted GPA.
- **Undo** — one-level undo (⌘Z) with a toast for deletes; restore from a timestamped backup; erase-all is now undoable too.
- **Notes undo/redo** — fixed (the menu-bar app had no Edit menu); toolbar buttons + ⌘Z/⌘⇧Z.

## [1.3.0] — 2026-08-25

- **Today & Insights** dashboards reworked — next-up hero, sparkline stat tiles, gridded 7-day chart with a weekly-average line, flashcard-retention section, and a weekly AI review.
- **Canvas import without an API token** — subscribe your Canvas Calendar Feed (.ics) and assignments import with due dates, auto-refresh, and de-duplication; a guided "Connect Canvas" flow.
- **Anki flashcard interop** — import `.apkg` decks and Anki/CSV text (cloze + HTML handled), export decks back to Anki.
- **FSRS-4.5 spaced repetition** replaces SM-2 for better-timed reviews.
- **Smart menu-bar title** — shows the most relevant thing (focus countdown, next class, or due count).

## [1.2.0] — 2026-08-25

- "Quiet Study Desk" design system applied across every module.
- In-place inline LaTeX in Notes, a live split preview, and a new Equation playground.

## [1.1.0] — 2026-08-24

- Notes rich-text editor (RTFD, fold chips, highlight-to-define, Writing Tools).
- System-wide LaTeX (bundled KaTeX, offline).
- Flashcards: tap-to-cloze and an editable flip composer.
- Snippets categories, Files groups, Dictionary reformat, AI reliability fixes.

## [1.0.0] — 2026-08-23

- First public release: 48 modules, local-first, an organize-don't-tutor AI assistant, distributed as an unsigned `.dmg` + Homebrew tap.
