-------------------------------------------------------------------------------
--  Core.lua
--  Incoming heal bars on EllesmereUI frames (raid + party from
--  EllesmereUIRaidFrames, player, target and focus from EllesmereUIUnitFrames).
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
--    * your heal's size is the spell tooltip's average times a ratio measured
--      from your real non-crit heals, per spell ID (so per rank) and tooltip,
--    * class colors split "others" into one bar per group healer, each read
--      with that healer as the calculator's source,
--    * your HoTs (not in the heal API, and auras are hidden in combat) are
--      tracked from your casts: plain amounts from the tooltip, drawn last,
--      seen through engine aura slots that the game hides once a HoT is gone.
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
-- EllesmereUIUnitFrames frames; they share the "unit" settings, each with its own on/off.
local UNIT_FRAMES = {
    { global = "EllesmereUIUnitFrames_Player", toggle = "framePlayer", label = "Player" },
    { global = "EllesmereUIUnitFrames_Target", toggle = "frameTarget", label = "Target" },
    { global = "EllesmereUIUnitFrames_Focus",  toggle = "frameFocus",  label = "Focus" },
}

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
local ALIAS_TOKENS = { "target", "focus" }
local dirty = {}
local allDirty = false
local calc, scratch  -- shared calculators (paints are sequential)
local roster = {}    -- flat { unit, classToken, ... }: group healers other than you
local playerClass
local myCast         -- { spell, size, source } while you cast, else nil
local healSizes = {} -- spellID -> tooltip range -> measured ratio; the saved table once logged in

-- Your HoTs by their Rank 1 spell ID. Every rank shares the name, and casts
-- are matched by name (in the client's language). tick: seconds between
-- ticks. direct: the spell also heals up front; that part is in the heal API
-- already, and it's what your heal size is measured from.
local HOT_SPELLS = {
    [139]  = { tick = 3 },                  -- Renew
    [774]  = { tick = 3 },                  -- Rejuvenation
    [8936] = { tick = 3, direct = true },   -- Regrowth
}
-- The same entries in a fixed order: each HoT has its own bar on every frame
-- and its own aura slot. name and ids (every rank's spell ID) fill in at login.
local HOT_FAMILIES = {}
for id, info in pairs(HOT_SPELLS) do
    info.rank1, info.ids = id, { [id] = true }
    HOT_FAMILIES[#HOT_FAMILIES + 1] = info
end
table.sort(HOT_FAMILIES, function(a, b) return a.rank1 < b.rank1 end)

ns.settingsGen = 0
ns.testMode = false
ns.castDebug = false
ns.stats = {
    secretAmounts = false, lastError = nil, apiOK = false, lastCast = nil,
    hotSlotsBuilt = 0, hotSlotsError = nil, hotRanks = 0,
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

-- Alpha aOn when flag is true, else aOff; flag may be SECRET.
local function AlphaIf(tex, flag, aOn, aOff)
    if not tex then return end
    if issecretvalue(flag) then
        if tex.SetAlphaFromBoolean then tex:SetAlphaFromBoolean(flag, aOn, aOff) else tex:SetAlpha(aOn) end
    else
        tex:SetAlpha(flag and aOn or aOff)
    end
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

    -- Your HoTs last, one bar per HoT: the clip above relies on the chain
    -- adding up to part of the total, so they start where everything else
    -- ends. Once the frame's aura slots are built these bars are only
    -- geometry (plain white, invisible): what shows is each slot's texture
    -- laid over its bar (see "Your HoTs on screen").
    local hp, hpPts = prev, prevPts
    if S.showOthers then hp, hpPts = rec.rest:GetStatusBarTexture(), far end
    for _, bar in ipairs(rec.hotBars) do
        if S.showMyHots then
            PlaceBar(bar, hp, hpPts, near, vert, rev, w, h, rec.hotSlots and WHITE or tex)
            bar:Show()
            hp, hpPts = bar:GetStatusBarTexture(), far
        else
            bar:Hide()
        end
    end
    return true
end

-------------------------------------------------------------------------------
--  Your heals over time. The heal API leaves HoTs out, and in combat the
--  client hides every aura from addons, so your HoTs are tracked from your
--  casts (see "Your heals over time" further down). This part matches them
--  to a frame's unit and adds up what's still to land: plain numbers.
-------------------------------------------------------------------------------
local hotByName = {}   -- spell name -> HOT_SPELLS entry; filled at login
-- "spell name:target name" -> { spell, info, total, ticks, tick, start, created, left, name, guid, token }
local myHots = {}

-- One aura; nil past the last one; false when the client hides it from
-- addons (in combat, reading such an aura raises an error).
local function ReadAura(unit, i, filter)
    local check = C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret
    if check then
        local ok, secret = pcall(check, unit, i, filter)
        if ok and (issecretvalue(secret) or secret) then return false end
    end
    local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
    if not ok then return false end
    return a
end

-- "Name", "Name-Realm" or "Name Surname" -> "Name".
local function ShortName(name)
    return type(name) == "string" and name:match("^[^%s%-]+") or nil
end

-- Ticks still to land; 0 once the HoT has run out.
local function HotTicksLeft(h, now)
    return math.max(0, math.min(h.ticks, h.ticks - math.floor((now - h.start) / h.tick)))
end

-- Whether a tracked HoT is on this unit: by GUID, else by token, else by name.
local function HotOnUnit(unit, h)
    local guid = UnitGUID(unit)
    if h.guid and guid and not issecretvalue(guid) then return guid == h.guid end
    if unit == h.token then return true end
    if h.token then
        local same = UnitIsUnit(unit, h.token)
        if not issecretvalue(same) then return same and true or false end
    end
    local name = UnitName(unit)
    if name and not issecretvalue(name) then return ShortName(name) == h.name end
    return false
end

-- What your HoTs on this unit have still to heal: one HoT (a HOT_SPELLS
-- entry), or all of them.
local function MyHotAmount(unit, info)
    local now, sum = GetTime(), 0
    for _, h in pairs(myHots) do
        if (not info or h.info == info) and HotOnUnit(unit, h) then
            sum = sum + HotTicksLeft(h, now) * h.total / h.ticks
        end
    end
    return sum
end

-------------------------------------------------------------------------------
--  Your HoTs on screen. In combat every aura is hidden from Lua, so a HoT
--  dispelled then can't be noticed there. The engine's AuraContainer matches
--  a unit's auras itself, though: per HoT, one slot filtered to your casts of
--  it (HELPFUL|PLAYER, every rank's spell ID), which the game shows only
--  while that HoT is on the unit. (Buff spell-ID filters work on units you
--  can assist; the engine's identity gate drops debuff ones on friendly
--  units, so this can't be done for debuffs.) What a slot holds shows and
--  hides with it, and while auras are secret every write to a slot's objects
--  is refused, so its texture is made once, in the slot's initializer, and
--  laid over the HoT's own bar: that bar stays ours to update and draws
--  nothing itself. The container can be pointed at another unit any time
--  ("none" turns it off).
-------------------------------------------------------------------------------
local hotQueue = {}          -- records waiting for their container
local hotRestyle = false     -- a restyle was refused (auras secret); retried out of combat
local hotRanksReady = false  -- every rank's spell ID collected (see ScanHotRanks)

-- The slot texture's look (refused while auras are secret).
local function StyleHotSlot(rec, tex)
    local S = ns.GetSettings(rec.scope)
    local fill = rec.health:GetStatusBarTexture()
    tex:SetTexture((S.useHealthTexture and fill and fill:GetTexture()) or WHITE)
    ColorTex(tex, S.myHotColor, S.useClassColors and 1 or (S.masterOpacity or 100) / 100)
end

local function InitHotSlot(rec, i, slot)
    -- The engine may run this again for the same button; build only once.
    if rec.hotTex[i] then return end
    local lvl = rec.health:GetFrameLevel()
    slot:SetFrameLevel(lvl + 2)
    slot:EnableMouse(false)
    slot:SetSize(1, 1)
    slot:SetPoint("CENTER", rec.holder, "CENTER")
    -- Clipped like the other bars: the holder is the bar plus the overflow allowance.
    local clip = CreateFrame("Frame", nil, slot)
    clip:SetClipsChildren(true)
    clip:SetAllPoints(rec.holder)
    clip:SetFrameLevel(lvl + 2)
    local tex = clip:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(rec.hotBars[i]:GetStatusBarTexture())
    rec.hotTex[i] = tex
    StyleHotSlot(rec, tex)
end

-- The unit the container watches: the frame's, or "none" while it's off.
local function BindHotUnit(rec, unit)
    local c = rec.hotContainer
    unit = unit or "none"
    if c:GetUnit() ~= unit then
        c:SetUnit(unit)
        c:UpdateAllAuras()
    end
end

local function BuildHotContainer(rec)
    if not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then C_AddOns.LoadAddOn("Blizzard_AuraContainer") end
    -- From here on the bars are plain white geometry: the slot textures anchor
    -- to their fills, so the fill texture must not be swapped again.
    for _, bar in ipairs(rec.hotBars) do
        bar:SetStatusBarTexture(WHITE)
        bar._tex = WHITE
    end
    local c = CreateFrame("AuraContainer", nil, rec.owner, "CustomAuraContainerTemplate")
    c:SetPoint("CENTER", rec.holder, "CENTER")
    c:SetSize(1, 1)
    c:SetFrameLevel(rec.health:GetFrameLevel() + 2)
    for i, info in ipairs(HOT_FAMILIES) do
        c:AddAuraSlot("bhbhot" .. info.rank1, "HELPFUL|PLAYER", {
            candidateFilters = { includeSpellIDs = info.ids },
            initializeFrame = function(slot) InitHotSlot(rec, i, slot) end,
        })
    end
    rec.hotContainer = c
    rec.hotSlots = true
    rec.L.gen = nil      -- lay the bars out again, as plain white
    dirty[rec] = true    -- the next paint binds the unit (after the slots, as the engine needs)
end

-- A few containers per frame: each slot is built through the engine.
local function BuildQueuedHots()
    for _ = 1, 2 do
        local rec = table.remove(hotQueue, 1)
        if not rec then return end
        local ok, err = pcall(BuildHotContainer, rec)
        if ok then
            ns.stats.hotSlotsBuilt = ns.stats.hotSlotsBuilt + 1
        else
            rec.hotFailed = true
            if not ns.stats.hotSlotsError and ns.Print then
                ns.Print("|cffff4040the game's aura slots didn't work, so a HoT dispelled in combat keeps "
                    .. "showing until it would have run out:|r " .. tostring(err))
            end
            ns.stats.hotSlotsError = err
        end
    end
end

-- Settings changed: restyle every slot texture built so far.
local function RestyleHots()
    hotRestyle = false
    for _, rec in ipairs(recList) do
        for _, tex in pairs(rec.hotTex or EMPTY) do
            if not pcall(StyleHotSlot, rec, tex) then hotRestyle = true end
        end
    end
end

-- Every rank of a HoT has its own spell ID, and a slot's filter needs them
-- all: at login, spell IDs are walked a few thousand per frame and each one
-- named like one of your HoTs is added. Containers wait until it's done.
local HOT_RANK_MAX = 100000
local hotRankNext = 1
local hotRankFrame = CreateFrame("Frame")
hotRankFrame:Hide()
hotRankFrame:SetScript("OnUpdate", function(self)
    local stop = debugprofilestop() + 4
    while hotRankNext <= HOT_RANK_MAX and debugprofilestop() < stop do
        local name = C_Spell.GetSpellName(hotRankNext)
        local info = name and not issecretvalue(name) and hotByName[name]
        if info then info.ids[hotRankNext] = true end
        hotRankNext = hotRankNext + 1
    end
    if hotRankNext > HOT_RANK_MAX then
        self:Hide()
        local n = 0
        for _, info in ipairs(HOT_FAMILIES) do
            for _ in pairs(info.ids) do n = n + 1 end
        end
        ns.stats.hotRanks = n
        hotRanksReady = true
        ns.MarkAll()
    end
end)

local function ScanHotRanks()
    if C_Spell and C_Spell.GetSpellName and debugprofilestop then
        hotRankFrame:Show()
    end
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
    local draw = (S.showMine or S.showOthers or S.showMyHots) and not (rec.toggle and not S[rec.toggle])
        and unit and rec.owner:IsVisible() and UnitExists(unit)
    -- Your HoTs' aura slots: the container is built once (queued, once every
    -- rank is known), then kept on this frame's unit while HoTs show.
    local hotsOn = draw and S.showMyHots
    if hotsOn and hotRanksReady and not (rec.hotContainer or rec.hotQueued or rec.hotFailed) then
        rec.hotQueued = true
        hotQueue[#hotQueue + 1] = rec
    end
    if rec.hotContainer then pcall(BindHotUnit, rec, hotsOn and unit or nil) end
    if not draw then
        rec.holder:Hide()
        return
    end

    local total, mine, others, maxHP, over
    local mineFit, useFlag   -- mineFit may be SECRET; useFlag is the plain "have it" flag
    local overflows          -- SECRET or plain: health + incoming heals exceed max health
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
            local _, fit, _, clamped = calc:GetIncomingHeals()
            mineFit, useFlag, overflows = fit, true, clamped
            -- No flag from this client: don't let it block the recolor.
            if not issecretvalue(overflows) and overflows == nil then overflows = true end
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
            -- Only when the client says the heals overflow does the flag pair
            -- draw (your fill hides under it); otherwise your fill shows as
            -- normal. A heal that fits can't be flagged, even when the cut-off
            -- is off (healing reduction on the target).
            local myA = (myColor.a or 1) * master
            AlphaIf(rec.mine:GetStatusBarTexture(), overflows, 0, myA)
            AlphaIf(fb:GetStatusBarTexture(), overflows, myA, 0)
            AlphaIf(rec.flagRest, overflows, (S.myOverhealColor.a or 1) * master, 0)
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
    if S.showMyHots then
        for i, bar in ipairs(rec.hotBars) do
            SetRange(bar, maxHP)
            if ns.testMode then
                bar:SetValue(i == 1 and 12 or 0)
            else
                bar:SetValue(MyHotAmount(unit, HOT_FAMILIES[i]))
            end
            -- With the aura slots built, the slot's texture is what shows; test
            -- bars have no aura behind them, so they draw themselves.
            if rec.hotSlots and not ns.testMode then
                bar:GetStatusBarTexture():SetAlpha(0)
            else
                SetColor(bar, S.myHotColor, master)
            end
        end
    end
    rec.holder:Show()
end

local function SafePaint(rec)
    local ok, err = pcall(Paint, rec)
    if not ok and ns.stats.lastError ~= err then
        ns.stats.lastError = err
        print("|cff33ccffBetter Heal Bars|r error: " .. tostring(err))
    end
end

-------------------------------------------------------------------------------
--  Dirty tracking (coalesced to one paint per frame per record)
-------------------------------------------------------------------------------
local function UnitOf(rec)
    if rec.kind == "rf" then return rec.owner:GetAttribute("unit") end
    -- EllesmereUI unit frames never carry a .unit field (it taints pings);
    -- _euiUnit is the live token, vehicle swaps included.
    return rec.owner._euiUnit or rec.owner:GetAttribute("unit")
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
    -- Target and focus may be a group member, whose events can arrive under
    -- the group token instead: list frames under both tokens.
    for _, alias in ipairs(ALIAS_TOKENS) do
        if unitMap[alias] and UnitExists(alias) then
            local inRaid = IsInRaid()
            for i = 1, inRaid and 40 or 4 do
                local g = (inRaid and "raid" or "party") .. i
                local same = UnitIsUnit(alias, g)
                if not issecretvalue(same) and same then
                    local a, b = unitMap[alias], unitMap[g] or EMPTY
                    local na, nb = #a, #b   -- both lists grow below
                    for j = 1, na do AddToMap(g, a[j]) end
                    for j = 1, nb do AddToMap(alias, b[j]) end
                    break
                end
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
    else
        for rec in pairs(dirty) do
            dirty[rec] = nil
            SafePaint(rec)
        end
    end
    -- HoT aura containers queued by those paints; each built one is marked
    -- dirty, so the next frame binds its unit.
    if #hotQueue > 0 then BuildQueuedHots() end
    if #hotQueue > 0 or next(dirty) then self:Show() end
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

-- Repaints every frame showing the unit one of your HoTs is on.
local function MarkHot(h)
    for _, rec in ipairs(recList) do
        if rec.unit and HotOnUnit(rec.unit, h) then dirty[rec] = true end
    end
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
    RestyleHots()
    MarkAll()
end

-------------------------------------------------------------------------------
--  Frame discovery
-------------------------------------------------------------------------------
local function HookHealth(rec, health)
    if health._bhbHooked then return end
    health._bhbHooked = true
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
    -- One bar per HoT; once the aura slots are built, the slots' textures
    -- (rec.hotTex) draw over them instead.
    rec.hotBars, rec.hotTex = {}, {}
    for i = 1, #HOT_FAMILIES do rec.hotBars[i] = NewBar(holder) end

    records[owner] = rec
    recList[#recList + 1] = rec
    rec.testIndex = #recList
    HookHealth(rec, health)

    owner:HookScript("OnAttributeChanged", function(_, name)
        if name == "unit" or name == "toggleForVehicle" then
            mapDirty = true
            MarkDirty(rec)
        end
    end)
    owner:HookScript("OnShow", function() mapDirty = true; MarkDirty(rec) end)
    owner:HookScript("OnHide", function() mapDirty = true end)
    return rec
end

-- Returns true when something new was attached. toggle: for unit frames, the
-- setting that turns this one frame on or off.
local function Attach(owner, health, kind, scope, toggle)
    if not (owner and health and health.GetStatusBarTexture) then return false end
    local rec = records[owner]
    if not rec then
        BuildRecord(owner, health, kind, scope).toggle = toggle
        return true
    end
    local changed = false
    rec.toggle = toggle
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
    for _, uf in ipairs(UNIT_FRAMES) do
        local f = _G[uf.global]
        if f and f.Health then
            changed = Attach(f, f.Health, "uf", "unit", uf.toggle) or changed
        end
    end
    if changed then MarkAll() end
end
ns.Scan = Scan

function ns.CountFrames()
    local counts = { unit = 0, party = 0, raid = 0 }
    local shown = { unit = 0, party = 0, raid = 0 }
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
    for _, uf in ipairs(UNIT_FRAMES) do
        local f = _G[uf.global]
        local ab = f and f.HealthPrediction and f.HealthPrediction.damageAbsorb
        if ab and ab._predOn then on[#on + 1] = uf.label .. " Frame" end
    end
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

-- Separators inside a number in any client language: "1,234", "1.234",
-- "1 234" (also with a no-break or narrow no-break space).
local THOUSANDS = "(%d)[,%.%s\194\160\226\128\175]+(%d%d%d)%f[%D]"

-- The heal range in the spell's description, in any client language. Only
-- the numbers are read: the first two in a row that look like a range
-- ("156 to 181", "156 bis 181", "156 à 181", "156~181"), i.e. the second is
-- larger and at most 1.5x the first. Returns the average, low and high ends;
-- without a range, the first number; nil when there's no readable amount.
local function TooltipHealSize(spellID)
    local text = SpellDescription(spellID)
    if not text then return nil end
    local n
    repeat text, n = text:gsub(THOUSANDS, "%1%2") until n == 0
    local nums = {}
    for d in text:gmatch("%d+") do nums[#nums + 1] = tonumber(d) end
    for i = 1, #nums - 1 do
        local lo, hi = nums[i], nums[i + 1]
        if lo >= 10 and hi > lo and hi <= lo * 1.5 then return (lo + hi) / 2, lo, hi end
    end
    local first = nums[1]
    if first and first > 0 then return first, first, first end
end

-- Lowercase sentences of a description.
local function Sentences(text)
    local list = {}
    text = text:lower():gsub("[\r\n]+", ". ")
    for s in (text .. ". "):gmatch("(.-)%.%s+") do list[#list + 1] = s end
    return list
end

-- A heal over time in a description: "heals the target of 45 damage over 15
-- sec", "for 32 over 12 sec", "restores 61 health over 18 sec" (mana, rage
-- and energy over time don't count). English text only. Returns the total,
-- the duration in seconds and the sentence, or nil.
local NOT_HEALTH = { mana = true, rage = true, energy = true }
local function HotFromText(text)
    local n
    repeat text, n = text:gsub(THOUSANDS, "%1%2") until n == 0
    for _, s in ipairs(Sentences(text)) do
        if s:find("heal") or s:find("restores") then
            for amount, word, secs in s:gmatch("(%d+)%s*(%a*)%s+over (%d+) sec") do
                if not NOT_HEALTH[word] then return tonumber(amount), tonumber(secs), s end
            end
        end
    end
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

local function Print(msg) print("|cff33ccffBetter Heal Bars|r " .. msg) end
ns.Print = Print

-- Tallies whether a group cast's end time is readable; /bhb casts prints it.
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
        print(("|cff33ccffBHB|r caster: %s (%s), spell: %s, end time: %s"):format(
            Readable(UnitName(u), "?"), u, Readable(UnitCastingInfo(u), "?"), endText))
    end
end

-------------------------------------------------------------------------------
--  Measured heal sizes. The combat log is Blizzard-only here, but UNIT_COMBAT
--  reports heals landing on you or your target with a readable amount and a
--  crit flag (no caster); its amount includes overheal. A heal is matched to
--  your cast that just succeeded, on the unit the cast was sent to. What's
--  kept is heal / tooltip average, per spell ID (so per rank) and per tooltip
--  range: the tooltip follows healing power, so any change (gear, buffs)
--  starts a fresh measurement, and going back to a range reuses its own.
-------------------------------------------------------------------------------
local PRIOR_WEIGHT = 10    -- each tooltip starts at x1.00, worth this many heals (rolls are noisy)
local MAX_WEIGHT = 30      -- the newest heal always counts at least 1/30
local MAX_RANGES = 8       -- tooltip ranges kept per spell; the least recently used goes first
local MATCH_WINDOW = 0.6   -- seconds between your cast succeeding and its heal landing
local sentByGUID = {}      -- cast GUID -> name the cast was sent to (false: none)
local sentCount = 0
local lastSent             -- the last name sent, for casts without a readable GUID
local pendingCast          -- { spell, tip, target, t }: succeeded, heal not seen yet
local pendingHeal          -- { unit, name, amount, flag, t }: landed, cast not matched yet
ns.healLog = false         -- /bhb combatlog prints every heal and what happened to it

local function Round(x) return math.floor(x + 0.5) end

-- The spell's tooltip right now: { base, lo, hi, key }, or nil without a heal amount.
local function Tooltip(spellID)
    local base, lo, hi = TooltipHealSize(spellID)
    if not base or base <= 0 then return nil end
    return { base = base, lo = lo, hi = hi, key = lo .. "-" .. hi }
end

-- For one spell and tooltip range: the ratio to use (heals blended with the
-- x1.00 start), the heal count and the heals' own average; nil when unmeasured.
local function Measured(spellID, key)
    local byTip = healSizes[spellID]
    local m = byTip and byTip[key]
    if not m then return end
    local w = math.min(m.n, MAX_WEIGHT)
    return (m.ratio * w + PRIOR_WEIGHT) / (w + PRIOR_WEIGHT), m.n, m.ratio
end

local function AddSample(spellID, key, ratio)
    local byTip = healSizes[spellID]
    if not byTip then
        byTip = {}
        healSizes[spellID] = byTip
    end
    local m = byTip[key]
    if not m then
        local count, oldest = 0, nil
        for k, v in pairs(byTip) do
            count = count + 1
            if not oldest or v.last < byTip[oldest].last then oldest = k end
        end
        if count >= MAX_RANGES then byTip[oldest] = nil end
        m = { ratio = 0, n = 0 }
        byTip[key] = m
    end
    m.n = m.n + 1
    m.ratio = m.ratio + (ratio - m.ratio) / math.min(m.n, MAX_WEIGHT)
    m.last = time()
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
    local tip = cast.tip
    if not tip then return false, "no heal amount in the tooltip" end
    if heal.amount < tip.lo * 0.9 or heal.amount > tip.hi * 1.5 then
        return false, ("outside the tooltip range %s"):format(tip.key)
    end
    AddSample(cast.spell, tip.key, heal.amount / tip.base)
    return true
end

local function LogSample(heal, cast, used, why)
    if not ns.healLog then return end
    local verdict
    if used then
        local ratio, n, raw = Measured(cast.spell, cast.tip.key)
        verdict = ("|cff40ff40used|r for %s at tooltip %s: heals land at x%.3f over %d; using x%.3f")
            :format(SpellLabel(cast.spell), cast.tip.key, raw, n, ratio)
    else
        verdict = "|cffffd100not used|r: " .. why
    end
    print(("|cff33ccffBHB|r heal on %s: %d%s; %s"):format(heal.unit, heal.amount,
        heal.flag == "CRITICAL" and " (crit)" or "", verdict))
end

local function OnHealLanded(unit, action, flag, amount)
    if issecretvalue(action) or action ~= "HEAL" then return end
    if issecretvalue(amount) or type(amount) ~= "number" or amount <= 0 or issecretvalue(flag) then
        if ns.healLog then print("|cff33ccffBHB|r heal on " .. unit .. ": amount or flag |cffff4040hidden|r") end
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
        LogSample(heal, cast, used, why)
    else
        -- The heal can arrive just before your cast's "succeeded" event.
        pendingHeal = heal
        if ns.healLog then
            print(("|cff33ccffBHB|r heal on %s: %d%s; waiting for a cast of yours to finish"):format(
                unit, amount, flag == "CRITICAL" and " (crit)" or ""))
        end
    end
end

-- v when it's a readable, non-nil value, else nil.
local function Plain(v)
    if issecretvalue(v) then return nil end
    return v
end

-- Whether a cast event's GUID is your current cast's (true when either is unknown).
local function IsMyCast(castGUID)
    castGUID = Plain(castGUID)
    return not (myCast and myCast.guid and castGUID) or castGUID == myCast.guid
end

-- The name a cast was sent to: by its GUID when known, else the last one sent.
local function SentTarget(castGUID)
    local entry = sentByGUID[Plain(castGUID) or false]
    if entry ~= nil then return entry or nil end
    return lastSent or nil
end

local function OnCastSent(target, castGUID)
    target = Plain(target)
    if type(target) ~= "string" or target == "" then target = false end
    lastSent = target
    castGUID = Plain(castGUID)
    if castGUID then
        sentCount = sentCount + 1
        if sentCount > 20 then wipe(sentByGUID); sentCount = 1 end
        sentByGUID[castGUID] = target
    end
end

-------------------------------------------------------------------------------
--  Your heals over time, tracked from your casts: in combat every aura is
--  hidden from addons, but your own casts' spell and target aren't. The amount
--  is the tooltip's, which follows your healing power. Out of combat your
--  auras are readable again, so they correct what was tracked.
-------------------------------------------------------------------------------
local HOT_SYNC_GRACE = 1   -- seconds a new HoT is kept before its aura must show up
local hotTicker

-- The group token (player, partyN, raidN) for a unit, or nil.
local function GroupToken(unit)
    if IsGroupToken(unit) then return unit end
    local same = UnitIsUnit(unit, "player")
    if not issecretvalue(same) and same then return "player" end
    local inRaid = IsInRaid()
    for i = 1, inRaid and 40 or 4 do
        local g = (inRaid and "raid" or "party") .. i
        same = UnitIsUnit(unit, g)
        if not issecretvalue(same) and same then return g end
    end
end

-- The unit with this name: you, a group member, then target and focus.
local function FindUnitByName(name)
    local short = ShortName(name)
    if not short then return nil end
    local function Is(u)
        if not UnitExists(u) then return false end
        local n = UnitName(u)
        return n ~= nil and not issecretvalue(n) and ShortName(n) == short
    end
    if Is("player") then return "player" end
    local inRaid = IsInRaid()
    for i = 1, inRaid and 40 or 4 do
        local u = (inRaid and "raid" or "party") .. i
        if Is(u) then return u end
    end
    for _, u in ipairs(ALIAS_TOKENS) do
        if Is(u) then return u end
    end
end

local function HotTick()
    local now = GetTime()
    for key, h in pairs(myHots) do
        local left = HotTicksLeft(h, now)
        local dead = h.token and UnitIsDeadOrGhost(h.token)
        if issecretvalue(dead) then dead = false end
        if left <= 0 or dead then
            myHots[key] = nil
            MarkHot(h)
        elseif left ~= h.left then
            h.left = left
            MarkHot(h)
        end
    end
    if not next(myHots) and hotTicker then
        hotTicker:Cancel()
        hotTicker = nil
    end
end

local function NewHot(spellID, info, name, guid, token)
    local text = SpellDescription(spellID)
    local total, duration = nil, nil
    if text then total, duration = HotFromText(text) end
    if not (total and duration and duration > 0) then return nil end
    local ticks = math.max(1, Round(duration / info.tick))
    local now = GetTime()
    return {
        spell = spellID, info = info, total = total, ticks = ticks, tick = duration / ticks, start = now, created = now,
        left = ticks, name = name, guid = guid, token = token,
    }
end

local function AddHot(key, h)
    local old = myHots[key]
    myHots[key] = h
    if old then MarkHot(old) end
    MarkHot(h)
    if not hotTicker then hotTicker = C_Timer.NewTicker(0.2, HotTick) end
end

-- Your cast succeeded: when it's a HoT, track it on the unit it was sent to.
-- Called on UNIT_SPELLCAST_SUCCEEDED only, so a cast that's interrupted,
-- fails or is cancelled (a Regrowth pushed out of range mid-cast) is never
-- tracked. Returns the spell's HOT_SPELLS entry, or nil when it isn't a HoT.
local function TrackHot(spellID, sentName)
    local spellName = SpellName(spellID)
    local info = spellName and not issecretvalue(spellName) and hotByName[spellName]
    if not info then return nil end
    -- No name sent: a self-cast.
    local unit = sentName and FindUnitByName(sentName) or (not sentName and "player") or nil
    local name = ShortName(sentName) or (unit and ShortName(Plain(UnitName(unit))))
    local guid = unit and Plain(UnitGUID(unit))
    local token = unit and GroupToken(unit)
    local h = (name or guid or token) and NewHot(spellID, info, name, guid, token)
    if ns.castDebug then
        print(("|cff33ccffBHB|r   your %s on %s: %s"):format(SpellLabel(spellID), name or "?",
            h and ("%d over %ds in %d ticks"):format(h.total, Round(h.ticks * h.tick), h.ticks)
              or "|cffff4040not tracked (no amount in the tooltip, or the target wasn't found)|r"))
    end
    if h then AddHot(spellName .. ":" .. (name or guid or token), h) end
    return info
end

-- Out of combat your auras are readable: drop HoTs that are gone (dispelled
-- or cancelled), line their timers up with the real ones, and pick up HoTs
-- cast before a /reload.
local function SyncHots(unit)
    if InCombatLockdown() or not UnitExists(unit) then return end
    local check = C_Secrets and C_Secrets.ShouldAurasBeSecret
    if check then
        local ok, secret = pcall(check)
        if not ok or issecretvalue(secret) or secret then return end
    end
    local name = ShortName(Plain(UnitName(unit)))
    if not name then return end
    local guid, token = Plain(UnitGUID(unit)), GroupToken(unit)
    local seen = {}
    for i = 1, 40 do
        local a = ReadAura(unit, i, "HELPFUL|PLAYER")
        if a == nil then break end
        local info = a and not issecretvalue(a.name) and hotByName[a.name]
        if info then
            local key = a.name .. ":" .. name
            seen[key] = true
            local h = myHots[key]
            if not h then
                h = NewHot(a.spellId, info, name, guid, token)
                if h then AddHot(key, h) end
            end
            local exp, dur = a.expirationTime, a.duration
            if h and type(exp) == "number" and exp > 0 and type(dur) == "number" and dur > 0 then
                h.start, h.tick = exp - dur, dur / h.ticks
                MarkHot(h)
            end
        end
    end
    local now = GetTime()
    for key, h in pairs(myHots) do
        if not seen[key] and now - h.created > HOT_SYNC_GRACE and HotOnUnit(unit, h) then
            myHots[key] = nil
            MarkHot(h)
        end
    end
end
ns.SyncHots = SyncHots

-- Leaving combat, a roster change or a /reload: re-find every HoT's unit and sync.
local function SyncAllHots()
    for _, h in pairs(myHots) do
        local u = h.name and FindUnitByName(h.name)
        if u then h.token = GroupToken(u) end
    end
    SyncHots("player")
    local inRaid = IsInRaid()
    for i = 1, inRaid and 40 or 4 do SyncHots((inRaid and "raid" or "party") .. i) end
end

local function OnCastSucceeded(castGUID, spellID)
    local mine = myCast and IsMyCast(castGUID) and (myCast.guid or myCast.spell == Plain(spellID))
    spellID = Plain(spellID) or (mine and myCast.spell)
    if not spellID then return end
    -- Your cast: the tooltip and target from when it started. Instants have no
    -- start, so read them now.
    local tip, target
    if mine then
        tip, target = myCast.tip, myCast.target
    else
        tip, target = Tooltip(spellID), SentTarget(castGUID)
    end
    -- A HoT with nothing up front has no heal landing now to measure.
    local hot = TrackHot(spellID, target)
    if hot and not hot.direct then return end
    local cast = { spell = spellID, tip = tip, target = target, t = GetTime() }
    local heal = pendingHeal
    pendingHeal = nil
    if heal then
        local used, why = TrySample(cast, heal)
        LogSample(heal, cast, used, why)
        if used then return end
    end
    pendingCast = cast
end

-------------------------------------------------------------------------------
--  Your casts
-------------------------------------------------------------------------------
-- /bhb casts: what the overheal check will use for this cast of yours.
local function CastDebug(c)
    local cuts = {}
    for _, scope in ipairs(ns.SCOPES) do
        cuts[#cuts + 1] = c.size and OverhealCut(c.size, ns.GetSettings(scope).overhealThreshold) or "-"
    end
    print(("|cff33ccffBHB|r   your %s (%d): size %s from %s; cut Unit/Party/Raid %s"):format(
        SpellLabel(c.spell), c.spell, c.size and Round(c.size) or "?", c.source, table.concat(cuts, "/")))
    if c.tip then
        local ratio, n, raw = Measured(c.spell, c.tip.key)
        print(("    tooltip %s, average %d; measured %s"):format(c.tip.key, Round(c.tip.base),
            ratio and ("x%.3f over %d heals, using x%.3f"):format(raw, n, ratio) or "none yet at this tooltip"))
    end
    print("    tooltip: " .. (SpellDescription(c.spell) or "|cffff4040none|r"))
end

local function OnCastStart(castGUID)
    local _, _, _, _, _, _, castID, _, spellID = UnitCastingInfo("player")
    spellID = Plain(spellID)
    if not spellID then
        myCast = nil
        return
    end
    local guid = Plain(castGUID) or Plain(castID)
    local tip = Tooltip(spellID)
    myCast = { spell = spellID, guid = guid, tip = tip, target = SentTarget(guid) }
    local ratio, n
    if tip then ratio, n = Measured(spellID, tip.key) end
    if ratio then
        myCast.size, myCast.source = tip.base * ratio, ("tooltip x%.3f (%d heals measured)"):format(ratio, n)
    elseif tip then
        myCast.size, myCast.source = tip.base, "tooltip"
    else
        myCast.source = "unknown"
    end
    ns.stats.lastCast = myCast
    if ns.castDebug then CastDebug(myCast) end
    MarkAll()
end

-- Stop/fail/interrupt/succeed. Pressing another spell mid-cast fails that
-- spell, not yours: only your cast's own GUID ends it, and without GUIDs a
-- failure is ignored while you're still casting.
local function OnCastEnd(event, castGUID)
    if not myCast or not IsMyCast(castGUID) then return end
    if not (myCast.guid and Plain(castGUID)) and event ~= "UNIT_SPELLCAST_STOP"
       and Plain(UnitCastingInfo("player")) then
        return
    end
    myCast = nil
    MarkAll()
end

-- /bhb heals
local function ListHeals()
    local ids = {}
    for id in pairs(healSizes) do ids[#ids + 1] = id end
    if #ids == 0 then
        Print("no heals measured yet. Heal yourself or your target (non-crits count).")
        return
    end
    table.sort(ids, function(a, b) return SpellLabel(a) < SpellLabel(b) end)
    Print("measured heals (real heal / tooltip average, per tooltip range; each starts at x1.00 worth "
        .. PRIOR_WEIGHT .. " heals):")
    for _, id in ipairs(ids) do
        local now = Tooltip(id)
        print(("  %s (%d):"):format(SpellLabel(id), id))
        for key in pairs(healSizes[id]) do
            local ratio, n, raw = Measured(id, key)
            print(("    tooltip %s: x%.3f over %d heals, using x%.3f%s"):format(key, raw, n, ratio,
                (now and now.key == key) and (" |cff40ff40(current, size %d)|r"):format(Round(now.base * ratio)) or ""))
        end
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
    elseif event == "UNIT_AURA" then
        if arg1 and (IsGroupToken(arg1) or arg1 == "target" or arg1 == "focus") then SyncHots(arg1) end
        if ns.auraLog and arg1 == ns.auraLog then
            local ok, err = pcall(ns.LogAuraEvent, arg1, arg2)
            if not ok then print("|cff33ccffBHB|r aura log failed: " .. tostring(err)) end
        end
    elseif event == "UNIT_COMBAT" then
        OnHealLanded(arg1, arg2, arg3, arg4)
    elseif event == "UNIT_SPELLCAST_SENT" then
        -- unit, target, castGUID, spellID
        if arg1 == "player" then OnCastSent(arg2, arg3) end
    elseif CAST_START[event] or CAST_END[event] then
        -- unit, castGUID, spellID
        if not (arg1 and IsGroupToken(arg1)) then return end
        if CAST_START[event] then CastTimeCheck(arg1) end
        if arg1 == "player" then
            if CAST_START[event] then
                OnCastStart(arg2)
            else
                if event == "UNIT_SPELLCAST_SUCCEEDED" then OnCastSucceeded(arg2, arg3) end
                OnCastEnd(event, arg2)
            end
        end
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        -- Same token, new unit (which may now also be you).
        local token = event == "PLAYER_TARGET_CHANGED" and "target" or "focus"
        mapDirty = true
        MarkUnit(token)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        RebuildRoster()
        Scan()
        SyncAllHots()
        MarkAll()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Auras are readable again: correct what was tracked in combat, and
        -- apply settings the HoT aura slots refused in combat.
        SyncAllHots()
        if hotRestyle then RestyleHots() end
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
        events:RegisterEvent("UNIT_AURA")
        events:RegisterUnitEvent("UNIT_COMBAT", "player", "target")
        local guid = UnitGUID("player")
        if guid and not issecretvalue(guid) then
            ns.db.healSizes[guid] = ns.db.healSizes[guid] or {}
            healSizes = ns.db.healSizes[guid]
        end
        events:RegisterEvent("GROUP_ROSTER_UPDATE")
        events:RegisterEvent("PLAYER_ENTERING_WORLD")
        events:RegisterEvent("PLAYER_TARGET_CHANGED")
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        pcall(events.RegisterEvent, events, "PLAYER_FOCUS_CHANGED")   -- not on every client
        if ns.InitOptions then ns.InitOptions() end
        playerClass = select(2, UnitClass("player"))
        for id, info in pairs(HOT_SPELLS) do
            local name = SpellName(id)
            if name and not issecretvalue(name) then
                info.name = name
                hotByName[name] = info
            end
        end
        ScanHotRanks()
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
    print(("  HoT aura slots: %s, %d frames ready, %d waiting%s"):format(
        hotRanksReady and (ns.stats.hotRanks .. " spell IDs") or "collecting spell IDs",
        ns.stats.hotSlotsBuilt, #hotQueue,
        ns.stats.hotSlotsError and (", |cffff4040last error:|r " .. tostring(ns.stats.hotSlotsError)) or ""))
    -- Which unit tokens repaint each unit frame (target/focus also list their group token).
    if mapDirty then RebuildMap() end
    for _, uf in ipairs(UNIT_FRAMES) do
        local rec = records[_G[uf.global] or false]
        if rec then
            local tokens = {}
            for u, l in pairs(unitMap) do
                for i = 1, #l do
                    if l[i] == rec then tokens[#tokens + 1] = u; break end
                end
            end
            table.sort(tokens)
            print(("  %s frame updates from: %s"):format(uf.label,
                #tokens > 0 and table.concat(tokens, ", ") or "nothing (hidden or no unit)"))
        end
    end
    print("  Cast end times:")
    for _, who in ipairs({ "player", "others" }) do
        local t = ns.stats.castTimes[who]
        print(("    %s: |cff40ff40%d plain|r, |cffff4040%d secret|r, %d no cast info")
            :format(who == "player" and "You" or "Group", t.plain, t.secret, t.missing))
    end
    local measured = 0
    for _ in pairs(healSizes) do measured = measured + 1 end
    print("  Spells with measured heals: " .. measured .. " (/bhb heals lists them)")
    local now = GetTime()
    for key, h in pairs(myHots) do
        print(("  Your HoT %s: %d of %d ticks left, %d to heal"):format(key, HotTicksLeft(h, now), h.ticks,
            Round(HotTicksLeft(h, now) * h.total / h.ticks)))
    end
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

-- /bhb auras [unit] [buffs] [mine]: the unit's debuffs (or buffs; mine: only
-- yours), which auras and fields this client hides, and whether lookups by
-- name still work on hidden ones.
local AURA_FIELDS = {
    "name", "spellId", "applications", "dispelName", "sourceUnit", "auraInstanceID", "duration",
    "expirationTime", "points",
}
local HOT_PROBES = {}   -- Rank 1 of each HoT (every rank shares the name)
for id in pairs(HOT_SPELLS) do HOT_PROBES[#HOT_PROBES + 1] = id end
table.sort(HOT_PROBES)

local function TimeLeft(exp, now)
    if issecretvalue(exp) then return Readable(exp) end
    if type(exp) ~= "number" then return "?" end
    return exp > 0 and ("%.1fs"):format(exp - now) or "no end"
end

-- Looks each spell up on the unit by name and by (Rank 1) spell ID.
local function ProbeByName(unit, filter, ids)
    local get = C_UnitAuras.GetAuraDataBySpellName
    if not get then
        print("  Lookup by name: |cffff4040C_UnitAuras.GetAuraDataBySpellName missing|r")
        return
    end
    local now = GetTime()
    for _, id in ipairs(ids) do
        local name = C_Spell.GetSpellName(id)
        if name and not issecretvalue(name) then
            local ok, a = pcall(get, unit, name, filter)
            local res
            if not ok then
                res = "|cffff4040error: " .. tostring(a) .. "|r"
            elseif issecretvalue(a) then
                res = "|cffff4040secret|r"
            elseif a == nil then
                res = "not on unit"
            else
                res = ("|cff40ff40found|r, ID %s, from %s, %s left"):format(Readable(a.spellId, "?"),
                    Readable(a.sourceUnit, "?"), TimeLeft(a.expirationTime, now))
            end
            print(("  Lookup %s: %s"):format(name, res))
            -- By spell ID: nil and secret data are told apart.
            local byID = C_UnitAuras.GetUnitAuraBySpellID
            if byID then
                local ok2, b = pcall(byID, unit, id)
                local r2 = not ok2 and ("|cffff4040error: " .. tostring(b) .. "|r")
                    or issecretvalue(b) and "|cffff4040secret|r"
                    or b == nil and "nil"
                    or ("|cff40ff40found|r, spell ID %s, %s left"):format(Readable(b.spellId, "?"),
                        TimeLeft(b.expirationTime, now))
                print(("  Lookup by ID %d: %s"):format(id, r2))
            end
        end
    end
end

local function SecretsReport()
    if not C_Secrets then
        print("  C_Secrets: |cffff4040missing|r")
        return
    end
    local names = {}
    for k, v in pairs(C_Secrets) do
        if type(v) == "function" then names[#names + 1] = k end
    end
    table.sort(names)
    print("  C_Secrets: " .. table.concat(names, ", "))
    if C_Secrets.ShouldAurasBeSecret then
        local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
        print("  ShouldAurasBeSecret(): " .. (ok and Readable(v, "nil") or ("error: " .. tostring(v))))
    end
end

local function DumpAuras(args)
    local unit, buffs, mine
    for w in args:gmatch("%S+") do
        if w == "buffs" or w == "buff" then buffs = true
        elseif w == "mine" then mine = true
        else unit = unit or w end
    end
    unit = unit or "target"
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
        Print("|cffff4040this client has no C_UnitAuras.GetAuraDataByIndex.|r")
        return
    end
    if not UnitExists(unit) then
        Print("no unit " .. unit)
        return
    end
    -- HoTs only matter on units you can heal.
    local friend = UnitIsFriend("player", unit)
    if not issecretvalue(friend) and not friend then
        Print(unit .. " isn't friendly; target a group member or use a token such as party1.")
        return
    end
    local kind = (mine and "your " or "") .. (buffs and "buffs" or "debuffs")
    local filter = (buffs and "HELPFUL" or "HARMFUL") .. (mine and "|PLAYER" or "")
    Print(("%s on %s (%s), you are %s"):format(kind, unit, Readable(UnitName(unit), "?"),
        InCombatLockdown() and "|cffff4040in combat|r" or "|cff40ff40out of combat|r"))
    local hidden, n, blocked, now = {}, 0, 0, GetTime()
    for i = 1, 40 do
        local a = ReadAura(unit, i, filter)
        if a == nil then break end
        n = i
        if not a then
            blocked = blocked + 1
            print(("  %d |cffff4040hidden from addons|r"):format(i))
        else
            for _, f in ipairs(AURA_FIELDS) do
                if issecretvalue(a[f]) then hidden[f] = true end
            end
            local pts, ptsText = a.points, "none"
            if issecretvalue(pts) then
                ptsText = Readable(pts)
            elseif type(pts) == "table" and #pts > 0 then
                local t = {}
                for j = 1, #pts do
                    if issecretvalue(pts[j]) then hidden.points = true end
                    t[j] = Readable(pts[j])
                end
                ptsText = table.concat(t, ", ")
            end
            print(("  %d %s (%s) x%s, %s, from %s, instance %s, %ss, %s left, points: %s"):format(i,
                Readable(a.name, "?"), Readable(a.spellId, "?"), Readable(a.applications, 0),
                Readable(a.dispelName, "no type"), Readable(a.sourceUnit, "?"), Readable(a.auraInstanceID, "?"),
                Readable(a.duration, "?"), TimeLeft(a.expirationTime, now), ptsText))
        end
    end
    if n == 0 then print("  no " .. kind) end
    if blocked == 40 then
        print("  |cffff4040Every aura slot reads as hidden, empty ones included, so the count can't be known.|r")
    elseif blocked > 0 then
        print(("  Auras hidden from addons: |cffff4040%d of %d|r"):format(blocked, n))
    end
    local list = {}
    for _, f in ipairs(AURA_FIELDS) do
        if hidden[f] then list[#list + 1] = f end
    end
    print("  Hidden fields: " .. (#list > 0 and ("|cffff4040" .. table.concat(list, ", ") .. "|r") or "|cff40ff40none|r"))
    if buffs then
        ProbeByName(unit, filter, HOT_PROBES)
        -- What the addon tracks from your casts, for comparison.
        local tracked = 0
        for key, h in pairs(myHots) do
            if HotOnUnit(unit, h) then
                tracked = tracked + 1
                print(("  Tracked HoT %s: %d of %d ticks left, %d to heal"):format(key, HotTicksLeft(h, now),
                    h.ticks, Round(HotTicksLeft(h, now) * h.total / h.ticks)))
            end
        end
        if tracked == 0 then print("  Tracked HoTs of yours: none") end
    end
    SecretsReport()
end

-- /bhb secrets: what this client keeps secret about auras, and the aura API it has.
local function SecretsDump()
    Print("secrets, you are " .. (InCombatLockdown() and "|cffff4040in combat|r" or "|cff40ff40out of combat|r"))
    SecretsReport()
    for name, enum in pairs(Enum or EMPTY) do
        if name:find("Secre") and type(enum) == "table" then
            local vals = {}
            for k, v in pairs(enum) do vals[#vals + 1] = k .. " = " .. tostring(v) end
            table.sort(vals)
            print(("  Enum.%s: %s"):format(name, table.concat(vals, ", ")))
        end
    end
    local fns = {}
    for k, v in pairs(C_UnitAuras or EMPTY) do
        if type(v) == "function" then fns[#fns + 1] = k end
    end
    table.sort(fns)
    print("  C_UnitAuras: " .. table.concat(fns, ", "))
    local S = C_Secrets or EMPTY
    for _, id in ipairs(HOT_PROBES) do
        local ok1, secret = pcall(S.ShouldSpellAuraBeSecret, id)
        local ok2, level = pcall(S.GetSpellAuraSecrecy, id)
        print(("  %s (%d): secret %s, secrecy %s"):format(tostring(C_Spell.GetSpellName(id)), id,
            ok1 and Readable(secret, "nil") or "error", ok2 and Readable(level, "nil") or "error"))
    end
    -- HoT tracking finds your cast's target by name or GUID.
    for _, u in ipairs({ "player", "party1", "target" }) do
        if UnitExists(u) then
            local ok, secret = pcall(S.ShouldUnitIdentityBeSecret, u)
            print(("  %s: identity secret %s, name %s, GUID %s"):format(u, ok and Readable(secret, "nil") or "error",
                Readable(UnitName(u), "nil"), Readable(UnitGUID(u), "nil")))
        end
    end
end

-- /bhb auralog [unit]: prints each UNIT_AURA payload for one unit, and whether
-- its auras can be read by instance ID (the slot order is hidden in combat).
ns.auraLog = nil

local function ReadInstance(unit, id)
    if issecretvalue(id) then return "ID " .. Readable(id) end
    local check = C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret
    local verdict = ""
    if check then
        local ok, secret = pcall(check, unit, id)
        verdict = ", instance secret " .. (ok and Readable(secret, "nil") or "error")
    end
    local get = C_UnitAuras.GetAuraDataByAuraInstanceID
    if not get then return ("ID %d%s, no GetAuraDataByAuraInstanceID"):format(id, verdict) end
    local ok, a = pcall(get, unit, id)
    local res
    if not ok then
        res = "|cffff4040read failed: " .. tostring(a) .. "|r"
    elseif issecretvalue(a) then
        res = "|cffff4040read: secret|r"
    elseif a == nil then
        res = "read: nil"
    else
        res = ("|cff40ff40read|r %s (%s) from %s, %s left"):format(Readable(a.name, "?"), Readable(a.spellId, "?"),
            Readable(a.sourceUnit, "?"), TimeLeft(a.expirationTime, GetTime()))
    end
    return ("ID %d%s, %s"):format(id, verdict, res)
end

local function LogAuraEvent(unit, info)
    local head = "|cff33ccffBHB|r UNIT_AURA " .. unit .. (InCombatLockdown() and " (in combat)" or "")
    if info == nil then print(head .. ": no update info") return end
    if issecretvalue(info) then print(head .. ": update info is secret") return end
    print(head .. ", full update: " .. Readable(info.isFullUpdate, "false"))
    local added = info.addedAuras
    if issecretvalue(added) then
        print("  added: |cffff4040secret list|r")
    elseif added then
        for _, a in ipairs(added) do
            if issecretvalue(a) then
                print("  added: |cffff4040secret aura|r")
            else
                print(("  added %s (%s) from %s, helpful %s; %s"):format(Readable(a.name, "?"), Readable(a.spellId, "?"),
                    Readable(a.sourceUnit, "?"), Readable(a.isHelpful, "?"), ReadInstance(unit, a.auraInstanceID)))
            end
        end
    end
    for _, key in ipairs({ "updatedAuraInstanceIDs", "removedAuraInstanceIDs" }) do
        local list = info[key]
        if issecretvalue(list) then
            print("  " .. key .. ": |cffff4040secret list|r")
        elseif list then
            for _, id in ipairs(list) do
                print("  " .. (key == "updatedAuraInstanceIDs" and "updated " or "removed ")
                    .. (key == "updatedAuraInstanceIDs" and ReadInstance(unit, id) or ("ID " .. Readable(id))))
            end
        end
    end
end
ns.LogAuraEvent = LogAuraEvent   -- the event handler is defined above this

-------------------------------------------------------------------------------
--  /bhb scan: walks spell IDs for descriptions that read like a heal over
--  time and saves them to BetterHealBarsDB.hotScan, each with a line in the
--  HOT_SPELLS format. English descriptions only; review before using.
-------------------------------------------------------------------------------
local SCAN_DEFAULT_MAX = 60000
local SCAN_BUDGET_MS = 8   -- per frame
local SCAN_LOAD_WAIT = 5   -- seconds without a load result before giving up on the rest
local SCAN_PRINT_MAX = 40  -- results printed to chat
local scanState

-- Returns false when the spell has no description to read (yet).
local function CheckDescription(st, id, name)
    local text = SpellDescription(id)
    if not text or text == "" then return false end
    st.described = st.described + 1
    local total, duration = HotFromText(text)
    if total then
        -- The tick interval isn't in the text: 3 sec is the usual one, so check it.
        local label = SpellLabel(id)
        local food = text:lower():find("seated") and true or nil
        st.hots[#st.hots + 1] = {
            id = id, name = label, total = total, duration = duration, text = text, food = food,
            listed = hotByName[name] and true or nil,
            line = ("[%d] = { tick = 3 }, -- %s: %d over %d sec%s"):format(id, label, total, duration,
                food and " (food/drink)" or ""),
        }
    end
    return true
end

local function ScanOne(st, id)
    local name = C_Spell.GetSpellName(id)
    if not name or issecretvalue(name) then return end
    st.found, st.highest = st.found + 1, id
    if CheckDescription(st, id, name) then return end
    -- The client loads spell text on demand: ask for it, and SPELL_DATA_LOAD_RESULT
    -- reads it again. Already loaded with no text: nothing to wait for.
    local cached = C_Spell.IsSpellDataCached and C_Spell.IsSpellDataCached(id)
    if C_Spell.RequestLoadSpellData and not (not issecretvalue(cached) and cached) then
        st.pending[id] = name
        st.pendingCount = st.pendingCount + 1
        C_Spell.RequestLoadSpellData(id)
    end
end

local scanFrame = CreateFrame("Frame")
scanFrame:Hide()

scanFrame:SetScript("OnEvent", function(_, _, id, success)
    local st = scanState
    local name = st and st.pending[id]
    if not name then return end
    st.pending[id] = nil
    st.pendingCount = st.pendingCount - 1
    st.lastLoad = GetTime()
    if success then
        st.loaded = st.loaded + 1
        pcall(CheckDescription, st, id, name)
    end
end)

local function FinishScan(stopped)
    scanFrame:Hide()
    scanFrame:UnregisterAllEvents()
    local st = scanState
    scanState = nil
    local hots = st.hots
    table.sort(hots, function(a, b) return a.id < b.id end)
    ns.db.hotScan = {
        build = (GetBuildInfo()), date = date("%Y-%m-%d %H:%M"), scannedTo = st.next - 1,
        highestSpell = st.highest, results = hots,
    }

    Print(("scan %s at ID %d: %d spells, %d with a description (%d loaded on request, %d never arrived)."):format(
        stopped and "stopped" or "done", st.next - 1, st.found, st.described, st.loaded, st.pendingCount))
    if st.described == 0 then
        Print("|cffff4040no spell descriptions could be read.|r Check one by hand: "
            .. "/dump C_Spell.GetSpellDescription(139)")
    end

    -- Food and drink are most of them; they're saved but not printed.
    local food, shown = 0, 0
    for _, r in ipairs(hots) do
        if r.food then food = food + 1 end
    end
    Print(("%d read like a heal over time (%d of them food or drink, not listed here):"):format(#hots, food))
    for _, r in ipairs(hots) do
        if not r.food then
            shown = shown + 1
            if shown <= SCAN_PRINT_MAX then
                print(("  %d %s: %d over %ds%s"):format(r.id, r.name, r.total, r.duration,
                    r.listed and " |cff40ff40(tracked)|r" or ""))
            end
        end
    end
    if shown > SCAN_PRINT_MAX then print(("  ...and %d more in the saved file"):format(shown - SCAN_PRINT_MAX)) end

    if st.errors > 0 then print(("  |cffff4040%d spell IDs couldn't be read.|r"):format(st.errors)) end
    if not stopped and st.highest > st.max - 5000 then
        Print(("spells exist up to ID %d; there may be more. Try /bhb scan %d."):format(st.highest, st.max * 2))
    end
    Print("/reload writes the full list (descriptions and ready-made lines) to "
        .. "WTF\\Account\\<account>\\SavedVariables\\BetterHealBars.lua, under hotScan.")
end

scanFrame:SetScript("OnUpdate", function()
    local st = scanState
    -- Descriptions may be hidden in combat.
    if InCombatLockdown() then
        if not st.paused then Print("scan paused while you're in combat.") end
        st.paused = true
        return
    end
    st.paused = false
    local stop = debugprofilestop() + SCAN_BUDGET_MS
    while st.next <= st.max and debugprofilestop() < stop do
        local ok = pcall(ScanOne, st, st.next)
        if not ok then st.errors = st.errors + 1 end
        st.next = st.next + 1
        if st.next % 10000 == 0 then
            Print(("scan at ID %d of %d, %d HoTs so far."):format(st.next, st.max, #st.hots))
        end
    end
    if st.next > st.max then
        -- Wait for requested spell text until it stops arriving.
        st.lastLoad = st.lastLoad or GetTime()
        if st.pendingCount == 0 or GetTime() - st.lastLoad > SCAN_LOAD_WAIT then FinishScan(false) end
    end
end)

local function StartScan(arg)
    if arg == "stop" then
        if scanState then FinishScan(true) else Print("no scan running.") end
        return
    end
    if scanState then
        Print(("scan running: ID %d of %d, %d HoTs. /bhb scan stop ends it."):format(
            scanState.next, scanState.max, #scanState.hots))
        return
    end
    if not (C_Spell and C_Spell.GetSpellName) then
        Print("|cffff4040this client has no C_Spell.GetSpellName.|r")
        return
    end
    local max = tonumber(arg) or SCAN_DEFAULT_MAX
    scanState = {
        next = 1, max = max, found = 0, highest = 0, errors = 0, hots = {},
        described = 0, loaded = 0, pending = {}, pendingCount = 0,
    }
    Print(("scanning spell IDs 1 to %d for heals over time..."):format(max))
    pcall(scanFrame.RegisterEvent, scanFrame, "SPELL_DATA_LOAD_RESULT")   -- not on every client
    scanFrame:Show()
end

SLASH_BETTERHEALBARS1 = "/bhb"
SLASH_BETTERHEALBARS2 = "/betterhealbars"
SlashCmdList.BETTERHEALBARS = function(msg)
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
    elseif msg == "secrets" then
        local ok, err = pcall(SecretsDump)
        if not ok then Print("|cffff4040secrets report failed:|r " .. tostring(err)) end
    elseif msg:match("^auralog") then
        local u = msg:match("^auralog%s*(%S*)")
        if u == "" and ns.auraLog then
            ns.auraLog = nil
            Print("aura log off")
        else
            ns.auraLog = u ~= "" and u or "target"
            Print("aura log on for " .. ns.auraLog .. ": every aura change on it prints. /bhb auralog turns it off.")
        end
    elseif msg:match("^scan") then
        StartScan(msg:match("^scan%s*(.*)$"))
    elseif msg:match("^auras") then
        local ok, err = pcall(DumpAuras, msg:match("^auras%s*(.*)$"))
        if not ok then Print("|cffff4040aura dump failed:|r " .. tostring(err)) end
    elseif msg == "rescan" then
        Scan()
        MarkAll()
        Print("rescanned frames")
    elseif ns.OpenOptions then
        ns.OpenOptions()
    end
end
