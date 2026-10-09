# Changelog

## [1.2.0] - 2026-10-09

### 12.1 support
- Requires 12.1 (`## Interface: 120100, 120105`); 12.0.7 is no longer supported.
- Penance deck is 4 casts (25% for the first card, was 3 / 33%). The phase predictor, history block colouring and consistency check use the new deck size.
- Void Shield holds up to 2 charges. The exact count is read from Blizzard's Cooldown Manager when it shows the buff (never reading the secret stack value — only whether its text is secret), so a Penance proc landing on a single held charge is detected instead of recorded as unknown. Otherwise the count is inferred from Mind Blast (+1) and Void Shield casts (−1).
- PW:S proc state now treats any non-proc texture as "no charge" rather than requiring the exact base icon, so a future icon change can't freeze the state.
- The display refreshes immediately when the last charge is spent (`ACTIONBAR_SLOT_CHANGED`) instead of waiting for the next tick.

### Forecast frame
- Four slots, one per card: **status · N+1 · N+2 · N+3**. The LAST-result light is replaced by the status slot.
- The status slot holds one light per charge, stacked opposite to the layout (a column in the horizontal layout, a row in the vertical one).
- At 2 charges with a possible proc on the next Penance, the status lights play Blizzard's action-bar proc glow as a reminder to spend a charge before the proc is wasted.
- New options: slot alignment (start / center / end), separate slot spacing and status stack spacing, and separate texture, size, colours and border for status lights. Options are reorganised into Layout, Prediction and Status tabs.
- Debug window shows the charge count, N+3, and whether the Cooldown Manager is tracking the Void Shield buff; the event log records charges per cast.

Mechanics adapted from [Void Shield Tracker](https://github.com/anozireth/VoidShieldTracker) v2.3.0.

---

## [1.1.2] - 2026-05-08

### Bugfixes
- Fixed nil crash (`bad argument #2 to 'min'`) inside `verifyHistoryBlocks` caused by `predictorHistoryDepth` being declared after the function that captures it as an upvalue.
- History block colouring and the verify label no longer reflect entries from a previous predictor run after a `[reset]` or prune-on-zone-entry.
- `DeckPredictor_pruneToOffset0` now resets phase[1]'s `slotsFilled`, `minSum`, and `maxSum` to 0, preventing stale phase state after a zone-entry prune.
- Auto-recovery replay correctly replays the last `RECOVERY_REPLAY_WINDOW` (4) history entries oldest→newest through a fresh predictor, restoring `predictorHistoryDepth` to the replay count.

---

## [1.1.1] - 2026-05-08

### Detection
- Added **"Prune offsets on zone entry"** option (General → Detection, on by default). When enabled, the two mid-block offset phases are discarded on `PLAYER_ENTERING_WORLD` instead of waiting for natural invalidation. The predictor converges to a single phase immediately, assuming the new instance starts at a clean deck-block boundary.

---

## [1.1.0] - 2026-05-08

### Detection
- Replaced dual-mechanism tracker (mech A debounce + mech B CHANNEL\_START) with a single clean algorithm: `UNIT_SPELLCAST_CHANNEL_START` + configurable delay (default 200 ms).
- PW:S proc detection now re-scans the action bar on login, spec change, talent update, and any `ACTIONBAR_SLOT_CHANGED` event, so the watched slot is never stale after a reload.

### Colour system
- Discrete thresholds changed from 30%/60% to **33%/66%** for evenly-spaced colour bands.
- Smooth gradient stops now sit at the midpoints of each discrete band (not the boundaries), so the gradient and discrete modes show the same representative colour at each probability.
- Both thresholds extracted to `THRESH_LO` / `THRESH_HI` constants — one place to change if values need adjusting in the future.

### Options panel
- Registered in the game's built-in **Addon Settings** panel (ESC → Options → Addon Settings → VoidShieldHelper) with a button that opens the `/vsh` panel — same pattern as Twintop's Resource Bar.
- Tabs renamed: **Forecast → Frame**, **Lights → Indicators**.
- Scale sliders renamed: **Forecast Scale → Indicator Frame Scale**, **Debug Scale → Debug Window Scale**.
- Colour legend swatches replaced with a live **gradient preview bar** showing the full 0–100% colour ramp with threshold markers and axis labels; updates instantly when toggling smooth/discrete mode.
- Panel height increased to 490 px to prevent the `/vsh to toggle` hint from overlapping the preview bar.
- Fixed mangled UTF-8 arrow character in the preview label.

### Debug window
- Fixed text overlap: `[checking…]` status is now embedded inline in the shield status line instead of occupying a separate row.
- PW:S slot label shortened to prevent wrapping.
- Added a dim **"/vsh to open options"** hint at the bottom-right corner.

---

## [1.0.0] - 2025

Initial release.
- Void Shield deck-mechanic predictor for Discipline Priests.
- Three-phase parallel tracker with probability averaging.
- Forecast indicator frame (LAST / N+1 / N+2 lights).
- Debug window with cast history, phase state, and raw probabilities.
- Options panel accessible via `/vsh`.
