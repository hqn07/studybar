# Changelog

All notable changes to StudyBar. Format follows [Keep a Changelog](https://keepachangelog.com);
this project uses [semantic versioning](https://semver.org).

## [Unreleased]

- **Read your textbook in StudyBar** — a book with its PDF attached gets *Read*: the PDF opens in Reading at your page and keeps your place, so the chat beside it (⌘J) always knows the page you're on. Select text and *Highlight* (⇧⌘H) saves it to the book's highlights with its page — ready to become flashcards.

- **A glossary of each course** — Study's new Glossary tab lists every term in the course with its definition, gathered from your notes (`term :: definition` lines, and the bold term-and-definition lines study notes are written in) and your flashcards, A to Z and searchable. *Make flashcards* adds the terms that don't have a card yet.

- **What your syllabus covers, and what you haven't** — Study ▸ Progress now opens with the course's syllabus coverage: each learning objective with the notes, flashcards and quiz answers you have on it, and the gaps marked. StudyBar reads the syllabus once for its objectives; after that the map keeps up by itself as you study. Each gap has its own *Quiz me*.

- **The tutor sees the page** — with ChatGPT or Claude, the tutor now looks at the actual slides and textbook pages its answer comes from, so graphs, diagrams and typeset equations count — not only the words on them. Each answer lists the pages it was shown.

- **Answers your way** — Settings ▸ Intelligence ▸ Answers: short or detailed, pitched at your level, and in the language you choose. It applies to the tutor, Ask this note and the assistant; rewriting and proofreading keep your note's own language.

- **Essay help** — a note's AI menu has a new Essay section: outline an essay from your topic or thesis, get feedback on the thesis (with two stronger versions), see the strongest counter-arguments, or draft a paragraph from your notes. A draft cites only sources from your Citations library and marks the rest *[source needed]* — it never makes one up. *Insert ▸ Citation* puts (Author, Year) where you're typing and adds the full reference under References.

- **Bring your library in, and take it out** — Citations imports BibTeX, RIS and CSL-JSON files from Zotero, Mendeley, EndNote or Google Scholar (or paste them into the search field), skipping ones you already have. *Copy all as* gives you BibTeX, RIS, CSL-JSON or a formatted bibliography. In-text citations now read (Smith & Jones, 2020) and (Smith et al., 2020).

- **Web pages, saved clean** — Convert ▸ *Add web page* (or drop a link from Safari) keeps just the article — no menus, ads or footers, with its pictures and equations — and turns it into a PDF, Markdown or a Word file in Downloads, or *Save as note*.

- **Markdown that opens anywhere** — Export as Markdown now keeps a note's pictures (in an `assets` folder beside it), its headings, lists, tables and [[links]], and its tags. Settings ▸ Data ▸ *Export notes as Markdown* writes every note at once, a folder per course — ready for Obsidian, Bear or Notion.

- **More from Canvas** — sync now brings each course's slides, PDFs and documents into Study as sources the tutor, quizzes and study guides read (up to 25 a sync; it can be turned off), and shows the last month's announcements on the course page.

- **Fixed: correct arithmetic marked wrong** — the tutor's arithmetic check misread numbers like 47e-6 (as 4 × 7e-6), so a right step in a full solution could be flagged *recheck this step*.

- **Fixed: BibTeX names for organizations** — a reference by an organization exported as if its last word were a surname; it's now kept whole.

## [2.5.0] — 2026-10-01

- **Study reads a whole course** — with ChatGPT, Claude or DeepSeek, a quiz, practice exam or study guide now reads up to 120,000 characters of the course at once — every note, where a 10-question quiz on a large course used to be written from about a quarter of it. The tutor sends as many of the best-matching passages as fit, instead of five. The local model reads what it always did.

- **The tutor can start over** — *New chat* clears the conversation, in Study and in the chat beside your work.

- **Pick the course where you'd look for it** — Study's course menu now heads the Sources column it fills, instead of sitting at the far end of the title row; a course named by its code shows once.

- **A calculator that works the way calculators do** — open brackets close themselves, shown in grey until you press =; `sin 30°`, `sqrt 2` and `ln 5` work without brackets; after =, an operator carries on from the answer; the clear key says C or AC for what it will clear, and Escape clears the line. The = key fills its space, and keys no longer appear twice.

- **Fixed: a slow first launch** — on a Mac with thousands of old backup copies, StudyBar moved them to the Trash before appearing, which took about a minute. It now does that in the background.

- **Check my work** — a new tutor mode: type your working, or attach a photo of it, and the tutor finds the first step that's wrong, says why, and shows that one step done right — then leaves the rest to you. StudyBar's calculator rechecks your arithmetic too, so a slip is flagged even if the AI reads past it.

- **Explain it back** — explain an idea in your own words and the tutor tells you what you got right, what's missing or wrong, scores it out of 10, and asks about the biggest gap.

- **Quiz me** — the tutor asks one question at a time, on the note open beside it (⌘J) or anywhere in the material you've ticked in Study, and marks each answer before the next. Send with nothing typed to skip to the next question. The tutor's modes now sit in two groups — help with a problem, and test yourself.

- **Flashcards inside your notes** — write a line as `term :: definition` and it becomes a flashcard in the course's deck. Change the definition and the card follows, keeping its review schedule; delete the line and the card goes. The note's footer counts its cards.

- **Exam binder** — the notes list's ⋯ menu ▸ *These notes as one PDF* puts every note the list shows (a course, or a search) into one PDF in the order you took them: a contents page with page numbers, each note starting on a new page, and bookmarks for every note and heading.

- **Export a note to Word** — Export as Word keeps the note's pictures and equations, which Rich Text export drops. Convert's Word output now keeps them too.

- **What the AI costs you** — Settings ▸ Intelligence shows this month's requests, tokens and an estimated cost for each ChatGPT, Claude or DeepSeek model you've used, plus last month's total.

- **Fixed: a line cut in half between PDF pages** — when a paragraph ran longer than a page, from the second page on the page break went through a line of text: the top of it showed at the foot of the page and the line was printed again on the next.

- **Fixed: Settings described an old rule** — Intelligence ▸ Boundaries still said StudyBar refuses to help with work you'd hand in, a rule removed in 2.4.0.

- **Cheat sheets** — the PDF export window's new Layout setting turns any note, or Study's guide (it has a *Cheat sheet* button), into a one- or two-page sheet: three columns a page, the type shrunk until it all fits, for an exam that allows a page of notes. It says what size the type came out at, or that it won't fit.

- **The tutor knows your weak topics** — the topics you score lowest on in Progress now go with every question to the tutor, which takes extra care with them, and with every new quiz, where about a third of the questions go to them.

- **Share a quiz** — a finished quiz or practice exam has *Share…*: one web page a classmate can open in any browser, take, and have marked, with the answers and why.

- **A summary while you record** — with ChatGPT, Claude or DeepSeek and Apple Speech, Voice writes a few points on what's just been said every few minutes, under *So far*, so a glance catches you up after you look away.

- **Listen to your notes** — the notes list's ⋯ menu ▸ *Audio review* turns the notes on screen into about eight minutes of spoken review in an audio file, for a walk or the bus. It uses your best installed voice; a Premium or Enhanced one (System Settings ▸ Accessibility ▸ Spoken Content) sounds far more natural.

- **Downloads go to their course** — turn on *Offer course files from Downloads* in Settings ▸ Integrations, and a file you download with a course code in its name, like “PHY2049 Lecture 7.pdf”, brings a notification that adds it to that course's Study sources.

- **Flashcards on top** — review cards in a small panel that floats over your other apps: from a deck's ⋯ menu, or the menu-bar menu for every due card.

- **Fill-in answers forgive subscripts** — ε0 now counts for ε₀, and m2 for m², in quizzes and shared quizzes.

- **Slides beside the lecture** — add the lecture's slides in Voice (a PDF or PowerPoint, before or after recording) and *Make study notes* follows them: a section for each slide the lecture talked about, with what was said and what the slide shows. The note then opens with the slides beside it, turned to the slide the part you're in is about. Any note can get its slides from the share menu ▸ *Add the lecture's slides*.

- **Better live transcription** — on macOS 26 and later, Voice's Apple Speech now uses Apple's newer speech engine. On a test lecture it got about a third fewer words wrong — 11% against 17% in a quiet room, 17% against 25% with background noise — and it no longer has to restart every minute. Older Macs keep the previous engine; the first time, macOS downloads the new model in the background and the recording uses the old engine meanwhile.

- **Fixed: spoken audio stopped after a few sentences** — Convert's text → spoken audio cut a long text off at its first pause: 1,500 words came out as a few seconds. It now reads all of it.

## [2.4.5] — 2026-09-30

- **Click a sentence to hear it** — a lecture recorded in StudyBar now keeps every sentence with its moment in the audio. Under the note's recording, **Transcript** lists them with their times; click one and the recording plays from just before it. It lists the recording rather than the note, so it still works after *Make study notes* has rewritten the text.

- **Star the moments that matter** — while recording, ⭐ in the recording bar, the menu-bar menu or a global shortcut marks the moment ("this will be on the exam"). The sentence gets a star in the transcript, with a *Starred only* filter, and *Make study notes* puts it in bold, keeps the ⭐ and makes it a likely exam question.

- **Record what the Mac is playing** — Voice ▸ *Listen to* ▸ *The Mac's sound* records a Zoom or Teams lecture, or a video, without the microphone, and everything else works as it does for the mic: live transcript, Whisper, the saved recording, stars. The first time, macOS asks to let StudyBar record the screen and its audio.

- **A study pack from a lecture's notes** — the note's ✨ AI menu ▸ *Study pack* makes flashcards from the note into the course's deck and writes a 10-question quiz from it, waiting on Study's Quiz tab, with a notification when it's ready. Lecture notes also end with *Questions to ask*: what the lecture left unclear, worth taking to the professor.

- **Progress: how each topic is going** — Study's new Progress tab scores every topic of the course from the quizzes and practice exams you've taken, weakest first, over each topic's last 20 answers, so what you've since learned shows. *Quiz me on the weakest* aims the next quiz at the material behind them. The course's flashcards due, and the ones you keep missing, are there too.

- **Plan review for an exam** — an assignment called an exam, midterm, final, test or quiz gets *Plan review*: review sessions 14, 10, 7, 5 and 3 days out, a timed practice exam two days out and a short last review the day before go on the day planner, each in free time around your classes, with what to do in Study. Planning again replaces the earlier plan; it's one undo.

- **Note history** — the clock on a note shows its earlier versions: one kept every ten minutes while you write, and one right before any big change, like an AI rewrite. Pick one to see, line by line, what restoring it brings back and removes, then restore it — and undo the restore the same way. History is kept on this Mac.

- **Recordings take a fraction of the space** — a lecture is now saved as speech-quality audio at about 11 MB an hour instead of 29–58, so a whole term of lectures fits in about 1.5 GB. A recording whose note you deleted (and emptied from StudyBar's trash) now goes to the Trash instead of staying on disk forever.

- **VoiceOver** — the controls added in 2.4 and here say what they do, the ⌘K list and Shelf items can be used with VoiceOver, and the sidebar opens a module again — VoiceOver announced each row as a button but pressing it did nothing.

- **Fixed: a note's recording player covered its toolbar** — its controls had outgrown their row and drew over the note's header, and the formatting bar while editing.

- **Fixed: flashcards lost their math** — `$\cos\theta$` in a card made by the AI came out as "\cos", a tab and "heta", `\frac` and `\beta` broke the same way, and one `\underline` lost every card in the reply.

## [2.4.0] — 2026-09-30

- **Study — learn a course from its own material** — a new module: pick a course and tick what to study from — its notes, textbook PDFs, syllabus, slides (.pptx), Word files, and photos of handouts (scanned pages are read on-device). Then ask the tutor, take a quiz, sit a timed practice exam scored by topic, or have a study guide written, each answer citing the page it came from. Quiz answers are checked against the material before you see them, missed questions go to a flashcard deck in one click, and a course can be searched by meaning as well as by word.

- **A tutor that teaches and works problems** — Hint, Next step, Full solution or Explain, from a typed question or a photo or screenshot of the problem. A full solution ends with its arithmetic written out, and StudyBar's own calculator recomputes it and flags a step that doesn't add up. The homework restriction is gone: StudyBar helps with the work you're actually doing.

- **Lecture recordings become study notes** — *Make study notes* keeps every detail of the lecture and adds definitions, examples, background and likely exam questions, drawn from your course's textbook and slides. Each addition is marked *💡 Added*, so what the AI wrote never passes for what was said. A lecture of any length is written in parts and joined, so nothing is cut off. *Complete these notes* does the same for notes you typed.

- **Recordings are kept, and the Mac stays awake for them** — the audio is saved with the note and plays above it. The Mac no longer sleeps mid-lecture, ⌘Q asks before ending a recording, and a notification warns once if the battery reaches 15% or the disk has under 1 GB left. Apple Speech adds punctuation and expects your course's own terms. Whisper gains Large v3 Turbo — about 630 MB, close to Large v3 and several times faster — and transcribes lecture videos as well as audio.

- **PDFs that look like the note** — export and print use the same renderer as the reading view, so paper matches the screen. Pages break between blocks: never through a table row or an equation, and never leaving a heading at the foot of a page. A preview shows the pages first, with paper size, margins, text size, a header and page numbers. Styled notes keep their colors, highlights and images, and every heading becomes a bookmark in the PDF's sidebar.

- **Tabs, windows, and the chat beside your work** — open a module or a note in a new tab (⌘T) or window (⌥⌘N), each keeping its own place. ⌥-click a module to open it on the right; ⌘J opens the tutor beside whatever you have open — the note, the book at its page, the assignment — already knowing what it is. **Start** on an assignment opens it with the tutor and a focus timer running.

- **The Shelf** — a small floating box (menu-bar menu ▸ Show Shelf) for files, links, text and images: drop things in, carry them between apps and modules, drag them out. Quick Look and Share included, and it survives restarts.

- **Convert — files into other files, with what macOS has** — Word, RTF, ODT, HTML, text and Markdown to each other and to PDF; Office files to PDF with their exact layout through Pages, Keynote or Numbers; PDFs to Word, text, images or slides, or to a smaller or searchable PDF; merge, split, extract and rotate pages; images, audio and video between formats. From the Convert module, the Shelf, or Finder's right-click ▸ Services ▸ Convert with StudyBar. Slides become study notes, and a note becomes a slide deck.

- **Capture from the screen** — ⌃⌥G, the menu-bar menu or ⌘K, then drag over a Zoom slide, a figure or a problem: copy its text, copy its math as LaTeX (with an engine that reads images), send it to the tutor, or copy the image.

- **Long AI jobs keep going when you leave** — a quiz, exam, study guide or lecture notes being written, and the tutor conversation, survive switching modules. A bar under the window shows what's still running elsewhere, and a notification says when it's done.

- **Smaller things** — unit conversion in ⌘K and the calculator ("3 ft in cm", "72 °F to C"); right-click a selection in a note to have it explained; Paste and Match Style (⌥⇧⌘V); `{course}` and `{week}` in snippets; saved links drop their tracking parameters. Answers from Claude and OpenAI can run to 16,000 tokens instead of 4,096, and Settings picks the model from the provider's own list.

- **Fixed: a backup copy of your data on every save** — StudyBar took its own saves for another device's, so each one copied your data to a `.conflict-*` backup and merged it. One store had collected 2,197 copies, 761 MB of iCloud Drive. Only the newest 10 are kept now; the rest move to the Trash.

## [2.3.0] — 2026-09-14

- **Math — a calculator you can reach without leaving what you're doing** — a new module with a keypad, a tape of past results and a display you can type into, plus variables (`x = 12`), `ans`, and a visible DEG/RAD switch so `sin(30)` means what your course means. Type arithmetic into ⌘K and the answer is the first row; ⌃⌥C summons the same calculator over any app; `studybar://calculator?expr=` lets a Shortcut hand it a number. All four share one history. `0.1 + 0.2` prints `0.3`, `2pi` and `3(4)` work as written on paper, and `1,250` is a number while `max(1,2)` keeps its comma.

- **Graph** — plot several functions at once, drag to pan, pinch to zoom, double-click to reset, and trace every visible curve at the same x. Asymptotes break the line rather than drawing a stroke through them, so `tan(x)` and `1/x` look right. Axes are squared, so a circle is round and the slope you read off the screen is the slope the function has.

- **3D** — `z = f(x, y)` as a lit surface you can spin, coloured by height with a legend, at a resolution and domain you choose. Points where the function has no value stay holes instead of collapsing to the floor, so `sqrt(1 - x² - y²)` is a dome rather than a dome with walls.

- **Slope fields for differential equations** — switch the Graph tab to *Slope field*, type `y' = …`, and see the direction field with arrowheads at a density you set, plus the solution curve through an initial condition you can move. The solver adapts its step to the equation, so one that blows up in finite time draws as a curve running to its asymptote instead of an oscillating scribble.

- **Finance for engineering economy** — the five time-value variables with any one solved for, and the amortization schedule that follows, copyable as a Markdown table that pastes into a note as a real table. A set of numbers with no answer says so rather than returning a plausible wrong one.

- **Lab uncertainty and linear systems** — carry each measurement's uncertainty through your own formula in quadrature, with a bar showing which measurement dominates the total and the result written the way a lab report wants it. And solve `A x = b`, with determinant and inverse, from a grid you type.

- **Fixed: the app stalled while a recording ran** — moving around StudyBar during a lecture recording could freeze for seconds at a time. A check for whether an AI key exists was reading the Keychain from inside the note editor's layout, which blocks; on the first read after any update it blocked for several seconds. Main-thread layout during a recording went from 95% busy to 2%.

- **Fixed: a lecture recording slowed every other module** — the microphone level was published to the whole app about thirty times a second, rebuilding the sidebar, header and whichever module you were in to redraw a strip 44 points wide.

- **Fixed: "Microphone or speech access off" was a dead end** — the screen offered only *Open Privacy Settings*, and granting access changed nothing until you relaunched, because nothing on that screen asked again. It now clears when you return to Voice, and has a **Try again** button.

- **Fixed: AI lists put a label on its own bullet** — a summary that introduced a list wrote `- Sign of work:` as a bullet level with the two points under it. A lead-in is now its own line with its points nested beneath, and indented sub-points render as sub-points everywhere — the reading view, print and export.

- **Fixed: Calendar showed imported coursework twice** — an item that arrived from a subscribed feed and was then tracked as an assignment appeared as two rows, one carrying the `[COURSE]` tag. They are matched by the feed's own identifier now, so two genuinely different events that share a title and a time still both show.

- **Calendar opens with what it already had** — subscribed feeds are fetched together rather than one after another and held briefly, so returning to the module no longer fills the week in piecemeal. Refresh still goes to the network.

## [2.2.0] — 2026-09-09

- **Route AI work by how much it costs to be wrong** — Settings ▸ Intelligence now assigns a stronger engine to the jobs that need accuracy (questions about a note, summaries and rewrites, turning recordings into notes, reading syllabi, spotting duplicates) while sorting and tidying stay on your local model and autocomplete always does. Each is a toggle, and the top of the screen shows which engine answers what.

- **Deep scan for duplicates** — the duplicate finder can now ask your AI engine about near-miss pairs the exact match can't judge: same course, within a week, partly matching titles, including an assignment re-imported under a shifted date. Findings are labelled as the model's opinion and still need your confirmation before anything merges.

- **Sort imported coursework into work, attendance and admin** — a Canvas feed arrives as one flat list where `L7 section 2.4` sits next to `SEPTEMBER 10 ATTENDANCE`. The new **⧉ Sort by kind** button in Assignments settles the obvious cases itself and asks your AI engine about the rest, then shows you everything before applying. Once sorted, This week and Overdue hide the housekeeping — one click brings it back, and nothing is ever deleted.

- **Insights counts what you actually did** — the module led with Pomodoro time and reading pace, which stay at zero unless you use those features, so a week of real work looked like a week of nothing. It now opens with assignments finished, a completion streak, and notes written; study-time and reading sections appear only once there's something in them. Finishing an assignment records *when*, so "this week" means this week rather than everything ever.

## [2.1.0] — 2026-09-09

- **Edits from a second device stop being dropped** — when the same assignment, course, class, to-do, deck, snippet, link, grade row or file group is changed in two places, the newer change now wins. Previously the comparison used the record's creation date, which is identical on both copies, so whichever device saved last kept its own version and the other edit survived only in a backup file.

- **Autocomplete holds the model for two minutes, not five** — the local model now stays warm across pauses in a writing session and hands its ~4.7 GB back shortly after you stop, instead of inheriting Ollama's default five-minute window.
- **Autocomplete no longer depends on the assistant's engine** — grey suggestions while typing always run on your local Ollama model, so pointing the assistant at DeepSeek or Claude doesn't silently switch them off. Settings ▸ Intelligence ▸ Smart typing names the model it uses and can check that it's actually running.

- **Quotations are checked against your notes** — if an answer puts words in quotation marks that aren't in the note it was given, the marks come off and the answer says so. The sentence stays; the claim that you wrote it doesn't.
- **Hosted engines stream too** — an answer from DeepSeek, OpenAI or any compatible provider now types itself out as it arrives instead of sitting on "Thinking…" for twenty seconds. Reasoning models' internal deliberation is not shown.

- **Homework requests are refused by StudyBar, not by the model** — asking Ask this note to write something you'd hand in ("write my homework answer exactly as I should submit it") is now stopped before any model is called, with a one-tap **Explain the method instead**. Asking how something works, or what your note says, is untouched.

- **Use any OpenAI-compatible provider** — Settings ▸ Intelligence ▸ ChatGPT now has an **API base URL** field, so the same engine can point at DeepSeek, Alibaba's Qwen, Together, Groq, Fireworks or OpenRouter with their own key and model name. Leave it alone for OpenAI itself.
- **A different engine for asking questions** — *Ask this note* can run on its own engine, separate from everything else: a paid model for questions that need reasoning, your local one for organizing, summarizing and extracting. Settings ▸ Intelligence ▸ Asking questions about a note.

- **Ask this note — with the weeks you choose** — while reading a lecture note, ask a question about it, and attach earlier notes as context (Add notes → this course first, or add the whole course in one click). The panel shows how many notes are attached and roughly how much of the model's context they fill, and answers say which note each piece came from. Answers use the notes where they cover the ground and go past them where they don't, so a note on one plant can still answer a question about another. Follow-ups keep the thread, answers render Markdown and math, and you can insert one under its question or copy it. StudyBar still won't write what you'd hand in.

- **Recordings only discard silence once the detector is sure** — a stretch judged to contain no speech is skipped rather than transcribed, but never before the recorder has recognized speech at least once in that recording, and never for more than a few stretches in a row. If the room fools it, you get an odd stray line in the transcript instead of a missing minute.

## [2.0.0] — 2026-09-08

- **Fixed: Export as Rich Text saved an empty file** — exporting (or printing) a note you had opened to *read* rather than edit produced a file with nothing in it, silently. Exports now come from the note itself rather than the editor window, so they work from either view.
- **Send a note as a PDF** — **Export as PDF** writes the note the way the reading view shows it: headings, bullets, tables and equations rendered, not their Markdown and LaTeX source. That is the version to hand a classmate. Print produces the same document.
- **Tables render** — a Markdown table in a note (the ones AI summaries like to produce) now draws as a table in the reading view and in print, instead of a wall of pipe characters.
- **Cleaner lecture transcripts** — the recorder now learns how loud your room actually is instead of using one fixed loudness cut-off, so it splits recordings at real pauses whether you're close to the mic or at the back of a hall. Stretches where nobody is talking are no longer sent to be transcribed at all, which is what used to sprinkle stray "Thank you." and "you" through a long lecture. Pauses are also judged over a slightly longer gap, so splits land between sentences rather than between words.
- **Notes group by week inside a course** — pick a course tab and the notes are sectioned by the week of the term they were written in (Week 3, Week 2, …), which is how lecture notes are actually kept. The All tab keeps the Today / This week / Earlier grouping.
- **New notes start with the week** — a new note in a course opens titled "Week 3 — ", so the part you retype every session is already there. Leave it untouched and the note is still discarded as blank.
- **Assignments open on this week** — the list now scopes to what's due in the next seven days, is overdue, or has no date, with **Overdue** and **All** one click away. A term of imported coursework is a few hundred rows; that isn't a list anyone works from.
- **Archive assignments you're never going to do** — imported items more than a week past due can be archived in one click (undoable). Archived work disappears from the list, the board, Today, notifications and the menu-bar count, but is kept and can be restored from the **Archived** tab or a row's context menu.
- **Fixed: Spotlight showed note markup** — note results in Spotlight used the raw body, so headings, bullet markers and LaTeX delimiters showed up in the preview line. They now use the same cleaned text the notes list does.
- **Fixed: AI-written math showed as raw LaTeX** — notes organized by AI (and anything pasted from a model, Wikipedia or Overleaf) used `\(…\)` and `\[…\]`, which StudyBar rendered as plain text instead of equations. Both styles now render, in the reading view and in list previews, and AI output is converted to StudyBar's `$…$` on arrival so it renders in the editor too. Existing notes are fixed on sight — nothing was rewritten on disk.

## [1.9.0] — 2026-09-03

- **Notes open to read, not just edit** — opening an existing note now shows it rendered (Markdown + math) in a clean reading view; click the page to edit. New notes still open ready to type. The reading view puts the title at the top and sets the text in a comfortable column.
- **A clearer Notes list** — each note now shows a course-color edge, when it was last edited and its length, and the list groups into **Pinned**, then **Today / This week / Earlier**. Row previews no longer leak raw Markdown symbols, and an empty note reads as "empty" instead of "No content".
- **Undo & redo buttons in Notes** — plus tag autocomplete that suggests tags you've already used, so you don't end up with three spellings of the same one.
- **Fixed: a deleted note could reappear** — a note deleted right after editing could come back once (needing a second delete) when syncing through iCloud. Deletes are now honored on the first try, and the note is still recoverable from Trash.
- **Plan any day from the schedule** — tap a day in the Week view to get AI-suggested study blocks for that date, the same way *Plan my day* works for today.
- **Paste a schedule to import classes** — paste a copied timetable, a registrar schedule or an email and StudyBar pulls out your weekly classes for review — like the .ics import, but from plain text. Imported classes auto-match an existing course by its code.
- **Your calendar on the day planner** — events from macOS Calendar now appear alongside your classes and study blocks (read-only, and only if you've already granted Calendar access), so you plan around real commitments.
- **A weekly study goal** — set a target number of hours per week and track it with a ring on Today and in Insights.
- **Wrap up your day** — when a planned study block's time has passed, Today offers to check it off or roll it to tomorrow.
- **Easier bug reports** — Settings ▸ Diagnostics can now email a privacy-safe report in one tap.

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
