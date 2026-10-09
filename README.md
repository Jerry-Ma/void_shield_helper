# VoidShieldHelper

A lightweight indicator addon for **Discipline Priests** that predicts the probability of your next **Void Shield** proc.

---

## How it works

Void Shield follows a deck mechanic: each group of Penance casts contains exactly one proc. VoidShieldHelper models this with parallel phase trackers (one per possible cycle offset). Each tracker independently maintains a probability distribution over the current group; invalid trackers are pruned as the history grows. The displayed probabilities are averaged across all still-valid trackers.

The mechanic changed in 12.1; the addon detects the client and adapts — one download covers both:

| | 12.0.7 | 12.1 |
|---|---|---|
| Penance deck | 3 casts (33% each) | 4 casts (25% each) |
| Proc charges held | 1 | up to 2 |
| Proc sources | Penance | Penance + Mind Blast |

On 12.1 Mind Blast grants a charge outright — it never turns a deck card, so it doesn't affect the prediction.

### Charge counting (12.1)

12.0 made aura data "secret", so the addon can't read the buff's stack count directly. If **Blizzard's Cooldown Manager** is showing the Void Shield buff, the addon piggybacks on it to know the exact 1-vs-2 charge count, which lets it detect a Penance proc that lands while you already hold a charge. Without it, the count is inferred from your Mind Blast / Void Shield casts, and such a Penance is recorded as *unknown*. The debug window shows the current count and prefixes it with `~` in the fallback mode.

### Forecast lights

| Light | Meaning |
|-------|---------|
| **LAST** | Result of your most recent Penance: cyan = proc, red = no proc, yellow = unknown |
| **N+1** | Probability your *next* Penance will proc |
| **N+2** | Probability the Penance *after that* will proc |

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
- Lock frames against accidental dragging
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
