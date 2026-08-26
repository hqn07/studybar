# Changelog

All notable changes to StudyBar. Format follows [Keep a Changelog](https://keepachangelog.com);
this project uses [semantic versioning](https://semver.org).

## [Unreleased]

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
