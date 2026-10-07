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
| Overheal recolor | Bars change color when health plus all incoming heals goes over max health by the threshold %. The color, opacity and on/off toggle are separate for your heals and for others' heals. |
| Master opacity | Multiplies the opacity of every color you picked (your heals, others' heals, both overheal colors). Off while class colors are on. |
| Party and Raid share settings | While on, the Party tab edits the Raid settings. |
| Copy to Player / Party / Raid | Copies every setting on the current tab to another tab. |

Slash commands:

- `/fhp` opens the options.
- `/fhp test` turns fake test bars on or off.
- `/fhp status` prints diagnostics.
- `/fhp rescan` finds frames again.


- **My / other split.** `GetIncomingHeals()` returns the total, the amount from the player, and the amount from everyone else.
- **Overflow.** The calculator's `SetIncomingHealOverflowPercent(1 + pct)` clamps the amounts. A clipping frame limits how far the bars can draw past the bar end.
- **Overheal threshold.** The same data is checked again with an overflow of `1 + threshold`. The calculator's `clamped` flag (possibly secret) is then turned into a color with `C_CurveUtil.EvaluateColorValueFromBoolean`.
- **Stacking.** Bars are chained by anchors, so the game's layout engine adds the amounts up, not Lua.
- **Class colors.** Each group healer's amount is read by passing that healer as the calculator's source, so it gets its own bar in the chain. Whatever is left over (healers outside the group) still shows in the other players' color.

### Limits

- **No HoT prediction or per-spell detail.** The client API only reports what Blizzard's prediction covers.

## License

GPL-3.0. See [LICENSE](LICENSE).
