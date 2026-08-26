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
- **Color** — one accent (`.tint`; the system accent, or a theme preset — see *Customization*). Semantic colors are **state only**: `.dsNow` (red) · `.dsWeek` (orange) · `.dsDone` (teal). Never use them as decoration.
- **Type** — one 3-role scale: `title3/semibold` module titles · `callout/medium` row titles · `caption` secondary/preview · `caption2 mono` labels & keywords.

## Components

Compose these — do not hand-roll a new chip/row/radius/spacing.

- **`Chip(_:_:selected:systemImage:dot:)`** — one component, four styles: `.tag`, `.filter`, `.key` (mono keyboard-key), `.status(.now/.week/.done/.neutral)`. Replaces keyword pills, tags, urgency pills, filter chips, course chips.
- **`SBRow`** — icon · title · subtitle · trailing. The canonical list item; one height, one radius, one surface.
- **`SectionHeader(title:count:systemImage:)`** — uppercase group label + count; pair with `DisclosureGroup` for collapsible groups.
- **`.dsCard()`** — standard panel surface (card radius + secondary background).
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

## Rollout

Kit-first (done): `DesignSystem.swift` added, no module changes yet. Then migrate
module-by-module — Assignments as the reference, then sweep by sidebar category —
deleting hand-rolled chips/rows as each adopts the kit.

Visual reference (tokens, components, popover mockups): the "Quiet Study Desk" artifact.
