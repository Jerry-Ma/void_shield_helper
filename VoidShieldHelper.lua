local ADDON_NAME = ...

-- Global table shared with VoidShieldHelper_Options.lua
VSH = VSH or {}

-- ─── Constants ───────────────────────────────────────────────────────────────

-- Penance spell IDs fired via UNIT_SPELLCAST_SUCCEEDED.
-- Both IDs are tracked; a 2-second debounce prevents multi-bolt double-counting.
local PENANCE_SPELL_IDS = {
    [47540] = true,  -- Penance
    [47666] = true,  -- Penance (alternate ID)
}

-- Power Word: Shield action-button textures.
-- BASE_SLOT_TEXTURE  : normal / not-procced PW:S icon
-- PROC_SLOT_TEXTURE  : Void Shield proc overlay (Borrowed Time / Rapture proc)
local BASE_SLOT_TEXTURE = 135940
local PROC_SLOT_TEXTURE = 7514191

-- Spell IDs for Power Word: Shield on the action bar (used to find the watch slot).
local PW_SHIELD_SPELL_IDS = {
    [17]      = true,  -- Power Word: Shield (base)
    [1253593] = true,  -- Power Word: Shield (proc / Void Shield variant)
}

local ACTION_BUTTON_PREFIXES = {
    "ActionButton",
    "MultiActionBar1Button",
    "MultiActionBar2Button",
    "MultiActionBar3Button",
    "MultiActionBar4Button",
}

-- How long after a penance UNIT_SPELLCAST_SUCCEEDED we wait before reading the
-- action-button texture to determine if a proc happened.
local PROC_CHECK_DELAY  = 0.2   -- seconds
-- Minimum gap between two counted penance casts (guards against multi-bolt events).
local PENANCE_DEBOUNCE  = 2.0   -- seconds
-- How many penance results to keep in the rolling history.
-- How many penance results to keep in the rolling log (purely for display).
-- No game-mechanic reason to cap this; just controls memory used by the table.
local MAX_HISTORY         = 30
-- How many of those entries to render in the debug frame (limited by frame height).
local MAX_DISPLAY_HISTORY = 9

-- Result constants
local RESULT_PROC     = "PROC"
local RESULT_NO_PROC  = "NO_PROC"
local RESULT_UNKNOWN  = "UNKNOWN"   -- shield was already up at cast time

-- ─── Deck predictor (Phase-State Filter) ────────────────────────────────────
-- Models the "sampling without replacement" deck mechanic:
-- every 3 Penance casts contain exactly one Void Shield proc.
-- Three phases run in parallel to handle unknown deck-start offsets.
--
-- Input values: 1 = PROC, 0 = NO_PROC, -1 = UNKNOWN (shield was already up)

local function DeckPredictor_new()
    -- Each phase represents a possible deck-start offset (0, 1, or 2 casts into a block).
    -- Casts before tracking began are injected as virtual unknowns (-1) so that the
    -- preceding partial block is handled correctly without special-casing.
    --
    -- offset=0: first cast is slot 0 of a new block  → 0 virtual unknowns
    -- offset=1: first cast is slot 2 of preceding block → 2 virtual unknowns
    -- offset=2: first cast is slot 1 of preceding block → 1 virtual unknown
    -- Formula: virtualSlots = (3 - offset) % 3
    local phases = {}
    for offset = 0, 2 do
        local v = (3 - offset) % 3   -- virtual unknown slots to pre-inject
        phases[offset + 1] = {
            isValid     = true,
            minSum      = 0,  -- confirmed procs in current block
            maxSum      = v,  -- virtual unknowns pre-injected as -1
            slotsFilled = v,  -- slots already consumed by virtual unknowns
        }
    end
    return { phases = phases }
end

local function DeckPredictor_update(self, val)
    for _, p in ipairs(self.phases) do
        -- Invariant: isValid is monotone-decreasing (set to false, never back to true).
        -- Skipping invalid phases here is a performance optimisation, not a correctness
        -- requirement; the update logic below never sets isValid back to true.
        if p.isValid then
            if val == 1 then
                p.minSum = p.minSum + 1
                p.maxSum = p.maxSum + 1
            elseif val == -1 then
                p.maxSum = p.maxSum + 1
            end

            if p.minSum > 1 then
                -- Too many confirmed procs in this block.
                p.isValid = false
            elseif p.slotsFilled == 2 then
                -- End of block: the block must have been able to contain exactly one proc.
                if p.maxSum == 0 then
                    p.isValid = false
                end
                p.minSum      = 0
                p.maxSum      = 0
                p.slotsFilled = 0
            else
                p.slotsFilled = p.slotsFilled + 1
            end
        end
    end
end

--- Returns nil, 0 if all phases have been invalidated (sequence violates the model).
local function DeckPredictor_getProb(self)
    local validPhases = {}
    for _, p in ipairs(self.phases) do
        if p.isValid then
            validPhases[#validPhases + 1] = p
        end
    end
    if #validPhases == 0 then return nil, 0 end

    local totalP = 0
    for _, p in ipairs(validPhases) do
        local remaining = 3 - p.slotsFilled
        local probPhi
        if p.minSum == 1 then
            probPhi = 0
        else
            local numUnknowns = p.maxSum - p.minSum
            probPhi = 1.0 / (numUnknowns + remaining)
        end
        totalP = totalP + probPhi
    end
    return totalP / #validPhases, #validPhases
end

--- Compute proc probability for a phase described by (sf, minS, maxS).
--- Returns 0 for impossible/invalid states.
local function probForState(sf, minS, maxS)
    if minS == 1 then return 0 end
    local numUnknowns = maxS - minS
    local remaining   = 3 - sf
    return 1.0 / (numUnknowns + remaining)
end

--- Advance a phase state by consuming one cast with value val (1 or 0).
--- Returns new (sf, minS, maxS, isValid).
local function advanceState(sf, minS, maxS, val)
    local newMin = minS + (val == 1 and 1 or 0)
    local newMax = maxS + (val == 1 and 1 or 0)
    if newMin > 1 then return 0, 0, 0, false end  -- too many procs
    if sf == 2 then
        if newMax == 0 then return 0, 0, 0, false end  -- block ended with no proc possible
        return 0, 0, 0, true   -- block resets cleanly
    end
    return sf + 1, newMin, newMax, true
end

--- Returns the probability that the cast AFTER the next one will proc,
--- averaged across all currently valid phases.
--- Returns nil if no valid phases exist.
local function DeckPredictor_getProbNextNext(self)
    local validPhases = {}
    for _, p in ipairs(self.phases) do
        if p.isValid then validPhases[#validPhases + 1] = p end
    end
    if #validPhases == 0 then return nil end

    local totalP = 0
    for _, p in ipairs(validPhases) do
        local sf, minS, maxS = p.slotsFilled, p.minSum, p.maxSum
        local p1 = probForState(sf, minS, maxS)  -- P(N+1 = proc)
        local p0 = 1 - p1                         -- P(N+1 = no-proc)

        local prob2 = 0
        -- Branch: N+1 is a proc
        if p1 > 0 then
            local sf1, min1, max1, valid1 = advanceState(sf, minS, maxS, 1)
            if valid1 then
                prob2 = prob2 + p1 * probForState(sf1, min1, max1)
            end
        end
        -- Branch: N+1 is not a proc
        if p0 > 0 then
            local sf0, min0, max0, valid0 = advanceState(sf, minS, maxS, 0)
            if valid0 then
                prob2 = prob2 + p0 * probForState(sf0, min0, max0)
            end
        end

        totalP = totalP + prob2
    end
    return totalP / #validPhases
end

-- ─── Saved variables ─────────────────────────────────────────────────────────

VoidShieldHelperDB = VoidShieldHelperDB or {}

-- ─── Runtime state ───────────────────────────────────────────────────────────

local isDiscPriest             = false

local watchSlot                = nil    -- cached action-bar slot for PW:S
local iterationsUntilSlotRefresh = 0

local shieldActive             = false  -- true when PROC_SLOT_TEXTURE is visible

local pendingCheck             = false  -- true while waiting for PROC_CHECK_DELAY
local shieldActiveOnCast       = false  -- snapshot of shieldActive at penance cast
local lastPenanceTime          = 0      -- time of last counted penance cast

-- plain result strings (RESULT_PROC / RESULT_NO_PROC / RESULT_UNKNOWN), newest first
local penanceHistory           = {}

--- Returns nil if every complete block in history has at most 1 PROC (consistent),
--- or a string describing the first offending block (inconsistent).
--- Only meaningful when the predictor has converged to a single phase.
--- UNKNOWN entries count as 0 procs (worst-case assumption for this check).
local function verifyHistoryBlocks(convergedPhaseOffset)
    local n = #penanceHistory
    if n == 0 then return nil end

    -- virtualUnknowns = slots before the first real cast in the first partial block.
    local virtualUnknowns = (3 - convergedPhaseOffset) % 3

    -- Count PROCs per block.  History is newest-first, so we walk it backwards
    -- (index n = oldest cast, index 1 = newest cast).
    local blockProcs = {}
    for histIdx = n, 1, -1 do
        local castIdx  = n - histIdx              -- 0-based, oldest = 0
        local absSlot  = castIdx + virtualUnknowns
        local blockIdx = math.floor(absSlot / 3)  -- 0-based block number

        if penanceHistory[histIdx] == RESULT_PROC then
            blockProcs[blockIdx] = (blockProcs[blockIdx] or 0) + 1
            if blockProcs[blockIdx] > 1 then
                return string.format("|cffff4444INCONSISTENT: block %d has %d procs|r",
                    blockIdx + 1, blockProcs[blockIdx])
            end
        end
    end
    return nil  -- all checked blocks are consistent
end

local predictor                = DeckPredictor_new()
local predictorBreakCount      = 0   -- how many times the predictor auto-reset due to a broken sequence

local debugFrame               = nil
local forecastFrame            = nil
local ticker                   = nil

-- ─── Forward declarations ────────────────────────────────────────────────────

local updateDebugDisplay
local updateForecastDisplay

-- ─── Texture scanning ────────────────────────────────────────────────────────

--- Scan all action bars for a PW:S texture and return it if found.
local function scanBarTexture()
    for _, prefix in ipairs(ACTION_BUTTON_PREFIXES) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and btn.icon then
                local tex = btn.icon:GetTexture()
                if tex == PROC_SLOT_TEXTURE then return PROC_SLOT_TEXTURE end
                if tex == BASE_SLOT_TEXTURE  then return BASE_SLOT_TEXTURE  end
            end
        end
    end
end

--- Return the current action-button texture for PW:S, preferring the cached slot.
local function getCurrentSlotTexture()
    if watchSlot then
        local tex = GetActionTexture(watchSlot)
        if tex then return tex end
    end
    return scanBarTexture()
end

--- Find and cache the action-bar slot that holds Power Word: Shield.
local function refreshWatchSlot()
    for slot = 1, 180 do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and PW_SHIELD_SPELL_IDS[id] then
            watchSlot = slot
            return
        end
    end
    watchSlot = nil
end

-- ─── Spec detection ──────────────────────────────────────────────────────────

local function updateSpecState()
    local _, class = UnitClass("player")
    local spec     = GetSpecialization()
    isDiscPriest   = (class == "PRIEST" and spec == 1)
end

-- ─── Shield state polling ────────────────────────────────────────────────────

--- Update shieldActive from the current action-button texture.
local function pollShieldState()
    local tex = getCurrentSlotTexture()
    if tex == PROC_SLOT_TEXTURE then
        shieldActive = true
    elseif tex == BASE_SLOT_TEXTURE then
        shieldActive = false
    end
    -- If tex is nil/unknown we keep the last known state.
end

-- ─── Penance cast handling ───────────────────────────────────────────────────

--- Push a result onto the history and refresh the debug display.
local function recordResult(result)
    table.insert(penanceHistory, 1, result)
    if #penanceHistory > MAX_HISTORY then
        penanceHistory[#penanceHistory] = nil
    end
    local val = result == RESULT_PROC and 1 or (result == RESULT_NO_PROC and 0 or -1)
    DeckPredictor_update(predictor, val)
    -- Auto-recover: if every phase was just killed the observed sequence
    -- violated the deck model (can happen with many UNKNOWNs or a genuine
    -- mechanic edge case).  Reset the predictor and re-feed this result as
    -- the first cast of a new predictor — it is still valid information.
    local prob = DeckPredictor_getProb(predictor)
    if prob == nil then
        predictorBreakCount = predictorBreakCount + 1
        predictor = DeckPredictor_new()
        DeckPredictor_update(predictor, val)
    end
    updateDebugDisplay()
    updateForecastDisplay()
end

--- Called once per logical penance cast (debounced).
-- Snapshots the current shield state, then after a short delay reads the
-- texture again to classify the cast as PROC / NO_PROC / UNKNOWN.
--
-- State machine:
--   Case 1: shield was INACTIVE → cast → shield now ACTIVE   → PROC
--   Case 2: shield was ACTIVE   → cast → (any state)         → UNKNOWN
--   Case 3: shield was INACTIVE → cast → shield still INACTIVE → NO_PROC
local function onPenanceCast()
    local now = GetTime()
    if now - lastPenanceTime < PENANCE_DEBOUNCE then return end
    lastPenanceTime = now

    -- Snapshot shield state at the moment of the cast.
    pollShieldState()
    shieldActiveOnCast = shieldActive
    pendingCheck       = true
    updateDebugDisplay()

    C_Timer.After(PROC_CHECK_DELAY, function()
        if not pendingCheck then return end
        pendingCheck = false

        pollShieldState()

        local result
        if shieldActiveOnCast then
            -- Shield was already up; impossible to tell if a new proc landed.
            result = RESULT_UNKNOWN
        elseif shieldActive then
            -- Shield was down, now it's up → proc triggered.
            result = RESULT_PROC
        else
            -- Shield was down and is still down → no proc.
            result = RESULT_NO_PROC
        end

        recordResult(result)
    end)
end
-- ─── Forecast UI ─────────────────────────────────────────────────────────────
-- Three lights: [last cast result] [N+1 probability] [N+2 probability]
-- N+1 is the primary indicator (full size); LAST and N+2 are smaller.
-- Lights are bottom-aligned.

local LIGHT_SIZE_MAIN  = 24   -- N+1 (next cast)
local LIGHT_SIZE_SMALL = 16   -- LAST and N+2
local LIGHT_GAP        = 14

local function createForecastFrame()
    local sizes   = { LIGHT_SIZE_SMALL, LIGHT_SIZE_MAIN, LIGHT_SIZE_SMALL }
    -- total width of all three lights + gaps between them
    local totalLightsW = sizes[1] + LIGHT_GAP + sizes[2] + LIGHT_GAP + sizes[3]  -- 16+14+24+14+16 = 84
    local frameW  = totalLightsW + 24   -- 108
    local frameH  = LIGHT_SIZE_MAIN + 16

    -- Y top-edge offsets so all lights align on their bottom edges
    -- N+1 bottom at -8-MAIN; LAST/N+2 bottom at same y, so top = bottom + SMALL
    local bottomY = -(8 + LIGHT_SIZE_MAIN)  -- shared bottom edge (relative to frame top)
    local topOffsets = { bottomY + LIGHT_SIZE_SMALL, -8, bottomY + LIGHT_SIZE_SMALL }
    -- startX = (frameW - totalLightsW) / 2 = 12
    local xOffsets = { 12, 12 + sizes[1] + LIGHT_GAP, 12 + sizes[1] + LIGHT_GAP + sizes[2] + LIGHT_GAP }

    local f = CreateFrame("Frame", "VoidShieldHelperForecastFrame", UIParent, "BackdropTemplate")
    f:SetSize(frameW, frameH)

    if VoidShieldHelperDB.forecastPos then
        local p = VoidShieldHelperDB.forecastPos
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        f:SetPoint("CENTER", 0, 100)
    end

    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1, tile = true, tileSize = 16,
    })
    f:SetBackdropColor(0, 0, 0, 0.80)
    f:SetBackdropBorderColor(0.32, 0.32, 0.32, 1)

    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        VoidShieldHelperDB.forecastPos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    f.lights = {}
    f.glows  = {}

    for i = 1, 3 do
        local sz   = sizes[i]
        local xOff = xOffsets[i]
        local yOff = topOffsets[i]

        -- Light square (ARTWORK)
        local light = f:CreateTexture(nil, "ARTWORK")
        light:SetSize(sz, sz)
        light:SetPoint("TOPLEFT", f, "TOPLEFT", xOff, yOff)
        light:SetColorTexture(0.3, 0.3, 0.3, 1)
        f.lights[i] = light

        -- placeholder glow slot (unused but keeps index parity with applyLight)
        f.glows[i] = nil
    end

    f:Show()
    return f
end

local function probColor(prob)
    if prob == nil then return 0.4, 0.4, 0.4 end
    if prob >= 1.0  then return 0.0, 0.9, 0.9 end   -- cyan: guaranteed proc
    if prob <= 0.0  then return 0.9, 0.2, 0.2 end   -- red: guaranteed no-proc
    local pct = prob * 100
    if pct >= 60 then return 0.1, 0.9, 0.1          -- green
    elseif pct >= 30 then return 0.9, 0.9, 0.1       -- yellow
    else return 1.0, 0.5, 0.0 end                    -- orange: low probability
end

local function applyLight(light, r, g, b)
    if light._useTex then
        -- Texture set by applySettings — tint with vertex color
        light:SetVertexColor(r, g, b, 1)
    else
        light:SetColorTexture(r, g, b, 1)
    end
end

updateForecastDisplay = function()
    if not forecastFrame then return end

    local prob1 = DeckPredictor_getProb(predictor)
    local prob2 = DeckPredictor_getProbNextNext(predictor)

    -- Light 1 (LAST): cyan = proc, red = no-proc, grey = no data; UNKNOWN not expected
    local lastResult = penanceHistory[1]
    local lr, lg, lb
    if lastResult == RESULT_PROC then
        lr, lg, lb = 0.0, 0.9, 0.9   -- cyan
    elseif lastResult == RESULT_NO_PROC then
        lr, lg, lb = 0.9, 0.2, 0.2   -- red
    elseif lastResult == RESULT_UNKNOWN then
        lr, lg, lb = 0.9, 0.9, 0.1   -- yellow (fallback)
    else
        lr, lg, lb = 0.3, 0.3, 0.3   -- no data
    end
    applyLight(forecastFrame.lights[1], lr, lg, lb)

    -- Light 2 (N+1): probability color (cyan at 100%)
    applyLight(forecastFrame.lights[2], probColor(prob1))

    -- Light 3 (N+2): probability color (cyan at 100%)
    applyLight(forecastFrame.lights[3], probColor(prob2))
end
-- ─── Debug UI ────────────────────────────────────────────────────────────────

local RESULT_COLOR = {
    [RESULT_PROC]    = "|cff00ff00",   -- green
    [RESULT_NO_PROC] = "|cffff4444",   -- red
    [RESULT_UNKNOWN] = "|cffffff00",   -- yellow
}

local function createDebugFrame()
    local f = CreateFrame("Frame", "VoidShieldHelperDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(240, 312)

    if VoidShieldHelperDB.pos then
        local p = VoidShieldHelperDB.pos
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        f:SetPoint("CENTER", 0, 200)
    end

    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1, tile = true, tileSize = 16,
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
    f:SetBackdropBorderColor(0.32, 0.32, 0.32, 1)

    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        VoidShieldHelperDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetText("VoidShield Helper")

    -- Current shield status line
    local statusLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30)
    statusLabel:SetText("Shield:")
    f.statusLabel = statusLabel

    local statusVal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusVal:SetPoint("LEFT", statusLabel, "RIGHT", 6, 0)
    f.statusVal = statusVal

    -- Pending indicator
    local pendingLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pendingLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -46)
    pendingLabel:SetText("")
    f.pendingLabel = pendingLabel

    -- Deck prediction probability
    local probLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    probLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -62)
    probLabel:SetWidth(220)
    probLabel:SetJustifyH("LEFT")
    probLabel:SetText("Next proc: —")
    f.probLabel = probLabel

    -- Phase / break info (second line under prob)
    local phaseLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    phaseLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -78)
    phaseLabel:SetWidth(220)
    phaseLabel:SetJustifyH("LEFT")
    phaseLabel:SetText("")
    f.phaseLabel = phaseLabel

    -- History verification (shown when phase converged)
    local verifyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    verifyLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -94)
    verifyLabel:SetWidth(220)
    verifyLabel:SetJustifyH("LEFT")
    verifyLabel:SetText("")
    f.verifyLabel = verifyLabel

    -- History section header
    local histHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    histHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -110)
    histHeader:SetText("Penance history (newest first):")

    -- History entry lines
    f.histLines = {}
    for i = 1, MAX_DISPLAY_HISTORY do
        local line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -110 - (i * 18))
        line:SetWidth(212)
        line:SetJustifyH("LEFT")
        line:SetText(string.format("#%d: —", i))
        f.histLines[i] = line
    end

    f:Show()
    return f
end

-- updateDebugDisplay is called from multiple places; defined here after the
-- frame creation helpers so it can reference them.
updateDebugDisplay = function()
    if not debugFrame then return end

    -- Shield status
    if shieldActive then
        debugFrame.statusVal:SetText("|cff00ff00ACTIVE|r")
    else
        debugFrame.statusVal:SetText("|cffff4444INACTIVE|r")
    end

    -- Pending indicator
    if pendingCheck then
        debugFrame.pendingLabel:SetText("|cffffff00waiting for texture check...|r")
    else
        debugFrame.pendingLabel:SetText("")
    end

    -- Prediction probability
    local prob, validCount = DeckPredictor_getProb(predictor)
    local prob2            = DeckPredictor_getProbNextNext(predictor)
    -- prob == nil should not occur here because recordResult auto-resets on break,
    -- but guard defensively anyway.
    if prob == nil then
        debugFrame.probLabel:SetText("|cffff8800Next proc: recovering...|r")
        debugFrame.phaseLabel:SetText("")
    else
        local function pctColor(p)
            local pct = math.floor(p * 100 + 0.5)
            local c
            if pct >= 60 then c = "|cff00ff00"
            elseif pct >= 30 then c = "|cffffff00"
            else c = "|cffff4444" end
            return pct, c
        end
        local pct1, c1 = pctColor(prob)
        local phaseWord  = validCount == 1 and "phase" or "phases"
        local breakSuffix = predictorBreakCount > 0
            and string.format(" |cffff8800[reset x%d]|r", predictorBreakCount)
            or ""
        local next2Str = ""
        if prob2 then
            local pct2, c2 = pctColor(prob2)
            next2Str = string.format("  N+2:%s%d%%|r", c2, pct2)
        end
        debugFrame.probLabel:SetText(string.format(
            "N+1:%s%d%%|r%s",
            c1, pct1, next2Str
        ))
        debugFrame.phaseLabel:SetText(string.format(
            "|cff888888[%d %s]|r%s",
            validCount, phaseWord, breakSuffix
        ))
    end

    -- Determine which phase is the sole survivor (for position highlighting).
    -- When validCount == 1 the converged phase tells us which deck-slot each
    -- historical cast occupied, so we colour the #N label by slot alignment.
    -- phases[1]=offset0, phases[2]=offset1, phases[3]=offset2 (by construction).
    local convergedPhaseOffset = nil
    if validCount == 1 then
        for idx, p in ipairs(predictor.phases) do
            if p.isValid then
                convergedPhaseOffset = idx - 1  -- 0, 1, or 2
                break
            end
        end
    end

    -- History verification line (only when converged)
    if convergedPhaseOffset then
        local warn = verifyHistoryBlocks(convergedPhaseOffset)
        if warn then
            debugFrame.verifyLabel:SetText(warn)
        else
            debugFrame.verifyLabel:SetText("|cff00ff00History OK|r")
        end
    else
        debugFrame.verifyLabel:SetText("")
    end

    -- Two alternating colours, one per block (even/odd block index).
    local BLOCK_COLORS = {
        "|cffffd700",   -- even blocks (gold)
        "|cff88ccff",   -- odd  blocks (light blue)
    }

    -- History
    for i = 1, MAX_DISPLAY_HISTORY do
        local result = penanceHistory[i]
        if result then
            local resultColor = RESULT_COLOR[result] or "|cffffffff"
            local indexLabel
            if convergedPhaseOffset then
                local n          = #penanceHistory
                local castIdx    = n - i                                    -- 0-based, oldest = 0
                local virtualU   = (3 - convergedPhaseOffset) % 3
                local blockIdx   = math.floor((castIdx + virtualU) / 3)     -- 0-based block number
                local blockColor = BLOCK_COLORS[(blockIdx % 2) + 1]
                indexLabel = string.format("%s#%d|r", blockColor, i)
            else
                indexLabel = string.format("|cff888888#%d|r", i)
            end
            debugFrame.histLines[i]:SetText(string.format("%s: %s%s|r", indexLabel, resultColor, result))
        else
            debugFrame.histLines[i]:SetText(string.format("|cff888888#%d: —|r", i))
        end
    end
end

-- ─── Frame settings (scale / lock / backdrop) ───────────────────────────────

local function applySettings()
    local db = VoidShieldHelperDB
    if not db then return end

    -- Scale
    if forecastFrame then forecastFrame:SetScale(db.forecastScale or 1.0) end
    if debugFrame    then debugFrame:SetScale(db.debugScale or 1.0) end

    -- Show / hide debug window
    if debugFrame then
        if db.hideDebug then
            debugFrame:Hide()
        elseif isDiscPriest and ticker then
            debugFrame:Show()
        end
    end

    -- Lock / unlock dragging
    local locked = db.locked or false
    for _, f in ipairs({ forecastFrame, debugFrame }) do
        if f then
            f:SetMovable(not locked)
            f:EnableMouse(not locked)
        end
    end

    -- LSM texture resolver (statusbar type = clean textures, no border artefacts)
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    local function resolveTexPath(name)
        if name and name ~= "" and LSM then
            local p = LSM:Fetch("statusbar", name, true)
            if p then return p end
        end
        return "Interface\\Buttons\\WHITE8x8"
    end

    -- Pixel-perfect backdrop helper (WHITE8x8 edge = 1-px solid border, no corner art)
    local function applyBackdrop(frame, texName, r, g, b, a, bSize, br, bg_, bb, ba)
        frame:SetBackdrop({
            bgFile   = resolveTexPath(texName),
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = math.max(1, bSize),
            tile = true, tileSize = 16,
        })
        frame:SetBackdropColor(r, g, b, a)
        frame:SetBackdropBorderColor(br, bg_, bb, (bSize > 0) and (ba or 1) or 0)
    end

    if forecastFrame then
        applyBackdrop(forecastFrame,
            db.backdropBg,
            db.bgColorR or 0, db.bgColorG or 0, db.bgColorB or 0, db.bgColorA or 0.82,
            db.borderSize or 1,
            db.borderColorR or 0.32, db.borderColorG or 0.32, db.borderColorB or 0.32, db.borderColorA or 1)
    end
    if debugFrame then
        applyBackdrop(debugFrame,
            db.debugBgTex,
            db.debugBgR or 0, db.debugBgG or 0, db.debugBgB or 0, db.debugBgA or 0.82,
            db.debugBorderSize or 1,
            db.debugBorderR or 0.32, db.debugBorderG or 0.32, db.debugBorderB or 0.32, db.debugBorderA or 1)
    end

    -- Light square texture
    local lightTexPath = nil
    if LSM and db.lightTexName and db.lightTexName ~= "" then
        lightTexPath = LSM:Fetch("statusbar", db.lightTexName)
    end
    if forecastFrame and forecastFrame.lights then
        for _, light in ipairs(forecastFrame.lights) do
            if lightTexPath then
                light:SetTexture(lightTexPath)
                -- reset vertex color to white so the texture shows as-is
                light:SetVertexColor(1, 1, 1, 1)
                light._useTex = true
            else
                light:SetTexture(nil)
                light._useTex = false
            end
        end
    end
end

VSH.applySettings = function() applySettings() end

-- ─── Ticker ──────────────────────────────────────────────────────────────────

local function tickUpdate()
    -- Periodically refresh the watched action-bar slot.
    iterationsUntilSlotRefresh = iterationsUntilSlotRefresh - 1
    if iterationsUntilSlotRefresh <= 0 then
        refreshWatchSlot()
        iterationsUntilSlotRefresh = 10  -- ~every 1 s at 0.1 s tick
    end

    local prevShieldActive = shieldActive
    pollShieldState()
    -- Only redraw when the shield state actually changed; avoids spamming
    -- font-string writes every 100 ms during idle play.
    if shieldActive ~= prevShieldActive then
        updateDebugDisplay()
        updateForecastDisplay()
    end
end

local function stopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    if debugFrame and debugFrame:IsShown() then debugFrame:Hide() end
    if forecastFrame and forecastFrame:IsShown() then forecastFrame:Hide() end
end

local function startTicker()
    if not isDiscPriest then return end
    if ticker then return end
    if forecastFrame and not forecastFrame:IsShown() then forecastFrame:Show() end
    local hideDbg = VoidShieldHelperDB and VoidShieldHelperDB.hideDebug
    if debugFrame and not hideDbg and not debugFrame:IsShown() then debugFrame:Show() end
    ticker = C_Timer.NewTicker(0.1, tickUpdate)
end

-- ─── Reset helpers ───────────────────────────────────────────────────────────

--- Full state reset (instance transitions reset the shuffle deck).
local function resetState()
    penanceHistory             = {}
    predictor                  = DeckPredictor_new()
    predictorBreakCount        = 0
    shieldActive               = false
    pendingCheck               = false
    shieldActiveOnCast         = false
    lastPenanceTime            = 0
    watchSlot                  = nil
    iterationsUntilSlotRefresh = 0
end

-- ─── Event handler ───────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        VoidShieldHelperDB = VoidShieldHelperDB or {}
        local db = VoidShieldHelperDB
        -- Initialise defaults for new fields
        if db.locked        == nil then db.locked        = false end
        if db.hideDebug     == nil then db.hideDebug     = false end
        db.forecastScale  = db.forecastScale  or 1.0
        db.debugScale     = db.debugScale     or 1.0
        db.backdropBg     = db.backdropBg     or ""
        if db.bgColorR    == nil then db.bgColorR    = 0    end
        if db.bgColorG    == nil then db.bgColorG    = 0    end
        if db.bgColorB    == nil then db.bgColorB    = 0    end
        if db.bgColorA    == nil then db.bgColorA    = 0.82 end
        db.lightTexName   = db.lightTexName   or ""
        if db.borderSize     == nil then db.borderSize     = 1    end
        if db.borderColorR   == nil then db.borderColorR   = 0.32 end
        if db.borderColorG   == nil then db.borderColorG   = 0.32 end
        if db.borderColorB   == nil then db.borderColorB   = 0.32 end
        if db.borderColorA   == nil then db.borderColorA   = 1    end
        -- Debug frame appearance (independent from forecast frame)
        if db.debugBgTex      == nil then db.debugBgTex      = "" end
        if db.debugBgR        == nil then db.debugBgR        = 0    end
        if db.debugBgG        == nil then db.debugBgG        = 0    end
        if db.debugBgB        == nil then db.debugBgB        = 0    end
        if db.debugBgA        == nil then db.debugBgA        = 0.82 end
        if db.debugBorderSize == nil then db.debugBorderSize = 1    end
        if db.debugBorderR    == nil then db.debugBorderR    = 0.32 end
        if db.debugBorderG    == nil then db.debugBorderG    = 0.32 end
        if db.debugBorderB    == nil then db.debugBorderB    = 0.32 end
        if db.debugBorderA    == nil then db.debugBorderA    = 1    end

        debugFrame    = createDebugFrame()
        forecastFrame = createForecastFrame()
        applySettings()
        updateSpecState()
        updateDebugDisplay()
        updateForecastDisplay()

        -- Slash command: /vsh toggles the options panel
        SLASH_VOIDSHIELDHELPER1 = "/vsh"
        SlashCmdList["VOIDSHIELDHELPER"] = function()
            if VSH.toggleOptions then VSH.toggleOptions() end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Deck resets on entering an instance or the world.
        stopTicker()
        resetState()
        updateSpecState()
        startTicker()
        updateDebugDisplay()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if unit ~= "player" then return end
        stopTicker()
        resetState()
        updateSpecState()
        startTicker()
        updateDebugDisplay()

    elseif event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        stopTicker()
        resetState()
        updateSpecState()
        startTicker()
        updateDebugDisplay()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if not isDiscPriest then return end
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        if PENANCE_SPELL_IDS[spellID] then
            onPenanceCast()
        end
    end
end)
