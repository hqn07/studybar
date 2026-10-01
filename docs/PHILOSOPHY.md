# StudyBar — Product Philosophy

What StudyBar is, what it refuses to be, and the principles that decide every feature.
The visual system lives in [`DESIGN.md`](DESIGN.md); this is the layer above it — the
*why* that the look serves.

> **North star.** A calm, private, honest study desk you own. It helps a student see
> and act on their week in seconds and learn the material, without leaving their work.

---

## The spine

Six principles, in priority order. When two conflict, the higher one wins.

1. **Never lose the user's data.** Data safety is a first principle, not a feature.
   Destructive actions are undoable; persistence is conflict-safe (3-way merge, never
   clobber); backups are automatic. If a change risks a byte of the user's work, it
   doesn't ship.
2. **Your data stays yours.** Your file, your Mac. No account, no paywall, no StudyBar
   server — ever. An AI engine sees what a request needs, never the data file. This is
   the identity, not a default to be talked out of.
3. **A study assistant, not a gatekeeper.** AI explains, quizzes and works problems with
   you (see below). How you use it is yours to decide.
4. **Calm by default.** Minimalist, distraction-free, compact. Ship small; let it grow
   to fit the person. Every pixel of chrome and every module is a tax on calm and must
   earn its place.
5. **Own your workspace.** The user arranges it — toolbars, visible modules, theme —
   within a system that keeps their choices coherent.
6. **Free and open.** MIT, open source, accessible over polish-gating. Access beats
   gloss.

---

## Local data, your choice of engine

The data is local; the AI engine is the student's choice — and hosted engines are a
first-class one, not an escape hatch. (Changed 2026-09-30: in practice the students using
StudyBar run it on ChatGPT, DeepSeek or Claude, and the jobs that matter most need them.)

- **Hosted engines are what the AI is built and tuned for.** With their own key, a student
  gets an engine that reads a whole course for a quiz, a 75-minute lecture in one go, a
  photographed problem. Prompts, context sizes and limits are set for them first.
- **Local engines stay.** On-device and Ollama run with zero network and zero account, for
  privacy, for offline, and for a student without a key. They do the lighter jobs well;
  where a job is too big for them, StudyBar does less rather than pretend.
- **Scoped and visible.** A request sends what it needs — the note, the passages, the
  question — never the data file. Keys live in the Keychain. Settings ▸ Intelligence shows
  which engine answers what, and what it has cost this month.
- The bar: *a student without a key still gets a complete app* — notes, flashcards, the
  planner, the converter. The AI is where a hosted engine earns its cost.

---

## A study assistant, not a gatekeeper

**The AI helps with the whole job of studying: organizing, explaining, quizzing, and
working problems.**

- **Organize:** summarize notes · make flashcards · triage and schedule assignments ·
  plan the week · turn a recording into notes.
- **Teach:** explain a concept, answer a question the note doesn't cover, and work a
  homework or practice problem step by step to its answer.
- **Fill in:** lecture notes get the definitions, explanations and examples the lecture
  skipped, *marked as added*, so what was said and what the AI added stay distinguishable.
- **Why the change (2026-09-29).** The earlier rule refused to solve problems or teach from
  the command bar. After a month of use it cost more than it protected: the refusals landed
  on ordinary studying far more often than on misuse. Integrity is the student's call.
- **What still holds:** every write to your data is a proposal you accept, and AI additions
  are labeled. Honesty about sources is the line now, not refusal.

---

## AI is a material, not a place

StudyBar's AI **meets you on the object and proposes** — you stay in flow and in control. It is never a chatbot you visit and copy-paste out of. Chat is the fallback,
not the home. (Apple's Writing Tools work because they appear *on the thing*, propose,
and let you accept — zero navigation, zero copy-paste, reversible.)

**Three layers of presence:**

1. **Inline (on-object)** — the workhorse, ~90% of use. The `✨` menu on anything with
   text transforms what's in front of you (summarize, rewrite, proofread, key points,
   continue; per-module actions like an assignment's *break into steps*). Result streams
   into a review card; you **accept or discard**. Non-destructive, single undo. One
   affordance everywhere text lives — learn it once (`Shell/AITextMenu.swift`).
2. **Command bar** — cross-object jobs ("plan my week", "flashcards from these notes").
   A **summoned floating panel** (`Core/AssistantPanel.swift`, opened via ⌘K), not a
   sidebar destination. It proposes **confirm-cards** you apply. Floats over your work,
   closes when done.
3. **Ambient suggestions** — **off by default** (user-invoke wins). A Settings ▸
   Intelligence toggle turns on gentle, **dismissible** chips ("Summarize?" on a long
   note). Never modal, never auto-acts.

**Two invariants under all of it:**

- **AI never mutates the store directly.** Inline → review card. Cross-object → confirm-
  cards. You commit. Always undoable. (Same spine as *never lose user data*.)
- **Your engine.** A hosted engine with your own key for the heavy jobs, a local one when
  nothing should leave the Mac — one setting, or split by kind of job.

**The test for any AI feature:** *can the user do it without leaving what they're looking
at, and is the result a proposal they accept?* If no → redesign or don't ship. We do **not**
build: a chat transcript as the primary surface, auto-apply, anything that makes you leave
the object, or proactive nagging.

---

## Breadth vs. calm

StudyBar does a lot (dozens of modules). A "quiet desk" with dozens of drawers isn't
quiet — unless calm is the default and breadth is opt-in. Three rules hold the line:

1. **Calm is default, breadth is opt-in.** Ship minimal. The user *adds* modules and
   toolbar items. StudyBar starts small and grows to fit the person — never the reverse.
   An empty-by-default surface beats a full one.
2. **Customization is the pressure valve.** Hide-unused, arrange toolbars, pick a theme →
   each user shrinks StudyBar to *their* subset. Breadth serves the many; calm serves each
   one. This is what lets breadth exist without imposing it.
3. **Every module earns its place — or costs nothing.** It passes the five-second test
   (below), or it is hideable/demotable so that when unused it is invisible, not clutter.

### The five-second test

Every feature and module answers one question:

> **Does this help a student see and act on their week in under five seconds, without
> leaving their work?**

If it can't, it is demoted, hidden by default, or cut. This test resolves breadth by
force: the core stays sharp, the long tail stays opt-in.

---

## Two surfaces, two jobs

StudyBar lives on two surfaces with different jobs. Cramming both jobs into one surface
is the classic mistake.

| | **Menu-bar popover** | **Main window** |
|---|---|---|
| **Job** | Glance + capture | The workspace — do the work |
| **Scope** | Hard-capped: Today, quick-add, timer, next class | The full module set, organized |
| **Calm via** | *Scope* — it physically can't sprawl | *Architecture* — grouped nav, a real Home, progressive disclosure |
| **Affordances** | Inline only (no sheets/alerts — the popover dismisses) | Normal Mac app: sheets, alerts, panels are fine here |

- The popover is the **quick surface**: it can't hold everything and shouldn't try.
- The window is the **home**: spacious, but still minimal. **Compact ≠ cramped —
  compact means no wasted chrome, not dense dashboards.** One thing at a time, whitespace,
  calm — with room to breathe.

> **Architecture note.** StudyBar began as a menu-bar-only app (`NSStatusItem` +
> `NSPopover`), which is *why* DESIGN.md rule #4 forbids modals — a popover dismisses when
> a sheet opens. A real window removes that constraint. The design rules therefore **fork
> by surface** (see DESIGN.md): the popover stays inline-only; the window uses standard
> app affordances.

---

## Customization within a fixed system

The user owns the arrangement and the palette. They never touch the primitives.

- **Themes** swap the accent and surface *tokens* only, from curated presets. Every radius,
  spacing step, and component holds. No raw-color freedom → no chaos.
- **Toolbars** show/hide/reorder *existing* components. They never restyle them.

The design system is the guardrail that keeps customization from becoming a mess.
**Customize arrangement and palette — never the primitives.** This is how principle #5
("own your workspace") coexists with DESIGN.md's "compose, don't restyle."

---

## What StudyBar refuses to be

Anti-goals are as load-bearing as goals.

- **Not a cloud SaaS.** No mandatory account, no subscription, no server that owns your data.
- **Not a dense dashboard.** No wall of widgets, no notification farm, no engagement bait.
- **Not a walled garden.** Local files, open formats, standard interop (Anki, .ics, RSS,
  citations). Your data leaves as easily as it arrives.
- **Not everything-for-everyone by default.** The long tail exists, but opt-in. The
  default is small.
