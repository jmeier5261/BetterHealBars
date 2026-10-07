# Forever HealPredict (EllesmereUI)

Incoming-heal bars for **EllesmereUI** frames on **WoW Forever** (client interface 16001, game type `camelot`).

- Raid frames and party frames come from `EllesmereUIRaidFrames`.
- The player frame comes from `EllesmereUIUnitFrames` (`EllesmereUIUnitFrames_Player`).

Install by copying the `ForeverHealPredict` folder into `_classic_beta_/Interface/AddOns/` (or the live Forever client's AddOns folder). Turn off EllesmereUI's own **Heal Prediction** option for raid, party and player frames, or you'll see two sets of bars. The addon warns at login when it's still on.

## Features

Each feature can be set separately for Player, Party and Raid frames.

| Option | Notes |
|---|---|
| Show my heals / Show other players' heals | Each has its own toggle, color and opacity. |
| Color heals by healer's class | Each group healer's heals are drawn in their EllesmereUI class color (your custom palette, if set). Healers outside your group, or of a non-healing class, keep the other players' color. A sub-option also colors your own heals by your class. Class-colored bars have their own opacity (default 60%). |
| Extend past bar end | Heals can run past the end of the bar, up to a set % of max health. |
| Overheal recolor | While you cast a heal, your heal bar changes color when at least the threshold % of that heal would be wasted. Example: a 100 heal on a target missing 60 wastes 40%, so it's flagged at a threshold of 40% or lower. Only your own heals are checked. |
| Master opacity | Multiplies the opacity of every color you picked (your heals, others' heals, the overheal color). Off while class colors are on. |
| Party and Raid share settings | While on, the Party tab edits the Raid settings. |
| Copy to Player / Party / Raid | Copies every setting on the current tab to another tab. |

Slash commands:

- `/fhp` opens the options.
- `/fhp test` turns fake test bars on or off.
- `/fhp status` prints diagnostics.
- `/fhp casts` turns cast debug on or off. Every group cast start prints the caster, spell and whether its end time is readable. Your casts also print the spell and rank, the heal size used and where it came from, the overheal cut-off per tab, the tooltip and measured averages, and the spell's tooltip text.
- `/fhp resetstats` clears the cast end time counts shown by `/fhp status`.
- `/fhp combatlog` turns the heal log on or off: each heal landing on you or your target prints its amount and whether it was used to measure your heal size, or why not.
- `/fhp heals` lists, per spell and rank, how your real heals compare to the tooltip average and the size that gives.
- `/fhp resetheals` clears the measurements.
- `/fhp rescan` finds frames again.


- **My / other split.** `GetIncomingHeals()` returns the total, the amount from the player, and the amount from everyone else.
- **Overflow.** The calculator's `SetIncomingHealOverflowPercent(1 + pct)` clamps the amounts. A clipping frame limits how far the bars can draw past the bar end.
- **Overheal threshold.** Your cast's spell ID is readable, so the heal's size is a plain number. It's the spell tooltip's average, which already follows your healing power as you change gear, times a correction measured from your real heals and saved per character. The combat log is Blizzard-only on this client, but `UNIT_COMBAT` reports heals on you and your target with a readable amount (overheal included) and a crit flag. A heal is matched to your cast that just succeeded (within 0.6 s) on the unit the cast was sent to; the sent name may carry a surname or realm. Non-crits within the tooltip range (90% of the low end to 150% of the high end) feed a running average of heal ÷ tooltip average per spell ID, so each rank is measured separately. Rolls are noisy, so each spell starts at ×1.00 counted as 10 heals, and the ratio used only moves away from the tooltip as real heals build up. It covers what the tooltip leaves out, such as talents. The part of your heal that fits (capped at missing health, possibly secret) becomes the value of a hidden StatusBar with the one-HP-wide range `[cut, cut + 1]`, where `cut = size × (1 − threshold)`. The bar clamps, so it's either empty (flagged) or full, and a texture anchored from its fill's end to your fill's end shows the overheal color only in the empty case. (`ColorCurve:Evaluate` rejects secret input from addon code on this client.)
- **Stacking.** Bars are chained by anchors, so the game's layout engine adds the amounts up, not Lua.
- **Class colors.** Each group healer's amount is read by passing that healer as the calculator's source, so it gets its own bar in the chain. Whatever is left over (healers outside the group) still shows in the other players' color.

### Limits

- **No HoT prediction or per-spell detail.** The client API only reports what Blizzard's prediction covers.
- **Heal size is an average.** Each heal's roll can't be known until it lands, and crits aren't counted. Heals are only measured on you and your target, so a spell you only cast on others keeps its tooltip average (English tooltips only). Heals from others landing first and heal absorbs on the target aren't taken into account.

## License

GPL-3.0. See [LICENSE](LICENSE).
