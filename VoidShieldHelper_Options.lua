-- VoidShieldHelper_Options.lua
-- Options panel: lock/unlock, scale, background texture+color, light texture.
-- Opened with /vsh.  Uses VSH global table set by VoidShieldHelper.lua.
-- Texture dropdowns use LibSharedMedia-3.0 (full list) with live preview,
-- search box, UIPanelScrollFrameTemplate scrollbar, and click-outside dismiss.

VSH = VSH or {}

-- ─── LibSharedMedia ───────────────────────────────────────────────────────────
local LSM_Cache = nil
local function GetLSM()
    if not LSM_Cache then
        LSM_Cache = LibStub and LibStub("LibSharedMedia-3.0", true)
    end
    return LSM_Cache
end

-- ─── Style ────────────────────────────────────────────────────────────────────
local S = {
    bg      = {0.08, 0.08, 0.08, 0.95},
    panel   = {0.12, 0.12, 0.12, 1.00},
    elem    = {0.14, 0.14, 0.14, 1.00},
    border  = {0.32, 0.32, 0.32, 1.00},
    accent  = {0.45, 0.55, 1.00, 1.00},
    text    = {0.85, 0.85, 0.85},
    dim     = {0.45, 0.45, 0.45},
    hl      = {0.22, 0.22, 0.22, 1.00},
}
local PANEL_W = 300

-- ─── Widget helpers ───────────────────────────────────────────────────────────

local function darkBackdrop(f, bgAlpha)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(S.elem[1], S.elem[2], S.elem[3], bgAlpha or 1)
    f:SetBackdropBorderColor(S.border[1], S.border[2], S.border[3], 1)
end

local function sectionHeader(parent, text, yOff)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOff)
    lbl:SetText(text)
    lbl:SetTextColor(S.accent[1], S.accent[2], S.accent[3])
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    line:SetPoint("RIGHT",  parent, "RIGHT", -10, 0)
    line:SetColorTexture(S.border[1], S.border[2], S.border[3], 0.6)
end

-- Checkbox: getter()→bool, setter(bool)
local function makeCheckbox(parent, label, yOff, getter, setter)
    local W = PANEL_W - 20
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(W, 22)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOff)

    local cb = CreateFrame("CheckButton", nil, c, "BackdropTemplate")
    cb:SetSize(16, 16)
    cb:SetPoint("LEFT", 0, 0)
    darkBackdrop(cb)
    local chk = cb:CreateTexture(nil, "OVERLAY")
    chk:SetTexture("Interface\\Buttons\\WHITE8x8")
    chk:SetVertexColor(S.accent[1], S.accent[2], S.accent[3])
    chk:SetPoint("CENTER"); chk:SetSize(8, 8)
    cb:SetCheckedTexture(chk)
    cb:SetHighlightTexture("")

    local txt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(S.text[1], S.text[2], S.text[3])

    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)
    c.refresh = function() cb:SetChecked(getter()) end
    return c
end

-- Slider: getter()→num, setter(num)
local function makeSlider(parent, label, min, max, step, yOff, getter, setter, fmt)
    local TW = 160
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(PANEL_W - 20, 44)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOff)

    local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    local trackBg = CreateFrame("Frame", nil, c, "BackdropTemplate")
    trackBg:SetPoint("TOPLEFT", 0, -18); trackBg:SetSize(TW, 8)
    darkBackdrop(trackBg)

    local fill = trackBg:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", 1, 0); fill:SetHeight(6)
    fill:SetColorTexture(S.accent[1], S.accent[2], S.accent[3], 0.8)

    local sl = CreateFrame("Slider", nil, c)
    sl:SetPoint("TOPLEFT", 0, -18); sl:SetSize(TW, 8)
    sl:SetOrientation("HORIZONTAL")
    sl:SetMinMaxValues(min, max); sl:SetValueStep(step)
    sl:SetObeyStepOnDrag(true)
    sl:SetHitRectInsets(-4, -4, -8, -8)
    local thumb = sl:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 14)
    thumb:SetColorTexture(S.accent[1], S.accent[2], S.accent[3], 1)
    sl:SetThumbTexture(thumb)

    local vLbl = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    vLbl:SetPoint("LEFT", trackBg, "RIGHT", 8, 0)
    vLbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    local function updateFill(v)
        local pct = (v - min) / (max - min)
        fill:SetWidth(math.max(1, pct * (TW - 2)))
        vLbl:SetText(string.format(fmt or "%.2f", v))
    end
    sl:SetValue(getter()); updateFill(getter())
    sl:SetScript("OnValueChanged", function(_, v) updateFill(v); setter(v) end)
    c.refresh = function()
        local v = getter(); sl:SetValue(v); updateFill(v)
    end
    return c
end

-- Color swatch: opens ColorPickerFrame with alpha support.
local function makeColorSwatch(parent, label, xOff, yOff, kr, kg, kb, ka)
    local sw = CreateFrame("Button", nil, parent, "BackdropTemplate")
    sw:SetSize(22, 22)
    sw:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, yOff)
    sw:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    sw:SetBackdropBorderColor(S.border[1], S.border[2], S.border[3], 1)

    local colorTex = sw:CreateTexture(nil, "ARTWORK")
    colorTex:SetPoint("TOPLEFT",     sw, "TOPLEFT",     2, -2)
    colorTex:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", -2, 2)

    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", sw, "RIGHT", 8, 0)
    lbl:SetText(label)
    lbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    -- alpha strip below the swatch (only when ka is provided)
    local alphaStrip
    if ka then
        alphaStrip = parent:CreateTexture(nil, "ARTWORK")
        alphaStrip:SetSize(22, 4)
        alphaStrip:SetPoint("TOP", sw, "BOTTOM", 0, -2)
    end

    local db = VoidShieldHelperDB
    local function Refresh()
        local r = db[kr] or 0
        local g = db[kg] or 0
        local b = db[kb] or 0
        colorTex:SetColorTexture(r, g, b, 1)
        if alphaStrip then
            alphaStrip:SetColorTexture(1, 1, 1, db[ka] or 1)
        end
    end

    sw:SetScript("OnShow", Refresh)
    sw:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.9, 0.9, 0.9, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Click to choose color & opacity", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    sw:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(S.border[1], S.border[2], S.border[3], 1)
        GameTooltip:Hide()
    end)
    sw:SetScript("OnClick", function()
        local opts = {
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                db[kr] = r; db[kg] = g; db[kb] = b
                if ka then db[ka] = ColorPickerFrame:GetColorAlpha() end
                if VSH.applySettings then VSH.applySettings() end
                Refresh()
            end,
            cancelFunc = function(prev)
                if prev then
                    db[kr] = prev.r; db[kg] = prev.g; db[kb] = prev.b
                    if ka then db[ka] = prev.opacity or 1 end
                    if VSH.applySettings then VSH.applySettings() end
                    Refresh()
                end
            end,
            r = db[kr] or 0, g = db[kg] or 0, b = db[kb] or 0,
        }
        if ka then
            opts.hasOpacity = true
            opts.opacity    = db[ka] or 1
        end
        ColorPickerFrame:SetupColorPickerAndShow(opts)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    Refresh()
    sw.refresh = Refresh
    return sw
end

-- ─── LSM Texture Dropdown ─────────────────────────────────────────────────────
-- mediaType: "background" or "statusbar"
-- getter() → name string; setter(name) → persist + apply
local activeMenu = nil   -- only one menu open at a time

local function makeTextureDropdown(parent, label, mediaType, yOff, getter, setter)
    local BTN_W   = PANEL_W - 20
    local ITEM_H  = 26
    local SRCH_H  = 24
    local MAX_VIS = 9
    local PREV_W  = 70

    local function getList()
        local LSM = GetLSM()
        if LSM then return LSM:List(mediaType) or {} end
        return {}
    end
    local function fetchPath(name)
        local LSM = GetLSM()
        if LSM and name and name ~= "" then
            return LSM:Fetch(mediaType, name)
        end
        return nil
    end

    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(BTN_W, 44)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOff)

    local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    local btn = CreateFrame("Button", nil, c, "BackdropTemplate")
    btn:SetSize(BTN_W, 22)
    btn:SetPoint("TOPLEFT", 0, -18)
    darkBackdrop(btn)

    local btnPrev = btn:CreateTexture(nil, "BORDER")
    btnPrev:SetPoint("LEFT", 4, 0); btnPrev:SetSize(PREV_W, 16)
    btnPrev:SetBlendMode("ADD")

    local btnTxt = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnTxt:SetPoint("LEFT", btnPrev, "RIGHT", 4, 0)
    btnTxt:SetPoint("RIGHT", -14, 0)
    btnTxt:SetJustifyH("LEFT")
    btnTxt:SetTextColor(S.text[1], S.text[2], S.text[3])

    local arrowTex = btn:CreateTexture(nil, "OVERLAY")
    arrowTex:SetSize(10, 10)
    arrowTex:SetPoint("RIGHT", -4, 0)
    arrowTex:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")

    local function refreshBtn()
        local name = getter()
        local path = fetchPath(name)
        btnTxt:SetText(name and name ~= "" and name or "|cff888888(none)|r")
        if path then
            btnPrev:SetTexture(path)
            btnPrev:SetAlpha(0.9)
        else
            btnPrev:SetTexture(nil)
        end
    end
    refreshBtn()

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(S.border[1], S.border[2], S.border[3], 1)
    end)

    -- Flyout menu
    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:SetWidth(BTN_W)
    menu:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(0.10, 0.10, 0.10, 0.97)
    menu:SetBackdropBorderColor(S.border[1], S.border[2], S.border[3], 1)
    menu:Hide()

    local srch = CreateFrame("EditBox", nil, menu, "BackdropTemplate")
    srch:SetPoint("TOPLEFT", 2, -2); srch:SetPoint("TOPRIGHT", -2, -2)
    srch:SetHeight(SRCH_H - 4)
    srch:SetAutoFocus(false)
    srch:SetFontObject(GameFontHighlightSmall)
    srch:SetTextInsets(6, 6, 0, 0)
    srch:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeSize = 1, tile = true, tileSize = 5,
    })
    srch:SetBackdropColor(0.08, 0.08, 0.08, 1)
    srch:SetBackdropBorderColor(0.28, 0.28, 0.28, 1)

    local ph = srch:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ph:SetPoint("LEFT", 6, 0); ph:SetText("Search...")
    ph:SetTextColor(S.dim[1], S.dim[2], S.dim[3])
    srch:SetScript("OnEditFocusGained", function()  ph:Hide() end)
    srch:SetScript("OnEditFocusLost",   function(self)
        if self:GetText() == "" then ph:Show() end
    end)
    srch:SetScript("OnEscapePressed", function() menu:Hide() end)

    local sf = CreateFrame("ScrollFrame", nil, menu, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     menu, "TOPLEFT",      2, -(SRCH_H + 2))
    sf:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -20, 2)

    local sc = CreateFrame("Frame", nil, sf)
    local CHILD_W = BTN_W - 2 - 20
    sc:SetWidth(CHILD_W)
    sf:SetScrollChild(sc)

    local scrollBar = sf.ScrollBar
    if scrollBar then
        scrollBar:SetPoint("TOPLEFT",    sf, "TOPRIGHT",    -16, -16)
        scrollBar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", -16,  16)
    end

    local rowPool = {}

    local function rebuildMenu(filter)
        for _, r in ipairs(rowPool) do r:Hide(); r:SetParent(nil) end
        wipe(rowPool)

        local list     = getList()
        filter         = filter and filter:lower() or ""
        local filtered = {}
        for _, name in ipairs(list) do
            if filter == "" or name:lower():find(filter, 1, true) then
                filtered[#filtered + 1] = name
            end
        end

        sc:SetHeight(math.max(#filtered * ITEM_H, 1))
        local visRows = math.min(#filtered, MAX_VIS)
        local menuH   = visRows * ITEM_H + SRCH_H + 6
        menu:SetHeight(math.max(menuH, SRCH_H + 12))

        if scrollBar then
            if #filtered <= MAX_VIS then scrollBar:Hide() else scrollBar:Show() end
        end

        local cur = getter()
        for idx, name in ipairs(filtered) do
            local row = CreateFrame("Button", nil, sc)
            row:SetSize(CHILD_W, ITEM_H)
            row:SetPoint("TOPLEFT", 0, -(idx - 1) * ITEM_H)

            local path = fetchPath(name)
            local rPrev = row:CreateTexture(nil, "BORDER")
            rPrev:SetPoint("LEFT", 4, 0); rPrev:SetSize(PREV_W, ITEM_H - 6)
            rPrev:SetBlendMode("ADD")
            if path then rPrev:SetTexture(path) end

            local rTxt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rTxt:SetPoint("LEFT", rPrev, "RIGHT", 4, 0)
            rTxt:SetText(name)
            if name == cur then
                rTxt:SetTextColor(1.0, 1.0, 0.5)
            else
                rTxt:SetTextColor(S.text[1], S.text[2], S.text[3])
            end

            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(S.hl[1], S.hl[2], S.hl[3], S.hl[4])

            row:SetScript("OnClick", function()
                setter(name)
                refreshBtn()
                menu:Hide()
                PlaySound(SOUNDKIT.GS_TITLE_OPTION_OK)
            end)
            rowPool[#rowPool + 1] = row
        end
    end

    srch:SetScript("OnTextChanged", function(self) rebuildMenu(self:GetText()) end)

    -- Click-outside overlay
    local overlay = CreateFrame("Frame", nil, UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN")
    overlay:EnableMouse(true)
    overlay:SetScript("OnMouseDown", function() menu:Hide() end)
    overlay:Hide()

    menu:SetScript("OnHide", function()
        srch:SetText(""); srch:ClearFocus(); ph:Show()
        overlay:Hide()
        if activeMenu == menu then activeMenu = nil end
    end)
    menu:SetScript("OnShow", function()
        overlay:Show()
        activeMenu = menu
    end)

    btn:SetScript("OnClick", function(self)
        if menu:IsShown() then menu:Hide(); return end
        if activeMenu and activeMenu ~= menu then activeMenu:Hide() end
        rebuildMenu()
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT",  self, "BOTTOMLEFT",  0, -2)
        menu:SetPoint("TOPRIGHT", self, "BOTTOMRIGHT", 0, -2)
        menu:Show()
        srch:SetFocus()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    c.refresh = refreshBtn
    return c
end

-- ─── Options panel ────────────────────────────────────────────────────────────

local optionsFrame = nil

local function buildOptionsFrame()
    local PANEL_H = 620

    local f = CreateFrame("Frame", "VoidShieldHelperOptionsFrame", UIParent, "BackdropTemplate")
    f:SetSize(PANEL_W, PANEL_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(S.bg[1], S.bg[2], S.bg[3], S.bg[4])
    f:SetBackdropBorderColor(S.border[1], S.border[2], S.border[3], 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)

    -- Title bar
    local tBar = f:CreateTexture(nil, "ARTWORK")
    tBar:SetHeight(26)
    tBar:SetPoint("TOPLEFT", 1, -1); tBar:SetPoint("TOPRIGHT", -1, -1)
    tBar:SetColorTexture(S.panel[1], S.panel[2], S.panel[3], 1)

    local tTxt = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tTxt:SetPoint("LEFT", tBar, "LEFT", 10, 0)
    tTxt:SetPoint("TOP",  tBar, "TOP",    0, -7)
    tTxt:SetText("VoidShieldHelper — Options")
    tTxt:SetTextColor(S.text[1], S.text[2], S.text[3])

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    closeBtn:SetSize(18, 18); closeBtn:SetPoint("TOPRIGHT", -4, -4)
    darkBackdrop(closeBtn)
    local cX = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cX:SetPoint("CENTER"); cX:SetText("X"); cX:SetTextColor(S.dim[1], S.dim[2], S.dim[3])
    closeBtn:SetScript("OnEnter", function() cX:SetTextColor(1, 0.3, 0.3) end)
    closeBtn:SetScript("OnLeave", function() cX:SetTextColor(S.dim[1], S.dim[2], S.dim[3]) end)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local db      = VoidShieldHelperDB
    local widgets = {}

    -- ── Section: Frames ───────────────────────────────────────────────────────
    sectionHeader(f, "Frames", -34)

    local wDbg = makeCheckbox(f, "Show Debug Window", -52,
        function() return not (db.hideDebug or false) end,
        function(v) db.hideDebug = not v; if VSH.applySettings then VSH.applySettings() end end)
    table.insert(widgets, wDbg)

    local wLck = makeCheckbox(f, "Lock Frames (disable dragging)", -78,
        function() return db.locked or false end,
        function(v) db.locked = v; if VSH.applySettings then VSH.applySettings() end end)
    table.insert(widgets, wLck)

    local wFS = makeSlider(f, "Forecast Scale", 0.5, 2.0, 0.05, -108,
        function() return db.forecastScale or 1.0 end,
        function(v) db.forecastScale = v; if VSH.applySettings then VSH.applySettings() end end)
    table.insert(widgets, wFS)

    local wDS = makeSlider(f, "Debug Scale", 0.5, 2.0, 0.05, -160,
        function() return db.debugScale or 1.0 end,
        function(v) db.debugScale = v; if VSH.applySettings then VSH.applySettings() end end)
    table.insert(widgets, wDS)

    -- ── Forecast Frame appearance ──────────────────────────────────────
    sectionHeader(f, "Forecast Frame", -216)

    local fBgLbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fBgLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -234)
    fBgLbl:SetText("BG Color"); fBgLbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    local fBrdLbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fBrdLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 155, -234)
    fBrdLbl:SetText("Border Color"); fBrdLbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    local fBgSw = makeColorSwatch(f, "", 10, -252, "bgColorR", "bgColorG", "bgColorB", "bgColorA")
    table.insert(widgets, fBgSw)

    local fBrdSw = makeColorSwatch(f, "", 155, -252, "borderColorR", "borderColorG", "borderColorB", "borderColorA")
    table.insert(widgets, fBrdSw)

    local wFBrdSz = makeSlider(f, "Border Size  (0=hidden)", 0, 4, 1, -286,
        function() return db.borderSize or 1 end,
        function(v) db.borderSize = math.floor(v+0.5)
            if VSH.applySettings then VSH.applySettings() end end, "%d")
    table.insert(widgets, wFBrdSz)

    local wFBgTex = makeTextureDropdown(f, "Background Texture", "statusbar", -338,
        function() return db.backdropBg or "" end,
        function(name) db.backdropBg = name
            if VSH.applySettings then VSH.applySettings() end end)
    table.insert(widgets, wFBgTex)

    local wFLtTex = makeTextureDropdown(f, "Light Texture (squares)", "statusbar", -390,
        function() return db.lightTexName or "" end,
        function(name) db.lightTexName = name
            if VSH.applySettings then VSH.applySettings() end end)
    table.insert(widgets, wFLtTex)

    -- ── Debug Frame appearance ──────────────────────────────────────────
    sectionHeader(f, "Debug Frame", -442)

    local dBgLbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dBgLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -460)
    dBgLbl:SetText("BG Color"); dBgLbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    local dBrdLbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dBrdLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 155, -460)
    dBrdLbl:SetText("Border Color"); dBrdLbl:SetTextColor(S.text[1], S.text[2], S.text[3])

    local dBgSw = makeColorSwatch(f, "", 10, -478, "debugBgR", "debugBgG", "debugBgB", "debugBgA")
    table.insert(widgets, dBgSw)

    local dBrdSw = makeColorSwatch(f, "", 155, -478, "debugBorderR", "debugBorderG", "debugBorderB", "debugBorderA")
    table.insert(widgets, dBrdSw)

    local wDBrdSz = makeSlider(f, "Border Size  (0=hidden)", 0, 4, 1, -512,
        function() return db.debugBorderSize or 1 end,
        function(v) db.debugBorderSize = math.floor(v+0.5)
            if VSH.applySettings then VSH.applySettings() end end, "%d")
    table.insert(widgets, wDBrdSz)

    local wDBgTex = makeTextureDropdown(f, "Background Texture", "statusbar", -564,
        function() return db.debugBgTex or "" end,
        function(name) db.debugBgTex = name
            if VSH.applySettings then VSH.applySettings() end end)
    table.insert(widgets, wDBgTex)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 5)
    hint:SetText("/vsh  to toggle")
    hint:SetTextColor(S.dim[1], S.dim[2], S.dim[3])

    f.refresh = function()
        for _, w in ipairs(widgets) do
            if w.refresh then w.refresh() end
        end
    end

    return f
end

function VSH.toggleOptions()
    if not optionsFrame then
        optionsFrame = buildOptionsFrame()
    elseif optionsFrame:IsShown() then
        optionsFrame:Hide()
        return
    end
    optionsFrame:Show()
    optionsFrame:Raise()
    if optionsFrame.refresh then optionsFrame.refresh() end
end
