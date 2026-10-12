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
| Show my heals over time | Heal prediction leaves HoTs out. With this on, the full amount your Renew, Rejuvenation and Regrowth have still to heal is drawn after the other heal bars, in its own color, shrinking as each tick lands. It disappears as soon as the HoT is gone, dispelled included. Only your own HoTs. |
| Master opacity | Multiplies the opacity of every color you picked (your heals, others' heals, your HoTs, the overheal color). Off while class colors are on. |
| Party and Raid share settings | While on, the Party tab edits the Raid settings. |
| Copy to Unit / Party / Raid | Copies every setting on the current tab to another tab. |

Slash commands:

- `/bhb` opens the options.
- `/bhb test` turns fake test bars on or off.
- `/bhb status` prints diagnostics.
- `/bhb casts` turns cast debug on or off. Every group cast start prints the caster, spell and whether its end time is readable. Your casts also print the spell and rank, the heal size used and where it came from, the overheal cut-off per tab, the tooltip and measured averages, and the spell's tooltip text. Your HoTs print their target, total and ticks, or why they weren't tracked.
- `/bhb resetstats` clears the cast end time counts shown by `/bhb status`.
- `/bhb combatlog` turns the heal log on or off: each heal landing on you or your target prints its amount and whether it was used to measure your heal size, or why not.
- `/bhb heals` lists, per spell, rank and tooltip range, how your real heals compare to the tooltip average, marking the current range with the size it gives.
- `/bhb resetheals` clears the measurements.
- `/bhb auras [unit] [buffs] [mine]` lists the debuffs on a friendly unit (target by default, or a token such as `party1`), or its buffs with `buffs`, only yours with `mine`, with their spell ID, stacks, type, source, duration, time left and points. It marks auras and fields the client hides from addons (in combat), and says whether you're in combat. With `buffs` it also looks up Renew, Rejuvenation and Regrowth by name and spell ID, and lists the HoTs the addon is tracking on the unit. It ends with the client's `C_Secrets` functions.
- `/bhb secrets` lists the client's `C_Secrets` and `C_UnitAuras` functions, its secrecy enums, whether each HoT's aura is secret, and whether you, `party1` and your target have a readable name and GUID.
- `/bhb auralog [unit]` turns on or off a log of every aura change on a unit (target by default): what each `UNIT_AURA` event carries, and whether those auras can be read by instance ID.
- `/bhb scan [maxID]` goes through spell IDs 1 to `maxID` (default 60000) for descriptions that read like a heal over time, a few each frame and paused in combat, then prints the first 40 (food and drink are only counted). After `/reload`, the full list (total, duration and a line for the addon's HoT table, with an assumed 3 sec tick) is in `WTF/Account/<account>/SavedVariables/BetterHealBars.lua` under `hotScan`. It matches English text, so review what it finds. `/bhb scan` while running shows progress; `/bhb scan stop` ends it early and keeps what was found.
- `/bhb rescan` finds frames again.

## How it works

- **My / other split.** `GetIncomingHeals()` returns the total, the amount from the player, and the amount from everyone else.
- **Overflow.** The calculator's `SetIncomingHealOverflowPercent(1 + pct)` clamps the amounts. A clipping frame limits how far the bars can draw past the bar end.
- **Overheal threshold.** Your cast's spell ID is readable, so the heal's size is a plain number. It's the spell tooltip's average, which already follows your healing power as you change gear, times a correction measured from your real heals and saved per character. The combat log is Blizzard-only on this client, but `UNIT_COMBAT` reports heals on you and your target with a readable amount (overheal included) and a crit flag. A heal is matched to your cast that just succeeded (within 0.6 s) on the unit the cast was sent to; the sent name may carry a surname or realm. Non-crits within the tooltip range (90% of the low end to 150% of the high end) feed a running average of heal ÷ tooltip average per spell ID (so per rank) and per tooltip range. Any change to the tooltip, such as gear, a buff or a debuff that changes your healing power, starts a fresh measurement; going back to a range you have used before reuses its measurement (up to 8 ranges per spell are kept). Rolls are noisy, so each one starts at ×1.00 counted as 10 heals, and the ratio used only moves away from the tooltip as real heals build up. It covers what the tooltip leaves out, such as talents. The part of your heal that fits (capped at missing health, possibly secret) becomes the value of a hidden StatusBar with the one-HP-wide range `[cut, cut + 1]`, where `cut = size × (1 − threshold)`. The bar clamps, so it's either empty (flagged) or full, and a texture anchored from its fill's end to your fill's end shows the overheal color only in the empty case. That pair is only shown while the calculator's `clamped` flag (health plus incoming heals exceed max health, possibly secret, applied with `SetAlphaFromBoolean`) is true, so a heal that fits is never flagged. (`ColorCurve:Evaluate` rejects secret input from addon code on this client.)
- **Stacking.** Bars are chained by anchors, so the game's layout engine adds the amounts up, not Lua.
- **Your HoTs.** In combat the client hides every aura from addons (`C_Secrets.ShouldAurasBeSecret()` is true, and Renew, Rejuvenation and Regrowth are `ContextuallySecret`), so HoTs can't be read from buffs. Your own casts stay readable: when Renew, Rejuvenation or Regrowth succeeds, the spell's tooltip gives the total and duration (it follows your healing power), and the target comes from the name the cast was sent to. Spells are matched by name, so every rank counts. The bar shows the ticks still to land times the amount per tick (3 sec ticks), drawn after the others' bar, and drops each time a tick is due. A HoT ends when it runs out or its target dies. Out of combat your auras are readable again, so on aura changes, leaving combat, roster changes and logging in, the tracked HoTs are lined up with the real ones: timers corrected, dispelled ones dropped, and ones cast before a `/reload` picked up. Regrowth's up-front heal is in the heal API already and is still measured like any other heal; Renew and Rejuvenation have nothing up front, so they aren't.
- **Dispelled HoTs.** In combat a dispelled HoT can't be seen from Lua, but the client's `AuraContainer` widget (from `Blizzard_AuraContainer`, as EllesmereUI uses for its aura displays) matches a unit's auras itself. Each frame gets a container with one slot per HoT, filtered to your casts of it: `HELPFUL|PLAYER` with `candidateFilters = { includeSpellIDs = ... }`, holding every rank's spell ID, collected by name from the client's spell list at login. The game shows a slot only while that HoT is on the unit. Each HoT has its own bar, which carries the amount but draws nothing once the slots are ready; what shows is a texture inside the slot, laid over that bar. While auras are secret the client refuses every write to a slot's objects, so the texture is created once, in the slot's initializer, and its look can only change out of combat (a change made in combat applies when combat ends). Until the slots are ready, or if the client lacks the widget, the bars draw themselves. Spell-ID filters work like this only for buffs on units you can assist: for debuffs on friendly units the client drops them (its identity gate), so heal-reducing debuffs such as Mortal Strike can't be detected this way.
- **Class colors.** Each group healer's amount is read by passing that healer as the calculator's source, so it gets its own bar in the chain. Whatever is left over (healers outside the group) still shows in the other players' color.

### Limits

- **Only your own HoTs.** Other players' HoTs can't be seen in combat, and the heal API doesn't report them. Your HoTs' amounts come from your casts, so ticks are assumed every 3 sec and talents that change HoT healing aren't counted. The HoT amount is read from English tooltip text. Finding the target needs its name or GUID to be readable when you cast. With Rejuvenation and Regrowth both up, a dispelled one leaves a gap where its bar was until it would have run out.
- **Heal size is an average.** Each heal's roll can't be known until it lands, and crits aren't counted. Heals are only measured on you and your target, so a spell you only cast on others keeps its tooltip average. The tooltip is read by its numbers only, so it works in any client language; spells that show a single amount instead of a range use the first number in the text, which is less reliable. Heals from others landing first and heal absorbs on the target aren't taken into account.
- **Healing reduction isn't taken into account.** Heal prediction leaves out debuffs such as Mortal Strike, and the client hides them from addons on friendly units, `AuraContainer` filters included. Heal bars on such a unit show more than will land, and with one on the target, any overheal can be flagged by the recolor, not just overheal at or above the threshold.

## License

GPL-3.0. See [LICENSE](LICENSE).
