# ELO Ranking for Soccer Mod (SoMoE-19)

A SourceMod plugin that adds a full ELO ranking system on top of
[MK99MA's SoMoE-19](https://github.com/MK99MA/SoMoE-19) fork of the CS:S Soccer Mod.

**Why this exists:** caps (pickup scrims) kept ending up lopsided — one
captain's pick would stack a team and the game was decided before it really
started. This plugin was built to make caps fairer over the length of a
match: captains are picked based on skill instead of chance where possible,
and if a game still gets badly one-sided, the players on the pitch get to
vote on a rebalancing swap at halftime instead of just grinding out a blowout.
The ELO leaderboard and player cards grew out of that — once skill is being
tracked to make picks fairer, it's a small step to also show it.

## ⚠️ Status: untested outside the original server

This has only been verified to *compile* cleanly against stock SoMoE-19 - it
has not yet been run on a live server other than the one it was built for.
Expect rough edges. If something breaks, behaves oddly, or just looks wrong,
please open an issue on this repo (or reach out directly) - bug reports are
very welcome and genuinely useful at this stage.

## How this is built

`soccer_mod_patch/` in this repo is **stock SoMoE-19** (pulled straight from
[MK99MA's GitHub](https://github.com/MK99MA/SoMoE-19)) with a small, clearly
marked set of hooks added — every addition is commented and searchable
(`elo_ranking`, `Elo_`, or `ELO`). It is not a wholesale rewrite and it does
not touch anything unrelated to ELO.

**Fully optional, fully reversible.** `elo_ranking.smx` is never a hard
requirement for soccer_mod — every hook checks whether the plugin is actually
loaded before doing anything. Install it and cap-picking becomes ELO-aware;
remove `elo_ranking.smx` again and soccer_mod falls straight back to normal
behavior (plain knife duel, no rating, no halftime vote) with no errors and
nothing broken. You can toggle it on and off freely.

**If you've customized `soccer_mod.sp`, `globals.sp`, `cap.sp`, `match.sp`,
or `afkkicker.sp` yourself:** don't overwrite them wholesale — you'd lose
your own changes along with anyone else's on top of stock SoMoE-19. Open a
diff against the stock versions instead and merge in just the ELO-marked
lines by hand.

**Always back up your existing `scripting/` folder before replacing
anything**, just in case.

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

- SourceMod 1.11+
- SoMoE-19 soccer_mod

## Installation

**Step 0 — back up first.** Copy your entire
`addons/sourcemod/scripting/soccer_mod.sp` file and `soccer_mod/` folder
somewhere safe before touching anything. If something goes wrong you can
always put your originals back.

**Step 1 — install the ELO plugin itself:**

1. Copy `elo_ranking.sp` into `addons/sourcemod/scripting/`
2. Copy `elo_ranking.inc` into `addons/sourcemod/scripting/include/`
3. Compile `elo_ranking.sp` (using your SourceMod's `spcomp`/`spcomp64`) and
   put the resulting `elo_ranking.smx` into `addons/sourcemod/plugins/`

**Step 2 — bring in the soccer_mod files ELO needs to hook into:**

The `soccer_mod_patch/scripting/` folder in this repo mirrors your server's
own `addons/sourcemod/scripting/` folder. Copy these 5 files over your
existing ones, in the same relative locations:

- `soccer_mod.sp`
- `soccer_mod/globals.sp`
- `soccer_mod/modules/cap.sp`
- `soccer_mod/modules/match.sp`
- `soccer_mod/modules/afkkicker.sp`

Then recompile `soccer_mod.sp` and replace your `soccer_mod.smx` with the
freshly compiled one.

**Step 3 — restart:**

Restart your server (or reload both plugins). Run `sm plugins list` in the
server console — you should see both `Soccer Mod - ELO Ranking` and your
soccer_mod plugin listed with no errors next to either of them.

**Step 4 — use it:**

Type `!elo` in chat to open the menu. That's it.

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
- `soccer_mod_patch/` was built and tested against SoMoE-19's `master` branch.
  If you're on an older tagged release, the surrounding code may have shifted
  slightly - the ELO-marked lines are still the same, just double-check they
  land in a sensible spot when merging by hand.
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

The ELO ranking system itself (this repo) was built for and by the Titans
clan and the soccer CS:S community.
