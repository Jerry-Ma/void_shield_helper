# Changelog

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
