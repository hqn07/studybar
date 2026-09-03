# Changelog

All notable changes to StudyBar. Format follows [Keep a Changelog](https://keepachangelog.com);
this project uses [semantic versioning](https://semver.org).

## [Unreleased]

## [1.8.6] — 2026-09-03

- **Syllabus, attached to the course** — open a course and **Attach syllabus**: the file is kept and re-openable, and **Extract details with AI** pulls out the grading breakdown, key dates, policies, office hours and textbooks. Review every extracted date in a checkable list (uncheck any that look wrong) before **Apply** — grade rows fill your Grade section and the checked, dated items become assignments. There's a **Dates only (faster)** mode when you just want the whole semester's due dates.
- **Exam markers on the schedule** — an exam due in the week you're viewing now shows as a red banner at the top of its day's column, not just a small dot, so the high-stakes items are unmissable.
- **Find duplicate assignments** — a new button in Assignments groups likely duplicates (the same task imported from two sources with different names) by course, due date and similar title. Pick which to keep; merging the rest is undoable.

## [1.8.5] — 2026-09-02

- **Diagnostics panel** — a new **Settings ▸ Diagnostics** tab: health checks (data, mic and speech permissions, Whisper models, Ollama, disk), an environment summary, a filterable log of recent technical events, and detection of an unexpected quit. One tap copies or saves a **redacted** report to send with a bug report — it never includes your note text or transcripts.
- **Voice: reliable live streaming** — with Whisper, the transcript now streams steadily while you record. Fixed chunks that occasionally came back blank, the first seconds being dropped while the model loaded, and tuned the chunk size so the text stays close to live (smaller/faster models stream almost instantly).

## [1.8.4] — 2026-09-02

- **Schedule shows your deadlines** — the Week view now marks each day with dots for what's due that week (red for exams and quizzes), and the day planner draws a line at each assignment's due time, so you can plan around them instead of holding them in your head.
- **A real, navigable week** — page through weeks with ‹ › (and a **This week** button); each column shows its date, and the deadline dots and planned-block count follow the week you're viewing.
- **Online classes** — mark a class **Online**: if it meets at a set time it stays on the grid with a video badge, and if it's asynchronous (no set time) it moves to an **Online** strip above the grid with a one-tap link. The editor lets an online class be saved with no meeting days.
- **Import your class schedule** — **Import from .ics…** turns a registrar or Canvas calendar export into your weekly classes (it understands recurring MWF-style meetings), with a review step to pick a course for each.
- **Lands on the current time** — both Schedule views now scroll to *now* when you open them, and class blocks are readable with VoiceOver.
- **Voice: transcribe as you record** — with Whisper, long recordings now transcribe in the background *while you talk*, so the text appears live and stopping finishes almost instantly — no more waiting for a whole lecture to process at the end.
- **Voice: no more re-download nag** — a Whisper model you've already downloaded is remembered across launches, so it no longer asks you to download it again every time.
- **Notes: tolerant math** — LaTeX with a small delimiter typo now renders instead of showing raw red source.

## [1.8.3] — 2026-09-02

- **Turn book highlights into flashcards** — on a book's **Highlights** tab, one tap on **Make flashcards** drafts a study card from each highlight (a question and answer when an AI engine is set up, a fill-in-the-blank otherwise). Review and edit the drafts inline, then accept the ones you want — they land in a deck named after the book and start spaced repetition.
- **Plan my day, on Today** — a new **Plan my day** button ranks what's due and proposes a short, ordered set of study blocks with a suggested length and a reason for each. Accept the ones you like and they drop onto today's plan.
- **Time & Focus, redesigned** — the four tabs collapse into one place: pick **Pomodoro**, **Timer**, or **Stopwatch**, set what you're working on and your options once, and start. Session history moves behind a button, and the ambient-noise bar is always there.
- **Fixed the Today hero showing a stray `{}`** — the one-line nudge on Today now always reads as a sentence, whichever AI engine you use.

## [1.8.2] — 2026-09-02

- **Send feedback, right from the app** — Settings ▸ About now has a one-tap **Send feedback by email**, plus links to report a bug or start a discussion. Email is the fastest way to reach the maintainer.
- **Removed the Density setting** — it only ever nudged the header and made no real difference in the app, so it's gone rather than pretending to do something.

## [1.8.1] — 2026-09-02

- **Notes toolbar, decluttered** — the formatting bar is now one tidy row instead of a long strip that scrolled tools off-screen. Common actions stay inline (bold/italic/underline/strike, bullet/numbered/checklist); the rest live in **Style ▾**, **Insert ▾** (table, image, equation, code, quote, divider, collapse, define), and a single **colour** menu. Undo/redo dropped from the bar (⌘Z / ⌘⇧Z still work).
- **Notes appearance, one click away** — a new **Aa** menu in the toolbar lets you change your notes' font, size, and line spacing right where you're writing (it applies live), instead of digging through Settings. And **Style ▾** now shows a checkmark on the heading level your cursor is in.
- **Release notes in the app** — Settings ▸ About now has a **Release Notes** section, so you can read what changed in each version without leaving StudyBar.
- **Safer deletes** — deleting a course, grade component, highlight, chapter, citation, or feed is now **undoable** and lands in **Recently Deleted**, like the rest of the app — no more silently-permanent removals.

## [1.8.0] — 2026-09-02

- **Ask your textbook** — attach a PDF to a book and StudyBar extracts its text on your Mac, so you can **search inside the book** and **ask questions answered from the actual pages** — with page citations you can trust, and **follow-up questions** that keep their thread. Only the handful of relevant pages are ever sent to the model (never the whole book), so it works within a local model's limits. Scanned PDFs are read with on-device **OCR**. Nothing leaves your Mac. Equations in answers render as real math.
- **AI, woven into the app — not a place you visit.** A **✨ menu on any text** (notes, assignments, reading, flashcards, and more) summarizes, rewrites, proofreads, or continues right where you're working — you **accept or discard**, and the original is kept. Assignments can **break into a checklist** of steps; the assistant for cross-note jobs is now a **summoned ⌘K command bar** rather than a sidebar you navigate to. Optional, off-by-default **suggestion chips** offer help (like "Summarize?") only when you turn them on.
- **A stronger local brain** — StudyBar now recommends **qwen2.5**, which follows formatting and math far better than the old default, and it tells you how to switch. Models **unload quickly after use** to keep your RAM free. If your Mac has Apple Intelligence, the on-device engine works with no download at all.
- **Reading, refreshed** — a compact book header (slim progress, chips) and **Overview / Highlights / Ask AI** tabs, so the page is calmer and the Q&A has its own home.
- **Voice notes, more reliable** — long dictation no longer loses a paragraph when Apple Speech resets; a silent mic is now surfaced clearly instead of failing quietly; Whisper transcribes with a visible progress state; and your raw transcript autosaves as you speak, recoverable if something interrupts you.
- **Open Source** — a new Settings tab crediting every open-source library StudyBar is built on, with versions and licenses.

## [1.6.0] — 2026-08-28

- **Notes, rebuilt** — the biggest upgrade to the app's most-used surface. Type Markdown and it formats in place (`#` headings, `-`/`*` bullets, `1.` numbered, `[]` checklists, `>` quotes, `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `---` divider), or use the toolbar / a **`/` slash menu** to insert any block. New blocks: **checklists** (tap the box), **code blocks**, and real **tables** (right-click to add or delete rows and columns, Tab to grow). **Equations** get a button with a symbol palette — no LaTeX knowledge needed — and math now renders natively everywhere (matching the editor), so a formula looks the same in the note, the preview and flashcards. In the window, Notes is a **two-pane workspace** (list + editor side by side), and notes can **link to each other** with `[[wikilinks]]` + a "Linked from" backlinks bar. Also: an **outline** jump-list, **focus mode**, **study templates** (Lecture / Cornell / Reading), **export** to Markdown or Rich Text, print and duplicate, an **equation/image drag-and-drop** (drop a macOS screenshot straight in — or paste it), and readable **typography settings** (font, size, line spacing) with larger, roomier defaults.
- **Smart typing (opt-in)** — with a local Ollama engine, Notes suggests the next few words as you type, shown in grey inline; press Tab to accept, keep typing to accept along. Turn it on in Settings ▸ Intelligence ▸ Smart typing; a small indicator shows when it's thinking. Runs entirely on your Mac and finishes your phrasing, never your homework.
- **Time blocking** — a new day-timeline module (Schedule & Calendar): plan *when* you'll do your work. Your classes show as faint context bands so you plan around them; drag a planned block to reschedule it or drag its edge to resize, snapped to 15 minutes; drag on an empty slot to create one. A "Plan" strip lists your open assignments and to-dos — drag one onto the timeline (or tap to drop it at the next free hour); the block links back to the item, and a Focus button starts a session logged to its course. Undoable, in Trash, and conflict-safe like everything else.
- **Schedule, redesigned** — a real weekly timetable instead of a day-by-day list. Weekday columns (Mon–Fri, plus Sat/Sun when used) over a time ruler, each class a block spanning its actual length; today's column highlighted with a live now-line. **A class can now meet on several days** — MWF is one class, not three — with a day picker, a "merge duplicate classes" action, and an opt-in **UF class-periods** mode (period grid 1–11 / E1–E3, enter a class by period).
- **Fixes** — deleting a note now sticks (it no longer reappears); tables survive save-and-reopen; formatting inside a heading keeps the heading; `$5 and $10` isn't mistaken for math.

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
