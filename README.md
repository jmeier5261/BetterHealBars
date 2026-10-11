# Better Heal Bars (EllesmereUI)

Incoming-heal bars for **EllesmereUI** frames on **WoW Forever** (client interface 16001, game type `camelot`).

- Raid frames and party frames come from `EllesmereUIRaidFrames`.
- The player, target and focus frames come from `EllesmereUIUnitFrames` (`EllesmereUIUnitFrames_Player`, `_Target`, `_Focus`).

Install by copying the `BetterHealBars` folder into `_classic_beta_/Interface/AddOns/` (or the live Forever client's AddOns folder). Turn off EllesmereUI's own **Heal Prediction** option for raid, party, player, target and focus frames, or you'll see two sets of bars. The addon warns at login when it's still on.

## Features

Each feature can be set separately for Unit, Party and Raid frames. The Unit tab covers the player, target and focus frames, which share its settings and can each be turned on or off.

| Option | Notes |
|---|---|
| Show my heals / Show other players' heals | Each has its own toggle, color and opacity. |
| Color heals by healer's class | Each group healer's heals are drawn in their EllesmereUI class color (your custom palette, if set). Healers outside your group, or of a non-healing class, keep the other players' color. A sub-option also colors your own heals by your class. Class-colored bars have their own opacity (default 60%). |
| Extend past bar end | Heals can run past the end of the bar, up to a set % of max health. |
| Overheal recolor | While you cast a heal, your heal bar changes color when at least the threshold % of that heal would be wasted. Example: a 100 heal on a target missing 60 wastes 40%, so it's flagged at a threshold of 40% or lower. Only your own heals are checked. |
| Healing reduction | Heal prediction leaves out debuffs such as Mortal Strike. With a known one on a friendly unit, every heal bar on it is drawn at the size that will land, and the reduction (such as `-50%`) can show over the health bar in a color and position you pick. Your overheal recolor always counts it. The debuffs are listed by spell ID in `HealCuts.lua`. |
| Master opacity | Multiplies the opacity of every color you picked (your heals, others' heals, the overheal color). Off while class colors are on. |
| Party and Raid share settings | While on, the Party tab edits the Raid settings. |
| Copy to Unit / Party / Raid | Copies every setting on the current tab to another tab. |

Slash commands:

- `/bhb` opens the options.
- `/bhb test` turns fake test bars on or off.
- `/bhb status` prints diagnostics.
- `/bhb casts` turns cast debug on or off. Every group cast start prints the caster, spell and whether its end time is readable. Your casts also print the spell and rank, the heal size used and where it came from, the overheal cut-off per tab, the tooltip and measured averages, and the spell's tooltip text.
- `/bhb resetstats` clears the cast end time counts shown by `/bhb status`.
- `/bhb combatlog` turns the heal log on or off: each heal landing on you or your target prints its amount and whether it was used to measure your heal size, or why not.
- `/bhb heals` lists, per spell, rank and tooltip range, how your real heals compare to the tooltip average, marking the current range with the size it gives.
- `/bhb resetheals` clears the measurements.
- `/bhb auras [unit]` lists the debuffs on a friendly unit (target by default, or a token such as `party1`) with their spell ID, stacks, type, source and points, marks the ones listed in `HealCuts.lua` and the fields the client hides, and prints the healing reduction counted and whether you're in combat.
- `/bhb scan [maxID]` goes through spell IDs 1 to `maxID` (default 60000) for descriptions that read like healing reduction, a few each frame and paused in combat, then prints the first 40. After `/reload`, the full list (description, amount and a line ready for `HealCuts.lua`) is in `WTF/Account/<account>/SavedVariables/BetterHealBars.lua` under `healCutScan`. It matches English text, so review what it finds. `/bhb scan` while running shows progress; `/bhb scan stop` ends it early and keeps what was found.
- `/bhb rescan` finds frames again.

## How it works

- **My / other split.** `GetIncomingHeals()` returns the total, the amount from the player, and the amount from everyone else.
- **Overflow.** The calculator's `SetIncomingHealOverflowPercent(1 + pct)` clamps the amounts. A clipping frame limits how far the bars can draw past the bar end.
- **Overheal threshold.** Your cast's spell ID is readable, so the heal's size is a plain number. It's the spell tooltip's average, which already follows your healing power as you change gear, times a correction measured from your real heals and saved per character. The combat log is Blizzard-only on this client, but `UNIT_COMBAT` reports heals on you and your target with a readable amount (overheal included) and a crit flag. A heal is matched to your cast that just succeeded (within 0.6 s) on the unit the cast was sent to; the sent name may carry a surname or realm. Non-crits within the tooltip range (90% of the low end to 150% of the high end) feed a running average of heal ÷ tooltip average per spell ID (so per rank) and per tooltip range. Any change to the tooltip, such as gear, a buff or a debuff that changes your healing power, starts a fresh measurement; going back to a range you have used before reuses its measurement (up to 8 ranges per spell are kept). Rolls are noisy, so each one starts at ×1.00 counted as 10 heals, and the ratio used only moves away from the tooltip as real heals build up. It covers what the tooltip leaves out, such as talents. The part of your heal that fits (capped at missing health, possibly secret) becomes the value of a hidden StatusBar with the one-HP-wide range `[cut, cut + 1]`, where `cut = size × (1 − threshold)`. The bar clamps, so it's either empty (flagged) or full, and a texture anchored from its fill's end to your fill's end shows the overheal color only in the empty case. That pair is only shown while the calculator's `clamped` flag (health plus incoming heals exceed max health, possibly secret, applied with `SetAlphaFromBoolean`) is true, so a heal that fits is never flagged. (`ColorCurve:Evaluate` rejects secret input from addon code on this client.)
- **Stacking.** Bars are chained by anchors, so the game's layout engine adds the amounts up, not Lua.
- **Healing reduction.** On `UNIT_AURA`, a friendly unit's debuffs are matched by spell ID against `HealCuts.lua`. Within a group only the strongest counts; groups multiply. Amounts can be secret, so they can't be multiplied, but a StatusBar's fill is value ÷ max of the bar's length: each heal bar is made that much shorter, which draws every amount times the multiplier. The calculator caps amounts before that, so its overflow cap is loosened until the shrunk amount can always reach the real limit, and the clipping frame cuts it there. Your overheal cut-off uses your heal size times the multiplier. Heals landing on a unit with a reduction aren't used to measure your heal size.
- **Class colors.** Each group healer's amount is read by passing that healer as the calculator's source, so it gets its own bar in the chain. Whatever is left over (healers outside the group) still shows in the other players' color.

### Limits

- **No HoT prediction or per-spell detail.** The client API only reports what Blizzard's prediction covers.
- **Heal size is an average.** Each heal's roll can't be known until it lands, and crits aren't counted. Heals are only measured on you and your target, so a spell you only cast on others keeps its tooltip average. The tooltip is read by its numbers only, so it works in any client language; spells that show a single amount instead of a range use the first number in the text, which is less reliable. Heals from others landing first and heal absorbs on the target aren't taken into account.
- **Healing reduction only counts listed debuffs.** Anything missing from `HealCuts.lua`, or whose spell ID the client hides, is ignored. Only percentage reductions are supported; flat ones (such as Wound Poison) aren't.

## License

GPL-3.0. See [LICENSE](LICENSE).
