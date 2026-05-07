# VoidShieldHelper

A lightweight indicator addon for **Discipline Priests** that predicts the probability of your next **Void Shield** proc.

---

## How it works

Void Shield procs follow a phase-based distribution across Penance casts. VoidShieldHelper tracks this pattern with a Phase-State Filter and displays three colour-coded lights:

| Light | Meaning |
|-------|---------|
| **LAST** | Result of your most recent Penance (cyan = proc, red = no proc) |
| **N+1** | Probability that your *next* Penance will proc |
| **N+2** | Probability that the Penance *after that* will proc |

Colour scale: **cyan** (100%) → **green** (≥ 60%) → **yellow** (30–60%) → **orange** (< 30%) → **red** (0%) → **grey** (no data)

A smooth gradient mode is available as an alternative to the discrete colour steps.

---

## Requirements

- Discipline Priest with the **Void Shield** talent
- No other addons required

> **Inspiration:** This addon was inspired by [VoidShieldProc](https://www.curseforge.com/wow/addons/voidshieldproc). VoidShieldHelper uses its own proc detection and does not require VoidShieldProc to be installed.

---

## Usage

`/vsh` — toggle the options panel

Frames appear automatically when logged in as a Discipline Priest with Penance on your action bar. All frames are draggable; positions are saved per character.

---

## Options

- Show/hide the debug window (history, phase state, raw probabilities)
- Lock frames against accidental dragging
- Per-frame scale (0.5× – 2.0×)
- Smooth gradient vs. discrete probability colours
- Per-frame background/border colour, size, and LibSharedMedia texture
- Light square size (main and secondary), spacing, border colour and size

---

## Feedback & bugs

Please report issues on the [GitHub repository](https://github.com/Jerry-Ma/void_shield_helper) or via the CurseForge comments.
