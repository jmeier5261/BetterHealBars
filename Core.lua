-------------------------------------------------------------------------------
--  Core.lua
--  Incoming heal bars on EllesmereUI frames (raid + party from
--  EllesmereUIRaidFrames, the player frame from EllesmereUIUnitFrames).
--
--  WoW Forever runs the 12.x restricted API: in combat, heal / health values
--  can be SECRET. Secrets may be passed to StatusBar:SetValue /
--  SetMinMaxValues / SetVertexColor, but cannot be compared, tested or used in
--  arithmetic. Everything below is laid out so no secret is ever inspected:
--    * amounts come from a UnitHealPredictionCalculator and go straight to
--      StatusBars that are chained by anchors (the layout engine does the sum),
--    * the overflow limit is the calculator's overflow percent + a clip frame,
--    * overheal: while you cast, the part of your heal that fits (a secret)
--      is the value of a StatusBar whose range is one HP wide around a plain
--      cut-off (from your heal's size and the threshold). The bar's clamping
--      leaves it either empty or full, and that geometry picks the color,
--    * your heal's size is the average of your measured non-crit heals of
--      that spell ID (so per rank), else the spell tooltip's average,
--    * class colors split "others" into one bar per group healer, each read
--      with that healer as the calculator's source.
--
--  Copyright (C) 2026 jmeier5261
--  Licensed under the GNU General Public License v3.0. See LICENSE.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local issecretvalue = issecretvalue or function() return false end
local CreateFrame, UnitExists, UnitIsUnit, UnitClass = CreateFrame, UnitExists, UnitIsUnit, UnitClass
local pairs, ipairs, wipe, type, tonumber = pairs, ipairs, wipe, type, tonumber

local WHITE = "Interface\\Buttons\\WHITE8X8"
local EMPTY = {}
-- Other classes' heals still show, in the "other players" color.
local HEALER_CLASSES = { PRIEST = true, DRUID = true, PALADIN = true, SHAMAN = true, MONK = true, EVOKER = true }
local TEST_CLASSES = { "PRIEST", "DRUID", "PALADIN", "SHAMAN", "MONK", "EVOKER" }

-- Region points per growth direction. NEAR = a bar's leading edge (where it
-- starts), FAR = a fill's trailing edge (where the next bar chains on). Paired
-- index-wise: NEAR[d][i] of the new bar sits on FAR[d][i] of the previous fill.
local NEAR = {
    RIGHT = { "TOPLEFT", "BOTTOMLEFT" },   LEFT = { "TOPRIGHT", "BOTTOMRIGHT" },
    UP    = { "BOTTOMLEFT", "BOTTOMRIGHT" }, DOWN = { "TOPLEFT", "TOPRIGHT" },
}
local FAR = {
    RIGHT = { "TOPRIGHT", "BOTTOMRIGHT" }, LEFT = { "TOPLEFT", "BOTTOMLEFT" },
    UP    = { "TOPLEFT", "TOPRIGHT" },     DOWN = { "BOTTOMLEFT", "BOTTOMRIGHT" },
}
-- The holder corner the "others after mine" clip stretches to.
local FAR_CORNER = { RIGHT = "BOTTOMRIGHT", LEFT = "BOTTOMLEFT", UP = "TOPRIGHT", DOWN = "BOTTOMRIGHT" }

local records = {}   -- owner frame -> rec
local recList = {}
local unitMap = {}   -- unit token -> { rec, ... }
local mapDirty = true
local dirty = {}
local allDirty = false
local calc, scratch  -- shared calculators (paints are sequential)
local roster = {}    -- flat { unit, classToken, ... }: group healers other than you
local playerClass
local myCast         -- { spell, size, source } while you cast, else nil
local healSizes = {} -- spellID -> { avg, n } measured heals; the saved table once logged in

ns.settingsGen = 0
ns.testMode = false
ns.castDebug = false
ns.stats = {
    secretAmounts = false, lastError = nil, apiOK = false, lastCast = nil,
    castTimes = { player = { plain = 0, secret = 0, missing = 0 }, others = { plain = 0, secret = 0, missing = 0 } },
}

-------------------------------------------------------------------------------
--  Painting
-------------------------------------------------------------------------------
local function NewBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar._tex = WHITE
    return bar
end

-- mult: master opacity multiplier applied on top of the color's own alpha.
local function ColorTex(tex, c, mult)
    tex:SetVertexColor(c.r, c.g, c.b)
    tex:SetAlpha((c.a or 1) * mult)
end

local function SetColor(bar, c, mult)
    local tex = bar:GetStatusBarTexture()
    if tex then ColorTex(tex, c, mult) end
end

-- EllesmereUI's palette (custom colors + darken) when readable; a secret token
-- can't be a table key, so it gets Blizzard's shade. Fills `out` with the
-- given opacity; returns `fallback` when the class is unknown.
local function ClassColor(token, alpha, out, fallback)
    local c
    if issecretvalue(token) then
        c = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(token)
    elseif not token then
        return fallback
    elseif EllesmereUI and EllesmereUI.GetClassColor then
        c = EllesmereUI.GetClassColor(token)
    else
        c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    end
    if not c then return fallback end
    out.r, out.g, out.b, out.a = c.r, c.g, c.b, alpha
    return out
end

local function PlaceBar(bar, target, pts, near, vert, rev, w, h, tex)
    bar:ClearAllPoints()
    bar:SetPoint(near[1], target, pts[1], 0, 0)
    bar:SetPoint(near[2], target, pts[2], 0, 0)
    if vert then bar:SetHeight(h) else bar:SetWidth(w) end
    bar:SetOrientation(vert and "VERTICAL" or "HORIZONTAL")
    bar:SetReverseFill(rev)
    if bar.SetRotatesTexture then bar:SetRotatesTexture(vert) end
    if bar._tex ~= tex then
        bar:SetStatusBarTexture(tex)
        bar._tex = tex
    end
end

-- Anchors only; skipped when nothing that affects geometry has changed.
local function Layout(rec, S, nS)
    local health = rec.health
    local fill = health:GetStatusBarTexture()
    if not fill then return false end

    local vert = health:GetOrientation() == "VERTICAL"
    local inv = health:GetReverseFill() and true or false
    local dir, seamPts
    if rec.kind == "rf" then
        -- EllesmereUI "Inverted Fill": the fill paints MISSING health, so the
        -- current-health seam is the fill's near edge and heals still grow
        -- right / up into the fill.
        dir = vert and "UP" or "RIGHT"
        seamPts = inv and NEAR[dir] or FAR[dir]
    else
        -- Unit frames: a reversed bar is a mirrored bar; heals grow the other way.
        if vert then dir = inv and "DOWN" or "UP" else dir = inv and "LEFT" or "RIGHT" end
        seamPts = FAR[dir]
    end
    local w, h = health:GetWidth(), health:GetHeight()
    local ext = S.overflowEnabled and ((vert and h or w) * (S.overflowPct or 0) / 100) or 0
    local tex = (S.useHealthTexture and fill:GetTexture()) or WHITE

    local L = rec.L
    if L.fill == fill and L.dir == dir and L.inv == inv and L.w == w and L.h == h
       and L.ext == ext and L.nS == nS and L.tex == tex and L.gen == ns.settingsGen then
        return true
    end
    L.fill, L.dir, L.inv, L.w, L.h, L.ext, L.nS, L.tex, L.gen = fill, dir, inv, w, h, ext, nS, tex, ns.settingsGen

    -- Holder = health bar rect plus the overflow allowance; it clips everything.
    local holder = rec.holder
    holder:SetFrameLevel(health:GetFrameLevel() + 1)
    holder:ClearAllPoints()
    local l, r, t, b = 0, 0, 0, 0
    if dir == "RIGHT" then r = ext elseif dir == "LEFT" then l = -ext
    elseif dir == "UP" then t = ext else b = -ext end
    holder:SetPoint("TOPLEFT", health, "TOPLEFT", l, t)
    holder:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", r, b)

    local near, far = NEAR[dir], FAR[dir]
    local rev = (dir == "LEFT" or dir == "DOWN")

    -- Chain: [your heals] -> [one bar per group healer (class colors)]
    local prev, prevPts = fill, seamPts
    if S.showMine then
        PlaceBar(rec.mine, prev, prevPts, near, vert, rev, w, h, tex)
        rec.mine:Show()
        local mineFill = rec.mine:GetStatusBarTexture()
        prev, prevPts = mineFill, far

        -- Overheal flag over your fill: flagBar ends up empty or full (see
        -- Paint); flagRest covers whatever part of your fill it leaves bare.
        local fb, fr = rec.flagBar, rec.flagRest
        fb:SetFrameLevel(rec.mine:GetFrameLevel() + 1)
        fb:ClearAllPoints()
        fb:SetAllPoints(mineFill)
        fb:SetOrientation(vert and "VERTICAL" or "HORIZONTAL")
        fb:SetReverseFill(rev)
        if fb.SetRotatesTexture then fb:SetRotatesTexture(vert) end
        if fb._tex ~= tex then
            fb:SetStatusBarTexture(tex)
            fb._tex = tex
        end
        local fbFill = fb:GetStatusBarTexture()
        fr:SetTexture(tex)
        fr:ClearAllPoints()
        fr:SetPoint(near[1], fbFill, far[1], 0, 0)
        fr:SetPoint(near[2], fbFill, far[2], 0, 0)
        fr:SetPoint(far[1], mineFill, far[1], 0, 0)
        fr:SetPoint(far[2], mineFill, far[2], 0, 0)
    else
        rec.mine:Hide()
    end
    for i = 1, nS do
        local seg = rec.segs[i]
        if not seg then
            seg = NewBar(holder)
            rec.segs[i] = seg
        end
        PlaceBar(seg, prev, prevPts, near, vert, rev, w, h, tex)
        seg:Show()
        prev, prevPts = seg:GetStatusBarTexture(), far
    end
    for i = nS + 1, #rec.segs do rec.segs[i]:Hide() end

    -- Remaining others: a bar of the full amount drawn from the seam, but seen
    -- only through a clip that starts where the chain ends. That shows exactly
    -- (total - drawn so far) without subtracting secret numbers.
    local ac = rec.afterClip
    if S.showOthers then
        ac:ClearAllPoints()
        ac:SetPoint(near[1], prev, prevPts[1], 0, 0)
        ac:SetPoint(FAR_CORNER[dir], holder, FAR_CORNER[dir], 0, 0)
        PlaceBar(rec.rest, fill, seamPts, near, vert, rev, w, h, tex)
        ac:Show()
        rec.rest:Show()
    else
        ac:Hide()
    end
    return true
end

-- Most of your heal that can land and still count as wasting >= pct% (and >= 1).
local function OverhealCut(size, pct)
    return math.floor(math.min(size * (1 - (pct or 0) / 100), size - 1))
end

local function SetRange(bar, maxHP)
    bar:SetMinMaxValues(0, maxHP)
end

local function Paint(rec)
    local S = ns.GetSettings(rec.scope)
    local unit = rec.unit
    if not (S.showMine or S.showOthers) or not unit or not rec.owner:IsVisible() or not UnitExists(unit) then
        rec.holder:Hide()
        return
    end

    local total, mine, others, maxHP, over
    local mineFit, useFlag   -- mineFit may be SECRET; useFlag is the plain "have it" flag
    local nS = 0
    local segVals, segClass = rec.segVals, rec.segClass
    local bySource = S.useClassColors and S.showOthers

    if ns.testMode then
        maxHP, mine, others, total = 100, 20, 15, 35
        if bySource then
            nS = 1
            segVals[1] = 8
            segClass[1] = TEST_CLASSES[rec.testIndex % #TEST_CLASSES + 1]
        end
        over = (rec.testIndex % 2 == 0)
    else
        local overflow = S.overflowEnabled and (1 + (S.overflowPct or 0) / 100) or 1
        calc:SetIncomingHealOverflowPercent(overflow)
        UnitGetDetailedHealPrediction(unit, "player", calc)
        total, mine, others = calc:GetIncomingHeals()
        maxHP = calc:GetMaximumHealth()
        if myCast and myCast.size and S.overhealMine and S.showMine then
            -- Same fill, re-evaluated, capped at missing health: the part of
            -- your heal that lands.
            calc:SetIncomingHealOverflowPercent(1)
            local _, fit = calc:GetIncomingHeals()
            mineFit, useFlag = fit, true
        end
        ns.stats.secretAmounts = issecretvalue(total)
        if bySource then
            -- Healer as the source: its "mine" is that healer's amount on this unit.
            scratch:SetIncomingHealOverflowPercent(overflow)
            for i = 1, #roster, 2 do
                UnitGetDetailedHealPrediction(unit, roster[i], scratch)
                local _, amt = scratch:GetIncomingHeals()
                nS = nS + 1
                segVals[nS] = amt
                segClass[nS] = roster[i + 1]
            end
        end
    end

    if not issecretvalue(maxHP) and (maxHP or 0) <= 0 then
        rec.holder:Hide()
        return
    end
    if not Layout(rec, S, nS) then
        rec.holder:Hide()
        return
    end

    local classAlpha = (S.classColorAlpha or 60) / 100
    -- Class colors have their own opacity, so the master multiplier is off with them.
    local master = S.useClassColors and 1 or (S.masterOpacity or 100) / 100
    if S.showMine then
        SetRange(rec.mine, maxHP)
        rec.mine:SetValue(mine)
        local myColor = S.myColor
        if S.useClassColors and S.classColorMine then
            myColor = ClassColor(playerClass, classAlpha, rec.mineColor, S.myColor)
        end
        if useFlag then
            -- Wasted >= threshold (and >= 1) <=> lands <= cut. Over the range
            -- [cut, cut + 1] the bar clamps whole amounts to empty (flagged)
            -- or full (not), so flagRest shows over all of your fill or none.
            local cut = OverhealCut(myCast.size, S.overhealThreshold)
            local fb = rec.flagBar
            fb:SetMinMaxValues(cut, cut + 1)
            fb:SetValue(mineFit)
            SetColor(fb, myColor, master)
            ColorTex(rec.flagRest, S.myOverhealColor, master)
            fb:Show()
            -- Your own fill only sets the size; the flag pair draws the colors.
            rec.mine:GetStatusBarTexture():SetAlpha(0)
        else
            rec.flagBar:Hide()
            SetColor(rec.mine, (S.overhealMine and over) and S.myOverhealColor or myColor, master)
        end
    else
        rec.flagBar:Hide()
    end
    for i = 1, nS do
        local seg = rec.segs[i]
        SetRange(seg, maxHP)
        seg:SetValue(segVals[i])
        local cols = rec.segColors
        cols[i] = cols[i] or {}
        SetColor(seg, ClassColor(segClass[i], classAlpha, cols[i], S.otherColor), master)
    end
    if S.showOthers then
        SetRange(rec.rest, maxHP)
        -- Explicit branch: `a and total or others` would truth-test a secret.
        if S.showMine then rec.rest:SetValue(total) else rec.rest:SetValue(others) end
        SetColor(rec.rest, S.otherColor, master)
    end
    rec.holder:Show()
end

local function SafePaint(rec)
    local ok, err = pcall(Paint, rec)
    if not ok and ns.stats.lastError ~= err then
        ns.stats.lastError = err
        print("|cff33ccffForever HealPredict|r error: " .. tostring(err))
    end
end

-------------------------------------------------------------------------------
--  Dirty tracking (coalesced to one paint per frame per record)
-------------------------------------------------------------------------------
local function UnitOf(rec)
    if rec.kind == "rf" then return rec.owner:GetAttribute("unit") end
    return rec.owner.unit or "player"
end

local function AddToMap(u, rec)
    local l = unitMap[u]
    if not l then l = {}; unitMap[u] = l end
    l[#l + 1] = rec
end

local function RebuildMap()
    wipe(unitMap)
    for _, rec in ipairs(recList) do
        local u = UnitOf(rec)
        rec.unit = u
        if u and rec.owner:IsVisible() then
            AddToMap(u, rec)
            -- Events for you may arrive as "player" rather than your raid/party token.
            if u ~= "player" then
                local same = UnitIsUnit(u, "player")
                if not issecretvalue(same) and same then AddToMap("player", rec) end
            end
        end
    end
    mapDirty = false
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self)
    self:Hide()
    if not ns.stats.apiOK then return end
    if mapDirty then RebuildMap() end
    if allDirty then
        allDirty = false
        wipe(dirty)
        for _, rec in ipairs(recList) do SafePaint(rec) end
        return
    end
    for rec in pairs(dirty) do
        dirty[rec] = nil
        SafePaint(rec)
    end
end)

local function MarkDirty(rec)
    dirty[rec] = true
    driver:Show()
end

local function MarkUnit(unit)
    if mapDirty then RebuildMap() end
    local l = unitMap[unit]
    if not l then return end
    for i = 1, #l do dirty[l[i]] = true end
    driver:Show()
end

local function MarkAll()
    mapDirty = true
    allDirty = true
    driver:Show()
end
ns.MarkAll = MarkAll

-- Settings changed: force re-layout and repaint everything.
function ns.Refresh()
    ns.settingsGen = ns.settingsGen + 1
    MarkAll()
end

-------------------------------------------------------------------------------
--  Frame discovery
-------------------------------------------------------------------------------
local function HookHealth(rec, health)
    if health._fhpHooked then return end
    health._fhpHooked = true
    health:HookScript("OnSizeChanged", function()
        local r = records[rec.owner]
        if r and r.health == health then
            r.L.w = nil
            MarkDirty(r)
        end
    end)
end

local function BuildRecord(owner, health, kind, scope)
    local rec = {
        owner = owner, health = health, kind = kind, scope = scope, L = {},
        segs = {}, segVals = {}, segClass = {}, segColors = {}, mineColor = {},
    }
    local holder = CreateFrame("Frame", nil, owner)
    holder:SetClipsChildren(true)
    holder:Hide()
    rec.holder = holder
    local ac = CreateFrame("Frame", nil, holder)
    ac:SetClipsChildren(true)
    rec.afterClip = ac
    rec.rest = NewBar(ac)
    rec.mine = NewBar(holder)
    rec.flagBar = NewBar(holder)
    rec.flagBar:Hide()
    rec.flagRest = rec.flagBar:CreateTexture(nil, "ARTWORK")

    records[owner] = rec
    recList[#recList + 1] = rec
    rec.testIndex = #recList
    HookHealth(rec, health)

    if kind == "rf" then
        owner:HookScript("OnAttributeChanged", function(_, name)
            if name == "unit" then
                mapDirty = true
                MarkDirty(rec)
            end
        end)
    end
    owner:HookScript("OnShow", function() mapDirty = true; MarkDirty(rec) end)
    owner:HookScript("OnHide", function() mapDirty = true end)
    return rec
end

-- Returns true when something new was attached.
local function Attach(owner, health, kind, scope)
    if not (owner and health and health.GetStatusBarTexture) then return false end
    local rec = records[owner]
    if not rec then
        BuildRecord(owner, health, kind, scope)
        return true
    end
    local changed = false
    if rec.scope ~= scope then rec.scope = scope; changed = true end
    if rec.health ~= health then
        -- Unit frame rebuilt its health bar (EllesmereUI reload of frames).
        rec.health = health
        wipe(rec.L)
        HookHealth(rec, health)
        changed = true
    end
    return changed
end

local function RaidFramesNS()
    local reg = EllesmereUI and EllesmereUI._ModuleNS
    return reg and reg.EllesmereUIRaidFrames
end
ns.RaidFramesNS = RaidFramesNS

local function Scan()
    local changed = false
    local rns = RaidFramesNS()
    if rns and rns.GetFFD then
        for _, btn in ipairs(rns._allButtons or EMPTY) do
            local d = rns.GetFFD(btn)
            if d.health then
                changed = Attach(btn, d.health, "rf", d._isParty and "party" or "raid") or changed
            end
        end
        for _, btn in ipairs(rns._partyAllButtons or EMPTY) do
            local d = rns.GetFFD(btn)
            if d.health then changed = Attach(btn, d.health, "rf", "party") or changed end
        end
    end
    local pf = _G.EllesmereUIUnitFrames_Player
    if pf and pf.Health then
        changed = Attach(pf, pf.Health, "uf", "player") or changed
    end
    if changed then MarkAll() end
end
ns.Scan = Scan

function ns.CountFrames()
    local counts = { player = 0, party = 0, raid = 0 }
    local shown = { player = 0, party = 0, raid = 0 }
    for _, rec in ipairs(recList) do
        counts[rec.scope] = counts[rec.scope] + 1
        if rec.holder:IsShown() then shown[rec.scope] = shown[rec.scope] + 1 end
    end
    return counts, shown
end

-------------------------------------------------------------------------------
--  Startup checks
-------------------------------------------------------------------------------
local function NewCalculator()
    local c = CreateUnitHealPredictionCalculator()
    if not (c.GetIncomingHeals and c.SetIncomingHealOverflowPercent and c.SetIncomingHealClampMode) then
        return nil
    end
    c:SetIncomingHealClampMode(Enum.UnitIncomingHealClampMode.MissingHealth)
    if c.SetMaximumHealthMode and Enum.UnitMaximumHealthMode then
        c:SetMaximumHealthMode(Enum.UnitMaximumHealthMode.Default)
    end
    if c.SetHealAbsorbMode and Enum.UnitHealAbsorbMode then
        c:SetHealAbsorbMode(Enum.UnitHealAbsorbMode.ReducedByIncomingHeals)
    end
    return c
end

local function InitCalculators()
    if not (CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction and Enum
            and Enum.UnitIncomingHealClampMode) then
        return false
    end
    calc, scratch = NewCalculator(), NewCalculator()
    return calc ~= nil and scratch ~= nil
end

-- Group members whose heals get their own class-colored bar. Your own token
-- is skipped (your heals are the "mine" bar); so is any member the client
-- won't confirm isn't you, so your heals are never drawn twice.
local function RebuildRoster()
    wipe(roster)
    local inRaid = IsInRaid()
    local n = GetNumGroupMembers() or 0
    local prefix = inRaid and "raid" or "party"
    local count = inRaid and n or math.max(n - 1, 0)
    for i = 1, count do
        local u = prefix .. i
        local same = UnitIsUnit(u, "player")
        if not issecretvalue(same) and not same then
            local _, token = UnitClass(u)
            if issecretvalue(token) or (token and HEALER_CLASSES[token]) then
                roster[#roster + 1] = u
                roster[#roster + 1] = token
            end
        end
    end
end

-- Which EllesmereUI frame types still have their own heal prediction on.
function ns.BuiltInPredictionScopes()
    local on = {}
    local rns = RaidFramesNS()
    if rns then
        if rns._scaledProfile and rns._scaledProfile.healPrediction then on[#on + 1] = "Raid Frames" end
        if rns._scaledPartyProxy and rns._scaledPartyProxy.healPrediction then on[#on + 1] = "Party Frames" end
    end
    local pf = _G.EllesmereUIUnitFrames_Player
    local ab = pf and pf.HealthPrediction and pf.HealthPrediction.damageAbsorb
    if ab and ab._predOn then on[#on + 1] = "Player Frame" end
    return on
end

-------------------------------------------------------------------------------
--  Your heal casts (the overheal recolor needs the heal's size as a plain number)
-------------------------------------------------------------------------------
-- The spell's description, or nil when there's none readable.
local function SpellDescription(spellID)
    local get = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
    local text = get and get(spellID)
    if type(text) ~= "string" or issecretvalue(text) then return nil end
    return text
end

-- Average of "X to Y" (or the first amount after "heal") in the spell's
-- description, plus the low and high ends; nil when there's no readable heal amount.
local function TooltipHealSize(spellID)
    local text = SpellDescription(spellID)
    if not text then return nil end
    text = text:gsub("(%d),(%d)", "%1%2")
    if not text:lower():find("heal") then return nil end
    local lo, hi = text:match("(%d+) to (%d+)")
    if lo then
        lo, hi = tonumber(lo), tonumber(hi)
        return (lo + hi) / 2, lo, hi
    end
    local n = tonumber(text:match("[Hh]eal[^%.]-(%d+)"))
    if n then return n, n, n end
end

local function SpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
    return GetSpellInfo and (GetSpellInfo(spellID)) or tostring(spellID)
end

-- "Healing Wave (Rank 4)". Each rank is its own spell ID, so it's measured separately.
local function SpellLabel(spellID)
    local name = tostring(SpellName(spellID) or spellID)
    local get = (C_Spell and C_Spell.GetSpellSubtext) or GetSpellSubtext
    local rank = get and get(spellID)
    if type(rank) == "string" and not issecretvalue(rank) and rank ~= "" then
        return ("%s (%s)"):format(name, rank)
    end
    return name
end

local function IsGroupToken(u)
    if u == "player" then return true end
    if IsInRaid() then return u:find("^raid%d") ~= nil end
    return u:find("^party%d") ~= nil
end

local function Readable(v, fallback)
    if issecretvalue(v) then return "|cffff4040<hidden>|r" end
    if v == nil then v = fallback end
    return tostring(v)
end

local function Print(msg) print("|cff33ccffForever HealPredict|r " .. msg) end
ns.Print = Print

-- Tallies whether a group cast's end time is readable; /fhp casts prints it.
local function CastTimeCheck(u)
    local who = (u == "player") and "player" or "others"
    if who == "others" then
        -- Your own raid/party token would duplicate "player".
        local same = UnitIsUnit(u, "player")
        if not issecretvalue(same) and same then return end
    end
    local counts = ns.stats.castTimes[who]
    local _, _, _, _, endMs = UnitCastingInfo(u)
    local endText
    if issecretvalue(endMs) then
        counts.secret = counts.secret + 1
        endText = "|cffff4040hidden by client|r"
    elseif not endMs then
        counts.missing = counts.missing + 1
        endText = "|cffff4040no cast info|r"
    else
        counts.plain = counts.plain + 1
        endText = ("|cff40ff40readable|r, lands in %.2fs"):format((endMs - GetTime() * 1000) / 1000)
    end
    if ns.castDebug then
        print(("|cff33ccffFHP|r caster: %s (%s), spell: %s, end time: %s"):format(
            Readable(UnitName(u), "?"), u, Readable(UnitCastingInfo(u), "?"), endText))
    end
end

-------------------------------------------------------------------------------
--  Measured heal sizes. The combat log is Blizzard-only here, but UNIT_COMBAT
--  reports heals landing on you or your target with a readable amount and a
--  crit flag (no caster); its amount includes overheal. A heal is matched to
--  your cast that just succeeded, on the unit the cast was sent to. The
--  tooltip already follows your healing power, so what's kept per spell ID
--  (so per rank) is a running average of heal / tooltip average: gear swaps
--  apply at once, and the ratio covers what the tooltip leaves out (talents).
-------------------------------------------------------------------------------
local PRIOR_WEIGHT = 10    -- each spell starts at x1.00, worth this many heals (rolls are noisy)
local MAX_WEIGHT = 30      -- the newest heal always counts at least 1/30
local MATCH_WINDOW = 0.6   -- seconds between your cast succeeding and its heal landing
local sentTarget           -- name your current cast was sent to
local pendingCast          -- { spell, target, t }: succeeded, heal not seen yet
local pendingHeal          -- { unit, name, amount, flag, t }: landed, cast not matched yet
ns.healLog = false         -- /fhp combatlog prints every heal and what happened to it

local function Round(x) return math.floor(x + 0.5) end

-- The ratio to use (heals blended with the x1.00 start), the heal count, and
-- the heals' own average; nil when nothing has been measured.
local function Measured(spellID)
    local m = healSizes[spellID]
    if type(m) ~= "table" then return end
    local w = math.min(m.n, MAX_WEIGHT)
    return (m.ratio * w + PRIOR_WEIGHT) / (w + PRIOR_WEIGHT), m.n, m.ratio
end

local function AddSample(spellID, ratio)
    local m = healSizes[spellID]
    if type(m) ~= "table" then
        m = { ratio = 0, n = 0 }
        healSizes[spellID] = m
    end
    m.n = m.n + 1
    m.ratio = m.ratio + (ratio - m.ratio) / math.min(m.n, MAX_WEIGHT)
end

-- The cast's target as sent ("Name", "Name Surname" or "Name-Realm") is this unit name.
local function SameName(sent, name)
    if not name then return false end
    sent = sent:match("^[^-]+")
    return sent == name or sent:sub(1, #name + 1) == name .. " "
end

-- Returns true when the heal was used, else false and why.
local function TrySample(cast, heal)
    if math.abs(heal.t - cast.t) > MATCH_WINDOW then return false, "no cast of yours just finished" end
    if heal.flag == "CRITICAL" then return false, "crit" end
    if cast.target then
        if not SameName(cast.target, heal.name) then return false, "your cast was sent to " .. cast.target end
    elseif heal.unit ~= "player" then
        return false, "your cast's target is unknown"
    end
    local base, lo, hi = TooltipHealSize(cast.spell)
    if not base or base <= 0 then return false, "no heal amount in the tooltip" end
    if heal.amount < lo * 0.9 or heal.amount > hi * 1.5 then
        return false, ("outside the tooltip range %d to %d"):format(lo, hi)
    end
    AddSample(cast.spell, heal.amount / base)
    return true
end

local function LogSample(heal, spellID, used, why)
    if not ns.healLog then return end
    local verdict
    if used then
        local ratio, n, raw = Measured(spellID)
        verdict = ("|cff40ff40used|r for %s: heals land at x%.3f of the tooltip average over %d; using x%.3f")
            :format(SpellLabel(spellID), raw, n, ratio)
    else
        verdict = "|cffffd100not used|r: " .. why
    end
    print(("|cff33ccffFHP|r heal on %s: %d%s; %s"):format(heal.unit, heal.amount,
        heal.flag == "CRITICAL" and " (crit)" or "", verdict))
end

local function OnHealLanded(unit, action, flag, amount)
    if issecretvalue(action) or action ~= "HEAL" then return end
    if issecretvalue(amount) or type(amount) ~= "number" or amount <= 0 or issecretvalue(flag) then
        if ns.healLog then print("|cff33ccffFHP|r heal on " .. unit .. ": amount or flag |cffff4040hidden|r") end
        return
    end
    local name = UnitName(unit)
    local heal = { unit = unit, name = not issecretvalue(name) and name or nil, amount = amount, flag = flag,
                   t = GetTime() }
    if pendingCast and heal.t - pendingCast.t > MATCH_WINDOW then pendingCast = nil end
    if pendingCast then
        local cast = pendingCast
        local used, why = TrySample(cast, heal)
        if used then pendingCast = nil end
        LogSample(heal, cast.spell, used, why)
    else
        -- The heal can arrive just before your cast's "succeeded" event.
        pendingHeal = heal
        if ns.healLog then
            print(("|cff33ccffFHP|r heal on %s: %d%s; waiting for a cast of yours to finish"):format(
                unit, amount, flag == "CRITICAL" and " (crit)" or ""))
        end
    end
end

local function OnCastSent(target)
    if issecretvalue(target) or type(target) ~= "string" or target == "" then
        sentTarget = nil
    else
        sentTarget = target
    end
end

local function OnCastSucceeded(spellID)
    if issecretvalue(spellID) or not spellID then spellID = myCast and myCast.spell end
    if not spellID then return end
    local cast = { spell = spellID, target = sentTarget, t = GetTime() }
    local heal = pendingHeal
    pendingHeal = nil
    if heal then
        local used, why = TrySample(cast, heal)
        LogSample(heal, spellID, used, why)
        if used then return end
    end
    pendingCast = cast
end

-------------------------------------------------------------------------------
--  Your casts
-------------------------------------------------------------------------------
-- /fhp casts: what the overheal check will use for this cast of yours.
local function CastDebug(c)
    local cuts = {}
    for _, scope in ipairs(ns.SCOPES) do
        cuts[#cuts + 1] = c.size and OverhealCut(c.size, ns.GetSettings(scope).overhealThreshold) or "-"
    end
    print(("|cff33ccffFHP|r   your %s (%d): size %s from %s; cut Player/Party/Raid %s"):format(
        SpellLabel(c.spell), c.spell, c.size and Round(c.size) or "?", c.source, table.concat(cuts, "/")))
    local ratio, n, raw = Measured(c.spell)
    print(("    tooltip average %s; measured %s"):format(c.base and Round(c.base) or "?",
        ratio and ("x%.3f over %d heals, using x%.3f"):format(raw, n, ratio) or "none yet"))
    print("    tooltip: " .. (SpellDescription(c.spell) or "|cffff4040none|r"))
end

local function OnCastStart()
    local spellID = select(9, UnitCastingInfo("player"))
    if issecretvalue(spellID) or not spellID then
        myCast = nil
        return
    end
    local base = TooltipHealSize(spellID)
    myCast = { spell = spellID, base = base }
    local ratio, n = Measured(spellID)
    if base and ratio then
        myCast.size, myCast.source = base * ratio, ("tooltip x%.3f (%d heals measured)"):format(ratio, n)
    elseif base then
        myCast.size, myCast.source = base, "tooltip"
    else
        myCast.source = "unknown"
    end
    ns.stats.lastCast = myCast
    if ns.castDebug then CastDebug(myCast) end
    MarkAll()
end

local function OnCastEnd()
    if not myCast then return end
    myCast = nil
    MarkAll()
end

-- /fhp heals
local function ListHeals()
    local ids = {}
    for id, m in pairs(healSizes) do
        if type(m) == "table" then ids[#ids + 1] = id end
    end
    if #ids == 0 then
        Print("no heals measured yet. Heal yourself or your target (non-crits count).")
        return
    end
    table.sort(ids, function(a, b) return SpellLabel(a) < SpellLabel(b) end)
    Print("measured heals (real heal / tooltip average; each spell starts at x1.00 worth "
        .. PRIOR_WEIGHT .. " heals):")
    for _, id in ipairs(ids) do
        local ratio, n, raw = Measured(id)
        local base = TooltipHealSize(id)
        print(("  %s (%d): x%.3f over %d heals, using x%.3f; tooltip average %s, so size %s"):format(
            SpellLabel(id), id, raw, n, ratio, base and Round(base) or "?", base and Round(base * ratio) or "?"))
    end
end

local function WarnBuiltIn()
    local on = ns.BuiltInPredictionScopes()
    if #on > 0 then
        Print("EllesmereUI's own Heal Prediction is enabled on: " .. table.concat(on, ", ")
            .. ". Turn it off in EllesmereUI options to avoid double bars.")
    end
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

local UNIT_EVENTS = {
    UNIT_HEAL_PREDICTION = true, UNIT_HEALTH = true, UNIT_MAXHEALTH = true,
    UNIT_HEAL_ABSORB_AMOUNT_CHANGED = true,
}
local CAST_START = { UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_DELAYED = true }
local CAST_END = {
    UNIT_SPELLCAST_STOP = true, UNIT_SPELLCAST_FAILED = true,
    UNIT_SPELLCAST_INTERRUPTED = true, UNIT_SPELLCAST_SUCCEEDED = true,
}

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if UNIT_EVENTS[event] then
        MarkUnit(arg1)
    elseif event == "UNIT_COMBAT" then
        OnHealLanded(arg1, arg2, arg3, arg4)
    elseif event == "UNIT_SPELLCAST_SENT" then
        if arg1 == "player" then OnCastSent(arg2) end
    elseif CAST_START[event] or CAST_END[event] then
        if not (arg1 and IsGroupToken(arg1)) then return end
        if CAST_START[event] then CastTimeCheck(arg1) end
        if arg1 == "player" then
            if CAST_START[event] then
                OnCastStart()
            else
                if event == "UNIT_SPELLCAST_SUCCEEDED" then OnCastSucceeded(arg3) end
                OnCastEnd()
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        RebuildRoster()
        Scan()
        MarkAll()
    elseif event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then ns.InitDB() end
    elseif event == "PLAYER_LOGIN" then
        ns.stats.apiOK = InitCalculators()
        if not ns.stats.apiOK then
            Print("|cffff4040this client has no heal prediction calculator API; the addon is inactive.|r")
            return
        end
        for e in pairs(UNIT_EVENTS) do events:RegisterEvent(e) end
        for e in pairs(CAST_START) do events:RegisterEvent(e) end
        for e in pairs(CAST_END) do events:RegisterEvent(e) end
        events:RegisterEvent("UNIT_SPELLCAST_SENT")
        events:RegisterUnitEvent("UNIT_COMBAT", "player", "target")
        local guid = UnitGUID("player")
        if guid and not issecretvalue(guid) then
            ns.db.healSizes[guid] = ns.db.healSizes[guid] or {}
            healSizes = ns.db.healSizes[guid]
            -- Older builds stored a number or an absolute average per spell.
            for id, m in pairs(healSizes) do
                if type(m) ~= "table" or not m.ratio then healSizes[id] = nil end
            end
        end
        events:RegisterEvent("GROUP_ROSTER_UPDATE")
        events:RegisterEvent("PLAYER_ENTERING_WORLD")
        if ns.InitOptions then ns.InitOptions() end
        playerClass = select(2, UnitClass("player"))
        RebuildRoster()
        Scan()
        -- EllesmereUI builds buttons lazily (party header, extra frames, frame reloads).
        C_Timer.NewTicker(2, Scan)
        C_Timer.After(5, WarnBuiltIn)
    end
end)

-------------------------------------------------------------------------------
--  Slash commands
-------------------------------------------------------------------------------
local function Status()
    Print("status")
    print("  API: " .. (ns.stats.apiOK and "|cff40ff40ok|r" or "|cffff4040missing|r"))
    local counts, shown = ns.CountFrames()
    for _, scope in ipairs(ns.SCOPES) do
        print(("  %s frames: %d attached, %d drawing"):format(ns.SCOPE_LABELS[scope], counts[scope], shown[scope]))
    end
    print("  Party & raid shared: " .. tostring(ns.db.sharePartyRaid))
    print("  Last heal amounts secret: " .. tostring(ns.stats.secretAmounts))
    print("  Group healers with class-colored bars: " .. (#roster / 2))
    print("  Cast end times:")
    for _, who in ipairs({ "player", "others" }) do
        local t = ns.stats.castTimes[who]
        print(("    %s: |cff40ff40%d plain|r, |cffff4040%d secret|r, %d no cast info")
            :format(who == "player" and "You" or "Group", t.plain, t.secret, t.missing))
    end
    local measured = 0
    for _ in pairs(healSizes) do measured = measured + 1 end
    print("  Spells with measured heals: " .. measured .. " (/fhp heals lists them)")
    local c = ns.stats.lastCast
    if c then
        print(("  Last cast: %s (%d), size %s from %s"):format(SpellLabel(c.spell), c.spell,
            c.size and Round(c.size) or "?", c.source))
    end
    print("  Test mode: " .. tostring(ns.testMode))
    local on = ns.BuiltInPredictionScopes()
    if #on > 0 then print("  |cffffd100EllesmereUI heal prediction still on:|r " .. table.concat(on, ", ")) end
    if ns.stats.lastError then print("  Last error: " .. ns.stats.lastError) end
end

SLASH_FOREVERHEALPREDICT1 = "/fhp"
SLASH_FOREVERHEALPREDICT2 = "/foreverhealpredict"
SlashCmdList.FOREVERHEALPREDICT = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "test" then
        ns.testMode = not ns.testMode
        Print("test mode " .. (ns.testMode and "on (fake heals; units at full health need overflow to show them)" or "off"))
        MarkAll()
    elseif msg == "status" then
        Status()
    elseif msg == "casts" then
        ns.castDebug = not ns.castDebug
        Print("cast debug " .. (ns.castDebug
            and "on: every group cast start shows whether its end time is readable; yours also show what the overheal check uses"
            or "off"))
    elseif msg == "resetstats" then
        for _, t in pairs(ns.stats.castTimes) do t.plain, t.secret, t.missing = 0, 0, 0 end
        Print("cast statistics reset")
    elseif msg == "combatlog" then
        ns.healLog = not ns.healLog
        Print("heal log " .. (ns.healLog
            and "on: each heal on you or your target shows whether it was used to measure your heal size"
            or "off"))
    elseif msg == "heals" then
        ListHeals()
    elseif msg == "resetheals" then
        wipe(healSizes)
        Print("measured heal sizes cleared; tooltip averages are used until new heals are measured.")
    elseif msg == "rescan" then
        Scan()
        MarkAll()
        Print("rescanned frames")
    elseif ns.OpenOptions then
        ns.OpenOptions()
    end
end
