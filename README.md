# VoidShieldHelper

A lightweight helper addon for **Discipline Priests** that tracks Penance casts and predicts the likelihood of your next **Void Shield** proc.

---

## What it does

Every third Penance cast has a chance to proc Void Shield, but the exact pattern isn't purely random — it follows a phase-based distribution. VoidShieldHelper tracks this pattern in real time and displays colour-coded probability lights so you always know whether your next Penance is likely to proc.

### Forecast lights

Three small indicator lights are shown on screen:

| Light | Meaning |
|-------|---------|
| **LAST** | Result of your most recent Penance (cyan = proc, red = no proc, yellow = unknown) |
| **N+1** | Probability that your *next* Penance will proc |
| **N+2** | Probability that the Penance *after that* will proc |

Colour scale: **cyan** (100%) → **green** (≥ 60%) → **yellow** (30–60%) → **orange** (< 30%) → **red** (0%) → **grey** (not enough data yet)

---

## Requirements

- **[VoidShieldProc](https://www.curseforge.com/wow/addons/voidshieldproc)** — VoidShieldHelper relies on this companion addon to detect Void Shield procs accurately. Install both addons together.
- The Void Shield talent must be active on your Discipline Priest.

---

## Usage

| Command | Action |
|---------|--------|
| `/vsh` | Toggle the options panel |

The forecast frame and debug frame appear automatically when you are logged in as a Discipline Priest and Penance is on your action bar.

---

## Options panel (`/vsh`)

- **Show Debug Window** — displays a detailed readout of history, phase state, and raw probabilities
- **Lock Frames** — prevents accidental dragging of the forecast and debug windows
- **Forecast / Debug Scale** — resize each frame independently (0.5× – 2.0×)

**Forecast Frame appearance**
- Background colour with alpha
- Border colour with alpha and configurable pixel border size (0 = hidden)
- Background texture (any texture registered with LibSharedMedia)
- Light square texture (any statusbar texture registered with LibSharedMedia)

**Debug Frame appearance**
- Same independent background/border controls as the Forecast Frame

All frames are freely draggable. Positions are saved per character.

---

## How the prediction works

VoidShieldHelper runs a **Phase-State Filter** — three parallel phase trackers (offset 0, 1, 2) that each maintain a probability distribution over the Void Shield proc cycle. After every Penance result the model is updated, invalid phases are pruned, and the weighted probabilities for the next one or two casts are displayed. The model self-resets if it detects an inconsistent history.

---

## Installation

1. Install **VoidShieldProc** from CurseForge.
2. Install **VoidShieldHelper** from CurseForge (or drop the folder into `Interface/AddOns/`).
3. Log in on a Discipline Priest with the Void Shield talent.

---

## Feedback & bugs

Please report issues on the [GitHub repository](https://github.com/Jerry-Ma/void_shield_helper) or via the CurseForge comments.
