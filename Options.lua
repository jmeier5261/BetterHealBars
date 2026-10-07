-------------------------------------------------------------------------------
--  Options.lua
--  Settings panel (Game Menu > Options > AddOns > Forever HealPredict, or /fhp)
--  One page with Player / Party / Raid tabs; every control edits the tab's
--  effective settings (party edits raid's while "share" is on).
--
--  Copyright (C) 2026 jmeier5261
--  Licensed under the GNU General Public License v3.0. See LICENSE.
-------------------------------------------------------------------------------
local _, ns = ...

local panel, category
local currentScope = "player"
local refreshers = {}   -- functions that re-read the current scope into widgets

local function S() return ns.GetSettings(currentScope) end

local function Changed()
    ns.Refresh()
end

-- Re-read every widget; keeps linked controls (swatch + opacity, parent +
-- dependent checkbox) in sync after any edit.
local function RefreshWidgets()
    for _, fn in ipairs(refreshers) do fn() end
end

-------------------------------------------------------------------------------
--  Widgets
-------------------------------------------------------------------------------
local function Header(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Note(parent, text, x, y, width)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(width or 280)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- requires: another setting key; this box is disabled while that one is off.
local function Checkbox(parent, label, x, y, key, tooltip, requires)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnClick", function(self)
        S()[key] = self:GetChecked() and true or false
        Changed()
        RefreshWidgets()
    end)
    if requires then
        cb:SetMotionScriptsWhileDisabled(true)
        refreshers[#refreshers + 1] = function()
            local on = S()[requires] and true or false
            cb:SetEnabled(on)
            fs:SetFontObject(on and "GameFontHighlight" or "GameFontDisable")
        end
    end
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    refreshers[#refreshers + 1] = function() cb:SetChecked(S()[key] and true or false) end
    return cb
end

local function Swatch(parent, anchor, key)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    b:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    local border = b:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0.8, 0.8, 0.8, 1)
    local color = b:CreateTexture(nil, "ARTWORK")
    color:SetPoint("TOPLEFT", 2, -2)
    color:SetPoint("BOTTOMRIGHT", -2, 2)
    color:SetColorTexture(1, 1, 1, 1)
    local function Show()
        local c = S()[key]
        color:SetColorTexture(c.r, c.g, c.b, c.a or 1)
    end
    b:SetScript("OnClick", function()
        local c = S()[key]
        local orig = { r = c.r, g = c.g, b = c.b, a = c.a or 1 }
        local function Apply()
            local r, g, bl = ColorPickerFrame:GetColorRGB()
            local a = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha() or 1
            local t = S()[key]
            t.r, t.g, t.b, t.a = r, g, bl, a
            RefreshWidgets()
            Changed()
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            r = orig.r, g = orig.g, b = orig.b, opacity = orig.a, hasOpacity = true,
            swatchFunc = Apply,
            opacityFunc = Apply,
            cancelFunc = function()
                local t = S()[key]
                t.r, t.g, t.b, t.a = orig.r, orig.g, orig.b, orig.a
                RefreshWidgets()
                Changed()
            end,
        })
    end)
    refreshers[#refreshers + 1] = Show
    return b
end

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- The Settings panel's own slider art (MinimalSliderTemplate's atlases), or
-- nil when this client lacks any piece.
local function MinimalSliderAtlases()
    local middle = (HasAtlas("_Minimal_SliderBar_Middle") and "_Minimal_SliderBar_Middle")
        or (HasAtlas("Minimal_SliderBar_Middle") and "Minimal_SliderBar_Middle")
    if middle and HasAtlas("Minimal_SliderBar_Left") and HasAtlas("Minimal_SliderBar_Right")
       and HasAtlas("Minimal_SliderBar_Button") then
        return { left = "Minimal_SliderBar_Left", middle = middle, right = "Minimal_SliderBar_Right",
                 thumb = "Minimal_SliderBar_Button" }
    end
end

-- enabledIf: optional function(settings) -> bool; the slider is disabled while it's false.
local function Slider(parent, x, y, key, minV, maxV, fmt, enabledIf)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)
    s:EnableMouseWheel(true)

    -- `track` is the visible bar; labels hang off its ends.
    local track, gap
    local atlas = MinimalSliderAtlases()
    if atlas then
        -- Blizzard's layout: caps at the frame edges, thumb travels flush to them.
        s:SetSize(220, 16)
        s:SetPoint("TOPLEFT", x, y)
        local left = s:CreateTexture(nil, "BORDER")
        left:SetAtlas(atlas.left, true)
        left:SetPoint("LEFT")
        local right = s:CreateTexture(nil, "BORDER")
        right:SetAtlas(atlas.right, true)
        right:SetPoint("RIGHT")
        local middle = s:CreateTexture(nil, "BORDER")
        middle:SetAtlas(atlas.middle)
        middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
        middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
        local thumb = s:CreateTexture(nil, "ARTWORK")
        thumb:SetAtlas(atlas.thumb, true)
        s:SetThumbTexture(thumb)
        track, gap = s, 2
    else
        -- The thumb's center travels from THUMB/2 to width - THUMB/2, so the frame
        -- is widened by THUMB and the track drawn only over that travel. An explicit
        -- thumb size keeps the range right before the texture has loaded.
        local THUMB = 32
        s:SetSize(220 + THUMB, 16)
        s:SetPoint("TOPLEFT", x - THUMB / 2, y)
        s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        s:GetThumbTexture():SetSize(THUMB, THUMB)
        track = s:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT", THUMB / 2, 0)
        track:SetPoint("RIGHT", -THUMB / 2, 0)
        track:SetHeight(6)
        track:SetColorTexture(0, 0, 0, 0.6)
        gap = 7
    end

    local label = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("BOTTOMLEFT", track, "TOPLEFT", 0, gap)
    local low = s:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    low:SetPoint("TOPLEFT", track, "BOTTOMLEFT", 0, 1 - gap)
    low:SetText(minV .. "%")
    local high = s:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    high:SetPoint("TOPRIGHT", track, "BOTTOMRIGHT", 0, 1 - gap)
    high:SetText(maxV .. "%")

    local refreshing = false
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        label:SetText(fmt:format(v))
        if refreshing then return end
        if S()[key] ~= v then
            S()[key] = v
            Changed()
        end
    end)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(self:GetValue() + delta)
    end)
    refreshers[#refreshers + 1] = function()
        refreshing = true
        s:SetValue(S()[key] or minV)
        label:SetText(fmt:format(S()[key] or minV))
        refreshing = false
        if enabledIf then
            local on = enabledIf(S()) and true or false
            s:SetEnabled(on)
            s:GetThumbTexture():SetDesaturated(not on)
            label:SetFontObject(on and "GameFontHighlightSmall" or "GameFontDisableSmall")
        end
    end
    return s
end

local function Button(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 100, 22)
    b:SetText(text)
    return b
end

-------------------------------------------------------------------------------
--  Panel
-------------------------------------------------------------------------------
local tabButtons = {}
local copyButtons = {}
local shareCB, scopeNote

local function RefreshAll()
    if not panel then return end
    for scope, b in pairs(tabButtons) do
        local label = ns.SCOPE_LABELS[scope]
        if ns.db.sharePartyRaid and (scope == "party" or scope == "raid") then label = label .. " *" end
        b:SetText(label)
        if scope == currentScope then b:LockHighlight() else b:UnlockHighlight() end
    end
    shareCB:SetChecked(ns.db.sharePartyRaid)
    local eff = ns.EffectiveScope(currentScope)
    if ns.db.sharePartyRaid and (currentScope == "party" or currentScope == "raid") then
        scopeNote:SetText("Shared: Party uses the Raid settings. Turning sharing off restores Party's previous settings.")
    else
        scopeNote:SetText("Editing: " .. ns.SCOPE_LABELS[currentScope] .. " frames")
    end
    for scope, b in pairs(copyButtons) do
        b:SetEnabled(ns.EffectiveScope(scope) ~= eff)
    end
    RefreshWidgets()
end

local function Build()
    panel = CreateFrame("Frame")
    panel:Hide()
    panel.name = "Forever HealPredict"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Forever HealPredict")
    Note(panel, "Incoming heal prediction for EllesmereUI player, party and raid frames.", 16, -38, 560)

    -- Scope tabs + share toggle
    local x = 16
    for _, scope in ipairs(ns.SCOPES) do
        local b = Button(panel, ns.SCOPE_LABELS[scope], 90)
        b:SetPoint("TOPLEFT", x, -60)
        b:SetScript("OnClick", function()
            currentScope = scope
            RefreshAll()
        end)
        tabButtons[scope] = b
        x = x + 94
    end
    shareCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    shareCB:SetSize(24, 24)
    shareCB:SetPoint("TOPLEFT", x + 12, -59)
    local shareLabel = shareCB:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    shareLabel:SetPoint("LEFT", shareCB, "RIGHT", 2, 1)
    shareLabel:SetText("Party and Raid share settings")
    shareCB:SetScript("OnClick", function(self)
        ns.db.sharePartyRaid = self:GetChecked() and true or false
        if not ns.db.sharePartyRaid then
            ns.Print("sharing off: Party's previous settings are restored.")
        end
        Changed()
        RefreshAll()
    end)
    shareCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Party and Raid share settings", 1, 1, 1)
        GameTooltip:AddLine("While on, party frames use the Raid settings: the Party tab edits them, and "
            .. "copying to Party copies to Raid. Party's previous settings are kept and restored when "
            .. "this is turned off.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    shareCB:SetScript("OnLeave", GameTooltip_Hide)
    scopeNote = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scopeNote:SetPoint("TOPLEFT", 16, -88)

    -- Left column
    local L = 16
    Header(panel, "Incoming Heals", L, -112)
    local cbMine = Checkbox(panel, "Show my heals", L, -130, "showMine")
    Swatch(panel, cbMine.label, "myColor")
    local cbOther = Checkbox(panel, "Show other players' heals", L, -156, "showOthers")
    Swatch(panel, cbOther.label, "otherColor")
    Checkbox(panel, "Use the health bar's texture", L, -182, "useHealthTexture",
        "Off draws flat colors, which keeps the colors exact.")

    Header(panel, "Extend Past Bar End", L, -218)
    Checkbox(panel, "Allow heals to extend past the end of the bar", L, -236, "overflowEnabled")
    Slider(panel, L + 4, -284, "overflowPct", 0, 100, "Maximum overflow: %d%% of max health")

    -- Right column
    local R = 330
    Header(panel, "Overheal Recolor", R, -112)
    Slider(panel, R + 4, -148, "overhealThreshold", 0, 100, "Threshold: %d%% of my heal wasted")
    local cbMyOH = Checkbox(panel, "Recolor my heals", R, -178, "overhealMine")
    Swatch(panel, cbMyOH.label, "myOverhealColor")
    Note(panel, "While you cast, your heal bar changes color when at least this share of the heal would "
        .. "overheal. The heal's size is measured from your heals on yourself and your target, per spell rank.",
        R, -206, 270)

    Header(panel, "Class Colors", R, -270)
    Checkbox(panel, "Color heals by healer's class", R, -288, "useClassColors",
        "Each group healer's incoming heals are drawn in their EllesmereUI class color. "
        .. "Healers outside your group keep the other players' color.")
    Checkbox(panel, "Also use my class color for my heals", R + 20, -314, "classColorMine",
        "Your heals use your EllesmereUI class color instead of your own color.",
        "useClassColors")
    Slider(panel, R + 4, -358, "classColorAlpha", 0, 100, "Class color opacity: %d%%",
        function(s) return s.useClassColors end)

    -- Copy / reset / test
    Header(panel, "Copy this tab's settings to", L, -360)
    x = L
    for _, scope in ipairs(ns.SCOPES) do
        local b = Button(panel, ns.SCOPE_LABELS[scope], 90)
        b:SetPoint("TOPLEFT", x, -380)
        b:SetScript("OnClick", function()
            if ns.CopyScope(currentScope, scope) then
                ns.Print(("copied %s settings to %s."):format(ns.SCOPE_LABELS[currentScope], ns.SCOPE_LABELS[scope]))
                Changed()
                RefreshAll()
            end
        end)
        copyButtons[scope] = b
        x = x + 94
    end

    local reset = Button(panel, "Reset tab", 100)
    reset:SetPoint("TOPLEFT", L, -418)
    reset:SetScript("OnClick", function()
        ns.ResetScope(currentScope)
        Changed()
        RefreshAll()
    end)
    local test = Button(panel, "Toggle test bars", 130)
    test:SetPoint("LEFT", reset, "RIGHT", 8, 0)
    test:SetScript("OnClick", function() SlashCmdList.FOREVERHEALPREDICT("test") end)
    Note(panel, "Test bars draw fake heals on every frame; alternate frames show the overheal color, "
        .. "and with class colors on, part of the other players' bar shows a sample healer class. "
        .. "Units at full health only show them inside the overflow area.", L, -446, 560)

    Header(panel, "Master Opacity", L, -496)
    Slider(panel, L + 4, -532, "masterOpacity", 0, 100, "Master opacity: %d%%",
        function(s) return not s.useClassColors end)
    Note(panel, "Scales the opacity of every color you picked above (your heals, other players' heals "
        .. "and the overheal color), on top of each color's own opacity. Off while class colors are "
        .. "on, since those use the class color opacity instead.", R, -516, 270)

    panel:SetScript("OnShow", RefreshAll)
end

function ns.InitOptions()
    if panel then return end
    Build()
    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    end
end

function ns.OpenOptions()
    currentScope = ns.SCOPES[1]
    RefreshAll()
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    end
end
