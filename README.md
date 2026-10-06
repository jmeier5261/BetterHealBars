# Forever HealPredict (EllesmereUI)

Incoming-heal bars for **EllesmereUI** frames on **WoW Forever** (client interface 16001, game type `camelot`).

- Raid frames and party frames come from `EllesmereUIRaidFrames`.
- The player frame comes from `EllesmereUIUnitFrames` (`EllesmereUIUnitFrames_Player`).

Install by copying the `ForeverHealPredict` folder into `_classic_beta_/Interface/AddOns/` (or the live Forever client's AddOns folder). Turn off EllesmereUI's own **Heal Prediction** option for raid, party and player frames, or you'll see two sets of bars. The addon warns at login when it's still on.

## Features

Each feature can be set separately for Player, Party and Raid frames.

| Option | Notes |
|---|---|
| Show my heals / Show other players' heals | Each has its own toggle and color. |
| Extend past bar end | Heals can run past the end of the bar, up to a set % of max health. |
| Overheal recolor | Bars change color when health plus all incoming heals goes over max health by the threshold %. The color and on/off toggle are separate for your heals and for others' heals. |
| Order by landing time | Other healers' casts that finish before yours are drawn ahead of your heal. |
| Party and Raid share settings | While on, the Party tab edits the Raid settings. |
| Copy to Player / Party / Raid | Copies every setting on the current tab to another tab. |

Slash commands:

- `/fhp` opens the options.
- `/fhp test` turns fake test bars on or off.
- `/fhp status` prints diagnostics, including how many cast end times were readable.
- `/fhp casts` prints each group cast as it starts, showing whether its end time is plain or secret.
- `/fhp resetstats` clears the cast counters.
- `/fhp rescan` finds frames again.

## Why it differs from HealPredict

Forever uses the 12.x restricted API. The old HealEngine read the combat log and did arithmetic on heal amounts, and neither works here:

- Addons can't use the combat log in restricted content.
- During combat, health and heal values can be **secret**. A secret value can be handed to a status bar for display. It can't be compared, added or branched on.

So this addon only uses Blizzard's `UnitHealPredictionCalculator`, through `UnitGetDetailedHealPrediction`:

- **My / other split.** `GetIncomingHeals()` returns the total, the amount from the player, and the amount from everyone else.
- **Overflow.** The calculator's `SetIncomingHealOverflowPercent(1 + pct)` clamps the amounts. A clipping frame limits how far the bars can draw past the bar end.
- **Overheal threshold.** The same data is checked again with an overflow of `1 + threshold`. The calculator's `clamped` flag (possibly secret) is then turned into a color with `C_CurveUtil.EvaluateColorValueFromBoolean`.
- **Stacking.** Bars are chained by anchors, so the game's layout engine adds the amounts up, not Lua.

### Limits

- **No HoT prediction or per-spell detail.** The client API only reports what Blizzard's prediction covers.
- **Landing order only works while you are casting.** It also needs readable cast end times (`UnitCastingInfo`). In restricted combat those can be secret. When they are, your heals are drawn first, and `/fhp status` counts how often that happened.
- **Healers outside your group are never ordered ahead of you.** Their heals only show up after your heal.

## License

GPL-3.0. See [LICENSE](LICENSE).
