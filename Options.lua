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
local currentScope = "raid"
local refreshers = {}   -- functions that re-read the current scope into widgets

local function S() return ns.GetSettings(currentScope) end

local function Changed()
    ns.Refresh()
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

local function Checkbox(parent, label, x, y, key, tooltip)
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
    end)
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
            Show()
            Changed()
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            r = orig.r, g = orig.g, b = orig.b, opacity = orig.a, hasOpacity = true,
            swatchFunc = Apply,
            opacityFunc = Apply,
            cancelFunc = function()
                local t = S()[key]
                t.r, t.g, t.b, t.a = orig.r, orig.g, orig.b, orig.a
                Show()
                Changed()
            end,
        })
    end)
    refreshers[#refreshers + 1] = Show
    return b
end

local function Slider(parent, x, y, key, minV, maxV, fmt)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(220, 16)
    s:SetPoint("TOPLEFT", x, y)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)
    s:EnableMouseWheel(true)
    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(6)
    track:SetColorTexture(0, 0, 0, 0.6)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local label = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
    local low = s:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    low:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -1)
    low:SetText(minV .. "%")
    local high = s:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    high:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", 0, -1)
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
        scopeNote:SetText("Editing: Party & Raid (shared)")
    else
        scopeNote:SetText("Editing: " .. ns.SCOPE_LABELS[currentScope] .. " frames")
    end
    for scope, b in pairs(copyButtons) do
        b:SetEnabled(ns.EffectiveScope(scope) ~= eff)
    end
    for _, fn in ipairs(refreshers) do fn() end
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
        Changed()
        RefreshAll()
    end)
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
    Slider(panel, R + 4, -148, "overhealThreshold", 0, 100, "Threshold: %d%% over max health")
    local cbMyOH = Checkbox(panel, "Recolor my heals", R, -178, "overhealMine")
    Swatch(panel, cbMyOH.label, "myOverhealColor")
    local cbOtherOH = Checkbox(panel, "Recolor other players' heals", R, -204, "overhealOthers")
    Swatch(panel, cbOtherOH.label, "otherOverhealColor")
    Note(panel, "Bars switch color when health + all incoming heals exceed max health by the threshold.",
        R, -232, 270)

    Header(panel, "Heal Order", R, -270)
    Checkbox(panel, "Order heals by landing time", R, -288, "landingOrder",
        "While you are casting, other healers' casts that finish before yours are drawn ahead of your heal. "
        .. "Needs readable cast times; when the client hides them (restricted combat) your heals are drawn first.")
    Note(panel, "Uses each healer's cast end time, not cast start. Falls back to your heals first when the client hides cast times.",
        R, -316, 270)

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
    Note(panel, "Test bars draw fake heals on every frame; alternate frames show the overheal colors. "
        .. "Units at full health only show them inside the overflow area.", L, -446, 560)

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
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    end
end
