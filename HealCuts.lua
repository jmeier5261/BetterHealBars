-------------------------------------------------------------------------------
--  HealCuts.lua
--  Debuffs that reduce healing taken, by spell ID. Every rank has its own
--  ID, so list each one (/bhb auras shows the IDs on a friendly unit, and
--  /bhb scan finds candidates by their description).
--    pct:   % less healing taken
--    group: debuffs in one group don't stack with each other, so only the
--           strongest counts; different groups multiply
--  Only percentages are supported; flat cuts such as Wound Poison aren't.
--
--  Copyright (C) 2026 jmeier5261
--  Licensed under the GNU General Public License v3.0. See LICENSE.
-------------------------------------------------------------------------------
local _, ns = ...

ns.HEAL_CUTS = {
    -- Wounds: "reducing the effectiveness of any healing by 50%"
    [12294] = { pct = 50, group = "mortal" },   -- Mortal Strike (Rank 1)
    [21551] = { pct = 50, group = "mortal" },   -- Mortal Strike (Rank 2)
    [21552] = { pct = 50, group = "mortal" },   -- Mortal Strike (Rank 3)
    [21553] = { pct = 50, group = "mortal" },   -- Mortal Strike (Rank 4)
    [27580] = { pct = 50, group = "mortal" },   -- Mortal Strike (Rank 4)
    [26652] = { pct = 50, group = "mortal" },   -- Copy of Mortal Strike (Rank 1)
    [13737] = { pct = 50, group = "mortal" },   -- Mortal Strike (NPC)
    [15708] = { pct = 50, group = "mortal" },   -- Mortal Strike (NPC)
    [16856] = { pct = 50, group = "mortal" },   -- Mortal Strike (NPC)
    [17547] = { pct = 50, group = "mortal" },   -- Mortal Strike (NPC)
    [19643] = { pct = 50, group = "mortal" },   -- Mortal Strike (NPC)
    [24573] = { pct = 50, group = "mortal" },   -- Mortal Strike (NPC)
    [22859] = { pct = 50, group = "mortal" },   -- Mortal Cleave (NPC)

    -- Hex of Weakness (Ranks 1-6)
    [9035]  = { pct = 20, group = "hex of weakness" },
    [19281] = { pct = 20, group = "hex of weakness" },
    [19282] = { pct = 20, group = "hex of weakness" },
    [19283] = { pct = 20, group = "hex of weakness" },
    [19284] = { pct = 20, group = "hex of weakness" },
    [19285] = { pct = 20, group = "hex of weakness" },

    -- NPC debuffs
    [7068]  = { pct = 75, group = "veil of shadow" },          -- Veil of Shadow
    [17820] = { pct = 75, group = "veil of shadow" },          -- Veil of Shadow
    [22687] = { pct = 75, group = "veil of shadow" },          -- Veil of Shadow
    [23224] = { pct = 75, group = "veil of shadow" },          -- Veil of Shadow
    [24674] = { pct = 75, group = "veil of shadow" },          -- Veil of Shadow
    [28440] = { pct = 75, group = "veil of shadow" },          -- Veil of Shadow
    [19716] = { pct = 75, group = "gehennas' curse" },         -- Gehennas' Curse
    [13583] = { pct = 50, group = "curse of the deadwood" },   -- Curse of the Deadwood
}
