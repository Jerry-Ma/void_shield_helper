# VoidShieldHelper

A lightweight indicator addon for **Discipline Priests** that predicts the probability of your next **Void Shield** proc.

---

## How it works

Void Shield follows a deck mechanic: each group of 3 Penance casts contains exactly one proc. VoidShieldHelper models this with three parallel phase trackers (one per possible cycle offset). Each tracker independently maintains a probability distribution over the current group; invalid trackers are pruned as the history grows. The displayed probabilities are averaged across all still-valid trackers.

### Forecast lights

| Light | Meaning |
|-------|---------|
| **LAST** | Result of your most recent Penance: cyan = proc, red = no proc, yellow = unknown |
| **N+1** | Probability your *next* Penance will proc |
| **N+2** | Probability the Penance *after that* will proc |

Colour scale: **cyan** (100% — will proc) → **green** (≥ 60%) → **yellow** (≥ 30%) → **orange** (< 30%) → **red** (0% — won't proc) → **grey** (not enough data)

A smooth gradient mode is available as an alternative to discrete colour steps.

---

## Usage

`/vsh` — toggle the options panel

Frames appear automatically when logged in as a Discipline Priest with Penance on your action bar. All frames are draggable; positions are saved per character.

> **Action bar requirement:** Proc detection works by watching the Power Word: Shield button icon on your action bars. **Power Word: Shield must be placed directly from the spellbook onto an action bar** — a macro that casts PW:S will not work. If you use macros for PW:S, enable an extra action bar and place the raw spell in any empty slot there; it does not need to be visible or on your main bars.

---

## Options

- Show/hide the debug window (cast history, phase state, raw probabilities)
- Lock frames against accidental dragging
- Per-frame scale (0.5× – 2.0×)
- Smooth gradient vs. discrete probability colours
- Per-frame background/border colour, size, and LibSharedMedia texture
- Light square size (main and secondary), spacing, border colour and size

---

## Acknowledgements

- Proc detection approach inspired by [Void Shield Proc Tracker](https://www.curseforge.com/wow/addons/void-shield-proc-tracker).
- Void Shield deck mechanic explained in [this video](https://www.youtube.com/watch?v=X1Od3Ovp2i0).

---

## Feedback & bugs

Please report issues on the [GitHub repository](https://github.com/Jerry-Ma/void_shield_helper) or via the CurseForge comments.
