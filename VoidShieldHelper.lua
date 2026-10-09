local ADDON_NAME = ...

-- Global table shared with VoidShieldHelper_Options.lua
VSH = VSH or {}

-- ─── Constants ───────────────────────────────────────────────────────────────

-- Penance spell IDs matched on UNIT_SPELLCAST_CHANNEL_START.
-- Penance spell chain (per SimulationCraft / SpellData):
--   47540  base driver cast on enemy  (fires CHANNEL_START for offensive Penance)
--   47758  damage channel triggered by 47540 (may also surface on CHANNEL_START)
--   47666  per-bolt tick — damage or healing (fires UNIT_SPELLCAST_SUCCEEDED)
--   47757  healing channel cast on friendly (fires CHANNEL_START for healing Penance)
--   47750  per-bolt healing tick (fires UNIT_SPELLCAST_SUCCEEDED)
-- All IDs are included so any variant that surfaces on CHANNEL_START is caught.
local PENANCE_SPELL_IDS = {
    [47540] = true,  -- Penance base driver (enemy / offensive)
    [47758] = true,  -- Penance damage channel
    [47666] = true,  -- Penance per-bolt tick (damage or healing)
    [47757] = true,  -- Penance healing channel (friendly)
    [47750] = true,  -- Penance per-bolt healing tick
}

-- Power Word: Shield action-button textures.
-- BASE_SLOT_TEXTURE  : normal / not-procced PW:S icon
-- PROC_SLOT_TEXTURE  : Void Shield proc overlay (Borrowed Time / Rapture proc)
local BASE_SLOT_TEXTURE = 135940
local PROC_SLOT_TEXTURE = 7514191

-- ─── Deck mechanics (12.1) ───────────────────────────────────────────────────
-- Penance is a 4-card deck (25% per cast), the proc holds up to 2 charges, and
-- Mind Blast is a second, deterministic proc source.  Mind Blast does NOT turn
-- a deck card, so it never reaches the predictor.
local DECK_SIZE   = 4
local MAX_CHARGES = 2

-- Casting the Void Shield variant of PW:S consumes one proc charge.
local VOID_SHIELD_CAST_IDS = {
    [1253593] = true,
}

-- Mind Blast grants a proc charge.  Used only by the fallback charge inference.
local MIND_BLAST_SPELL_IDS = {
    [8092] = true,
}

-- Void Shield proc aura ("Master the Darkness").  Used only to find which
-- Cooldown Manager item is ours via its non-secret config cooldownInfo.
local VOID_SHIELD_AURA_ID = 1253591

-- Blizzard Cooldown Manager buff viewers whose items render an exact stack
-- count (see readBlizzardStacks).
local COOLDOWN_VIEWER_FRAMES = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

-- Discrete colour thresholds.  Orange [0, THRESH_LO), yellow [THRESH_LO, THRESH_HI), green [THRESH_HI, 1].
local THRESH_LO = 0.33
local THRESH_HI = 0.66

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

-- How long after UNIT_SPELLCAST_CHANNEL_START to read the proc texture.
-- Configurable via Options → General → Detection (default 200 ms).
local PROC_CHECK_DELAY_DEFAULT_MS = 200
local function getProcCheckDelay()
    local db = VoidShieldHelperDB
    local ms = db and db.procCheckDelayMs or PROC_CHECK_DELAY_DEFAULT_MS
    return ms / 1000
end
-- How many penance results to keep in the rolling history.
-- How many penance results to keep in the rolling log (purely for display).
-- No game-mechanic reason to cap this; just controls memory used by the table.
local MAX_HISTORY         = 30
-- How many of those entries to render in the debug frame (limited by frame height).
local MAX_DISPLAY_HISTORY = 9
-- How many recent history entries to replay through a fresh predictor on auto-recovery.
local RECOVERY_REPLAY_WINDOW = 4
-- Max raw event log entries kept for the copy-log popup.
local MAX_EVENT_LOG       = 60

-- Result constants
local RESULT_PROC     = "PROC"
local RESULT_NO_PROC  = "NO_PROC"
local RESULT_UNKNOWN  = "UNKNOWN"   -- shield was already up at cast time

-- ─── Deck predictor (Phase-State Filter) ────────────────────────────────────
-- Models the "sampling without replacement" deck mechanic:
-- every DECK_SIZE Penance casts contain exactly one Void Shield proc.
-- DECK_SIZE phases run in parallel to handle unknown deck-start offsets.
--
-- Input values: 1 = PROC, 0 = NO_PROC, -1 = UNKNOWN (shield was already up)

local function DeckPredictor_new()
    -- Each phase represents a possible deck-start offset (0..DECK_SIZE-1 casts into a block).
    -- Casts before tracking began are injected as virtual unknowns (-1) so that the
    -- preceding partial block is handled correctly without special-casing.
    --
    -- e.g. with a 3-card deck:
    -- offset=0: first cast is slot 0 of a new block  → 0 virtual unknowns
    -- offset=1: first cast is slot 2 of preceding block → 2 virtual unknowns
    -- offset=2: first cast is slot 1 of preceding block → 1 virtual unknown
    -- Formula: virtualSlots = (DECK_SIZE - offset) % DECK_SIZE
    local phases = {}
    for offset = 0, DECK_SIZE - 1 do
        local v = (DECK_SIZE - offset) % DECK_SIZE   -- virtual unknown slots to pre-inject
        phases[offset + 1] = {
            isValid     = true,
            minSum      = 0,  -- confirmed procs in current block
            maxSum      = v,  -- virtual unknowns pre-injected as -1
            slotsFilled = v,  -- slots already consumed by virtual unknowns
        }
    end
    return { phases = phases }
end

--- Discard phases with non-zero offset, keeping only the offset-0 phase.
--- Used when entering a new zone/instance with the "prune offsets" option on:
--- assumes the dungeon starts at a clean block boundary so the predictor
--- converges immediately instead of waiting for natural invalidation.
local function DeckPredictor_pruneToOffset0(self)
    for i, p in ipairs(self.phases) do
        if i == 1 then
            -- Reset offset-0 phase to a clean block start.
            -- Without this, the stale slotsFilled/minSum/maxSum from the
            -- previous run causes an impossible sequence on the first new
            -- cast, triggering auto-recovery and INCONSISTENT warnings.
            p.isValid     = true
            p.minSum      = 0
            p.maxSum      = 0
            p.slotsFilled = 0
        else
            p.isValid = false
        end
    end
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
            elseif p.slotsFilled == DECK_SIZE - 1 then
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
        local remaining = DECK_SIZE - p.slotsFilled
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
    local remaining   = DECK_SIZE - sf
    return 1.0 / (numUnknowns + remaining)
end

--- Advance a phase state by consuming one cast with value val (1 or 0).
--- Returns new (sf, minS, maxS, isValid).
local function advanceState(sf, minS, maxS, val)
    local newMin = minS + (val == 1 and 1 or 0)
    local newMax = maxS + (val == 1 and 1 or 0)
    if newMin > 1 then return 0, 0, 0, false end  -- too many procs
    if sf == DECK_SIZE - 1 then
        if newMax == 0 then return 0, 0, 0, false end  -- block ended with no proc possible
        return 0, 0, 0, true   -- block resets cleanly
    end
    return sf + 1, newMin, newMax, true
end

--- P(the cast `ahead` steps from now procs) for one phase state.  ahead = 1 is
--- the next cast.  Branches on proc / no-proc for every intermediate cast,
--- weighting each branch by its probability (at most 2^(ahead-1) leaves).
local function probAheadForState(sf, minS, maxS, ahead)
    local p1 = probForState(sf, minS, maxS)
    if ahead <= 1 then return p1 end
    local total = 0
    if p1 > 0 then
        local s, mn, mx, ok = advanceState(sf, minS, maxS, 1)
        if ok then total = total + p1 * probAheadForState(s, mn, mx, ahead - 1) end
    end
    if p1 < 1 then
        local s, mn, mx, ok = advanceState(sf, minS, maxS, 0)
        if ok then total = total + (1 - p1) * probAheadForState(s, mn, mx, ahead - 1) end
    end
    return total
end

--- Returns the probability that the cast `ahead` steps from now will proc
--- (2 = N+2, 3 = N+3), averaged across all currently valid phases.
--- Returns nil if no valid phases exist.
local function DeckPredictor_getProbAhead(self, ahead)
    local totalP, count = 0, 0
    for _, p in ipairs(self.phases) do
        if p.isValid then
            count  = count + 1
            totalP = totalP + probAheadForState(p.slotsFilled, p.minSum, p.maxSum, ahead)
        end
    end
    if count == 0 then return nil end
    return totalP / count
end

-- ─── Saved variables ─────────────────────────────────────────────────────────

VoidShieldHelperDB = VoidShieldHelperDB or {}

-- Defaults for a fresh install, filled into any missing key on ADDON_LOADED.
-- Frames start unlocked with the debug window shown, so a new user can reach
-- the Options button straight away.  Positions are deliberately absent: the
-- forecast frame defaults to screen centre and the debug window to its right.
local DB_DEFAULTS = {
    -- General
    locked            = false,
    hideDebug         = false,
    hideOutOfCombat   = false,
    forecastScale     = 1.0,
    debugScale        = 1.0,
    procCheckDelayMs  = 200,
    pruneOffsetOnZone = true,
    smoothColors      = true,
    -- Forecast frame backdrop (transparent, borderless)
    backdropBg   = "",
    bgColorR     = 0,    bgColorG     = 0,    bgColorB     = 0,    bgColorA     = 0,
    borderSize   = 0,
    borderColorR = 0.32, borderColorG = 0.32, borderColorB = 0.32, borderColorA = 1,
    -- Layout
    verticalLayout = false,
    lightAlign     = "end",
    lightGap       = 9,
    -- Prediction lights
    lightTexName    = "",
    lightSizeMain   = 24,
    lightSizeSmall  = 16,
    lightBorderSize = 1,
    lightBorderR = 0, lightBorderG = 0, lightBorderB = 0, lightBorderA = 1,
    -- Status (charge) lights
    statusTexName    = "",
    statusAlong      = 16,
    statusAcross     = 24,
    statusGap        = 1,
    statusStack      = "across",
    statusOnR  = 0,   statusOnG  = 0.9, statusOnB  = 0.9,
    statusOffR = 0.3, statusOffG = 0.3, statusOffB = 0.3,
    statusBorderSize = 1,
    statusBorderR = 0, statusBorderG = 0, statusBorderB = 0, statusBorderA = 1,
    -- Debug window
    debugBgTex      = "",
    debugBgR        = 0,    debugBgG        = 0,    debugBgB        = 0,    debugBgA        = 0.82,
    debugBorderSize = 1,
    debugBorderR    = 0.32, debugBorderG    = 0.32, debugBorderB    = 0.32, debugBorderA    = 1,
}
VSH.DEFAULTS = DB_DEFAULTS

-- ─── Runtime state ───────────────────────────────────────────────────────────

local isDiscPriest             = false

local watchSlot                = nil    -- cached action-bar slot for PW:S
local iterationsUntilSlotRefresh = 0

local shieldActive             = false  -- true when PROC_SLOT_TEXTURE is visible
local chargeCount              = 0      -- active proc charges (0..MAX_CHARGES)
local blizzardCount            = false  -- true when chargeCount came from the Cooldown Manager
local cooldownIDCache          = nil    -- cached Cooldown Manager cooldownID for our proc
local cdmTracked               = false  -- Cooldown Manager has an item for our proc buff

-- Penance cast results (RESULT_PROC / RESULT_NO_PROC / RESULT_UNKNOWN), newest first.
local penanceHistory           = {}

-- ─── Detection state ─────────────────────────────────────────────────────────
-- Owned by onPenanceCastStart.  Swap the detection algorithm by replacing that
-- function; its only external contract is calling recordResult(result).
local pendingCheck             = false  -- true while the proc-check timer is live
local shieldActiveOnCast       = false  -- shield snapshot taken at cast start
local chargesOnCast            = 0      -- charge-count snapshot taken at cast start

-- ─── Shared event log ────────────────────────────────────────────────────────
-- Ring buffer of plain-text event strings for the copy-log popup, newest first.
local eventLog                 = {}

--- Prepend a timestamped string to the shared event log.
local function logEvent(msg)
    local t = string.format("%.2f", GetTime() % 1000)
    table.insert(eventLog, 1, string.format("[%s] %s", t, msg))
    if #eventLog > MAX_EVENT_LOG then
        eventLog[#eventLog] = nil
    end
end


local predictorHistoryDepth    = 0   -- how many penanceHistory entries the current predictor has processed

--- Returns nil if every complete block in history has at most 1 PROC (consistent),
--- or a string describing the first offending block (inconsistent).
--- Only meaningful when the predictor has converged to a single phase.
--- UNKNOWN entries count as 0 procs (worst-case assumption for this check).
local function verifyHistoryBlocks(convergedPhaseOffset)
    local n = math.min(#penanceHistory, predictorHistoryDepth)
    if n == 0 then return nil end

    -- virtualUnknowns = slots before the first real cast in the first partial block.
    local virtualUnknowns = (DECK_SIZE - convergedPhaseOffset) % DECK_SIZE

    -- Count PROCs per block.  History is newest-first, so we walk it backwards
    -- (index n = oldest cast, index 1 = newest cast).
    local blockProcs = {}
    for histIdx = n, 1, -1 do
        local castIdx  = n - histIdx              -- 0-based, oldest = 0
        local absSlot  = castIdx + virtualUnknowns
        local blockIdx = math.floor(absSlot / DECK_SIZE)  -- 0-based block number

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
local inCombat                 = false

-- ─── Forward declarations ────────────────────────────────────────────────────

local updateDebugDisplay
local updateForecastDisplay
local updateFrameVisibility

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

-- True if v is a 12.0 "secret value".  issecretvalue is the sanctioned way to
-- ask WITHOUT using the value (comparisons/arithmetic on secrets throw).
local function isSecret(v)
    if issecretvalue then return issecretvalue(v) end
    return false
end

--- Does a Cooldown Manager item's (config) cooldownInfo reference our proc spell?
--- These are static data-table fields, not live combat data, so comparing them
--- is not secret.
local function cooldownInfoMatches(info)
    if not info then return false end
    if info.spellID == VOID_SHIELD_AURA_ID
        or info.overrideSpellID == VOID_SHIELD_AURA_ID
        or info.overrideTooltipSpellID == VOID_SHIELD_AURA_ID then
        return true
    end
    local linked = info.linkedSpellIDs
    if linked then
        for _, id in ipairs(linked) do
            if id == VOID_SHIELD_AURA_ID then return true end
        end
    end
    return false
end

--- The Applications FontString for a Cooldown Manager item (icon vs bar layout).
local function itemApplicationsFontString(itemFrame)
    local iconField = itemFrame.Icon
    if not iconField then return nil end
    if iconField.GetObjectType and iconField:GetObjectType() == "Texture" then
        return itemFrame.Applications and itemFrame.Applications.Applications  -- buff-icon item
    end
    return iconField.Applications                                              -- buff-bar item
end

--- Does this FontString currently render any text?
--- Blizzard writes the stack count only when stacks > 1 (plain "" otherwise).
--- The count is a secret we never read; the text merely BEING secret means a
--- count was rendered, i.e. stacks > 1.  GetText is the only usable channel —
--- layout metrics read secret regardless of content.
--- Returns true/false, or nil if the probe threw.
local function fontStringHasText(fs)
    local ok, hasText = pcall(function()
        local t = fs:GetText()
        if isSecret(t) then return true end
        return t ~= nil and t ~= ""
    end)
    if ok then return hasText end
    return nil
end

--- The Cooldown Manager item frame tracking our proc buff, or nil.  The viewers
--- keep an item for every tracked buff whether or not the aura is up, so this
--- also answers "is the buff tracked at all".
local function findCooldownItemUnsafe()
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        return nil
    end
    for _, frameName in ipairs(COOLDOWN_VIEWER_FRAMES) do
        local viewer = _G[frameName]
        local pool = viewer and viewer.itemFramePool
        if pool then
            for itemFrame in pool:EnumerateActive() do
                local cdID = itemFrame.cooldownID
                if cdID and (cdID == cooldownIDCache
                        or cooldownInfoMatches(C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID))) then
                    cooldownIDCache = cdID
                    return itemFrame
                end
            end
        end
    end
    return nil
end

local function findCooldownItem()
    local ok, item = pcall(findCooldownItemUnsafe)
    if ok then return item end
    return nil
end

--- Exact charge count piggybacked off Blizzard's Cooldown Manager, or nil when
--- it can't be determined (item not tracked, or every probe hit a secret).
local function readBlizzardStacks()
    local item = findCooldownItem()
    cdmTracked = item ~= nil
    if not item then return nil end
    local appsFS = itemApplicationsFontString(item)
    local hasText = appsFS and fontStringHasText(appsFS)
    if appsFS == nil or hasText == nil then return nil end
    return hasText and MAX_CHARGES or 1
end

--- Update shieldActive / chargeCount from the PW:S action-button texture (the
--- authoritative 0-vs-(>=1) signal).  Only the PROC texture is matched: ANY
--- other texture means no charge, so a base-icon change in a future patch
--- degrades to "no charge" instead of freezing the state.  When a proc is up,
--- 1-vs-2 is refined from the Cooldown Manager, else from event inference
--- (onSpellSucceeded).
local function pollShieldState()
    local tex = getCurrentSlotTexture()
    if tex == PROC_SLOT_TEXTURE then
        shieldActive = true
        local n = readBlizzardStacks()
        if n then
            blizzardCount = true
            chargeCount   = n
        else
            blizzardCount = false
            if chargeCount < 1 then chargeCount = 1 end
        end
    elseif tex ~= nil then
        shieldActive  = false
        chargeCount   = 0
        blizzardCount = false
    end
    -- If tex is nil we keep the last known state.
end

--- Classify the just-finished Penance by comparing post-cast state to the cast
--- snapshot.  With an exact Cooldown Manager count the charge delta also catches
--- a proc landing while a charge is already up (except at the cap); otherwise
--- the binary texture can't see a new proc behind an existing one → UNKNOWN.
local function classifyCast()
    if blizzardCount then
        if chargesOnCast >= MAX_CHARGES then
            return RESULT_UNKNOWN
        elseif chargeCount > chargesOnCast then
            return RESULT_PROC
        end
        return RESULT_NO_PROC
    end
    if shieldActiveOnCast then
        return RESULT_UNKNOWN
    elseif shieldActive then
        return RESULT_PROC
    end
    return RESULT_NO_PROC
end

-- ─── Penance cast handling ───────────────────────────────────────────────────
-- recordResult(result) is the interface between the detection algorithm and
-- the history / predictor / display layers.  Only onPenanceCastStart calls it.

--- Push a result onto the history, update the deck predictor, and refresh displays.
local function recordResult(result)
    table.insert(penanceHistory, 1, result)
    if #penanceHistory > MAX_HISTORY then
        penanceHistory[#penanceHistory] = nil
    end
    local val = result == RESULT_PROC and 1 or (result == RESULT_NO_PROC and 0 or -1)
    predictorHistoryDepth = math.min(predictorHistoryDepth + 1, MAX_HISTORY)
    DeckPredictor_update(predictor, val)
    -- Auto-recover: if every phase was just killed the observed sequence
    -- violated the deck model (can happen with many UNKNOWNs or a genuine
    -- mechanic edge case).  Reset the predictor and re-feed this result as
    -- the first cast of a new predictor — it is still valid information.
    local prob = DeckPredictor_getProb(predictor)
    if prob == nil then
        predictorBreakCount = predictorBreakCount + 1
        predictor = DeckPredictor_new()
        -- Replay the most recent RECOVERY_REPLAY_WINDOW entries (oldest first)
        -- so the phase filter can eliminate offsets inconsistent with recent history,
        -- rather than restarting with all 3 phases and just the triggering cast.
        local replayN = math.min(#penanceHistory, RECOVERY_REPLAY_WINDOW)
        for j = replayN, 1, -1 do
            local rv = penanceHistory[j] == RESULT_PROC and 1
                     or (penanceHistory[j] == RESULT_NO_PROC and 0 or -1)
            DeckPredictor_update(predictor, rv)
        end
        -- The predictor only knows about replayN entries; treat older history
        -- as belonging to a previous run (grey in display, skipped in verify).
        predictorHistoryDepth = replayN
    end
    updateDebugDisplay()
    updateForecastDisplay()
end

-- ─── Detection algorithm ─────────────────────────────────────────────────────
-- To swap detection algorithms: replace onPenanceCastStart and update the
-- UNIT_SPELLCAST_* registrations at the bottom of this file.
-- Contract: call recordResult(RESULT_PROC | RESULT_NO_PROC | RESULT_UNKNOWN)
-- exactly once per logical Penance cast.
--
-- Current algorithm: UNIT_SPELLCAST_CHANNEL_START + configurable delay.
--   State machine:
--     shield ACTIVE  at cast start           → UNKNOWN  (new proc undetectable)
--     shield INACTIVE, ACTIVE after delay    → PROC
--     shield INACTIVE, INACTIVE after delay  → NO_PROC

--- Called on UNIT_SPELLCAST_CHANNEL_START for a matched Penance spell ID.
local function onPenanceCastStart(spellID)
    if pendingCheck then
        -- A previous cast's timer is still live.  Force-complete it now so the
        -- history stays contiguous (handles fast recasts inside the delay window).
        logEvent("CHANNEL_START while check pending; force-completing")
        pendingCheck = false
        pollShieldState()
        recordResult(classifyCast())
    end
    pendingCheck       = false
    pollShieldState()
    shieldActiveOnCast = shieldActive
    chargesOnCast      = chargeCount
    logEvent(string.format("CHANNEL_START %d shield=%s charges=%d%s", spellID,
        shieldActive and "Y" or "N", chargeCount, blizzardCount and " (CDM)" or ""))
    pendingCheck = true
    C_Timer.After(getProcCheckDelay(), function()
        if not pendingCheck then return end
        pendingCheck = false
        pollShieldState()
        local result = classifyCast()
        logEvent(string.format("  -> %s charges=%d", result, chargeCount))
        recordResult(result)
    end)
    updateDebugDisplay()
end

--- Fallback charge inference for when the Cooldown Manager isn't providing an
--- exact count: Mind Blast adds a charge, casting the Void Shield
--- variant of PW:S consumes one.  The texture (pollShieldState) stays the
--- 0-vs-(>=1) anchor.  In this mode a Penance proc landing on an existing charge
--- is invisible, so that cast is recorded UNKNOWN.
local function onSpellSucceeded(spellID)
    if blizzardCount then return end
    if MIND_BLAST_SPELL_IDS[spellID] then
        if chargeCount < MAX_CHARGES then
            chargeCount  = chargeCount + 1
            shieldActive = true
            logEvent(string.format("MIND_BLAST charges=%d", chargeCount))
            updateDebugDisplay()
            updateForecastDisplay()
        end
    elseif VOID_SHIELD_CAST_IDS[spellID] then
        if chargeCount > 0 then
            chargeCount  = chargeCount - 1
            shieldActive = chargeCount > 0
            logEvent(string.format("VOID_SHIELD cast charges=%d", chargeCount))
            updateDebugDisplay()
            updateForecastDisplay()
        end
    end
end

-- ─── Forecast UI ─────────────────────────────────────────────────────────────
-- The frame is a row (horizontal layout) or column (vertical layout) of four
-- logical slots, one per card of the 4-cast deck:
--   [status] [N+1] [N+2] [N+3]
-- All geometry is described relative to the layout axis, so settings mean the
-- same thing in either layout:
--   ALONG  = the direction the slots run (x when horizontal, y when vertical)
--   ACROSS = perpendicular to it
-- Slot 1 holds the STATUS lights, one per Void Shield charge, splitting the
-- slot's along x across extent.  db.statusStack stacks them "across" the
-- layout (default) or "along" it.  A column fills from the bottom, a row from
-- the left.  At the charge cap with a possible proc on the next cast they play
-- the action-bar proc glow: spend a charge first, or that proc is wasted.
-- Slots 2-4 hold the PREDICTION lights; N+1 is the primary (full size).
-- Every slot is aligned across the layout axis by db.lightAlign:
--   "start" = top / left, "center", "end" = bottom / right.
-- Sizes/gaps come from the DB; DB_DEFAULTS is the single source of defaults.
local LIGHT_SIZE_MAIN_DEFAULT  = DB_DEFAULTS.lightSizeMain
local LIGHT_SIZE_SMALL_DEFAULT = DB_DEFAULTS.lightSizeSmall
local LIGHT_GAP_DEFAULT        = DB_DEFAULTS.lightGap      -- between logical slots
local STATUS_ALONG_DEFAULT     = DB_DEFAULTS.statusAlong   -- whole status slot, all charges
local STATUS_ACROSS_DEFAULT    = DB_DEFAULTS.statusAcross
local STATUS_GAP_DEFAULT       = DB_DEFAULTS.statusGap     -- between stacked status lights
local STATUS_STACK_DEFAULT     = DB_DEFAULTS.statusStack
local LIGHT_ALIGN_DEFAULT      = DB_DEFAULTS.lightAlign
local NUM_SLOTS                = 4
local FRAME_PADDING            = 8
local WHITE_TEX                = "Interface\\Buttons\\WHITE8x8"

-- Blizzard's own proc-loop marching ants (the art the action bars use when a
-- spell procs).  Played by a C-side FlipBook AnimationGroup, so it costs no
-- Lua per frame.  The atlas has transparent padding baked in, hence the scale.
local PROC_GLOW_ATLAS   = "UI-HUD-ActionBar-Proc-Loop-Flipbook"
local PROC_GLOW_PADDING = 1.4

local function fetchStatusbar(name)
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM and name and name ~= "" then
        return LSM:Fetch("statusbar", name, true)
    end
    return nil
end

--- A light: backdrop fill (tinted per update) plus a pixel border.
local function makeLight(parent, w, h, texPath, borderSize, br, bg, bb, ba)
    local light = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    light:SetSize(w, h)
    light:SetBackdrop({
        bgFile   = texPath or WHITE_TEX,
        edgeFile = WHITE_TEX,
        edgeSize = math.max(1, borderSize),
        tile = true, tileSize = 16,
    })
    light:SetBackdropColor(0.3, 0.3, 0.3, 1)
    light:SetBackdropBorderColor(br, bg, bb, (borderSize > 0) and ba or 0)
    return light
end

local function addProcGlow(light, w, h)
    local glow = light:CreateTexture(nil, "OVERLAY")
    glow:SetAtlas(PROC_GLOW_ATLAS)
    glow:SetSize(w * PROC_GLOW_PADDING, h * PROC_GLOW_PADDING)
    glow:SetPoint("CENTER")
    glow:Hide()
    local ag = glow:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local anim = ag:CreateAnimation("FlipBook")
    anim:SetFlipBookRows(6)
    anim:SetFlipBookColumns(5)
    anim:SetFlipBookFrames(30)
    anim:SetDuration(1.0)
    light.glow, light.glowAnim = glow, ag
end

-- Rebuild (or initially build) the light frames inside forecastFrame.
-- Tears down existing lights first so it can be called on settings change.
local function rebuildLights(f)
    local db       = VoidShieldHelperDB or {}
    local szMain   = db.lightSizeMain  or LIGHT_SIZE_MAIN_DEFAULT
    local szSmall  = db.lightSizeSmall or LIGHT_SIZE_SMALL_DEFAULT
    local gap      = db.lightGap       or LIGHT_GAP_DEFAULT
    local statAlong  = db.statusAlong  or STATUS_ALONG_DEFAULT
    local statAcross = db.statusAcross or STATUS_ACROSS_DEFAULT
    local statGap  = db.statusGap      or STATUS_GAP_DEFAULT
    local align    = db.lightAlign     or LIGHT_ALIGN_DEFAULT
    local vertical = db.verticalLayout

    -- Tear down the previous slots (their lights go with them).
    if f.slots then
        for _, slot in ipairs(f.slots) do
            slot:Hide()
            slot:SetParent(nil)
        end
    end
    f.slots, f.lights, f.statusLights = {}, {}, {}

    -- Each slot's extent ALONG the layout axis and ACROSS it.
    local along  = { statAlong,  szMain, szSmall, szSmall }
    local across = { statAcross, szMain, szSmall, szSmall }
    local span, crossMax = gap * (NUM_SLOTS - 1), 0
    for i = 1, NUM_SLOTS do
        span     = span + along[i]
        crossMax = math.max(crossMax, across[i])
    end
    if vertical then
        f:SetSize(crossMax + FRAME_PADDING * 2, span + FRAME_PADDING * 2)
    else
        f:SetSize(span + FRAME_PADDING * 2, crossMax + FRAME_PADDING * 2)
    end

    -- Lay the slots out along the axis; offset each across it by alignment
    -- (measured from the top in the horizontal layout, from the left in the
    -- vertical one, so "start" is top / left in both).
    local pos = FRAME_PADDING
    for i = 1, NUM_SLOTS do
        local free  = crossMax - across[i]
        local cross = FRAME_PADDING + ((align == "start" and 0)
                                    or (align == "center" and free / 2)
                                    or free)
        local slot = CreateFrame("Frame", nil, f)
        if vertical then
            slot:SetSize(across[i], along[i])
            slot:SetPoint("TOPLEFT", f, "TOPLEFT", cross, -pos)
        else
            slot:SetSize(along[i], across[i])
            slot:SetPoint("TOPLEFT", f, "TOPLEFT", pos, -cross)
        end
        pos = pos + along[i] + gap
        f.slots[i] = slot
    end

    -- Prediction lights (N+1, N+2, N+3) fill slots 2-4.
    local lbs = db.lightBorderSize or 1
    local predTex = fetchStatusbar(db.lightTexName)
    for i = 2, NUM_SLOTS do
        local light = makeLight(f.slots[i], along[i], along[i], predTex, lbs,
            db.lightBorderR or 0, db.lightBorderG or 0, db.lightBorderB or 0, db.lightBorderA or 1)
        light:SetPoint("TOPLEFT")
        f.lights[i - 1] = light
    end

    -- Status lights split slot 1 (statAlong x statAcross) into one light per
    -- charge, stacked across the layout (default) or along it.  On screen a
    -- column fills upward from the bottom, a row rightward from the left.
    local stackAlong = (db.statusStack or STATUS_STACK_DEFAULT) == "along"
    local stackLen   = stackAlong and statAlong or statAcross
    local each       = math.max(1, (stackLen - statGap * (MAX_CHARGES - 1)) / MAX_CHARGES)
    local lAlong     = stackAlong and each or statAlong
    local lAcross    = stackAlong and statAcross or each
    local lightW     = vertical and lAcross or lAlong
    local lightH     = vertical and lAlong or lAcross
    local column     = (stackAlong and vertical) or (not stackAlong and not vertical)
    local sbs = db.statusBorderSize or 1
    local statTex = fetchStatusbar(db.statusTexName)
    for i = 1, MAX_CHARGES do
        local light = makeLight(f.slots[1], lightW, lightH, statTex, sbs,
            db.statusBorderR or 0, db.statusBorderG or 0, db.statusBorderB or 0, db.statusBorderA or 1)
        local step = (i - 1) * (each + statGap)
        if column then
            light:SetPoint("BOTTOMLEFT", f.slots[1], "BOTTOMLEFT", 0, step)
        else
            light:SetPoint("TOPLEFT", f.slots[1], "TOPLEFT", step, 0)
        end
        addProcGlow(light, lightW, lightH)
        f.statusLights[i] = light
    end
end

local function createForecastFrame()
    local f = CreateFrame("Frame", "VoidShieldHelperForecastFrame", UIParent, "BackdropTemplate")

    if VoidShieldHelperDB.forecastPos then
        local p = VoidShieldHelperDB.forecastPos
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        f:SetPoint("CENTER")
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

    rebuildLights(f)

    f:Show()
    return f
end

-- Colour stops for the smooth gradient.
-- Each stop is anchored at the MID-POINT of the corresponding discrete colour
-- range so the gradient shows the "pure" colour where discrete mode would.
-- Midpoints are derived from THRESH_LO / THRESH_HI automatically.
-- Each entry: { prob 0-1, r, g, b }
local PROB_STOPS = {
    { THRESH_LO / 2,                   1.0, 0.5, 0.0 },  -- orange  midpoint
    { (THRESH_LO + THRESH_HI) / 2,     0.9, 0.9, 0.1 },  -- yellow  midpoint
    { (THRESH_HI + 1.0) / 2,           0.1, 0.9, 0.1 },  -- green   midpoint
}

local function lerpColor(r1, g1, b1, r2, g2, b2, t)
    return r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t
end

local function probColor(prob)
    if prob == nil then return 0.4, 0.4, 0.4 end
    if prob >= 1.0  then return 0.0, 0.9, 0.9 end   -- cyan: guaranteed proc
    if prob <= 0.0  then return 0.9, 0.2, 0.2 end   -- red: guaranteed no-proc

    local db = VoidShieldHelperDB
    if db and db.smoothColors then
        -- Smooth gradient: pure colour at each midpoint, blends at boundaries.
        local s = PROB_STOPS
        if prob <= s[1][1] then
            return s[1][2], s[1][3], s[1][4]  -- clamp to first colour
        end
        for i = 1, #s - 1 do
            local lo, hi = s[i], s[i + 1]
            if prob >= lo[1] and prob <= hi[1] then
                local span = hi[1] - lo[1]
                local t = (span > 0) and (prob - lo[1]) / span or 0
                return lerpColor(lo[2], lo[3], lo[4], hi[2], hi[3], hi[4], t)
            end
        end
        local last = s[#s]
        return last[2], last[3], last[4]  -- clamp to last colour
    end

    -- Discrete mode (default)
    if prob >= THRESH_HI then return 0.1, 0.9, 0.1          -- green
    elseif prob >= THRESH_LO then return 0.9, 0.9, 0.1       -- yellow
    else return 1.0, 0.5, 0.0 end                           -- orange
end

local function applyLight(light, r, g, b)
    -- SetBackdropColor works for both solid color and texture modes:
    -- with bgFile=WHITE8x8 it produces a solid colour; with a real texture it tints it.
    light:SetBackdropColor(r, g, b, 1)
end

updateForecastDisplay = function()
    if not forecastFrame then return end

    local lights = forecastFrame.lights
    local prob1  = DeckPredictor_getProb(predictor)

    -- Status lights: one per charge held.  At the cap a proc on the next
    -- Penance would be wasted, so they glow until a charge is spent.
    local db = VoidShieldHelperDB or {}
    local capped = chargeCount >= MAX_CHARGES and prob1 ~= nil and prob1 > 0
    for i, light in ipairs(forecastFrame.statusLights) do
        if i <= chargeCount then
            applyLight(light, db.statusOnR or 0, db.statusOnG or 0.9, db.statusOnB or 0.9)
        else
            applyLight(light, db.statusOffR or 0.3, db.statusOffG or 0.3, db.statusOffB or 0.3)
        end
        if capped and not light.glowAnim:IsPlaying() then
            light.glow:Show()
            light.glowAnim:Play()
        elseif not capped and light.glowAnim:IsPlaying() then
            light.glowAnim:Stop()
            light.glow:Hide()
        end
    end

    -- Prediction lights (N+1, N+2, N+3): probability color (cyan at 100%)
    applyLight(lights[1], probColor(prob1))
    applyLight(lights[2], probColor(DeckPredictor_getProbAhead(predictor, 2)))
    applyLight(lights[3], probColor(DeckPredictor_getProbAhead(predictor, 3)))
end
-- ─── Debug UI ────────────────────────────────────────────────────────────────

local RESULT_COLOR = {
    [RESULT_PROC]    = "|cff00ff00",   -- green
    [RESULT_NO_PROC] = "|cffff4444",   -- red
    [RESULT_UNKNOWN] = "|cffffff00",   -- yellow
}

local function createDebugFrame()
    local f = CreateFrame("Frame", "VoidShieldHelperDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(240, 338)

    if VoidShieldHelperDB.pos then
        local p = VoidShieldHelperDB.pos
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        -- Until it is dragged, sit just right of the forecast frame (and
        -- follow it); dragging re-anchors to the screen and saves that.
        f:SetPoint("LEFT", forecastFrame, "RIGHT", 12, 0)
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

    -- PW:S action-bar slot info / warning
    local slotLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slotLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -46)
    slotLabel:SetWidth(220)
    slotLabel:SetJustifyH("LEFT")
    slotLabel:SetText("")
    f.slotLabel = slotLabel

    -- Cooldown Manager tracking of the Void Shield buff (exact charge count)
    local cdmLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cdmLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -62)
    cdmLabel:SetWidth(220)
    cdmLabel:SetJustifyH("LEFT")
    cdmLabel:SetText("")
    f.cdmLabel = cdmLabel

    -- Deck prediction probability
    local probLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    probLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -78)
    probLabel:SetWidth(220)
    probLabel:SetJustifyH("LEFT")
    probLabel:SetText("Next proc: —")
    f.probLabel = probLabel

    -- Phase / break info (second line under prob)
    local phaseLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    phaseLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -94)
    phaseLabel:SetWidth(220)
    phaseLabel:SetJustifyH("LEFT")
    phaseLabel:SetText("")
    f.phaseLabel = phaseLabel

    -- History verification (shown when phase converged)
    local verifyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    verifyLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -110)
    verifyLabel:SetWidth(220)
    verifyLabel:SetJustifyH("LEFT")
    verifyLabel:SetText("")
    f.verifyLabel = verifyLabel

    -- History section header
    local histHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    histHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -126)
    histHeader:SetText("Penance history (newest first):")

    -- History entry lines
    f.histLines = {}
    for i = 1, MAX_DISPLAY_HISTORY do
        local line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -126 - (i * 18))
        line:SetWidth(212)
        line:SetJustifyH("LEFT")
        line:SetText(string.format("#%d: —", i))
        f.histLines[i] = line
    end

    -- Options button (same as /vsh)
    local optBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    optBtn:SetSize(80, 20)
    optBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    optBtn:SetText("Options")
    optBtn:SetScript("OnClick", function()
        if VSH.toggleOptions then VSH.toggleOptions() end
    end)
    f.optBtn = optBtn

    -- Anchored to the frame corner, not the button, so it stays put while the
    -- button is hidden by the lock.
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -92, 11)
    hint:SetText("|cff888888/vsh|r")

    f:Show()
    return f
end

-- updateDebugDisplay is called from multiple places; defined here after the
-- frame creation helpers so it can reference them.
updateDebugDisplay = function()
    if not debugFrame then return end

    -- Shield status with charge count ("~" marks a count inferred from casts
    -- rather than read from the Cooldown Manager; kept short so the line fits
    -- with the pending indicator appended while a check is in flight).
    local status = string.format("%s %s%d/%d",
        shieldActive and "|cff00ff00ACTIVE|r" or "|cffff4444INACTIVE|r",
        blizzardCount and "" or "|cff888888~|r", chargeCount, MAX_CHARGES)
    if pendingCheck then
        status = status .. "  |cffffff00[checking...]|r"
    end
    debugFrame.statusVal:SetText(status)

    -- PW:S slot info / warning
    if debugFrame.slotLabel then
        if watchSlot then
            debugFrame.slotLabel:SetText(string.format(
                "|cff00ff00PW:S on bar: slot %d|r", watchSlot))
        else
            debugFrame.slotLabel:SetText(
                "|cffff4444PW:S not on action bar!|r")
        end
    end

    -- Cooldown Manager buff info / warning
    if cdmTracked then
        debugFrame.cdmLabel:SetText("|cff00ff00Void Shield in Cooldown Manager|r")
    else
        debugFrame.cdmLabel:SetText("|cffff8800Void Shield not in CDM: count inferred|r")
    end

    -- Prediction probability
    local prob, validCount = DeckPredictor_getProb(predictor)
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
        local aheadStr = ""
        for ahead = 2, 3 do
            local pa = DeckPredictor_getProbAhead(predictor, ahead)
            if pa then
                local pctA, cA = pctColor(pa)
                aheadStr = aheadStr .. string.format("  N+%d:%s%d%%|r", ahead, cA, pctA)
            end
        end
        debugFrame.probLabel:SetText(string.format(
            "N+1:%s%d%%|r%s",
            c1, pct1, aheadStr
        ))
        debugFrame.phaseLabel:SetText(string.format(
            "|cff888888[%d %s]|r%s",
            validCount, phaseWord, breakSuffix
        ))
    end

    -- Determine which phase is the sole survivor (for position highlighting).
    -- When validCount == 1 the converged phase tells us which deck-slot each
    -- historical cast occupied, so we colour the #N label by slot alignment.
    -- phases[k] = offset k-1 (by construction).
    local convergedPhaseOffset = nil
    if validCount == 1 then
        for idx, p in ipairs(predictor.phases) do
            if p.isValid then
                convergedPhaseOffset = idx - 1  -- 0..DECK_SIZE-1
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
            if convergedPhaseOffset and i <= predictorHistoryDepth then
                -- Only colour entries the current predictor has processed.
                local n          = math.min(#penanceHistory, predictorHistoryDepth)
                local castIdx    = n - i                                    -- 0-based, oldest = 0
                local virtualU   = (DECK_SIZE - convergedPhaseOffset) % DECK_SIZE
                local blockIdx   = math.floor((castIdx + virtualU) / DECK_SIZE)  -- 0-based block number
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

    -- Lock: fully click-through.  No dragging, and no mouse-enabled children
    -- either (the debug window's Options button is hidden; /vsh still works).
    local locked = db.locked or false
    for _, f in ipairs({ forecastFrame, debugFrame }) do
        if f then
            f:SetMovable(not locked)
            f:EnableMouse(not locked)
        end
    end
    if debugFrame then debugFrame.optBtn:SetShown(not locked) end

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
            db.bgColorR or 0, db.bgColorG or 0, db.bgColorB or 0, db.bgColorA or 0,
            db.borderSize or 0,
            db.borderColorR or 0.32, db.borderColorG or 0.32, db.borderColorB or 0.32, db.borderColorA or 1)
    end
    if debugFrame then
        applyBackdrop(debugFrame,
            db.debugBgTex,
            db.debugBgR or 0, db.debugBgG or 0, db.debugBgB or 0, db.debugBgA or 0.82,
            db.debugBorderSize or 1,
            db.debugBorderR or 0.32, db.debugBorderG or 0.32, db.debugBorderB or 0.32, db.debugBorderA or 1)
    end

    -- Light squares: rebuild to apply new sizes / gap / texture / border
    if forecastFrame then
        rebuildLights(forecastFrame)
        -- Re-apply indicator colours after rebuild resets them
        updateForecastDisplay()
    end
end

VSH.applySettings         = function() applySettings() end
VSH.updateForecastDisplay = function() updateForecastDisplay() end
VSH.rebuildLights         = function() if forecastFrame then rebuildLights(forecastFrame); updateForecastDisplay() end end
VSH.updateFrameVisibility = function() updateFrameVisibility() end
VSH.THRESH_LO             = THRESH_LO
VSH.THRESH_HI             = THRESH_HI
VSH.probColor             = function(p) return probColor(p) end

local logPopup = nil  -- shared popup for the debug log (opened from options)

VSH.showDebugLog = function()
    local lines = {}
    lines[#lines+1] = "=== Penance history (newest first) ==="
    for i = 1, #penanceHistory do
        lines[#lines+1] = string.format("#%d: %s", i, penanceHistory[i])
    end
    lines[#lines+1] = ""
    lines[#lines+1] = "=== Event log (newest first) ==="
    for i = 1, #eventLog do
        lines[#lines+1] = eventLog[i]
    end
    local text = table.concat(lines, "\n")

    if not logPopup then
        local pop = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        pop:SetSize(500, 400)
        pop:SetPoint("CENTER")
        pop:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1, tile = true, tileSize = 16,
        })
        pop:SetBackdropColor(0, 0, 0, 0.92)
        pop:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
        pop:SetFrameStrata("DIALOG")
        pop:EnableMouse(true)
        pop:SetMovable(true)
        pop:RegisterForDrag("LeftButton")
        pop:SetScript("OnDragStart", function(self) self:StartMoving() end)
        pop:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)

        local hdr = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        hdr:SetPoint("TOP", pop, "TOP", 0, -8)
        hdr:SetText("Debug Log")

        local hint = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOP", pop, "TOP", 0, -26)
        hint:SetText("|cff888888Ctrl-A to select all, Ctrl-C to copy|r")

        local scroll = CreateFrame("ScrollFrame", nil, pop, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",  pop, "TOPLEFT",  10, -46)
        scroll:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -30, 36)

        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject("ChatFontNormal")
        eb:SetWidth(scroll:GetWidth())
        eb:SetScript("OnEscapePressed", function() pop:Hide() end)
        scroll:SetScrollChild(eb)
        pop.editBox = eb

        local closeBtn = CreateFrame("Button", nil, pop, "UIPanelButtonTemplate")
        closeBtn:SetSize(80, 22)
        closeBtn:SetPoint("BOTTOM", pop, "BOTTOM", 0, 8)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function() pop:Hide() end)

        logPopup = pop
    end
    logPopup.editBox:SetText(text)
    logPopup.editBox:SetCursorPosition(0)
    logPopup:Show()
end

-- ─── Ticker ──────────────────────────────────────────────────────────────────

local function tickUpdate()
    -- Periodically refresh the watched action-bar slot.
    iterationsUntilSlotRefresh = iterationsUntilSlotRefresh - 1
    if iterationsUntilSlotRefresh <= 0 then
        refreshWatchSlot()
        iterationsUntilSlotRefresh = 10  -- ~every 1 s at 0.1 s tick
        -- The Cooldown Manager can be configured at any time; re-check whether
        -- it tracks our buff (pollShieldState only looks while a charge is up).
        local wasTracked = cdmTracked
        cdmTracked = findCooldownItem() ~= nil
        if cdmTracked ~= wasTracked then updateDebugDisplay() end
    end

    local prevShieldActive, prevCharges = shieldActive, chargeCount
    pollShieldState()
    -- Only redraw when the shield state actually changed; avoids spamming
    -- font-string writes every 100 ms during idle play.
    if shieldActive ~= prevShieldActive or chargeCount ~= prevCharges then
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

updateFrameVisibility = function()
    if not forecastFrame then return end
    local db = VoidShieldHelperDB or {}
    forecastFrame:SetShown(isDiscPriest and (not (db.hideOutOfCombat) or inCombat))
end

local function startTicker()
    if not isDiscPriest then return end
    if ticker then return end
    updateFrameVisibility()
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
    predictorHistoryDepth      = 0
    shieldActive               = false
    chargeCount                = 0
    blizzardCount              = false
    cooldownIDCache            = nil
    pendingCheck               = false
    shieldActiveOnCast         = false
    chargesOnCast              = 0
    eventLog                   = {}
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
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")  -- detection algorithm
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")      -- fallback charge inference
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")        -- entered combat
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")         -- left combat

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        VoidShieldHelperDB = VoidShieldHelperDB or {}
        local db = VoidShieldHelperDB
        -- Drop keys from pre-release builds of the status-light layout.
        db.statusSize, db.statusWidth, db.statusHeight = nil, nil, nil
        if db.statusStack ~= "along" and db.statusStack ~= "across" then db.statusStack = nil end
        -- Fill in any missing settings (new install, or keys added since).
        for k, v in pairs(DB_DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end

        -- Forecast first: the debug window's default position hangs off it.
        forecastFrame = createForecastFrame()
        debugFrame    = createDebugFrame()
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
        stopTicker()
        local db = VoidShieldHelperDB
        if db and db.pruneOffsetOnZone then
            -- Prune mode: keep only the offset-0 phase so the predictor converges
            -- immediately on the first cast of the new run (assumes a clean block
            -- boundary).  History and event log are cleared so the debug display
            -- doesn't inherit stale block-colouring / verify results from the old run.
            DeckPredictor_pruneToOffset0(predictor)
            penanceHistory     = {}
            eventLog           = {}
            predictorBreakCount = 0
            predictorHistoryDepth = 0
            pendingCheck       = false
            shieldActiveOnCast = false
            chargesOnCast      = 0
            shieldActive       = false
            chargeCount        = 0
            blizzardCount      = false
            watchSlot          = nil
        else
            -- Default: full reset on every zone transition.
            resetState()
        end
        updateSpecState()
        refreshWatchSlot()
        startTicker()
        updateDebugDisplay()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if unit ~= "player" then return end
        stopTicker()
        resetState()
        updateSpecState()
        refreshWatchSlot()
        startTicker()
        updateDebugDisplay()

    elseif event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        stopTicker()
        resetState()
        updateSpecState()
        refreshWatchSlot()
        startTicker()
        updateDebugDisplay()

    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        if not isDiscPriest then return end
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        if PENANCE_SPELL_IDS[spellID] then
            onPenanceCastStart(spellID)
        else
            logEvent(string.format("CHANNEL_START %d (no match)", spellID))
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if not isDiscPriest then return end
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        onSpellSucceeded(spellID)

    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        -- Spending the last charge swaps the PW:S icon, which fires this event;
        -- refresh here rather than waiting for the next tick.
        local prevSlot = watchSlot
        local prevShieldActive, prevCharges = shieldActive, chargeCount
        refreshWatchSlot()
        pollShieldState()
        if watchSlot ~= prevSlot or shieldActive ~= prevShieldActive
            or chargeCount ~= prevCharges then
            updateDebugDisplay()
            updateForecastDisplay()
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        updateFrameVisibility()

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        updateFrameVisibility()

    end
end)
