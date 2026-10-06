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
--    * the overheal threshold is the calculator's "clamped" boolean at an
--      overflow of (1 + threshold), turned into a color by C_CurveUtil,
--    * landing order needs cast end times; those are used only when plain.
--
--  Copyright (C) 2026 jmeier5261
--  Licensed under the GNU General Public License v3.0. See LICENSE.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local issecretvalue = issecretvalue or function() return false end
local CreateFrame, UnitExists, UnitIsUnit, IsInRaid = CreateFrame, UnitExists, UnitIsUnit, IsInRaid
local UnitCastingInfo = UnitCastingInfo
local pairs, ipairs, wipe, type = pairs, ipairs, wipe, type

local WHITE = "Interface\\Buttons\\WHITE8X8"
local MAX_SEGS = 8   -- other healers' casts drawn ahead of yours (landing order)
local EMPTY = {}

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
local casting = {}   -- group unit token -> cast end time (ms), plain values only
local calc, scratch  -- shared calculators (paints are sequential)

ns.settingsGen = 0
ns.testMode = false
ns.stats = {
    secretAmounts = false, lastError = nil, apiOK = false,
    -- Cast end time reads from UnitCastingInfo, split by outcome.
    -- [who] = { plain = n, secret = n, missing = n }, who = "player" | "others"
    castTimes = { player = { plain = 0, secret = 0, missing = 0 }, others = { plain = 0, secret = 0, missing = 0 } },
    orderedPaints = 0,   -- paints that actually drew another healer ahead of you
}
ns.castDebug = false

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

-- flag: nil/false/true or a SECRET boolean. Never compared directly.
local function Tint(bar, flag, cOn, cOff)
    local tex = bar:GetStatusBarTexture()
    if not tex then return end
    if issecretvalue(flag) then
        local ev = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
        if ev then
            tex:SetVertexColor(ev(flag, cOn.r, cOff.r), ev(flag, cOn.g, cOff.g), ev(flag, cOn.b, cOff.b))
            if tex.SetAlphaFromBoolean then
                tex:SetAlphaFromBoolean(flag, cOn.a or 1, cOff.a or 1)
            else
                tex:SetAlpha(cOff.a or 1)
            end
            return
        end
        flag = false
    end
    local c = flag and cOn or cOff
    tex:SetVertexColor(c.r, c.g, c.b)
    tex:SetAlpha(c.a or 1)
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
local function Layout(rec, S, nB)
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
       and L.ext == ext and L.nB == nB and L.tex == tex and L.gen == ns.settingsGen then
        return true
    end
    L.fill, L.dir, L.inv, L.w, L.h, L.ext, L.nB, L.tex, L.gen = fill, dir, inv, w, h, ext, nB, tex, ns.settingsGen

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

    -- Chain: [other healers landing before you] -> [your heals]
    local prev, prevPts = fill, seamPts
    for i = 1, MAX_SEGS do
        local seg = rec.segs[i]
        if i <= nB then
            if not seg then
                seg = NewBar(holder)
                rec.segs[i] = seg
            end
            PlaceBar(seg, prev, prevPts, near, vert, rev, w, h, tex)
            seg:Show()
            prev, prevPts = seg:GetStatusBarTexture(), far
        elseif seg then
            seg:Hide()
        end
    end
    if S.showMine then
        PlaceBar(rec.mine, prev, prevPts, near, vert, rev, w, h, tex)
        rec.mine:Show()
        prev, prevPts = rec.mine:GetStatusBarTexture(), far
    else
        rec.mine:Hide()
    end

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

local function SetRange(bar, maxHP)
    bar:SetMinMaxValues(0, maxHP)
end

-- Fills `out` with other group healers' amounts on `unit` whose casts finish
-- before yours. Returns the count. Only plain cast times are ever stored.
local function CollectEarlierHeals(unit, out)
    local myEnd = casting.player
    if not myEnd then return 0 end
    local now = GetTime() * 1000
    local n = 0
    for token, endMs in pairs(casting) do
        if endMs < now - 1000 then
            -- Missed stop event (unit went out of range etc.).
            casting[token] = nil
        elseif token ~= "player" and endMs < myEnd then
            UnitGetDetailedHealPrediction(unit, token, scratch)
            local _, amt = scratch:GetIncomingHeals()
            n = n + 1
            out[n] = amt
            if n >= MAX_SEGS then break end
        end
    end
    return n
end

local function Paint(rec)
    local S = ns.GetSettings(rec.scope)
    local unit = rec.unit
    if not (S.showMine or S.showOthers) or not unit or not rec.owner:IsVisible() or not UnitExists(unit) then
        rec.holder:Hide()
        return
    end

    local total, mine, others, maxHP, over
    local nB = 0
    local segVals = rec.segVals
    local ordered = S.landingOrder and S.showMine and S.showOthers

    if ns.testMode then
        maxHP, mine, others, total = 100, 20, 15, 35
        if ordered then nB = 1; segVals[1] = 6 end
        over = (rec.testIndex % 2 == 0)
    else
        calc:SetIncomingHealOverflowPercent(S.overflowEnabled and (1 + (S.overflowPct or 0) / 100) or 1)
        UnitGetDetailedHealPrediction(unit, "player", calc)
        total, mine, others = calc:GetIncomingHeals()
        maxHP = calc:GetMaximumHealth()
        if S.overhealMine or S.overhealOthers then
            -- Same fill, re-evaluated: clamped == health + incoming > max * (1 + threshold).
            calc:SetIncomingHealOverflowPercent(1 + (S.overhealThreshold or 0) / 100)
            local _, _, _, clamped = calc:GetIncomingHeals()
            over = clamped
        end
        ns.stats.secretAmounts = issecretvalue(total)
        if ordered then
            nB = CollectEarlierHeals(unit, segVals)
            if nB > 0 then ns.stats.orderedPaints = ns.stats.orderedPaints + 1 end
        end
    end

    if not issecretvalue(maxHP) and (maxHP or 0) <= 0 then
        rec.holder:Hide()
        return
    end
    if not Layout(rec, S, nB) then
        rec.holder:Hide()
        return
    end

    local otherFlag = S.overhealOthers and over
    for i = 1, nB do
        local seg = rec.segs[i]
        SetRange(seg, maxHP)
        seg:SetValue(segVals[i])
        Tint(seg, otherFlag, S.otherOverhealColor, S.otherColor)
    end
    if S.showMine then
        SetRange(rec.mine, maxHP)
        rec.mine:SetValue(mine)
        Tint(rec.mine, S.overhealMine and over, S.myOverhealColor, S.myColor)
    end
    if S.showOthers then
        SetRange(rec.rest, maxHP)
        -- Explicit branch: `a and total or others` would truth-test a secret.
        if S.showMine then rec.rest:SetValue(total) else rec.rest:SetValue(others) end
        Tint(rec.rest, otherFlag, S.otherOverhealColor, S.otherColor)
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
    local rec = { owner = owner, health = health, kind = kind, scope = scope, segs = {}, segVals = {}, L = {} }
    local holder = CreateFrame("Frame", nil, owner)
    holder:SetClipsChildren(true)
    holder:Hide()
    rec.holder = holder
    local ac = CreateFrame("Frame", nil, holder)
    ac:SetClipsChildren(true)
    rec.afterClip = ac
    rec.rest = NewBar(ac)
    rec.mine = NewBar(holder)

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
--  Cast tracking (landing order)
-------------------------------------------------------------------------------
local function AnyLandingOrder()
    for _, scope in ipairs(ns.SCOPES) do
        if ns.GetSettings(scope).landingOrder then return true end
    end
    return false
end

local function IsGroupToken(u)
    if u == "player" then return true end
    if IsInRaid() then return u:find("^raid%d") ~= nil end
    return u:find("^party%d") ~= nil
end

local function Readable(v, fallback)
    if issecretvalue(v) then return "<hidden>" end
    return v or fallback
end

local function CastDebug(u, result, endMs)
    if not ns.castDebug then return end
    local caster = Readable(UnitName(u), "?")
    local spell = Readable(UnitCastingInfo(u), "?")
    local endText
    if result == "plain" then
        endText = ("|cff40ff40readable|r, lands in %.2fs"):format((endMs - GetTime() * 1000) / 1000)
    elseif result == "SECRET" then
        endText = "|cffff4040hidden by client|r"
    else
        endText = "|cffff4040no cast info|r"
    end
    print(("|cff33ccffFHP|r caster: %s (%s), spell: %s, end time: %s"):format(caster, u, spell, endText))
end

local function CastStarted(u)
    local who = (u == "player") and "player" or "others"
    if who == "others" then
        -- Your own raid/party token would duplicate "player".
        local same = UnitIsUnit(u, "player")
        if not issecretvalue(same) and same then return end
    end
    local counts = ns.stats.castTimes[who]
    local _, _, _, _, endMs = UnitCastingInfo(u)
    if issecretvalue(endMs) then
        casting[u] = nil
        counts.secret = counts.secret + 1
        CastDebug(u, "SECRET")
        return
    end
    if not endMs then
        casting[u] = nil
        counts.missing = counts.missing + 1
        CastDebug(u, "no cast info")
        return
    end
    counts.plain = counts.plain + 1
    casting[u] = endMs
    CastDebug(u, "plain", endMs)
end

-------------------------------------------------------------------------------
--  Startup checks
-------------------------------------------------------------------------------
local function InitCalculators()
    if not (CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction and Enum
            and Enum.UnitIncomingHealClampMode) then
        return false
    end
    calc = CreateUnitHealPredictionCalculator()
    if not (calc.GetIncomingHeals and calc.SetIncomingHealOverflowPercent and calc.SetIncomingHealClampMode) then
        return false
    end
    calc:SetIncomingHealClampMode(Enum.UnitIncomingHealClampMode.MissingHealth)
    if calc.SetMaximumHealthMode and Enum.UnitMaximumHealthMode then
        calc:SetMaximumHealthMode(Enum.UnitMaximumHealthMode.Default)
    end
    if calc.SetHealAbsorbMode and Enum.UnitHealAbsorbMode then
        calc:SetHealAbsorbMode(Enum.UnitHealAbsorbMode.ReducedByIncomingHeals)
    end
    scratch = CreateUnitHealPredictionCalculator()
    scratch:SetIncomingHealClampMode(Enum.UnitIncomingHealClampMode.MaximumHealth)
    return true
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

local function Print(msg) print("|cff33ccffForever HealPredict|r " .. msg) end
ns.Print = Print

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

events:SetScript("OnEvent", function(_, event, arg1)
    if UNIT_EVENTS[event] then
        MarkUnit(arg1)
    elseif CAST_START[event] or CAST_END[event] then
        if not (arg1 and IsGroupToken(arg1)) then return end
        if CAST_START[event] then CastStarted(arg1) else casting[arg1] = nil end
        -- Only reorders anything while you are casting (or when your cast changes).
        if (arg1 == "player" or casting.player) and AnyLandingOrder() then MarkAll() end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        wipe(casting)
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
        events:RegisterEvent("GROUP_ROSTER_UPDATE")
        events:RegisterEvent("PLAYER_ENTERING_WORLD")
        if ns.InitOptions then ns.InitOptions() end
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
    print("  Cast end times (plain = usable for landing order):")
    for _, who in ipairs({ "player", "others" }) do
        local c = ns.stats.castTimes[who]
        print(("    %s: |cff40ff40%d plain|r, |cffff4040%d secret|r, %d no cast info")
            :format(who == "player" and "You" or "Group", c.plain, c.secret, c.missing))
    end
    print("  Paints that ordered another healer ahead of you: " .. ns.stats.orderedPaints)
    local now = GetTime() * 1000
    for token, endMs in pairs(casting) do
        print(("    casting now: %s, lands in %.2fs"):format(token, (endMs - now) / 1000))
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
        Print("cast time debug " .. (ns.castDebug and "on: every group cast start shows whether its end time is readable" or "off"))
    elseif msg == "resetstats" then
        for _, c in pairs(ns.stats.castTimes) do c.plain, c.secret, c.missing = 0, 0, 0 end
        ns.stats.orderedPaints = 0
        Print("cast statistics reset")
    elseif msg == "rescan" then
        Scan()
        MarkAll()
        Print("rescanned frames")
    elseif ns.OpenOptions then
        ns.OpenOptions()
    end
end
