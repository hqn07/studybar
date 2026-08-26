# UI Inspiration — Helium Browser

Captured 2026-08-26. Reference material for the customization surface + windowed-app
pivot. Not a spec to copy wholesale — the *elements* below are the keepers, filtered
through [`PHILOSOPHY.md`](PHILOSOPHY.md) and [`DESIGN.md`](DESIGN.md).

Helium's "Customize" panel is, in effect, a polished execution of the customization
surface we already specced (curated theme presets + light/dark/device + grouped nav).
It validates the direction; borrow the execution, not the browser chrome.

## Keepers (adopt)

| Helium element | StudyBar adoption | Surface |
|---|---|---|
| **Theme swatch grid** — rounded squares, each a 4-quadrant palette preview (accent + surface tones), ✓ badge on the selected one, an **eyedropper** tile for custom | This *is* our "curated theme presets." Each swatch = an accent + surface **token** set. Eyedropper sets a custom **accent**; the system regenerates the rest. | Window (full grid) + a compact strip in the popover's Settings |
| **Light / Dark / Device** segmented pill — icon + label, soft tinted selection with a check | We already follow system light/dark — add the explicit tri-toggle. One tap, clean. | Both |
| **Settings sidebar** — icon + label rows, **grouped with separators**, subtle rounded highlight on the selected row | The model for the **window's** module nav + Settings. Matches "window = grouped nav, progressive disclosure." | Window |
| **Grouped rounded section-cards** — related rows inside one padded card, not a flat list | Reinforces `.dsCard()`: group settings/module sections into cards for a calmer scan. | Both |
| **Muted single-weight icons**, low contrast until active (tint only on the active item) | Already rule #6; Helium executes it well. SF Symbols one weight, tint = active only. | Both |
| **Inline controls** — Zoom `− 100% +`, dropdowns, a ghost **"Reset to default"** | Inline steppers / dropdowns / ghost-reset — no modal needed. Matches our inline rule. | Both |

## Skip / adapt (would break our philosophy)

- **Wallpapers behind content** → no. StudyBar is distraction-free; imagery behind your
  week is noise. Ceiling: a *subtle* accent-tinted surface, never a photo.
- **Browser-chrome density** → Helium still carries many controls. Take the *styling*,
  not the quantity. We stay compact.
- **Raw custom color everywhere** → keep to an accent + surface **token** swap
  ("customize palette, not primitives"). The eyedropper picks the accent only; the
  system derives the surfaces.

## The three that matter

1. **Theme swatch grid** (quadrant preview + ✓ + eyedropper)
2. **Light / Dark / Device** segmented pill
3. **Grouped settings/module sidebar**

All three slot into decisions already made — they just show a polished execution.

## Next step

Build a **mockup Artifact** of StudyBar's customization surface (theme grid +
light/dark/device + grouped sidebar) in Quiet Study Desk tokens, to eyeball the
direction before any Swift.

Source: three Helium screenshots (Customize panel, overflow menu, `helium://settings`).
