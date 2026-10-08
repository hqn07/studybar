# StudyBar UI — "Quiet Study Desk"

The design direction for StudyBar and the guardrails any new screen follows.
The kit lives in [`Sources/StudyBar/Shell/DesignSystem.swift`](../Sources/StudyBar/Shell/DesignSystem.swift).
The *why* above this — what StudyBar is and refuses to be — lives in
[`PHILOSOPHY.md`](PHILOSOPHY.md).

## Direction

**Refined-native.** SF Pro, system materials, respects light/dark and the system
accent color — it should feel like an app Apple could have shipped. On top of that,
a **shared component vocabulary** so every module looks and behaves the same:
compact, scan-first, calm.

StudyBar renders on **two surfaces with different jobs** — the rules below fork where
it matters (see *Surfaces*):

- **Menu-bar popover (~380 pt)** — glance + capture. Inline-only; it dismisses if a
  sheet or panel opens. Calm by scope.
- **Main window** — the workspace. Standard Mac-app affordances (sheets, alerts,
  panels) are allowed here. Calm by architecture: grouped nav, a real Home, progressive
  disclosure. Compact ≠ cramped — spacious but minimal.

## Tokens (`DS`)

- **Radius** — `control 6` (pills/buttons) · `card 10` (rows/panels) · `modal 14` (overlays). Nothing else.
- **Space** — base-4 step: `xs 4 · s 6 · m 8 · l 12 · xl 16`.
- **Width** — `content 1200` caps a module's lists and dashboards on a wide window · `prose 680` is the reading measure for running text (notes, tutor answers, study guides, articles; the note editor's text matches it) · `form 760` is for question-and-answer layouts (quizzes, progress, glossary). Lists and grids are fluid up to `content`; only prose keeps a measure.
- **Color** — one accent (`.tint`; the system accent, or a theme preset — see *Customization*). Semantic colors are **state only**: `.dsNow` (red) · `.dsWeek` (orange) · `.dsDone` (teal). Never use them as decoration.
- **Type** — one 3-role scale: `title3/semibold` module titles · `callout/medium` row titles · `caption` secondary/preview · `caption2 mono` labels & keywords. Plus `Font.dsGlance` (26 pt rounded semibold) for a number worth seeing at a glance.

## Components

Compose these — do not hand-roll a new chip/row/radius/spacing.

- **`Chip(_:_:selected:systemImage:dot:)`** — one component, four styles: `.tag`, `.filter`, `.key` (mono keyboard-key), `.status(.now/.week/.done/.neutral)`. Replaces keyword pills, tags, urgency pills, filter chips, course chips.
- **`SBRow`** — icon · title · subtitle · trailing. The canonical list item: a plain line — no fill, a hairline below, the surface only under the pointer. Hand-rolled rows take `.sbRowSeparator()` for the same line. **Rows vs cards:** a list is rows a hairline apart; a card is only for a thing you pick up and act on (a course, Today's hero and tiles, an Insights panel).
- **`ModulePane(title:primary:controls:more:)`** — a module's header. One labeled `primary` action (the module's create action, titled "New", or its plain verb where "New" means nothing: Review, Plan my day, Paste); `controls` only for view switchers that must stay in sight (segmented pickers, tab pickers) and badges that appear when there's work; everything else in `more`, the ⋯ menu right after the title, titled with what it does.
- **`GlanceFilter(items:)`** — a module's scopes as large counts you click ("14 this week · 2 overdue · 34 all") — the summary and the filter in one strip; a scope with nothing in it is left out unless selected.
- **`SectionHeader(title:count:systemImage:)`** — uppercase group label + count; pair with `DisclosureGroup` for collapsible groups.
- **`.dsCard()`** — standard panel surface (card radius + secondary background).
- **`GlanceRow(stats:emptyText:)`** of **`GlanceStat(value:label:isEmpty:)`** — numbers that matter, value over label in `dsGlance`, no tile around them. **Zeros are hidden:** mark a zero or missing value `isEmpty` and it's left out rather than drawn as "0" or "—"; when every stat is empty the row says so in one line (`emptyText`) or draws nothing.
- **`ConfirmCard`** (existing) — every inline confirm/prompt. No sheets/alerts/color panels (they dismiss the popover).
- **`EmptyState`** (existing, `ContentUnavailableView`) — every module ships one with a next action.
- **Buttons** — native styles, mapped: primary `.borderedProminent` · secondary `.bordered` · ghost `.borderless` (tinted) · danger `role: .destructive`.

## Seven rules for any new screen

1. **Compose, don't restyle.** Build from the kit. Writing a new corner radius? Stop.
2. **One accent, semantic state.** Tint = interactive/selected. Red/amber/teal = status only.
3. **Summary before detail.** Lead with what needs attention (due chip, count, next-up).
4. **Inline in the popover; native in the window.** In the **popover**, never modal — push with `NavigationStack`, confirm with `ConfirmCard`, no sheets/alerts/`NSColorPanel` (they dismiss it). In the **window**, standard app affordances (sheets, alerts, panels) are fine; still prefer inline when it's calmer.
5. **Three radii, one grid.** 6 / 10 / 14; spacing on the base-4 scale; nothing off-grid.
6. **Native materials & motion.** System vibrancy, SF Symbols at one weight, one spring for reveals (folds, flips).
7. **Earn the empty state.** Real `EmptyState` with a next action — never a blank pane.

## The window's frame

- **Every module header spans the pane.** `ModuleInfo.wide` means *spatial* — two-pane editors, calendars, boards (Notes, Schedule, Calendar, Study, Board, Settings) fill the pane; every other module's content sits in a column capped at `DS.Width.content`, centered, under a header that still spans. `ModulePane` applies the cap from the environment, so the popover is never capped.
- **Grids grow columns, not rows.** Use `GridItem(.adaptive(minimum:))` so a wide window adds a column (Courses: 2 at the narrowest, 4 at 1200; Insights' cards: 1 → 2) instead of stretching one row across the screen.
- **The sidebar** has four groups — Plan, Capture, Study, Tools — with Settings pinned at the bottom. A group gets a header only when it has three or more rows and more than eight modules show (`SidebarLayout`, pinned by `--design-selftest`); unselected rows are secondary, so navigation recedes and the work stays in focus.
- **One toolbar row.** The window has no header row of its own: the left pane's `ModulePane` / `SubHeader` header *is* the toolbar row, 44 pt, up in the titlebar beside the traffic lights, draggable where it's empty (`WindowDragArea`). The sidebar toggle and the search field are drawn once by `RootView` at fixed spots in that row, so the search field never moves or loses focus. In a split, the left module owns the row; the right pane keeps its strip (picker · swap · close) below it, its own header inline. The app menu (New Tab, New Window, Quit) sits beside Settings at the foot of the sidebar.
- **A page pushed over a module brings its own toolbar row.** Use `SubHeader`, or give a custom header `.toolbarRow()` (`.toolbarRow(false)` when it isn't at the top of the pane). A `ModulePane`'s content is never the toolbar row, and a sheet's header opts out (`.environment(\\.isPrimaryPane, false)`). Below 760 pt the search field narrows and a primary button drops its label before the title is squeezed.
- **Today has two layouts.** At 900 pt and wider: one screen — quick add, the hero beside up to four glance tiles (each left out when empty), today's classes and deadlines beside the next seven days. Narrower — the popover, a split pane — the single column.
- **Pushed pages keep to the column too.** An editor or detail page pushed inside a module has no `ModulePane`, so its `navigationDestination` applies `.moduleColumn(DS.Width.form)` (a form) or `.moduleColumn()` (any other page); with no cap set — the popover, a spatial module — it does nothing.
- **Raw radii are ratcheted:** `scripts/design-lint.sh` counts corner radii written as numbers instead of `DS.Radius` and fails above the ceiling in `scripts/design-lint.baseline`; lower the ceiling (`--update`) as rows are cleaned up.
- **Check every screen before a release:** `scripts/module-audit.sh <out-dir>` renders every module at 720 / 1280 / 1680 pt in dark and light, each on an empty store, and the popover, with an `index.html` to look through. It runs from a test copy with its own preferences and throwaway data — as must every flag (`scripts/test-copy.sh --design-selftest`): the Debug build shares the installed app's preferences, and the app builds its state before it reads any flag.

## Surfaces

Two surfaces, two jobs. Same kit, forked rules.

| | **Menu-bar popover** | **Main window** |
|---|---|---|
| **Job** | Glance + capture | The workspace |
| **Scope** | Today, quick-add, timer, next class | Full module set, organized |
| **Modals** | None — inline only (it dismisses) | Sheets / alerts / panels allowed |
| **Width** | ~380 pt, fixed | Resizable; layout adapts |
| **Calm via** | Scope | Architecture (grouped nav, Home, progressive disclosure) |

A module shown on both surfaces shares components but not chrome: the popover shows the
compact, scan-first slice; the window shows the full view with room to breathe.

## Customization

The user owns arrangement and palette — never the primitives. This is how "own your
workspace" coexists with rule #1 ("compose, don't restyle").

- **Themes** swap the accent and surface *tokens* only, from a curated preset set. Every
  radius, spacing step, and component holds. Light/dark and system-accent remain the
  default theme. No raw-color freedom.
- **Toolbars** show / hide / reorder *existing* components. They never restyle them. A
  hidden module costs nothing; the default set is minimal.

Rule: customization operates on **layout and theme tokens**, never on radii, spacing, type
scale, or component internals. The system stays fixed so every arrangement stays coherent.

## AI surfaces

AI follows PHILOSOPHY.md's *"material, not a place."* Its UI rules:

- **`✨` affordance** — a tinted "AI" pill, identical everywhere text lives
  ([`AITextMenu`](../Sources/StudyBar/Shell/AITextMenu.swift)). Pinned to the Notes toolbar's
  trailing edge (never inside a scrolling strip that can hide it); a top-trailing overlay on
  other text editors.
- **Review card** — every inline result renders in a `.tint`-tinted card: streams while
  working, then Accept (**Replace** in place / **Insert** below, per action) + **Discard**.
  The original is untouched until Accept; it's a single undo.
- **Command bar** — the assistant is a summoned floating panel
  ([`AssistantPanel`](../Sources/StudyBar/Core/AssistantPanel.swift)), not a sidebar module.
  Cross-object results are confirm-cards.
- **Chips** — opt-in proactive suggestions are dismissible capsules with one action, never
  modal, gated behind Settings ▸ Intelligence ▸ *Suggest actions as I work*.

## Rollout

Kit-first (done): `DesignSystem.swift` added, no module changes yet. Then migrate
module-by-module — Assignments as the reference, then sweep by sidebar category —
deleting hand-rolled chips/rows as each adopts the kit.

Visual reference (tokens, components, popover mockups): the "Quiet Study Desk" artifact.
