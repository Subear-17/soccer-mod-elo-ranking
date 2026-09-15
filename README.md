# ELO Ranking for Soccer Mod (SoMoE-19)

An add-on SourceMod plugin that adds a full ELO ranking system on top of
[MK99MA's SoMoE-19](https://github.com/MK99MA/SoMoE-19) fork of the CS:S Soccer Mod.
This repo adds a new plugin plus a small set of hooks into soccer_mod's own
files — it does not replace or fork soccer_mod itself.

## Features

- **Ranked 6v6 leaderboard** — real ELO rating, win/loss record, and average
  MVP points per game. Only counts matches that actually qualify: minimum
  roster size (6 per side, 5 tolerated so a mid-match sub doesn't invalidate
  anything) and a configurable minimum match duration.
- **Unranked leaderboard** — built from your soccer_mod's own existing
  lifetime stats (goals, assists, saves, points, etc.), so a server's real
  history isn't lost when installing this — it's just kept as its own
  separate, always-has-existed track next to the clean-slate Ranked one.
- **Player career pages** ("FIFA cards") for both tracks: 5 core attributes
  (Shooting, Passing, Defending, Touches, Win Rate) percentile-ranked against
  the rest of the server, an overall rating, and a prestige tier (Bronze →
  Silver → Gold → World Class → Legend) based on leaderboard rank — so tiers
  stay meaningful no matter how spread out ratings get over time.
- **Automatic join-name history** — every distinct name the server has seen
  a steamid connect with, tracked with timestamps, separate from admin-set
  nicknames.
- **Admin tools** — rename a player's stat display name (with history), or
  manually adjust a player's ELO, both from an in-game menu.
- **ELO-aware cap picking** — the two candidate captains' ELO decides who
  picks first automatically; falls back to the classic knife duel when
  they're close enough (configurable threshold).
- **Halftime rebalance vote** — when the score gap gets too large, proposes
  ELO-balanced player swaps between position-matched players and lets the
  12 people on the pitch vote on it.
- Everything reachable via a single `!elo` chat command — no console
  commands to memorize.

## Requirements

This plugin is built against **SoMoE-19's own `soccer_mod.sp`/`cap.sp`/
`match.sp`/`afkkicker.sp`/`stats.sp`** — it calls into those files directly to
know when a cap match starts/ends and to read live match stats. It will not
do anything useful on a different soccer_mod fork unless you manually add the
same hook calls (see `soccer_mod_patch/` below for exactly what was changed).

- SourceMod 1.11+
- MK99MA's SoMoE-19 soccer_mod

## Installation

1. **Install the plugin itself:**
   - Copy `elo_ranking.sp` into `addons/sourcemod/scripting/`
   - Copy `elo_ranking.inc` into `addons/sourcemod/scripting/include/`
   - Compile `elo_ranking.sp` and drop the resulting `elo_ranking.smx` into
     `addons/sourcemod/plugins/`

2. **Update your soccer_mod install to call into it:**
   - The `soccer_mod_patch/` folder contains complete, ready-to-use versions
     of the 6 SoMoE-19 files this plugin needs: `soccer_mod.sp`, and inside
     `soccer_mod/`: `globals.sp`, `modules/cap.sp`, `modules/match.sp`,
     `modules/afkkicker.sp`, `modules/stats.sp`.
   - **If you haven't customized these files yourself:** just copy them over
     your existing ones and recompile `soccer_mod.sp`.
   - **If you HAVE customized any of these files:** don't overwrite them —
     open a diff between your version and the one in this repo, and manually
     merge in just the ELO-related additions (they're all clearly commented,
     search for "elo_ranking" or "Elo_" in each file).
   - Recompile `soccer_mod.sp` and replace your `soccer_mod.smx`.

3. Restart your server (or reload both plugins). You should see both
   `Soccer Mod - ELO Ranking` and your soccer_mod plugin listed with no
   errors in `sm plugins list`.

4. Type `!elo` in chat to open the menu.

## Configuration (ConVars)

| ConVar | Default | Purpose |
|---|---|---|
| `sm_soccermod_elo_datapath` | *(empty)* | Custom folder for ELO's data files. Leave empty to use `addons/sourcemod/data/elo_ranking/` (works with zero setup). Only set this if you want the data stored somewhere else, e.g. a mount that survives a full server reinstall. |
| `sm_soccermod_elo_tiebreak_pct` | `6.0` | If the two cap-designate captains' ELO differs by less than this percent, fall back to a knife duel instead of auto-picking who goes first. |
| `sm_soccermod_elo_6v6_minmin` | `25.0` | Minimum match length (minutes) for a Ranked 6v6 cap to count toward ELO. Rosters of 5 per side also qualify (covers a team briefly playing a player short mid-match). |

## Notes

- Ranked data always starts clean on a fresh install — it only ever grows
  from real, qualifying matches, regardless of how long your server has been
  running soccer_mod before installing this.
- Unranked data comes straight from your existing `soccer_mod_public_stats`
  table, so it reflects your server's real history from day one.
- This is an early, actively-developed plugin — feedback and issues welcome.

## Credits

This plugin only exists on top of other people's work — full credit for
Soccer Mod itself goes to:

- **[Marco Boogers](https://github.com/marcoboogers/soccermod)** — original
  creator of Soccer Mod for Counter-Strike: Source.
- **[MK99MA](https://github.com/MK99MA/SoMoE-19)** — SoMoE-19, the actively
  maintained edit of Soccer Mod this plugin is built directly against.
  SoMoE-19 itself also incorporates: Duckjump Script (Marco Boogers), Allchat
  / DeadChat (Frenzzy), ShortSprint (walmar), a simple AFK kicker (shavit),
  and Updater (GoD-Tony) — see the [SoMoE-19 README](https://github.com/MK99MA/SoMoE-19#readme)
  for the full list.

The ELO ranking system itself (this repo) was built for and by the "Pons"
CS:S community.
