# StudyBar — Product Philosophy

What StudyBar is, what it refuses to be, and the principles that decide every feature.
The visual system lives in [`DESIGN.md`](DESIGN.md); this is the layer above it — the
*why* that the look serves.

> **North star.** A calm, private, honest study desk you own. It helps a student see
> and act on their week in seconds, without leaving their work — and never does the
> work for them.

---

## The spine

Six principles, in priority order. When two conflict, the higher one wins.

1. **Never lose the user's data.** Data safety is a first principle, not a feature.
   Destructive actions are undoable; persistence is conflict-safe (3-way merge, never
   clobber); backups are automatic. If a change risks a byte of the user's work, it
   doesn't ship.
2. **Local-first, always.** Your file, your Mac. No account, no paywall, no cloud
   required — ever. This is the identity, not a default to be talked out of.
3. **Organize, never do the homework.** The academic-integrity line (see below). AI is
   a librarian, not a ghostwriter.
4. **Calm by default.** Minimalist, distraction-free, compact. Ship small; let it grow
   to fit the person. Every pixel of chrome and every module is a tax on calm and must
   earn its place.
5. **Own your workspace.** The user arranges it — toolbars, visible modules, theme —
   within a system that keeps their choices coherent.
6. **Free and open.** MIT, open source, accessible over polish-gating. Access beats
   gloss.

---

## Local-first > AI quality

The best AI answer today needs the cloud. We take the worse-but-private one by default.

- **Local is the default and the identity.** On-device / Ollama runs with zero network,
  zero account. Ship quality that stands on its own with no cloud attached.
- **Cloud is a labeled escape hatch, never the default.** A user may bring their own key
  for a stronger model. It is opt-in, clearly marked, and nothing core depends on it.
- The bar: *a student who never touches the cloud gets a complete, useful app.* If a
  feature only works with cloud AI, it's a bonus tier — not the feature.

---

## Organize, never do the homework

**AI acts on what the student already made or scheduled; it never produces gradeable
content.**

- **Allow (organize):** summarize *your* note · extract flashcards from *your* material ·
  triage and schedule assignments · reformat citations · plan the week · define a term ·
  tag and link · turn *your* voice memo into a note. Transform · structure · retrieve ·
  schedule.
- **Refuse (homework):** write the essay · answer the problem set · generate arguments or
  prose the student would submit as their own.
- **The test:** *Would a professor count this as the student's own work?* If the output is
  something you'd **submit**, it's homework — refuse.
- **Enforcement is architecture, not trust.** A small local model can't police itself, so
  the *design* draws the line: every AI write-tool is an organize-verb (`create_flashcard`,
  `schedule`, `tag`, `add_citation`). None emits submittable prose. **The tool catalog is
  the guardrail.** Rule: never add a tool whose output is gradeable content.

---

## AI is a material, not a place

StudyBar's AI **meets you on the object and proposes** — you stay in flow, in control,
on-device. It is never a chatbot you visit and copy-paste out of. Chat is the fallback,
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
- **Local-first.** Apple on-device model is the default when available (free, private,
  fast enough for these bounded tasks); Ollama / cloud are user-chosen upgrades.

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
- **Not a homework machine.** It will not write, solve, or answer what you'd submit.
- **Not a dense dashboard.** No wall of widgets, no notification farm, no engagement bait.
- **Not a walled garden.** Local files, open formats, standard interop (Anki, .ics, RSS,
  citations). Your data leaves as easily as it arrives.
- **Not everything-for-everyone by default.** The long tail exists, but opt-in. The
  default is small.
