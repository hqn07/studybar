# Windowed-App Migration Sketch

How StudyBar goes from **menu-bar-popover-only** to **a full windowed Mac app + a
menu-bar companion**, without breaking anything or losing the calm. Direction set in
[`PHILOSOPHY.md`](PHILOSOPHY.md); rules forked by surface in [`DESIGN.md`](DESIGN.md);
appearance surface mocked in the "Customize StudyBar" artifact.

## Where we are today

- The **popover and the window are the same view** — both host `RootView` (AppDelegate:
  `popover.contentViewController` and `showWindow()` both wrap `RootView().environmentObject(state)`).
  So the window already exists; it just isn't *differentiated* or first-class.
- `RootView` = header + sidebar split (auto-rails < 440 pt) + module content + overlays
  (palette, break, onboarding, undo). Sidebar from `ModuleRegistry.byCategory`.
- **Theming already half-wired:** `@AppStorage` `accentHex` (#4F8DFD) → `.tint`;
  `appearance` (system/light/dark) → `.preferredColorScheme`; `density`. The mockup's
  theme grid + light/dark/device write these exact keys.
- `ModulePrefs` already supports **hide / star / reorder** per module — the "breadth
  opt-in" pressure valve exists; the window surfaces it.
- `SB_DOCK=1` already flips `NSApp.setActivationPolicy(.regular)` — the Dock-app path is
  one line.

The migration is therefore mostly **splitting one shared view into two surfaces** and
**promoting the window**, not a rewrite.

## Target: two surfaces, two jobs

```
┌─ MENU-BAR POPOVER ─────────┐        ┌─ MAIN WINDOW ─────────────────────────────┐
│  glance + capture          │        │  the workspace                             │
│  ~380 pt, inline-only      │  ───▶  │  resizable · grouped sidebar · modals OK   │
│                            │  opens │                                            │
│  • Today glance (next-up,  │        │  [rail] [ sidebar ] [ module content ]     │
│    due count, next class)  │        │   icons  grouped      full-width views     │
│  • Quick-add (NL parse)    │        │          by category                       │
│  • Focus timer (mini)      │        │  + Settings ▸ Appearance = theme grid,     │
│  • Favorites → open window │        │    light/dark/device, toolbar arrange      │
│  • Search → open window    │        │                                            │
└────────────────────────────┘        └────────────────────────────────────────────┘
```

- **Popover is a dashboard + launcher, not a module navigator.** It shows the capped
  glance set and *opens the window* for anything deeper. Stays inline-only (it dismisses).
- **Window is the home.** Full module set, spacious, standard app affordances. Calm by
  architecture, not amputation.

### Popover capped set (hard cap — resist adding to it)

| Slot | Source | Note |
|---|---|---|
| Today glance | condensed `TodayView` | next-up hero, due-today count, next class |
| Quick-add | `QuickParse` NL bar | "essay due fri for chem" → Assignment/Todo |
| Focus timer | `TimeFocusView` mini | start / running countdown |
| Favorites | `ModulePrefs` starred | tap → opens window to that module |
| Search | global search | opens window with results |

Everything else is **window-only**.

## Module → surface map (29 modules)

Window holds all 29 (grouped by category). Popover shows only the glance slices above.

| Category | Modules | Popover slice? |
|---|---|---|
| Overview | Today · Insights · Assistant | Today (glance) · Assistant (quick-ask, optional) |
| Assignments | Assignments | via Today glance + quick-add |
| Capture | Notes · Scratchpad · Voice · Clipboard · Snippets | quick-add only; full capture in window |
| Time & Focus | Time & Focus | mini timer |
| Schedule | Schedule · Calendar | next-class glance |
| Links & Resources | Quick Links · Reading List · Files · News | — window |
| Research | Citations · Word Count · Dictionary · Lookup · Equation | — window |
| Study | Flashcards · Reading | — window |
| Organize | To-Do · Board · Semester · Grade Calc · Courses | quick-add (To-Do) |
| System | Settings | — window (Appearance surface lives here) |

**Heavy modules that most want the window's room:** Notes (rich editor), Calendar,
Insights (charts), Board (kanban), Reading, Equation, Flashcards study. These get
two-column / wider layouts in the window that a 380 pt popover can't hold.

### Optional: calm the sidebar (10 → ~8 groups)

10 categories is a lot for the window rail. A gentle consolidation (not required —
`ModulePrefs` custom order already lets each user re-slice):

- **Home** — Today, Insights, Assistant
- **Work** — Assignments, To-Do, Board, Courses, Semester, Grade Calc
- **Capture** — Notes, Scratchpad, Voice, Clipboard, Snippets
- **Study** — Flashcards, Reading, Time & Focus
- **Schedule** — Schedule, Calendar
- **Library** — Quick Links, Reading List, Files, News
- **Research** — Citations, Word Count, Dictionary, Lookup, Equation
- **System** — Settings

## Architecture changes

- **Split the root.** `RootView` → `WindowRoot` (full: sidebar + content + window
  chrome) and `PopoverRoot` (compact: the capped set + launcher). Both read the same
  `AppState`. AppDelegate: `popover` hosts `PopoverRoot`; `showWindow()` hosts `WindowRoot`.
  Shared subviews (TodayView glance, timer, quick-add) are extracted once and reused.
- **Deep links open the window.** `studybar://open?module=<id>` and Spotlight/Favorites
  must target `WindowRoot` (select module + `showWindow()`), never try to navigate the
  popover. (`openSettings()` already does this pattern.)
- **Window becomes first-class.** Persist frame (autosave name), sensible min size
  (~720×520), native toolbar (search + module title + quick actions), remember last
  module. Summon from: global hotkey, menu-bar right-click "Open StudyBar", optional Dock.
- **Dock decision — deferred, made a setting.** Keep `LSUIElement` (menu-bar companion
  always present) as the default; add a **"Show StudyBar in the Dock"** toggle that
  flips activation policy (reusing the `SB_DOCK` mechanism) for users who want it to feel
  like a normal app. Avoids a jarring identity change; lets the pivot land gradually.
- **Rule #4 forks by surface.** `WindowRoot` may use sheets / alerts / inspectors /
  `NSColorPanel` (the window doesn't dismiss); `PopoverRoot` stays strictly inline
  (`NavigationStack` + `ConfirmCard`). Overlays (onboarding, break, undo) move to
  `WindowRoot`; the popover keeps only the undo toast.
- **Customization surface (the mockup, for real).** Settings ▸ Appearance: theme preset
  grid (writes `accentHex`) · Light/Dark/Device segment (writes `appearance`) · grouped
  sidebar · toolbar/module **hide-reorder** (drives `ModulePrefs`). Status colors
  (`.dsNow/.dsWeek/.dsDone`) stay fixed regardless of accent — enforce in code.

## Phasing (each phase ships on its own)

- **Phase 1 — split the roots. ✅ shipped (`79d7d93`).** `RootView(surface:)` forks the
  body: `.popover` = search + Today glance + module launcher (Favorites → All) + ⋯ menu;
  `.window` = the full sidebar + content. Navigation hand-off via
  `WindowOpener.routeToWindow` (popover watches `selectedModuleID`, AppDelegate opens the
  window + dismisses the popover, no-op unless the popover is active) — zero call-site
  churn. Deep-links/Spotlight/notifications already route to the window via
  `AppActions.open`. *Was low risk — reused views.*
- **Phase 2 — window as home. ✅ mostly shipped (`ffd8457`).** Remember-last-module
  (`AppState` persists `selectedModuleID`), dynamic window title ("StudyBar — <Module>"),
  min size 720×480 (frame already autosaved), and **Dock-as-a-setting** ("Show StudyBar
  in the Dock" → live activation-policy flip; default menu-bar-only). *Remaining:* a real
  native `NSToolbar` (deferred — the in-content header serves; SwiftUI↔NSToolbar search
  state is fiddly) and allowing sheets/inspectors in the window where they help.
- **Phase 3 — customization surface. ✅ shipped (`ab86a89`).** Settings ▸ Appearance now
  has the accent **preset grid** (`Palette.accents`, ✓ + glow) + Custom ColorPicker +
  Light/Dark/Device segment; re-tints the app live. Module hide/reorder (the "toolbar
  arrange" half) already ships in Settings ▸ Modules. *Honest scope:* StudyBar themes the
  accent + light/dark; surface tokens stay system materials (surface theming = a later,
  bigger change). *Remaining:* ship-minimal-by-default defaults pass.
- **Phase 4 — surface-aware modules. ✅ shipped (`8696a72`).** `ModuleInfo.wide` flag:
  spatial modules (Insights, Calendar, Board, Reading) fill the window; text/list modules
  get a centered readable column (max 820 pt) — engages only once the window is widened
  past its default, so no regression at default size. *Deferred:* Notes list+editor
  master-detail (riskier per-module refactor of the daily driver; weak to verify headlessly).

## Risks / open questions

- **Popover feature loss anxiety.** Users who lived in the popover's full sidebar lose it
  there. Mitigation: Favorites launcher + "everything's in the window, one keystroke away."
- **Two layouts to maintain** for shared modules that appear on both surfaces — keep the
  popover slice *thin* (glance only) so there's little duplicate UI.
- **Onboarding** must now teach two surfaces — keep it in the window.
- **Data safety unaffected** — single `AppState`, conflict-safe persistence; surfaces are
  views over the same store.
- **Open:** does the popover keep *any* module navigation (Favorites) or become pure
  glance? Leaning: Favorites-as-launcher only.
