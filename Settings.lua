-------------------------------------------------------------------------------
--  Settings.lua
--  Saved variables, defaults, per-scope resolution (unit / party / raid),
--  the party+raid share toggle and copy between scopes.
--
--  Copyright (C) 2026 jmeier5261
--  Licensed under the GNU General Public License v3.0. See LICENSE.
-------------------------------------------------------------------------------
local _, ns = ...

-- "unit" is EllesmereUIUnitFrames' player, target and focus frames.
ns.SCOPES = { "unit", "party", "raid" }
ns.SCOPE_LABELS = { unit = "Unit", party = "Party", raid = "Raid" }

local function Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end

-- Palette carried over from HealPredict's raid palette, used by every scope.
local function ScopeDefaults(my, other, overflowOn, overflowPct)
    return {
        showMine           = true,
        showOthers         = true,
        myColor            = Color(my[1], my[2], my[3], 1),
        otherColor         = Color(other[1], other[2], other[3], 1),
        useHealthTexture   = false,
        useClassColors     = false,         -- each group healer's heals in their EllesmereUI class color
        classColorMine     = false,         -- ...and your own heals in yours
        classColorAlpha    = 60,            -- % opacity of class-colored bars

        overflowEnabled    = overflowOn,
        overflowPct        = overflowPct,   -- % of max health heals may run past the bar end

        overhealThreshold  = 20,            -- % of your heal that would be wasted
        overhealMine       = false,
        myOverhealColor    = Color(0.90, 0.55, 0.10, 1),

        masterOpacity      = 100,           -- % multiplier on the colors above; ignored with class colors
    }
end

ns.DEFAULTS = {
    unit   = ScopeDefaults({ 0.043, 0.533, 0.412 }, { 0.082, 0.349, 0.282 }, true, 5),
    party  = ScopeDefaults({ 0.043, 0.533, 0.412 }, { 0.082, 0.349, 0.282 }, true, 25),
    raid   = ScopeDefaults({ 0.043, 0.533, 0.412 }, { 0.082, 0.349, 0.282 }, true, 5),
}
-- Which unit frames draw; everything else on the Unit tab is shared by all three.
ns.DEFAULTS.unit.framePlayer = true
ns.DEFAULTS.unit.frameTarget = true
ns.DEFAULTS.unit.frameFocus  = true

local function DeepCopy(src)
    if type(src) ~= "table" then return src end
    local t = {}
    for k, v in pairs(src) do t[k] = DeepCopy(v) end
    return t
end
ns.DeepCopy = DeepCopy

-- Fill keys missing from dst with defaults (new options after an update).
local function FillMissing(dst, defaults)
    for k, v in pairs(defaults) do
        if dst[k] == nil then
            dst[k] = DeepCopy(v)
        elseif type(v) == "table" and type(dst[k]) == "table" then
            FillMissing(dst[k], v)
        end
    end
end

function ns.InitDB()
    BetterHealBarsDB = BetterHealBarsDB or {}
    local db = BetterHealBarsDB
    db.version = 1
    if db.sharePartyRaid == nil then db.sharePartyRaid = false end
    db.healSizes = db.healSizes or {}   -- player GUID -> { spellID -> { "lo-hi" tooltip -> { ratio, n, last } } }
    db.scopes = db.scopes or {}
    for _, scope in ipairs(ns.SCOPES) do
        db.scopes[scope] = db.scopes[scope] or {}
        FillMissing(db.scopes[scope], ns.DEFAULTS[scope])
    end
    ns.db = db
end

-- Which stored table a scope reads from: party follows raid while shared.
function ns.EffectiveScope(scope)
    if scope == "party" and ns.db.sharePartyRaid then return "raid" end
    return scope
end

function ns.GetSettings(scope)
    return ns.db.scopes[ns.EffectiveScope(scope)]
end

function ns.CopyScope(from, to)
    from, to = ns.EffectiveScope(from), ns.EffectiveScope(to)
    if from == to then return false end
    ns.db.scopes[to] = DeepCopy(ns.db.scopes[from])
    return true
end

function ns.ResetScope(scope)
    scope = ns.EffectiveScope(scope)
    ns.db.scopes[scope] = DeepCopy(ns.DEFAULTS[scope])
end
