#if defined _elo_ranking_included
	#endinput
#endif
#define _elo_ranking_included

/**
 * elo_ranking.inc - interface between soccer_mod and the standalone elo_ranking plugin.
 * Natives prefixed Elo_ are implemented by elo_ranking.smx (soccer_mod calls into it).
 * Natives prefixed SoccerMod_ are implemented by soccer_mod.smx (elo_ranking calls into it).
 */

// ---- Elo_* : implemented by elo_ranking.smx ----

native void Elo_OnMatchStart();

native void Elo_OnMatchEnd(bool ctWon, bool tWon);

/**
 * @param scoreCT               matchScoreCT
 * @param scoreT                matchScoreT
 * @param capCTClient           capCT
 * @param capTClient            capT
 * @param capFirstPickCTClient  capFirstPickCT
 * @param capFirstPickTClient   capFirstPickT
 */
native void Elo_CheckHalftimeSwap(int scoreCT, int scoreT, int capCTClient, int capTClient, int capFirstPickCTClient, int capFirstPickTClient);

/**
 * @param matchWasStarted  matchStarted, at the moment of the kick
 */
native void Elo_InvalidateMatch(bool matchWasStarted);

native float Elo_GetCapRating(int client);

native float Elo_GetRating(const char[] steamid, const char[] format);

native void Elo_GetDisplayName(const char[] steamid, const char[] liveName, char[] outName, int outSize);

// ---- SoccerMod_* : implemented by soccer_mod.smx ----

/**
 * Current match's in-memory MVP points for this steamid (from stats.sp's statsKeygroupMatch),
 * 0.0 if the player never registered a stat event this match, or if no match is currently tracked.
 */
native float SoccerMod_GetMatchPoints(const char[] steamid);

/**
 * This player's stat breakdown for the CURRENT in-progress match only (not a lifetime total) -
 * goals, assists, own_goals, saves, passes, interceptions, hits (ball touches - "hits" here means
 * contact with the ball prop, never player-on-player damage), in that exact order. elo_ranking
 * calls this only for matches that actually qualify as Ranked, then keeps its own running lifetime
 * totals in its own data file - deliberately NOT reading soccer_mod's own lifetime SQL stats for
 * the Ranked track, so a fresh install on a server with years of pre-existing soccer_mod history
 * still starts Ranked at a clean slate. Returns false if no match is currently tracked or this
 * steamid never registered a stat event this match.
 */
native bool SoccerMod_GetMatchStatBreakdown(const char[] steamid, int outStats[7]);

/**
 * UNRANKED track only: lifetime totals from soccer_mod's own soccer_mod_public_stats SQL table -
 * every casual round ever played on this install, no gating at all (goals, assists, own_goals,
 * hits, passes, interceptions, ball_losses, saves, rounds_won, rounds_lost, points, mvp, motm - in
 * that exact order). This is the pre-existing history a server already has before installing ELO
 * ranking, shown as "Unranked" so it isn't lost, and kept fully separate from the Ranked track's
 * own clean-slate data above. Returns false if the steamid has no row yet.
 */
native bool SoccerMod_GetPublicStats(const char[] steamid, int outStats[13]);

/**
 * UNRANKED track only: FIFA-card-style attributes (0-99) derived from soccer_mod_public_stats,
 * percentile-ranked against the whole lifetime playerbase. Order: [0]=Shooting, [1]=Passing,
 * [2]=Defending, [3]=Touches. Returns false if this steamid has no soccer_mod_public_stats row.
 */
native bool SoccerMod_GetCardAttributes(const char[] steamid, int outAttrs[4]);

/**
 * UNRANKED track only: top N players by soccer_mod_public_stats.points (the old, ungated lifetime
 * MVP-points column), for the Unranked leaderboard. Caller creates both ArrayLists (String and
 * cell respectively) and passes them in; this fills steamidsOut with steamids and pointsOut with
 * their matching points, both ordered points-descending, and returns how many rows were filled
 * (0 if soccer_mod isn't loaded or the table is empty).
 */
native int SoccerMod_GetTopPlayersByPoints(ArrayList steamidsOut, ArrayList pointsOut, int maxCount);

public SharedPlugin __pl_elo_ranking =
{
	name = "elo_ranking",
	file = "elo_ranking.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_elo_ranking_SetNTVOptional()
{
	MarkNativeAsOptional("Elo_OnMatchStart");
	MarkNativeAsOptional("Elo_OnMatchEnd");
	MarkNativeAsOptional("Elo_CheckHalftimeSwap");
	MarkNativeAsOptional("Elo_InvalidateMatch");
	MarkNativeAsOptional("Elo_GetCapRating");
	MarkNativeAsOptional("Elo_GetRating");
	MarkNativeAsOptional("Elo_GetDisplayName");
}
#endif
