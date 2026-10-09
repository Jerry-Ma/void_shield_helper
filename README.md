# VoidShieldHelper

A lightweight indicator addon for **Discipline Priests** that predicts the probability of your next **Void Shield** proc.

---

## How it works

Void Shield follows a deck mechanic: each group of Penance casts contains exactly one proc. VoidShieldHelper models this with parallel phase trackers (one per possible cycle offset). Each tracker independently maintains a probability distribution over the current group; invalid trackers are pruned as the history grows. The displayed probabilities are averaged across all still-valid trackers.

As of 12.1 (the addon requires 12.1 or later):

- The Penance deck is **4 casts** (25% for the first card).
- Void Shield holds **up to 2 charges**.
- **Mind Blast** grants a charge outright. It never turns a deck card, so it doesn't affect the prediction.

### Charge counting

12.0 made aura data "secret", so the addon can't read the buff's stack count directly. If **Blizzard's Cooldown Manager** is showing the Void Shield buff, the addon piggybacks on it to know the exact 1-vs-2 charge count, which lets it detect a Penance proc that lands while you already hold one charge. Without it, the count is inferred from your Mind Blast / Void Shield casts, and such a Penance is recorded as *unknown*. Either way, a Penance cast while holding 2 charges is *unknown*. The debug window shows the current count and prefixes it with `~` in the fallback mode.

### Forecast lights

The frame has four slots, one per card of the deck: **[status] [N+1] [N+2] [N+3]**.

| Slot | Meaning |
|------|---------|
| **Status** | One light per Void Shield charge, splitting the slot's total size; lit = charge held. They stack across the layout by default (a column when horizontal, a row when vertical), or along it. They play the action-bar **proc glow** when you're at 2 charges and the next Penance could proc — spend a charge first or that proc is wasted. |
| **N+1** (large) | Probability your *next* Penance will proc |
| **N+2** | Probability the Penance after that will proc |
| **N+3** | Probability the Penance after *that* will proc |

Sizes and directions are described relative to the layout, so they keep their meaning when you switch between horizontal and vertical: **along** is the direction the four slots run, **across** is perpendicular to it.

Layout options: horizontal or vertical, spacing along, and alignment across (start = top/left, center, end = bottom/right). Prediction and status lights each have their own texture, size and border; status lights also have total size along / across, stack direction, stack spacing and colours.

Colour scale: **cyan** (100% — will proc) → **green** (≥ 66%) → **yellow** (≥ 33%) → **orange** (< 33%) → **red** (0% — won't proc) → **grey** (not enough data)

A smooth gradient mode is available as an alternative to discrete colour steps.

---

## Usage

`/vsh` — toggle the options panel

Frames appear automatically when logged in as a Discipline Priest with Penance on your action bar. All frames are draggable; positions are saved per character.

The addon also appears in the game's built-in **Addon Settings** panel (ESC → Options → Addon Settings → VoidShieldHelper).

> **Action bar requirement:** Proc detection works by watching the Power Word: Shield button icon on your action bars. **Power Word: Shield must be placed directly from the spellbook onto an action bar** — a macro that casts PW:S will not work. If you use macros for PW:S, enable an extra action bar and place the raw spell in any empty slot there; it does not need to be visible or on your main bars.

---

## Options

- Show/hide the debug window (cast history, phase state, raw probabilities)
- Lock frames: no dragging and fully click-through (the debug window's Options button is hidden; use `/vsh`)
- Per-frame scale (0.5× – 2.0×): **Indicator Frame Scale** and **Debug Window Scale**
- Smooth gradient vs. discrete probability colours (with live preview bar)
- Per-frame background/border colour, size, and LibSharedMedia texture
- Light square size (main and secondary), spacing, border colour and size
- Configurable proc-check delay (50–500 ms, default 200 ms)

---

## Acknowledgements

- 12.1 deck/charge support adapted from [Void Shield Tracker](https://github.com/anozireth/VoidShieldTracker) by anozireth, a port of this addon.
- Proc detection approach inspired by [Void Shield Proc Tracker](https://www.curseforge.com/wow/addons/void-shield-proc-tracker).
- Void Shield deck mechanic explained in [this video](https://www.youtube.com/watch?v=X1Od3Ovp2i0).

---

## Feedback & bugs

Please report issues on the [GitHub repository](https://github.com/Jerry-Ma/void_shield_helper) or via the CurseForge comments.
