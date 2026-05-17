# Prism

A floating skill overlay for **FFXI** (Ashita v4). Tracks your combat and magic skills with tier-colored crystals, donuts, or pills — plus effective level and minimum mob level hints so you know what to hunt next.

![Prism crystals](assets/crystals.png)

## Display modes

| Crystals (default) | Donuts | Pills |
|---|---|---|
| ![Crystals](assets/crystals.png) | ![Donuts](assets/donuts.png) | ![Pills](assets/pills.png) |

Tier color encodes rank: **A+ gold**, **B green**, **C cyan**, **D blue**, **E/F grey**.

## Features

- **Three display modes**: tier-colored FFXI crystals (default), OSRS-style donuts, or compact text pills
- **Tier coloring** mirrors FFXI rank tiers — A+ gold, B green, C cyan, D blue, E/F grey
- **Effective level + min-mob hints**: see the lowest mob level that can still skill you up
- **Skillup capture** via packet `0x29` (authoritative tenths) with a chat fallback — your fractional progress survives between integer ticks
- **Sort modes**: Default, By Grade, Progress %, Lowest
- **Per-skill visibility toggles**, capped-skill filter, items-per-row, and a 0.6×–2.0× scale slider
- **Chrome-less overlay** — drag with the settings panel toggle, configure with `/prism`

Skill capture adapted from [Jull256/skilluptracker](https://github.com/Jull256/skilluptracker) (Mujihina original).

## Install

1. Drop the `prism` folder into `Ashita/addons/`
2. In game: `/addon load prism`
3. Open settings: `/prism`

## Commands

```
/prism                              -- open settings panel (also /pr)
/prism on | off | toggle            -- show/hide overlay
/prism mode crystals|donuts|pills   -- display style
/prism perrow 1..24                 -- items per row
/prism capped                       -- toggle showing capped skills
/prism persistfrac on|off|toggle    -- persist fractional skill progress across /logout
/prism show <name>                  -- show a specific skill (e.g. Elemental)
/prism hide <name>                  -- hide a specific skill
/prism reset                        -- reset window position
```

## Settings panel

![Prism settings](assets/settings.png)

Open with `/prism` or `/pr`. All options persist to Ashita's per-character config.

## Notes

- **Magic skills are gated by your main job's rank table** — sub-job magic skills are hidden by design (their caps are halved anyway).
- **Fractional skill (e.g. 9.1) only flows via chat/packet** — the game's memory only exposes integers. Prism saves your fractional progress to Ashita's per-character config (toggle in settings or `/prism persistfrac off`), so a `/logout` doesn't throw away the 0.1–0.9 you already earned.
- Skill caps use rank slopes calibrated against low-level (`L≤9`) reference points; some piecewise interpolation remains.

## Acknowledgments

- **Nerf (nerfonline)** from the Ashita Discord shared the [FFXI Skill Calculator spreadsheet](https://docs.google.com/spreadsheets/d/1VE4as2FWwrD4e_lJ4h1wG6Ga50PAJGzGaWkOGOx0mvE/edit) covering canonical L1–75 skill caps and per-job rank assignments for both Horizon and Retail. Full integration of that data into Prism's cap and rank tables is planned for an upcoming release. Thanks, Nerf.
- Skillup capture pattern (packet `0x29` MessageNum 38/53) adapted from [Jull256/skilluptracker](https://github.com/Jull256/skilluptracker) (Mujihina).

## License

GPL-3.0 — see [LICENSE](LICENSE).
