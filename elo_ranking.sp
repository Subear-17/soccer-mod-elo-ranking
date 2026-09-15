#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <morecolors>

// <sourcemod> itself unconditionally #defines REQUIRE_EXTENSIONS (see core.inc) as the default
// for anything included afterward - so without this #undef, SteamWorks.inc's own SharedPlugin-
// style Extension marker would compile with required=1, making the WHOLE plugin refuse to load
// the instant the SteamWorks extension isn't installed, regardless of MarkNativeAsOptional calls
// on the individual natives (that only prevents a native-binding failure, it doesn't override
// this separate, stronger extension-level requirement flag).
#undef REQUIRE_EXTENSIONS
#include <SteamWorks>

#include "elo_ranking.inc"

public Plugin myinfo =
{
	name        = "Soccer Mod - ELO Ranking",
	author      = "Morten (Pons) - split from soccer_mod into a standalone plugin",
	description = "Outcome-based ELO ranking (2v2/3v3/6v6) for soccer_mod caps, with an MVP-performance modifier. Requires soccer_mod.",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/MK99MA/SoMoE-19"
};

// ************************************************************************************************************
// ****************************************** SOCCER MOD - ELO RATING ******************************************
// ************************************************************************************************************
// Outcome-based rating system (win/loss only, never per-stat), designed 2026-09 with the community after
// years of unbalanced caps. Data path is configurable via sm_soccermod_elo_datapath - see
// RefreshEloDataPaths() below - so it can optionally live outside the game server's own volume
// (e.g. a separate mount) to survive server reinstalls/migrations. Keyed by SteamID64, never by
// display name.
//
// Three independent rating pools: "2v2", "3v3", "6v6". A match only counts if it meets format-specific
// minimums (roster size + duration) and wasn't AFK-kick-invalidated.
//
// Split into its own plugin (2026-09) so it can be distributed/tested independently of the rest of
// soccer_mod. Talks to soccer_mod purely through elo_ranking.inc's natives/forwards - see that file for
// the full interface. Chat prefix/colors and the cap-positions file path are duplicated here as static
// literals (soccer_mod never changes these at runtime, so this is a one-time contract, not live state).

// Data file location is configurable (sm_soccermod_elo_datapath) so this works out of the box on
// ANY server with zero setup by default (addons/sourcemod/data/elo_ranking/), while still letting
// a specific install point at a custom path (e.g. a separate Pterodactyl mount) to survive full
// server reinstalls - see RefreshEloDataPaths(). g_EloFile/g_EloLogFile are resolved at runtime,
// not compile-time constants, precisely so this is a per-server config choice, not a hardcoded path.
char g_EloDataDir[PLATFORM_MAX_PATH];
char g_EloFile[PLATFORM_MAX_PATH];
char g_EloLogFile[PLATFORM_MAX_PATH];
ConVar cv_EloDataPath;

#define ELO_DEFAULT_RATING  1500.0
#define ELO_K_FACTOR        32.0
// Accounts allowed to manually adjust ratings via the admin menu - Subi (owner), plus psycho' and
// Fragz added 2026-09-15 on Morten's request.
#define ELO_OWNER_COUNT 3
char eloOwnerSteamids[ELO_OWNER_COUNT][32] = { "[U:1:39480114]", "[U:1:98554807]", "[U:1:361486683]" };

// Mirrors soccer_mod's globals.sp - static literals that never change at runtime, so duplicating them
// here (rather than a native round-trip on every single chat line) is safe and avoids unnecessary coupling.
char prefix[32]       = "Soccer Mod";
char prefixcolor[32]  = "green";
char textcolor[32]    = "lightgreen";
char pathCapPositionsFile[PLATFORM_MAX_PATH] = "cfg/sm_soccermod/soccer_mod_cap_positions.txt";

char eloAdjustTargetSteamid[32];
char eloAdjustTargetName[MAX_NAME_LENGTH];
float eloAdjustTargetCurrentRating;
char eloRenameTargetSteamid[32];
char eloRenameTargetName[MAX_NAME_LENGTH];
bool eloAwaitingRenameInput[MAXPLAYERS+1];
char eloDetailViewSteamid[MAXPLAYERS+1][32];
bool eloDetailViewRanked[MAXPLAYERS+1]; // which track's card this client's detail page is showing

char eloFormat6v6[] = "6v6"; // Ranked's single rating pool - covers both 5v5 and 6v6 rosters

// current-match tracking, snapshotted at MatchStart(), consumed at match end
bool  eloMatchValid;                 // false = AFK-kicked or otherwise disqualified, never rate this match
float eloMatchStartTime;
char  eloRosterCT[6][32];
char  eloRosterT[6][32];
int   eloRosterCTCount;
int   eloRosterTCount;
char  eloMatchFormat[8];

// halftime swap-vote state
#define ELO_SWAP_GAP_TRIGGER  5
#define ELO_SWAP_VOTE_SECONDS 20
bool   eloSwapVoteActive;
int    eloSwapNumOptions;                  // how many real swap options are in play (0-3), index [eloSwapNumOptions] is always "keep"
int    eloSwapCandidateA[3];               // client on the currently-winning side, per option
int    eloSwapCandidateB[3];               // client on the currently-losing side, per option
int    eloSwapVoteCounts[4];               // index 3 = "keep teams as they are"
bool   eloSwapVoteVoted[MAXPLAYERS+1];
Menu   eloSwapMenu;

// cvar-backed
ConVar cv_EloCapTiebreakPct;
ConVar cv_Elo6v6MinMinutes;
ConVar cv_EloSteamApiKey;

// Steam Web API name lookup (optional - only runs at all if sm_soccermod_elo_steamapikey is set).
// The ONLY way a historic player (someone in soccer_mod's old stats who hasn't reconnected since
// this plugin was installed) ever gets a real name instead of a raw SteamID - see EloGetDisplayName,
// EloQueueSteamApiLookup, Timer_EloProcessApiQueue. Queued rather than looked up synchronously
// because HTTP is inherently async and EloGetDisplayName is called on every single leaderboard row
// render, so it must stay cheap.
ArrayList g_EloApiQueue;
#define ELO_API_BATCH_MAX 100 // Steam Web API's own documented limit for GetPlayerSummaries

// ****************************************************************************************************
// ******************************************** INIT / CVARS ********************************************
// ****************************************************************************************************
// MarkNativeAsOptional() only has an effect when called here - native binding happens between
// AskPluginLoad2 and OnPluginStart, so calling it from OnPluginStart (as a first attempt did) is
// too late and the plugin still hard-fails to load if the native isn't there yet.
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// SoccerMod_GetMatchPoints is provided by soccer_mod, but elo_ranking must not hard-fail to
	// load without it (that would break the whole point of testing this plugin standalone on
	// another server) - marked optional here, with a graceful 0.0 fallback in EloGetMatchPoints.
	MarkNativeAsOptional("SoccerMod_GetMatchPoints");
	MarkNativeAsOptional("SoccerMod_GetPublicStats");
	MarkNativeAsOptional("SoccerMod_GetCardAttributes");
	MarkNativeAsOptional("SoccerMod_GetMatchStatBreakdown");
	MarkNativeAsOptional("SoccerMod_GetTopPlayersByPoints");

	// SteamWorks.inc's own SharedPlugin marker only sets required=0 (not a hard extension
	// dependency) - but each individual native it declares is still implicitly REQUIRED unless
	// explicitly marked optional too, same rule as everything else on this page. Without this,
	// the whole plugin refuses to load ("Required extension SteamWorks... not running") the
	// moment the SteamWorks extension isn't installed - defeating the entire point of this being
	// an optional feature. Only marking the handful this plugin actually calls.
	MarkNativeAsOptional("SteamWorks_CreateHTTPRequest");
	MarkNativeAsOptional("SteamWorks_SetHTTPCallbacks");
	MarkNativeAsOptional("SteamWorks_SetHTTPRequestContextValue");
	MarkNativeAsOptional("SteamWorks_SendHTTPRequest");
	MarkNativeAsOptional("SteamWorks_GetHTTPResponseBodySize");
	MarkNativeAsOptional("SteamWorks_GetHTTPResponseBodyData");
	return APLRes_Success;
}

public void OnPluginStart()
{
	cv_EloCapTiebreakPct = CreateConVar("sm_soccermod_elo_tiebreak_pct", "6.0",
		"If the two cap-designate captains' ELO differs by less than this percent, fall back to the knife duel instead of auto-assigning first pick.");
	cv_Elo6v6MinMinutes = CreateConVar("sm_soccermod_elo_6v6_minmin", "25.0", "Minimum match length (minutes) for a Ranked 6v6 cap to count toward ELO.");
	cv_EloDataPath = CreateConVar("sm_soccermod_elo_datapath", "",
		"Custom absolute directory for ELO's data files. Leave empty (default) to use addons/sourcemod/data/elo_ranking/ - works out of the box on any server with zero setup. Only set this if you specifically want the data stored somewhere else (e.g. a separate mount that survives full server reinstalls).");
	cv_EloDataPath.AddChangeHook(OnEloDataPathChanged);

	cv_EloSteamApiKey = CreateConVar("sm_soccermod_elo_steamapikey", "",
		"Optional free Steam Web API key (get one at https://steamcommunity.com/dev/apikey). When set, ELO ranking automatically looks up real Steam names for historic players who haven't reconnected since this plugin was installed, instead of showing a raw SteamID on the leaderboards. Leave empty to disable - everything else works exactly the same either way. Requires the SteamWorks extension.",
		FCVAR_PROTECTED);

	g_EloApiQueue = new ArrayList(ByteCountToCells(32));
	CreateTimer(5.0, Timer_EloProcessApiQueue, _, TIMER_REPEAT);

	// DANGEROUS BUG FIXED HERE (2026-09-10, take 2): both FileExists() AND a plain OpenFile(...,"r")
	// probe false-negative on this absolute path specifically when called this early in plugin
	// startup (before the engine's filesystem search paths are fully set up for the map) - even
	// though the exact same calls work fine later during normal gameplay. Confirmed: this WIPED
	// real player data on two separate restarts. There is no need to pre-create the file at all -
	// every read function here already degrades gracefully when ImportFromFile hits a missing/
	// empty file (just an empty KeyValues tree), and every write function creates it on demand via
	// ExportToFile. So: don't touch the file at plugin start, full stop.

	RegAdminCmd("sm_renamestat", Cmd_EloRenameStat, ADMFLAG_GENERIC,
		"sm_renamestat <steamid> <new name> - sets a player's displayed stats/ELO name, with history");

	AddCommandListener(EloSayHook, "say");
	AddCommandListener(EloSayHook, "say_team");

	RegAdminCmd("sm_elolog", Cmd_EloLog, ADMFLAG_GENERIC,
		"sm_elolog [count] - Subi only, prints the last N ELO log entries to console (default 20)");

	CreateNative("Elo_OnMatchStart", Native_Elo_OnMatchStart);
	CreateNative("Elo_OnMatchEnd", Native_Elo_OnMatchEnd);
	CreateNative("Elo_CheckHalftimeSwap", Native_Elo_CheckHalftimeSwap);
	CreateNative("Elo_InvalidateMatch", Native_Elo_InvalidateMatch);
	CreateNative("Elo_GetCapRating", Native_Elo_GetCapRating);
	CreateNative("Elo_GetRating", Native_Elo_GetRating);
	CreateNative("Elo_GetDisplayName", Native_Elo_GetDisplayName);
	RegPluginLibrary("elo_ranking");

	RegConsoleCmd("sm_elo", Cmd_Elo, "Opens the ELO ranking menu (chat trigger: !elo)");

	// Loud and immediate, not just documented in the README - so an installer sees this the
	// moment they load the plugin, in the same server console they're already watching for
	// startup errors, rather than only discovering it later as an unexplained "why no names?"
	// support question.
	CreateTimer(3.0, Timer_EloWarnMissingApiKey);
}

public Action Timer_EloWarnMissingApiKey(Handle timer)
{
	char apiKey[64];
	cv_EloSteamApiKey.GetString(apiKey, sizeof(apiKey));
	if (apiKey[0] == '\0')
	{
		LogMessage("[elo_ranking] sm_soccermod_elo_steamapikey is not set - historic players will show raw SteamIDs on the leaderboards instead of real names. This is optional; see the README for how to get a free key.");
	}
	return Plugin_Stop;
}

public Action Cmd_Elo(int client, int args)
{
	OpenEloMainMenu(client);
	return Plugin_Handled;
}

// Own top-level menu (typing "!elo" in chat, via SM's standard chat-trigger-to-sm_ command
// mapping) - no longer nested inside soccer_mod's Statistics menu, per Morten's request 2026-09-15.
public void OpenEloMainMenu(int client)
{
	Menu menu = new Menu(EloMainMenuHandler);
	menu.SetTitle("Subi's ELO Ranking Plugin\n(test plugin - currently records data per-server only)");

	menu.AddItem("leaderboard", "Ranked Leaderboard (6v6)");
	menu.AddItem("unrankedleaderboard", "Unranked Leaderboard (casual/all-time)");

	if (CheckCommandAccess(client, "generic_admin", ADMFLAG_GENERIC))
	{
		menu.AddItem("adminrename", "Admin: Rename a player's stat name");
	}
	if (IsEloOwner(client))
	{
		menu.AddItem("adminelo", "Admin: Adjust a player's ELO");
	}

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int EloMainMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char menuItem[32];
		menu.GetItem(choice, menuItem, sizeof(menuItem));

		if (StrEqual(menuItem, "leaderboard"))                CreateTimer(0.1, Timer_OpenEloLeaderboardMenu, GetClientUserId(client));
		else if (StrEqual(menuItem, "unrankedleaderboard"))   CreateTimer(0.1, Timer_OpenEloUnrankedLeaderboardMenu, GetClientUserId(client));
		else if (StrEqual(menuItem, "adminrename"))           CreateTimer(0.1, Timer_OpenEloRenameTargetMenu, GetClientUserId(client));
		else if (StrEqual(menuItem, "adminelo"))              CreateTimer(0.1, Timer_OpenEloAdjustTargetMenu, GetClientUserId(client));
	}
	else if (action == MenuAction_End) delete menu;
	return 0;
}

public Action Timer_OpenEloUnrankedLeaderboardMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client)) OpenEloUnrankedLeaderboardMenu(client);
	return Plugin_Stop;
}

public void OnClientPutInServer(int client)
{
	if (!IsFakeClient(client))
	{
		char steamid[32], liveName[MAX_NAME_LENGTH];
		GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
		GetClientName(client, liveName, sizeof(liveName));
		EloEnsurePlayerRecorded(steamid);
		EloRecordJoinName(steamid, liveName);
	}
	CreateTimer(8.0, EloTimer_CheckPositions, GetClientUserId(client));
}

// Deferred to OnConfigsExecuted rather than OnPluginStart, same caution as the file-timing bug
// documented above: filesystem probes (DirExists here) this early in plugin startup can give
// false negatives before the engine's own filesystem search paths are fully set up.
public void OnConfigsExecuted()
{
	RefreshEloDataPaths();
}

public void OnEloDataPathChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	RefreshEloDataPaths();
}

// Resolves g_EloFile/g_EloLogFile from sm_soccermod_elo_datapath. Empty (the default) resolves to
// addons/sourcemod/data/elo_ranking/ - always writable, no server-specific setup required, so a
// fresh GitHub download works immediately on any soccer_mod server. Set the cvar to point
// somewhere else only if you specifically want the data stored outside the normal SM data folder
// (e.g. a separate mount that survives a full server reinstall).
void RefreshEloDataPaths()
{
	char custom[PLATFORM_MAX_PATH];
	cv_EloDataPath.GetString(custom, sizeof(custom));

	if (custom[0] != '\0') strcopy(g_EloDataDir, sizeof(g_EloDataDir), custom);
	else BuildPath(Path_SM, g_EloDataDir, sizeof(g_EloDataDir), "data/elo_ranking");

	if (!DirExists(g_EloDataDir)) CreateDirectory(g_EloDataDir, 511);

	Format(g_EloFile, sizeof(g_EloFile), "%s/soccer_mod_elo.kv", g_EloDataDir);
	Format(g_EloLogFile, sizeof(g_EloLogFile), "%s/soccer_mod_elo_log.txt", g_EloDataDir);
}

// Auto-tracked history of every distinct Steam display name the server has ever seen this
// steamid connect with (separate from the admin-set "displayname" nickname/rename-history system
// below) - only writes a new entry when the name actually changed since last join, so someone
// reconnecting repeatedly with the same name doesn't spam the list.
void EloRecordJoinName(const char[] steamid, const char[] liveName)
{
	if (liveName[0] == '\0') return;

	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);

	char lastName[MAX_NAME_LENGTH];
	kv.GetString("lastjoinname", lastName, sizeof(lastName), "");
	if (StrEqual(lastName, liveName))
	{
		delete kv;
		return;
	}

	char timeString[32];
	FormatTime(timeString, sizeof(timeString), "%Y-%m-%d %H:%M:%S");
	kv.JumpToKey("joinnames", true);
	kv.JumpToKey(timeString, true);
	kv.SetString("name", liveName);
	kv.GoBack();
	kv.GoBack();

	kv.SetString("lastjoinname", liveName);
	kv.Rewind();
	kv.ExportToFile(g_EloFile);
	delete kv;
}

public void EloShowJoinNameHistory(int client, const char[] steamid)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);

	if (!kv.JumpToKey("joinnames", false))
	{
		CPrintToChat(client, "{%s}[%s] {%s}No join-name history recorded for this player yet.", prefixcolor, prefix, textcolor);
		delete kv;
		return;
	}

	if (kv.GotoFirstSubKey())
	{
		do
		{
			char timeString[32], name[MAX_NAME_LENGTH];
			kv.GetSectionName(timeString, sizeof(timeString));
			kv.GetString("name", name, sizeof(name), "?");
			CPrintToChat(client, "{%s}[%s] {%s}%s: joined as \"%s\"", prefixcolor, prefix, textcolor, timeString, name);
		}
		while (kv.GotoNextKey());
	}
	delete kv;
}

// ****************************************************************************************************
// ******************************************** NATIVE EXPORTS ********************************************
// ****************************************************************************************************
public any Native_Elo_OnMatchStart(Handle plugin, int numParams)
{
	EloOnMatchStart();
	return 0;
}

public any Native_Elo_OnMatchEnd(Handle plugin, int numParams)
{
	EloOnMatchEnd(GetNativeCell(1) != 0, GetNativeCell(2) != 0);
	return 0;
}

public any Native_Elo_CheckHalftimeSwap(Handle plugin, int numParams)
{
	EloCheckHalftimeSwap(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), GetNativeCell(4), GetNativeCell(5), GetNativeCell(6));
	return 0;
}

public any Native_Elo_InvalidateMatch(Handle plugin, int numParams)
{
	EloInvalidateMatch(GetNativeCell(1) != 0);
	return 0;
}

public any Native_Elo_GetCapRating(Handle plugin, int numParams)
{
	return EloGetCapRating(GetNativeCell(1));
}

public any Native_Elo_GetRating(Handle plugin, int numParams)
{
	char steamid[32], format[8];
	GetNativeString(1, steamid, sizeof(steamid));
	GetNativeString(2, format, sizeof(format));
	return EloGetRating(steamid, format);
}

public any Native_Elo_GetDisplayName(Handle plugin, int numParams)
{
	char steamid[32], liveName[MAX_NAME_LENGTH], outName[MAX_NAME_LENGTH];
	GetNativeString(1, steamid, sizeof(steamid));
	GetNativeString(2, liveName, sizeof(liveName));
	EloGetDisplayName(steamid, liveName, outName, sizeof(outName));
	SetNativeString(3, outName, GetNativeCell(4));
	return 0;
}

// ****************************************************************************************************
// ******************************************** COMMANDS ********************************************
// ****************************************************************************************************
public Action Cmd_EloLog(int client, int args)
{
	if (!IsEloOwner(client))
	{
		ReplyToCommand(client, "You don't have access to the ELO log.");
		return Plugin_Handled;
	}

	int count = 20;
	if (args >= 1)
	{
		char arg1[8];
		GetCmdArg(1, arg1, sizeof(arg1));
		count = StringToInt(arg1);
		if (count <= 0) count = 20;
	}

	if (!FileExists(g_EloLogFile))
	{
		ReplyToCommand(client, "No ELO log entries yet.");
		return Plugin_Handled;
	}

	// Read the whole file into an array, then print only the last `count` lines - simplest way
	// to get "tail -N" behaviour without random-access file reading support.
	File f = OpenFile(g_EloLogFile, "r");
	ArrayList lines = new ArrayList(ByteCountToCells(256));
	char buffer[256];
	while (!f.EndOfFile() && f.ReadLine(buffer, sizeof(buffer)))
	{
		lines.PushString(buffer);
	}
	delete f;

	int total = lines.Length;
	int start = (total > count) ? (total - count) : 0;

	ReplyToCommand(client, "---- ELO log (last %i of %i entries) ----", total - start, total);
	for (int i = start; i < total; i++)
	{
		lines.GetString(i, buffer, sizeof(buffer));
		ReplyToCommand(client, "%s", buffer);
	}
	delete lines;
	return Plugin_Handled;
}

public Action Cmd_EloRenameStat(int client, int args)
{
	if (args < 2)
	{
		CPrintToChat(client, "{%s}[%s] {%s}Usage: sm_renamestat <steamid> <new name>", prefixcolor, prefix, textcolor);
		return Plugin_Handled;
	}

	char steamid[32], newName[MAX_NAME_LENGTH];
	GetCmdArg(1, steamid, sizeof(steamid));

	// remaining args joined as the new name
	char buffer[MAX_NAME_LENGTH];
	newName[0] = '\0';
	for (int i = 2; i <= args; i++)
	{
		GetCmdArg(i, buffer, sizeof(buffer));
		if (i > 2) StrCat(newName, sizeof(newName), " ");
		StrCat(newName, sizeof(newName), buffer);
	}

	EloSetDisplayName(steamid, newName, client);
	CPrintToChat(client, "{%s}[%s] {%s}Updated stats display name for %s -> %s", prefixcolor, prefix, textcolor, steamid, newName);
	return Plugin_Handled;
}

void EloCreateFile()
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ExportToFile(g_EloFile);
	delete kv;
}

// Human-readable append-only audit log (plain text, separate from the ratings KV) - covers both
// automatic match-result updates and manual admin adjustments/renames, so progress and any admin
// action can be reviewed later without needing to be watching chat at the time.
void EloLogChange(const char[] steamid, const char[] playerName, const char[] eventType, const char[] detail)
{
	char timeString[32];
	FormatTime(timeString, sizeof(timeString), "%Y-%m-%d %H:%M:%S");

	char line[256];
	Format(line, sizeof(line), "[%s] %s (%s) - %s: %s", timeString, playerName, steamid, eventType, detail);

	File f = OpenFile(g_EloLogFile, "a");
	if (f != null)
	{
		f.WriteLine(line);
		delete f;
	}
}

void EloLogRatingChange(const char[] steamid, const char[] format, float oldRating, float newRating, const char[] eventType)
{
	char liveName[MAX_NAME_LENGTH], playerName[MAX_NAME_LENGTH];
	int target = -1;
	for (int player = 1; player <= MaxClients; player++)
	{
		if (!IsClientInGame(player) || IsFakeClient(player)) continue;
		char sid[32];
		GetClientAuthId(player, AuthId_Engine, sid, sizeof(sid));
		if (StrEqual(sid, steamid)) { target = player; break; }
	}
	if (target != -1)
	{
		GetClientName(target, liveName, sizeof(liveName));
		EloGetDisplayName(steamid, liveName, playerName, sizeof(playerName));
	}
	else strcopy(playerName, sizeof(playerName), steamid);

	char detail[128];
	Format(detail, sizeof(detail), "%s %.0f -> %.0f (%+.0f)", format, oldRating, newRating, newRating - oldRating);
	EloLogChange(steamid, playerName, eventType, detail);
}

// ****************************************************************************************************
// ******************************************** READ / WRITE ********************************************
// ****************************************************************************************************
// Ensures a steamid's node + the three format subkeys exist, jumps kv into the steamid node. Caller must delete kv.
KeyValues EloOpenPlayer(const char[] steamid)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);

	// IMPORTANT: JumpToKey(key, false) still moves position INTO the key when it's found (the
	// "create" flag only governs what happens if it's NOT found) - so GoBack() must run in BOTH
	// branches, or position silently drifts one level deeper on every call for an existing key.
	// (This is exactly what corrupted live player data: 3v3 ended up nested inside 2v2, 6v6 nested
	// inside that, after just a couple of calls for the same player.)
	// Note: 2v2/3v3 pools are no longer created for new players (Ranked is 5v5/6v6 only, per
	// Morten's request 2026-09-15) - any existing 2v2/3v3 data from before that change is left
	// untouched on disk, just never read or added to going forward.
	if (kv.JumpToKey(eloFormat6v6, false))
	{
		kv.GoBack();
	}
	else
	{
		kv.JumpToKey(eloFormat6v6, true);
		kv.SetFloat("rating", ELO_DEFAULT_RATING);
		kv.SetNum("games", 0);
		kv.GoBack();
	}
	return kv;
}

float EloGetRating(const char[] steamid, const char[] format)
{
	KeyValues kv = EloOpenPlayer(steamid);
	kv.JumpToKey(format, false);
	float rating = kv.GetFloat("rating", ELO_DEFAULT_RATING);
	delete kv;
	return rating;
}

int EloGetGames(const char[] steamid, const char[] format)
{
	KeyValues kv = EloOpenPlayer(steamid);
	kv.JumpToKey(format, false);
	int games = kv.GetNum("games", 0);
	delete kv;
	return games;
}

void EloSetRating(const char[] steamid, const char[] format, float newRating, int newGames)
{
	KeyValues kv = EloOpenPlayer(steamid);
	kv.JumpToKey(format, false);
	kv.SetFloat("rating", newRating);
	kv.SetNum("games", newGames);
	kv.GoBack();
	kv.Rewind();
	kv.ExportToFile(g_EloFile);
	delete kv;
}

// Convenience for cap.sp - captains are compared on 6v6 rating specifically.
float EloGetCapRating(int client)
{
	char steamid[32];
	GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
	return EloGetRating(steamid, eloFormat6v6);
}

// This player's 1-indexed rank on the 6v6 leaderboard (1 = highest rated), used for the card's
// prestige tier - rank-based rather than a fixed rating threshold so the tiers stay meaningful no
// matter how spread out ratings get over time (top-3 is always top-3, per Morten's request).
int EloGetRank6v6(const char[] targetSteamid)
{
	float myRating = ELO_DEFAULT_RATING;
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(targetSteamid, true);
	if (kv.JumpToKey(eloFormat6v6, false))
	{
		myRating = kv.GetFloat("rating", ELO_DEFAULT_RATING);
		kv.GoBack();
	}
	kv.Rewind();

	int higherCount = 0;
	if (kv.GotoFirstSubKey())
	{
		do
		{
			char sid[32];
			kv.GetSectionName(sid, sizeof(sid));
			if (sid[0] != '[') continue;
			if (StrEqual(sid, targetSteamid)) continue;

			if (kv.JumpToKey(eloFormat6v6, false))
			{
				float r = kv.GetFloat("rating", ELO_DEFAULT_RATING);
				if (r > myRating) higherCount++;
				kv.GoBack();
			}
		}
		while (kv.GotoNextKey());
	}
	delete kv;
	return higherCount + 1;
}

// **************************************************************************************************************
// ******************************************** DISPLAY NAME OVERRIDE ********************************************
// **************************************************************************************************************
// Admin-settable nickname (independent of live Steam name), with history. Used everywhere a player's
// name shows up next to their ELO. Shown as "(Nickname) LiveSteamName" so admins can always see who's
// who - falls back to just liveName if no nickname was ever set.
void EloGetDisplayName(const char[] steamid, const char[] liveName, char[] outName, int outSize)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);
	char nickname[MAX_NAME_LENGTH];
	kv.GetString("displayname", nickname, sizeof(nickname), "");
	char apiName[MAX_NAME_LENGTH];
	kv.GetString("apiname", apiName, sizeof(apiName), "");
	bool apiChecked = (kv.GetNum("apinamechecked", 0) != 0);
	delete kv;

	// Pass "" for liveName when the player isn't currently connected and no live name could be
	// looked up - showing "(Nickname) [U:1:xxxx]" in that case was exactly the clutter Morten
	// flagged, so an empty/missing live name (or one identical to the nickname) just shows the
	// nickname alone; the raw steamid is now only ever a true last resort with nothing else to
	// go on, never mixed in alongside a nickname.
	bool haveRealLiveName = (liveName[0] != '\0');

	if (nickname[0] != '\0' && haveRealLiveName && !StrEqual(nickname, liveName))
		Format(outName, outSize, "(%s) %s", nickname, liveName);
	else if (nickname[0] != '\0')
		strcopy(outName, outSize, nickname);
	else if (haveRealLiveName)
		strcopy(outName, outSize, liveName);
	else if (apiName[0] != '\0')
		strcopy(outName, outSize, apiName);
	else
	{
		strcopy(outName, outSize, steamid);
		// Last resort: nothing else identifies this player at all, and we haven't tried the
		// Steam Web API yet for them - queue it (async, see Timer_EloProcessApiQueue) so the
		// NEXT time this menu is opened, a real name is there instead. No-op if no API key is
		// configured.
		if (!apiChecked) EloQueueSteamApiLookup(steamid);
	}
}

void EloQueueSteamApiLookup(const char[] steamid)
{
	char apiKey[64];
	cv_EloSteamApiKey.GetString(apiKey, sizeof(apiKey));
	if (apiKey[0] == '\0') return; // feature is off unless a key is configured

	if (g_EloApiQueue.FindString(steamid) != -1) return; // already queued, don't duplicate
	if (g_EloApiQueue.Length >= 500) return; // sane upper bound, never grows unbounded

	g_EloApiQueue.PushString(steamid);
}

// Converts a Steam3 ID ("[U:1:XXXXXXXXX]", the format GetClientAuthId(..., AuthId_Engine, ...)
// returns and the format every steamid is keyed by throughout this file) into a SteamID64 decimal
// string, via schoolbook decimal addition of the account ID onto the fixed universe/type/instance
// base - needed because a SteamID64 (up to ~7.6*10^16) doesn't fit in Pawn's 32-bit cells or in a
// double without losing precision, so this can't just be done with normal integer/float math.
void EloSteamID3ToID64(const char[] steamid3, char[] outId64, int outSize)
{
	outId64[0] = '\0';

	int colonPos = FindCharInString(steamid3, ':', true);
	int bracketPos = FindCharInString(steamid3, ']', true);
	if (colonPos == -1 || bracketPos == -1 || bracketPos <= colonPos) return;

	int accLen = bracketPos - colonPos - 1;
	if (accLen <= 0 || accLen >= 16) return;

	char accountIdStr[16];
	strcopy(accountIdStr, accLen + 1, steamid3[colonPos + 1]);

	char base[24];
	strcopy(base, sizeof(base), "76561197960265728");
	int baseLen = strlen(base);
	int addLen = strlen(accountIdStr);
	int maxLen = (baseLen > addLen) ? baseLen : addLen;

	char result[24];
	int carry = 0;
	for (int i = 0; i < maxLen; i++)
	{
		int baseDigit = (i < baseLen) ? (base[baseLen - 1 - i] - '0') : 0;
		int addDigit  = (i < addLen)  ? (accountIdStr[addLen - 1 - i] - '0') : 0;
		int sum = baseDigit + addDigit + carry;
		carry = sum / 10;
		result[maxLen - 1 - i] = '0' + (sum % 10);
	}

	if (carry > 0)
	{
		// Never actually happens with real Steam account IDs (nowhere near large enough to
		// overflow the 17-digit base), but handled for correctness.
		for (int i = maxLen; i > 0; i--) result[i] = result[i - 1];
		result[0] = '0' + carry;
		result[maxLen + 1] = '\0';
	}
	else
	{
		result[maxLen] = '\0';
	}

	strcopy(outId64, outSize, result);
}

// Batches up to ELO_API_BATCH_MAX queued lookups into a single Steam Web API call every 5 seconds
// (a fixed poll instead of firing one request per queued player, to stay well under Steam's own
// rate limits regardless of how many unknown historic players a fresh install has). Requests
// format=vdf so the response is plain KeyValues text - SourceMod can parse that natively with no
// JSON library dependency.
public Action Timer_EloProcessApiQueue(Handle timer)
{
	if (g_EloApiQueue.Length == 0) return Plugin_Continue;

	char apiKey[64];
	cv_EloSteamApiKey.GetString(apiKey, sizeof(apiKey));
	if (apiKey[0] == '\0')
	{
		g_EloApiQueue.Clear();
		return Plugin_Continue;
	}

	if (GetFeatureStatus(FeatureType_Native, "SteamWorks_CreateHTTPRequest") != FeatureStatus_Available)
	{
		g_EloApiQueue.Clear();
		return Plugin_Continue;
	}

	ArrayList batch = new ArrayList(ByteCountToCells(32));
	char idList[4096];
	idList[0] = '\0';

	while (g_EloApiQueue.Length > 0 && batch.Length < ELO_API_BATCH_MAX)
	{
		char steamid3[32];
		g_EloApiQueue.GetString(0, steamid3, sizeof(steamid3));
		g_EloApiQueue.Erase(0);

		char id64[24];
		EloSteamID3ToID64(steamid3, id64, sizeof(id64));
		if (id64[0] == '\0') continue;

		if (batch.Length > 0) StrCat(idList, sizeof(idList), ",");
		StrCat(idList, sizeof(idList), id64);
		batch.PushString(steamid3);
	}

	if (batch.Length == 0)
	{
		delete batch;
		return Plugin_Continue;
	}

	char url[4400];
	Format(url, sizeof(url), "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key=%s&format=vdf&steamids=%s", apiKey, idList);

	Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (req == INVALID_HANDLE)
	{
		delete batch;
		return Plugin_Continue;
	}

	SteamWorks_SetHTTPCallbacks(req, EloHttp_OnPlayerSummaries);
	SteamWorks_SetHTTPRequestContextValue(req, view_as<int>(batch));
	SteamWorks_SendHTTPRequest(req);

	return Plugin_Continue;
}

public int EloHttp_OnPlayerSummaries(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, any data)
{
	ArrayList batch = view_as<ArrayList>(data);

	// Mark every steamid in this batch as checked (with no name yet) FIRST, so a permanently
	// failing lookup (bad key, deleted account, transient error) never gets silently re-queued
	// forever - a successful match below just overwrites this with the real name.
	for (int i = 0; i < batch.Length; i++)
	{
		char steamid3[32];
		batch.GetString(i, steamid3, sizeof(steamid3));
		EloStoreApiLookupResult(steamid3, "");
	}

	if (!failure && requestSuccessful && statusCode == k_EHTTPStatusCode200OK)
	{
		int bodySize;
		SteamWorks_GetHTTPResponseBodySize(request, bodySize);
		if (bodySize > 0)
		{
			char[] body = new char[bodySize + 1];
			SteamWorks_GetHTTPResponseBodyData(request, body, bodySize + 1);

			KeyValues kv = new KeyValues("response");
			if (kv.ImportFromString(body) && kv.JumpToKey("players") && kv.GotoFirstSubKey())
			{
				do
				{
					char steamid64[24], personaName[MAX_NAME_LENGTH];
					kv.GetString("steamid", steamid64, sizeof(steamid64), "");
					kv.GetString("personaname", personaName, sizeof(personaName), "");
					if (steamid64[0] == '\0' || personaName[0] == '\0') continue;

					for (int i = 0; i < batch.Length; i++)
					{
						char steamid3[32], candidateId64[24];
						batch.GetString(i, steamid3, sizeof(steamid3));
						EloSteamID3ToID64(steamid3, candidateId64, sizeof(candidateId64));
						if (StrEqual(candidateId64, steamid64))
						{
							EloStoreApiLookupResult(steamid3, personaName);
							break;
						}
					}
				}
				while (kv.GotoNextKey());
			}
			delete kv;
		}
	}

	delete batch;
	delete request;
	return 0;
}

// Makes the "raw SteamID instead of a name" state impossible to miss, instead of silently
// showing nothing - this note appears directly on both leaderboard menus (where an installer
// will actually be looking) whenever the feature is off because no key is configured, so nobody
// has to guess why old players aren't resolving to real names.
void EloGetApiSetupNote(char[] outNote, int outSize)
{
	char apiKey[64];
	cv_EloSteamApiKey.GetString(apiKey, sizeof(apiKey));
	if (apiKey[0] != '\0')
	{
		outNote[0] = '\0';
		return;
	}
	strcopy(outNote, outSize, "\n(Old players show raw SteamIDs - set sm_soccermod_elo_steamapikey to fix this, see README)");
}

void EloStoreApiLookupResult(const char[] steamid, const char[] apiName)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);
	kv.SetNum("apinamechecked", 1);
	if (apiName[0] != '\0') kv.SetString("apiname", apiName);
	kv.Rewind();
	kv.ExportToFile(g_EloFile);
	delete kv;
}

void EloSetDisplayName(const char[] steamid, const char[] newName, int adminClient)
{
	char oldName[MAX_NAME_LENGTH];
	char adminSteamid[32];
	GetClientAuthId(adminClient, AuthId_Engine, adminSteamid, sizeof(adminSteamid));

	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);
	kv.GetString("displayname", oldName, sizeof(oldName), "");

	if (oldName[0] != '\0')
	{
		char timeString[32];
		FormatTime(timeString, sizeof(timeString), "%Y-%m-%d %H:%M");
		kv.JumpToKey("history", true);
		kv.JumpToKey(timeString, true);
		kv.SetString("oldname", oldName);
		kv.SetString("changedby", adminSteamid);
		kv.GoBack();
		kv.GoBack();
	}

	kv.SetString("displayname", newName);
	kv.Rewind();
	kv.ExportToFile(g_EloFile);
	delete kv;

	char logDetail[128];
	Format(logDetail, sizeof(logDetail), "\"%s\" -> \"%s\" by %s", oldName[0] ? oldName : "(none)", newName, adminSteamid);
	EloLogChange(steamid, newName, "rename", logDetail);
}

// ****************************************************************************************************
// ******************************************** LEADERBOARD ********************************************
// ****************************************************************************************************
// Everyone who has ever been rated (not just currently online), sorted by 6v6 ELO descending.
// SourceMod's Menu class paginates automatically once item count exceeds one page, so no manual
// paging logic is needed even for a few hundred entries.
#define ELO_LEADERBOARD_MAX 512

public void OpenEloLeaderboardMenu(int client)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);

	char steamids[ELO_LEADERBOARD_MAX][32];
	char names[ELO_LEADERBOARD_MAX][MAX_NAME_LENGTH];
	float ratings[ELO_LEADERBOARD_MAX];
	int gamesArr[ELO_LEADERBOARD_MAX];
	int count = 0;

	if (kv.GotoFirstSubKey())
	{
		do
		{
			if (count >= ELO_LEADERBOARD_MAX) break;

			char steamid[32];
			kv.GetSectionName(steamid, sizeof(steamid));
			if (steamid[0] != '[') continue; // skip anything that isn't a steamid-shaped key

			strcopy(steamids[count], 32, steamid);

			char liveName[MAX_NAME_LENGTH];
			liveName[0] = '\0';
			for (int player = 1; player <= MaxClients; player++)
			{
				if (!IsClientInGame(player) || IsFakeClient(player)) continue;
				char sid[32];
				GetClientAuthId(player, AuthId_Engine, sid, sizeof(sid));
				if (StrEqual(sid, steamid)) { GetClientName(player, liveName, sizeof(liveName)); break; }
			}
			// Falls back to the raw SteamID if the player was never renamed and isn't online right
			// now - that's the only identity we have on record for someone who's never connected
			// during this session and has no admin-set display name.
			EloGetDisplayName(steamid, liveName, names[count], MAX_NAME_LENGTH);

			if (kv.JumpToKey(eloFormat6v6, false))
			{
				ratings[count] = kv.GetFloat("rating", ELO_DEFAULT_RATING);
				gamesArr[count] = kv.GetNum("games", 0);
				kv.GoBack();
			}
			else
			{
				ratings[count] = ELO_DEFAULT_RATING;
				gamesArr[count] = 0;
			}

			count++;
		}
		while (kv.GotoNextKey());
	}
	delete kv;

	// simple descending insertion sort - fine for a few hundred entries, built on demand only
	for (int i = 1; i < count; i++)
	{
		float keyRating = ratings[i];
		char keySteamid[32]; strcopy(keySteamid, 32, steamids[i]);
		char keyName[MAX_NAME_LENGTH]; strcopy(keyName, MAX_NAME_LENGTH, names[i]);
		int keyGames = gamesArr[i];

		int j = i - 1;
		while (j >= 0 && ratings[j] < keyRating)
		{
			ratings[j+1] = ratings[j];
			strcopy(steamids[j+1], 32, steamids[j]);
			strcopy(names[j+1], MAX_NAME_LENGTH, names[j]);
			gamesArr[j+1] = gamesArr[j];
			j--;
		}
		ratings[j+1] = keyRating;
		strcopy(steamids[j+1], 32, keySteamid);
		strcopy(names[j+1], MAX_NAME_LENGTH, keyName);
		gamesArr[j+1] = keyGames;
	}

	Menu menu = new Menu(EloLeaderboardMenuHandler);
	char titleString[192];
	char apiNote[128];
	EloGetApiSetupNote(apiNote, sizeof(apiNote));
	Format(titleString, sizeof(titleString), "Ranked Leaderboard (%i players, 6v6)\nClick a name for their Career page%s", count, apiNote);
	menu.SetTitle(titleString);

	if (count == 0)
	{
		menu.AddItem("none", "No rated players yet", ITEMDRAW_DISABLED);
	}
	for (int i = 0; i < count; i++)
	{
		char itemLabel[96];
		Format(itemLabel, sizeof(itemLabel), "#%i %s - %i (%i games)", i+1, names[i], RoundToNearest(ratings[i]), gamesArr[i]);
		// "info" is the steamid itself, not an index - lets the select handler open that exact
		// player's detail page directly with no extra lookup.
		menu.AddItem(steamids[i], itemLabel);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int EloLeaderboardMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char steamid[32];
		menu.GetItem(choice, steamid, sizeof(steamid));
		if (!StrEqual(steamid, "none"))
		{
			// Delayed, not a synchronous Display() from inside this same select callback - the
			// same known SM/engine footgun documented elsewhere in this file for rapid-fire menu
			// clicks (see Timer_ReopenEloAdjustMenu below).
			strcopy(eloDetailViewSteamid[client], sizeof(eloDetailViewSteamid[]), steamid);
			eloDetailViewRanked[client] = true;
			CreateTimer(0.1, Timer_OpenEloPlayerDetailMenu, GetClientUserId(client));
		}
	}
	else if (action == MenuAction_Cancel) CreateTimer(0.1, Timer_OpenEloMainMenu, GetClientUserId(client));
	else if (action == MenuAction_End) delete menu;
	return 0;
}

public Action Timer_OpenEloMainMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client)) OpenEloMainMenu(client);
	return Plugin_Stop;
}

public Action Timer_OpenEloPlayerDetailMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client)) OpenEloPlayerDetailMenu(client, eloDetailViewSteamid[client], eloDetailViewRanked[client]);
	return Plugin_Stop;
}

public Action Timer_OpenEloLeaderboardMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client)) OpenEloLeaderboardMenu(client);
	return Plugin_Stop;
}

// ****************************************************************************************************
// ******************************************** UNRANKED LEADERBOARD ********************************************
// ****************************************************************************************************
// Sorted by soccer_mod's own lifetime "points" column - the pre-existing history any server
// already has before installing this plugin (casual play, no gating, possibly imported from an
// even older server's data - see Morten's GER-server merge, 2026-09-15). Gracefully shows an
// empty list if soccer_mod isn't loaded.
#define ELO_UNRANKED_MAX 256

public void OpenEloUnrankedLeaderboardMenu(int client)
{
	Menu menu = new Menu(EloUnrankedLeaderboardMenuHandler);

	ArrayList steamidList = new ArrayList(ByteCountToCells(32));
	ArrayList pointsList = new ArrayList();
	int count = 0;

	if (GetFeatureStatus(FeatureType_Native, "SoccerMod_GetTopPlayersByPoints") == FeatureStatus_Available)
	{
		count = SoccerMod_GetTopPlayersByPoints(steamidList, pointsList, ELO_UNRANKED_MAX);
	}

	char titleString[192];
	char apiNote[128];
	EloGetApiSetupNote(apiNote, sizeof(apiNote));
	Format(titleString, sizeof(titleString), "Unranked Leaderboard (%i players)\nClick a name for their Career page%s", count, apiNote);
	menu.SetTitle(titleString);

	if (count == 0)
	{
		menu.AddItem("none", "No unranked data available", ITEMDRAW_DISABLED);
	}

	char steamid[32];
	for (int i = 0; i < count; i++)
	{
		steamidList.GetString(i, steamid, sizeof(steamid));
		int points = pointsList.Get(i);

		char liveName[MAX_NAME_LENGTH];
		liveName[0] = '\0';
		for (int player = 1; player <= MaxClients; player++)
		{
			if (!IsClientInGame(player) || IsFakeClient(player)) continue;
			char sid[32];
			GetClientAuthId(player, AuthId_Engine, sid, sizeof(sid));
			if (StrEqual(sid, steamid)) { GetClientName(player, liveName, sizeof(liveName)); break; }
		}
		char name[MAX_NAME_LENGTH];
		EloGetDisplayName(steamid, liveName, name, sizeof(name));

		char itemLabel[96];
		Format(itemLabel, sizeof(itemLabel), "#%i %s - %i pts", i+1, name, points);
		menu.AddItem(steamid, itemLabel);
	}

	delete steamidList;
	delete pointsList;

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int EloUnrankedLeaderboardMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char steamid[32];
		menu.GetItem(choice, steamid, sizeof(steamid));
		if (!StrEqual(steamid, "none"))
		{
			strcopy(eloDetailViewSteamid[client], sizeof(eloDetailViewSteamid[]), steamid);
			eloDetailViewRanked[client] = false;
			CreateTimer(0.1, Timer_OpenEloPlayerDetailMenu, GetClientUserId(client));
		}
	}
	else if (action == MenuAction_Cancel) CreateTimer(0.1, Timer_OpenEloMainMenu, GetClientUserId(client));
	else if (action == MenuAction_End) delete menu;
	return 0;
}

// ****************************************************************************************************
// ******************************************** PLAYER DETAIL PAGE ********************************************
// ****************************************************************************************************
// The start of the "FIFA card" direction Morten wants long-term: per-player breakdown across all
// three rated formats (rating, win/loss record, average MVP points per match), plus their full
// auto-tracked join-name history. Opened by clicking a name on the leaderboard.
public void OpenEloPlayerDetailMenu(int client, const char[] targetSteamid, bool ranked)
{
	char liveName[MAX_NAME_LENGTH];
	liveName[0] = '\0';
	for (int player = 1; player <= MaxClients; player++)
	{
		if (!IsClientInGame(player) || IsFakeClient(player)) continue;
		char sid[32];
		GetClientAuthId(player, AuthId_Engine, sid, sizeof(sid));
		if (StrEqual(sid, targetSteamid)) { GetClientName(player, liveName, sizeof(liveName)); break; }
	}
	char displayName[MAX_NAME_LENGTH];
	EloGetDisplayName(targetSteamid, liveName, displayName, sizeof(displayName));

	Menu menu = new Menu(EloPlayerDetailMenuHandler);

	// The "card" itself: OVR + the 5 core attributes + a prestige tier, all in the menu title so
	// it reads as one compact block instead of scattering into the scrollable item list below.
	// Ranked pulls from elo_ranking's own clean-slate data; Unranked pulls from soccer_mod's
	// pre-existing lifetime SQL stats - see EloGetRankedCardAttributes / SoccerMod_GetCardAttributes.
	bool haveCardData = false;
	int attrs[4]; // SHO, PAS, DEF, TCH
	int winrate = 50;
	char tier[16];
	strcopy(tier, sizeof(tier), "BRONZE");

	if (ranked)
	{
		float clutchWinPct = -1.0;
		KeyValues kv = new KeyValues("EloRatings");
		kv.ImportFromFile(g_EloFile);
		kv.JumpToKey(targetSteamid, true);
		if (kv.JumpToKey(eloFormat6v6, false))
		{
			int games6v6 = kv.GetNum("games", 0);
			if (games6v6 > 0) clutchWinPct = (float(kv.GetNum("wins", 0)) / float(games6v6)) * 100.0;
			kv.GoBack();
		}
		delete kv;

		haveCardData = EloGetRankedCardAttributes(targetSteamid, attrs);
		winrate = (clutchWinPct >= 0.0) ? (40 + RoundToNearest(clutchWinPct * 0.59)) : 50;

		// Tier is driven by 6v6 LEADERBOARD RANK, not the absolute rating number - self-scaling
		// regardless of how spread out ratings end up over time (top-3 is still top-3 whether
		// the field spans 1500-1700 today or 1500-2300 a year from now), per Morten's request.
		int rank6v6 = EloGetRank6v6(targetSteamid);
		if (rank6v6 <= 3)       strcopy(tier, sizeof(tier), "LEGEND");
		else if (rank6v6 <= 10) strcopy(tier, sizeof(tier), "WORLD CLASS");
		else if (rank6v6 <= 20) strcopy(tier, sizeof(tier), "GOLD");
		else if (rank6v6 <= 40) strcopy(tier, sizeof(tier), "SILVER");
	}
	else
	{
		if (GetFeatureStatus(FeatureType_Native, "SoccerMod_GetCardAttributes") == FeatureStatus_Available)
			haveCardData = SoccerMod_GetCardAttributes(targetSteamid, attrs);

		// No real "win rate" concept for casual/unranked play - a neutral filler, same as Ranked
		// uses before any rated games exist.
		winrate = 50;

		int rankPoints = EloGetUnrankedRankByPoints(targetSteamid);
		if (rankPoints <= 3)       strcopy(tier, sizeof(tier), "LEGEND");
		else if (rankPoints <= 10) strcopy(tier, sizeof(tier), "WORLD CLASS");
		else if (rankPoints <= 20) strcopy(tier, sizeof(tier), "GOLD");
		else if (rankPoints <= 40) strcopy(tier, sizeof(tier), "SILVER");
	}

	char trackTag[12];
	strcopy(trackTag, sizeof(trackTag), ranked ? " (Ranked)" : " (Unranked)");

	char cardTitle[192];
	if (haveCardData)
	{
		int ovr = RoundToNearest(float(attrs[0] + attrs[1] + attrs[2] + attrs[3] + winrate) / 5.0);
		Format(cardTitle, sizeof(cardTitle),
			"%s%s  [%s]\nOVR %i   SHO %i  PAS %i  DEF %i  TCH %i  WR %i",
			displayName, trackTag, tier, ovr, attrs[0], attrs[1], attrs[2], attrs[3], winrate);
	}
	else
	{
		Format(cardTitle, sizeof(cardTitle), "%s%s\n(no career data yet)", displayName, trackTag);
	}
	menu.SetTitle(cardTitle);

	if (ranked)
	{
		menu.AddItem("stat", "-- Ratings --", ITEMDRAW_DISABLED);
		KeyValues kv = new KeyValues("EloRatings");
		kv.ImportFromFile(g_EloFile);
		kv.JumpToKey(targetSteamid, true);
		if (kv.JumpToKey(eloFormat6v6, false))
		{
			float rating = kv.GetFloat("rating", ELO_DEFAULT_RATING);
			int games = kv.GetNum("games", 0);
			int wins = kv.GetNum("wins", 0);
			int losses = kv.GetNum("losses", 0);
			float totalPoints = kv.GetFloat("totalpoints", 0.0);
			float avgPoints = (games > 0) ? (totalPoints / float(games)) : 0.0;
			float winPct = (games > 0) ? (float(wins) / float(games) * 100.0) : 0.0;
			kv.GoBack();

			char line[112];
			Format(line, sizeof(line), "6v6: %i ELO  |  %i-%i (%.0f%%)  |  %.1f pts/game", RoundToNearest(rating), wins, losses, winPct, avgPoints);
			menu.AddItem("stat", line, ITEMDRAW_DISABLED);
		}
		delete kv;

		int careerStats[7], gamesRated;
		if (EloGetCareerStats(targetSteamid, careerStats, gamesRated))
		{
			char careerLine1[112], careerLine2[112], careerLine3[112];
			Format(careerLine1, sizeof(careerLine1), "Goals: %i  |  Assists: %i  |  Own goals: %i", careerStats[0], careerStats[1], careerStats[2]);
			Format(careerLine2, sizeof(careerLine2), "Saves: %i  |  Passes: %i  |  Interceptions: %i", careerStats[3], careerStats[4], careerStats[5]);
			Format(careerLine3, sizeof(careerLine3), "Rated games played: %i", gamesRated);
			menu.AddItem("stat", "-- Career (Ranked) --", ITEMDRAW_DISABLED);
			menu.AddItem("stat", careerLine1, ITEMDRAW_DISABLED);
			menu.AddItem("stat", careerLine2, ITEMDRAW_DISABLED);
			menu.AddItem("stat", careerLine3, ITEMDRAW_DISABLED);
		}
	}
	else
	{
		int s[13];
		if (GetFeatureStatus(FeatureType_Native, "SoccerMod_GetPublicStats") == FeatureStatus_Available
			&& SoccerMod_GetPublicStats(targetSteamid, s))
		{
			char careerLine1[112], careerLine2[112], careerLine3[112];
			Format(careerLine1, sizeof(careerLine1), "Goals: %i  |  Assists: %i  |  Own goals: %i", s[0], s[1], s[2]);
			Format(careerLine2, sizeof(careerLine2), "Saves: %i  |  Passes: %i  |  Interceptions: %i", s[7], s[4], s[5]);
			Format(careerLine3, sizeof(careerLine3), "MVP awards: %i  |  MOTM awards: %i", s[11], s[12]);
			menu.AddItem("stat", "-- Career (Unranked) --", ITEMDRAW_DISABLED);
			menu.AddItem("stat", careerLine1, ITEMDRAW_DISABLED);
			menu.AddItem("stat", careerLine2, ITEMDRAW_DISABLED);
			menu.AddItem("stat", careerLine3, ITEMDRAW_DISABLED);
		}
	}

	char steamidLine[48];
	Format(steamidLine, sizeof(steamidLine), "SteamID: %s", targetSteamid);
	menu.AddItem("stat", "-- Info --", ITEMDRAW_DISABLED);
	menu.AddItem("stat", steamidLine, ITEMDRAW_DISABLED);

	menu.AddItem("names", "View join-name history");
	menu.AddItem("rename_history", "View admin rename history");

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);

	eloDetailViewRanked[client] = ranked;

	// Per-client, NOT a shared global - the leaderboard is open to every player, so multiple
	// people can have different players' detail pages open at the same time. Reusing the
	// admin-only eloRenameTargetSteamid global here would let concurrent viewers clobber each
	// other's target.
	strcopy(eloDetailViewSteamid[client], sizeof(eloDetailViewSteamid[]), targetSteamid);
}

public int EloPlayerDetailMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char menuItem[16];
		menu.GetItem(choice, menuItem, sizeof(menuItem));

		if (StrEqual(menuItem, "names"))
		{
			EloShowJoinNameHistory(client, eloDetailViewSteamid[client]);
			CreateTimer(0.1, Timer_OpenEloPlayerDetailMenu, GetClientUserId(client));
		}
		else if (StrEqual(menuItem, "rename_history"))
		{
			EloShowNameHistory(client, eloDetailViewSteamid[client]);
			CreateTimer(0.1, Timer_OpenEloPlayerDetailMenu, GetClientUserId(client));
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (eloDetailViewRanked[client]) CreateTimer(0.1, Timer_OpenEloLeaderboardMenu, GetClientUserId(client));
		else CreateTimer(0.1, Timer_OpenEloUnrankedLeaderboardMenu, GetClientUserId(client));
	}
	else if (action == MenuAction_End) delete menu;
	return 0;
}

// This player's 1-indexed rank on the Unranked (soccer_mod_public_stats.points) leaderboard - the
// same rank-based tiering idea as EloGetRank6v6, just for the Unranked track. 9999 (always BRONZE)
// if soccer_mod isn't loaded or this steamid isn't in the top ELO_UNRANKED_MAX by points.
int EloGetUnrankedRankByPoints(const char[] targetSteamid)
{
	if (GetFeatureStatus(FeatureType_Native, "SoccerMod_GetTopPlayersByPoints") != FeatureStatus_Available) return 9999;

	ArrayList steamidList = new ArrayList(ByteCountToCells(32));
	ArrayList pointsList = new ArrayList();
	int count = SoccerMod_GetTopPlayersByPoints(steamidList, pointsList, ELO_UNRANKED_MAX);

	int rank = 9999;
	char steamid[32];
	for (int i = 0; i < count; i++)
	{
		steamidList.GetString(i, steamid, sizeof(steamid));
		if (StrEqual(steamid, targetSteamid)) { rank = i + 1; break; }
	}
	delete steamidList;
	delete pointsList;
	return rank;
}

// ****************************************************************************************************
// ******************************************** JOIN-TIME POSITION PROMPT ********************************************
// ****************************************************************************************************
// Nag anyone who hasn't set >=2 positions shortly after they load in, so most people are already
// configured before a cap fight ever starts (CapStartFight prompts again as a fallback for stragglers).
// Guarantees a persisted (default 1500, 0 games) entry exists for every player who has ever
// connected, not just ones who've actually played a rated match or been manually adjusted -
// otherwise the leaderboard would only ever show the handful of people someone happened to touch.
void EloEnsurePlayerRecorded(const char[] steamid)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	bool alreadyExists = kv.JumpToKey(steamid, false);
	if (alreadyExists) { delete kv; return; }
	delete kv;

	// EloOpenPlayer creates the three default format nodes as a side effect; just open+export.
	KeyValues kv2 = EloOpenPlayer(steamid);
	kv2.Rewind();
	kv2.ExportToFile(g_EloFile);
	delete kv2;
}

public Action EloTimer_CheckPositions(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !IsClientInGame(client) || !IsClientConnected(client)) return Plugin_Stop;

	char steamid[32];
	GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));

	KeyValues kv = new KeyValues("capPositions");
	kv.ImportFromFile(pathCapPositionsFile);
	kv.JumpToKey(steamid, true);

	int posCount = kv.GetNum("gk", 0) + kv.GetNum("def", 0) + kv.GetNum("mid", 0) + kv.GetNum("wing", 0);
	delete kv;

	if (posCount < 2)
	{
		CPrintToChat(client, "{%s}[%s] {%s}Please select at least 2 positions to be pick-eligible for caps", prefixcolor, prefix, textcolor);
		// OpenCapPositionMenu lives in soccer_mod's cap.sp, not exposed here - the periodic in-game
		// reminder from cap.sp itself still catches stragglers, so just the chat nag is fine here.
	}
	return Plugin_Stop;
}

// ****************************************************************************************************
// ******************************************** OWNER-ONLY ELO SEEDING ********************************************
// ****************************************************************************************************
bool IsEloOwner(int client)
{
	if (client == 0) return true; // server console - lets Claude/Morten batch-seed via rcon too
	char steamid[32];
	GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
	for (int i = 0; i < ELO_OWNER_COUNT; i++)
	{
		if (StrEqual(steamid, eloOwnerSteamids[i])) return true;
	}
	return false;
}

// Shared by both the ELO-adjust and rename target menus: online players first (live name),
// then everyone else who has ever been rated but isn't online right now (their saved display
// name / steamid), so admin actions aren't limited to whoever happens to be connected.
void EloAddKnownPlayersToMenu(Menu menu, bool showElo)
{
	char seen[ELO_LEADERBOARD_MAX][32];
	int seenCount = 0;

	for (int player = 1; player <= MaxClients; player++)
	{
		if (!IsClientInGame(player) || !IsClientConnected(player) || IsFakeClient(player)) continue;

		char steamid[32], playerName[MAX_NAME_LENGTH], menuString[96];
		GetClientAuthId(player, AuthId_Engine, steamid, sizeof(steamid));
		GetClientName(player, playerName, sizeof(playerName));

		if (showElo)
		{
			int curElo = RoundToNearest(EloGetRating(steamid, eloFormat6v6));
			Format(menuString, sizeof(menuString), "%s (%i)", playerName, curElo);
		}
		else strcopy(menuString, sizeof(menuString), playerName);

		menu.AddItem(steamid, menuString);
		if (seenCount < ELO_LEADERBOARD_MAX) strcopy(seen[seenCount++], 32, steamid);
	}

	// Offline players, sorted by 6v6 rating descending (same convention as the leaderboard) so
	// the most relevant/best players land on page 1 instead of wherever they happen to fall in
	// the KV file's arbitrary on-disk order - this is why someone like psycho' could look
	// "missing" before: he was there, just buried several pages deep.
	char offlineSteamids[ELO_LEADERBOARD_MAX][32];
	char offlineNames[ELO_LEADERBOARD_MAX][MAX_NAME_LENGTH];
	float offlineRatings[ELO_LEADERBOARD_MAX];
	int offlineCount = 0;

	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	if (kv.GotoFirstSubKey())
	{
		do
		{
			if (offlineCount >= ELO_LEADERBOARD_MAX) break;

			char steamid[32];
			kv.GetSectionName(steamid, sizeof(steamid));
			if (steamid[0] != '[') continue;

			bool alreadyListed = false;
			for (int i = 0; i < seenCount; i++) if (StrEqual(seen[i], steamid)) { alreadyListed = true; break; }
			if (alreadyListed) continue;

			char savedName[MAX_NAME_LENGTH];
			EloGetDisplayName(steamid, "", savedName, sizeof(savedName));

			float rating = ELO_DEFAULT_RATING;
			if (kv.JumpToKey(eloFormat6v6, false))
			{
				rating = kv.GetFloat("rating", ELO_DEFAULT_RATING);
				kv.GoBack();
			}

			strcopy(offlineSteamids[offlineCount], 32, steamid);
			strcopy(offlineNames[offlineCount], MAX_NAME_LENGTH, savedName);
			offlineRatings[offlineCount] = rating;
			offlineCount++;
		}
		while (kv.GotoNextKey());
	}
	delete kv;

	for (int i = 1; i < offlineCount; i++)
	{
		float keyRating = offlineRatings[i];
		char keySteamid[32]; strcopy(keySteamid, 32, offlineSteamids[i]);
		char keyName[MAX_NAME_LENGTH]; strcopy(keyName, MAX_NAME_LENGTH, offlineNames[i]);

		int j = i - 1;
		while (j >= 0 && offlineRatings[j] < keyRating)
		{
			offlineRatings[j+1] = offlineRatings[j];
			strcopy(offlineSteamids[j+1], 32, offlineSteamids[j]);
			strcopy(offlineNames[j+1], MAX_NAME_LENGTH, offlineNames[j]);
			j--;
		}
		offlineRatings[j+1] = keyRating;
		strcopy(offlineSteamids[j+1], 32, keySteamid);
		strcopy(offlineNames[j+1], MAX_NAME_LENGTH, keyName);
	}

	for (int i = 0; i < offlineCount; i++)
	{
		char menuString[96];
		if (showElo) Format(menuString, sizeof(menuString), "%s (%i) [offline]", offlineNames[i], RoundToNearest(offlineRatings[i]));
		else Format(menuString, sizeof(menuString), "%s [offline]", offlineNames[i]);
		menu.AddItem(offlineSteamids[i], menuString);
	}
}

public void OpenEloAdjustTargetMenu(int client)
{
	if (!IsEloOwner(client))
	{
		return;
	}

	Menu menu = new Menu(EloAdjustTargetMenuHandler);
	menu.SetTitle("Statistics - Admin - Adjust ELO (6v6)");

	EloAddKnownPlayersToMenu(menu, true);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int EloAdjustTargetMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		// menu "info" (arg 2) = the raw steamid we passed to AddItem; "display" (arg 5) is the
		// decorated label ("Name (elo)") - deliberately NOT used as the name, see bug below.
		char displayLabel[MAX_NAME_LENGTH];
		menu.GetItem(choice, eloAdjustTargetSteamid, sizeof(eloAdjustTargetSteamid), _, displayLabel, sizeof(displayLabel));

		int target = -1;
		for (int player = 1; player <= MaxClients; player++)
		{
			if (!IsClientInGame(player) || IsFakeClient(player)) continue;
			char steamid[32];
			GetClientAuthId(player, AuthId_Engine, steamid, sizeof(steamid));
			if (StrEqual(steamid, eloAdjustTargetSteamid)) { target = player; break; }
		}
		if (target != -1) GetClientName(target, eloAdjustTargetName, sizeof(eloAdjustTargetName));
		else strcopy(eloAdjustTargetName, sizeof(eloAdjustTargetName), eloAdjustTargetSteamid);

		// Track the working rating IN MEMORY from here on - every +/- click below operates on
		// this, never re-reading from disk mid-session. Re-reading from disk on every click was
		// the actual bug: on the live server, repeated Menu.Display() calls from inside their own
		// select handler plus back-to-back rapid clicks landed multiple Select events in the same
		// tick, and a same-tick re-read of the file didn't reliably reflect the write that just
		// happened a few lines earlier - so click 2/3/4 silently recomputed from the same stale
		// base instead of compounding.
		eloAdjustTargetCurrentRating = EloGetRating(eloAdjustTargetSteamid, eloFormat6v6);

		OpenEloAdjustMenu(client);
	}
	else if (action == MenuAction_Cancel) CreateTimer(0.1, Timer_OpenEloAdjustTargetMenu, GetClientUserId(client));
	else if (action == MenuAction_End) delete menu;
	return 0;
}

public void OpenEloAdjustMenu(int client)
{
	if (!IsEloOwner(client)) return;

	Menu menu = new Menu(EloAdjustMenuHandler);
	char titleString[96];
	Format(titleString, sizeof(titleString), "%s - current ELO: %i", eloAdjustTargetName, RoundToNearest(eloAdjustTargetCurrentRating));
	menu.SetTitle(titleString);

	menu.AddItem("+100", "+100");
	menu.AddItem("+50", "+50");
	menu.AddItem("+25", "+25");
	menu.AddItem("-25", "-25");
	menu.AddItem("-50", "-50");
	menu.AddItem("-100", "-100");
	menu.AddItem("done", "Done - back to player list");

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int EloAdjustMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		if (!IsEloOwner(client)) return 0;

		char menuItem[8];
		menu.GetItem(choice, menuItem, sizeof(menuItem));

		if (StrEqual(menuItem, "done"))
		{
			OpenEloAdjustTargetMenu(client);
			return 0;
		}

		int delta = StringToInt(menuItem);
		int games = EloGetGames(eloAdjustTargetSteamid, eloFormat6v6);
		float oldRating = eloAdjustTargetCurrentRating;
		eloAdjustTargetCurrentRating += float(delta);
		EloSetRating(eloAdjustTargetSteamid, eloFormat6v6, eloAdjustTargetCurrentRating, games);

		char adminSteamid[32];
		GetClientAuthId(client, AuthId_Engine, adminSteamid, sizeof(adminSteamid));
		char logDetail[64];
		Format(logDetail, sizeof(logDetail), "6v6 %.0f -> %.0f (%+i) by %s", oldRating, eloAdjustTargetCurrentRating, delta, adminSteamid);
		EloLogChange(eloAdjustTargetSteamid, eloAdjustTargetName, "manual adjust", logDetail);

		PrintToConsole(client, "%s (%s) ELO -> %i", eloAdjustTargetName, eloAdjustTargetSteamid, RoundToNearest(eloAdjustTargetCurrentRating));

		// Redisplay one server frame later, not synchronously inside this same select callback -
		// an immediate re-Display() from within its own handler is a known SM/engine footgun for
		// menu clicks getting misrouted when the client fires them in rapid succession.
		CreateTimer(0.1, Timer_ReopenEloAdjustMenu, GetClientUserId(client));
	}
	else if (action == MenuAction_Cancel) CreateTimer(0.1, Timer_OpenEloAdjustTargetMenu, GetClientUserId(client));
	else if (action == MenuAction_End) delete menu;
	return 0;
}

public Action Timer_ReopenEloAdjustMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client)) OpenEloAdjustMenu(client);
	return Plugin_Stop;
}

public Action Timer_OpenEloAdjustTargetMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client)) OpenEloAdjustTargetMenu(client);
	return Plugin_Stop;
}

// ****************************************************************************************************
// ******************************************** ADMIN RENAME MENU ********************************************
// ****************************************************************************************************
public void OpenEloRenameTargetMenu(int client)
{
	if (!IsEloOwner(client))
	{
		return;
	}

	Menu menu = new Menu(EloRenameTargetMenuHandler);
	menu.SetTitle("Statistics - Admin - Rename a player's stat name");

	EloAddKnownPlayersToMenu(menu, false);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int EloRenameTargetMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char liveName[MAX_NAME_LENGTH];
		menu.GetItem(choice, eloRenameTargetSteamid, sizeof(eloRenameTargetSteamid), _, liveName, sizeof(liveName));
		strcopy(eloRenameTargetName, sizeof(eloRenameTargetName), liveName);
		OpenEloRenameActionMenu(client);
	}
	else if (action == MenuAction_Cancel) CreateTimer(0.1, Timer_OpenEloMainMenu, GetClientUserId(client));
	else if (action == MenuAction_End) delete menu;
	return 0;
}

public void OpenEloRenameActionMenu(int client)
{
	Menu menu = new Menu(EloRenameActionMenuHandler);
	char titleString[96];
	Format(titleString, sizeof(titleString), "%s - current: %s", eloRenameTargetSteamid, eloRenameTargetName);
	menu.SetTitle(titleString);

	menu.AddItem("rename", "Rename (type new name in chat next)");
	menu.AddItem("history", "View name history");

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int EloRenameActionMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char menuItem[16];
		menu.GetItem(choice, menuItem, sizeof(menuItem));

		if (StrEqual(menuItem, "rename"))
		{
			eloAwaitingRenameInput[client] = true;
			CPrintToChat(client, "{%s}[%s] {%s}Type the new stat name for %s in chat now.", prefixcolor, prefix, textcolor, eloRenameTargetName);
		}
		else if (StrEqual(menuItem, "history"))
		{
			EloShowNameHistory(client, eloRenameTargetSteamid);
			OpenEloRenameActionMenu(client);
		}
	}
	else if (action == MenuAction_Cancel) CreateTimer(0.1, Timer_OpenEloRenameTargetMenu, GetClientUserId(client));
	else if (action == MenuAction_End) delete menu;
	return 0;
}

public Action Timer_OpenEloRenameTargetMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client != 0 && IsClientInGame(client)) OpenEloRenameTargetMenu(client);
	return Plugin_Stop;
}

public void EloShowNameHistory(int client, const char[] steamid)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);

	if (!kv.JumpToKey("history", false))
	{
		CPrintToChat(client, "{%s}[%s] {%s}No rename history for this player yet.", prefixcolor, prefix, textcolor);
		delete kv;
		return;
	}

	if (kv.GotoFirstSubKey())
	{
		do
		{
			char timeString[32], oldName[MAX_NAME_LENGTH], changedBy[32];
			kv.GetSectionName(timeString, sizeof(timeString));
			kv.GetString("oldname", oldName, sizeof(oldName), "?");
			kv.GetString("changedby", changedBy, sizeof(changedBy), "?");
			CPrintToChat(client, "{%s}[%s] {%s}%s: was \"%s\" (changed by %s)", prefixcolor, prefix, textcolor, timeString, oldName, changedBy);
		}
		while (kv.GotoNextKey());
	}
	delete kv;
}

// Awaiting-rename-input is consumed by the very next chat line the admin sends, anywhere -
// keeps the whole rename flow inside menu+chat, no console command needed.
public Action EloSayHook(int client, const char[] command, int argc)
{
	if (client == 0 || !eloAwaitingRenameInput[client]) return Plugin_Continue;

	char text[192];
	GetCmdArgString(text, sizeof(text));
	StripQuotes(text);
	TrimString(text);

	if (text[0] == '\0') return Plugin_Continue;

	eloAwaitingRenameInput[client] = false;
	EloSetDisplayName(eloRenameTargetSteamid, text, client);
	PrintToConsole(client, "%s -> %s", eloRenameTargetName, text);
	strcopy(eloRenameTargetName, sizeof(eloRenameTargetName), text);

	return Plugin_Handled; // swallow this line so it doesn't also post as normal chat
}

// ****************************************************************************************************
// ******************************************** MATCH LIFECYCLE ********************************************
// ****************************************************************************************************
// Called via the Elo_OnMatchStart native, right after match.sp locks teams in.
void EloOnMatchStart()
{
	eloMatchValid = true;
	eloMatchStartTime = GetEngineTime();
	eloRosterCTCount = 0;
	eloRosterTCount = 0;
	eloMatchFormat[0] = '\0';

	for (int player = 1; player <= MaxClients; player++)
	{
		if (!IsClientInGame(player) || !IsClientConnected(player) || IsFakeClient(player)) continue;

		int team = GetClientTeam(player);
		char steamid[32];
		GetClientAuthId(player, AuthId_Engine, steamid, sizeof(steamid));

		if (team == 3 && eloRosterCTCount < 6)      strcopy(eloRosterCT[eloRosterCTCount++], 32, steamid);
		else if (team == 2 && eloRosterTCount < 6)  strcopy(eloRosterT[eloRosterTCount++], 32, steamid);
	}

	// Ranked is 5v5/6v6 only (raised from 2v2/3v3/6v6 on Morten's request 2026-09-15 - smaller
	// scrims still run through the normal match/cap flow same as always, they just don't move
	// anyone's Ranked rating). Both roster sizes share the single "6v6" rating pool.
	if (eloRosterCTCount == eloRosterTCount && (eloRosterCTCount == 5 || eloRosterCTCount == 6))
	{
		strcopy(eloMatchFormat, sizeof(eloMatchFormat), eloFormat6v6);
	}
	// any other headcount (uneven teams, 1v1, 2v2, 3v3, 4v4...) -> eloMatchFormat stays empty, never rated
}

// Called via the Elo_InvalidateMatch native from afkkicker.sp's NukeClient(), before/after the kick
// itself - invalidates the whole in-progress match. matchWasStarted is soccer_mod's matchStarted
// global, passed in since this plugin no longer has direct access to it.
void EloInvalidateMatch(bool matchWasStarted)
{
	if (matchWasStarted) eloMatchValid = false;
}

float EloRequiredMinutes(const char[] format)
{
	if (StrEqual(format, eloFormat6v6)) return cv_Elo6v6MinMinutes.FloatValue;
	return 999999.0; // unknown format -> never satisfiable, never rated
}

// Called via the Elo_OnMatchEnd native once a match genuinely concludes (normal end OR early
// MatchStop, gated the same way the existing stats system gates on matchValid). ctWon/tWon are
// mutually exclusive; pass neither for a draw.
void EloOnMatchEnd(bool ctWon, bool tWon)
{
	if (!eloMatchValid) return;
	if (eloMatchFormat[0] == '\0') return; // unrecognized roster shape, never rated
	if (eloRosterCTCount == 0 || eloRosterTCount == 0) return;

	float minutesPlayed = (GetEngineTime() - eloMatchStartTime) / 60.0;
	if (minutesPlayed < EloRequiredMinutes(eloMatchFormat)) return;

	if (!ctWon && !tWon) return; // draws don't move rating - keeps the update symmetric/simple

	EloApplyResult(eloRosterCT, eloRosterCTCount, eloRosterT, eloRosterTCount, ctWon, eloMatchFormat);
}

// Standard team-average ELO: every player on a team gets the SAME delta, based on their team's average
// rating vs the opposing team's average rating - deliberately NOT weighted by individual in-match stats,
// that's the whole point (a defender's blocks/clears count exactly as much as a winger's goals: the team won).
// How much an individual's in-match MVP performance can nudge their ELO delta, as a fraction of
// the K-factor - ADDITIVE (not multiplying the whole delta), so a match's outcome and its MVP
// performance now weigh in at roughly the same order of magnitude (raised from 0.20 -> 0.50 on
// Morten's explicit request, 2026-09-15: a perfect MVP performance can swing +/-50% of the
// K-factor, i.e. up to +/-16 points on top of the outcome delta - deliberately on par with a
// typical outcome swing, not just a minor nudge anymore).
#define ELO_MVP_MODIFIER_MAX 0.50

// This match's "points" for one player - queried from soccer_mod's live in-memory MVP tracker via the
// SoccerMod_GetMatchPoints native (stats.sp's statsKeygroupMatch), 0 if they never registered a stat
// event, or if soccer_mod has no match currently tracked.
float EloGetMatchPoints(const char[] steamid)
{
	if (GetFeatureStatus(FeatureType_Native, "SoccerMod_GetMatchPoints") != FeatureStatus_Available) return 0.0;
	return SoccerMod_GetMatchPoints(steamid);
}

void EloApplyResult(char teamA[6][32], int countA, char teamB[6][32], int countB, bool teamAWon, const char[] format)
{
	float sumA = 0.0, sumB = 0.0;
	float ratingsA[6], ratingsB[6];
	int gamesA[6], gamesB[6];

	for (int i = 0; i < countA; i++)
	{
		ratingsA[i] = EloGetRating(teamA[i], format);
		gamesA[i]   = EloGetGames(teamA[i], format);
		sumA += ratingsA[i];
	}
	for (int i = 0; i < countB; i++)
	{
		ratingsB[i] = EloGetRating(teamB[i], format);
		gamesB[i]   = EloGetGames(teamB[i], format);
		sumB += ratingsB[i];
	}

	float avgA = sumA / countA;
	float avgB = sumB / countB;

	float expectedA = 1.0 / (1.0 + Pow(10.0, (avgB - avgA) / 400.0));
	float expectedB = 1.0 - expectedA;

	float actualA = teamAWon ? 1.0 : 0.0;
	float actualB = teamAWon ? 0.0 : 1.0;

	float deltaA = ELO_K_FACTOR * (actualA - expectedA);
	float deltaB = ELO_K_FACTOR * (actualB - expectedB);

	// MVP performance nudge, relative to each player's OWN team's average this match (not raw
	// points compared across the whole lobby) - a rough attempt to blunt the cross-position bias,
	// since a defender's points are compared against other defenders/wingers on the same side
	// having had the same match conditions, not against the match's top-scoring winger overall.
	float nudgeMax = ELO_K_FACTOR * ELO_MVP_MODIFIER_MAX;

	float pointsA[6], pointsB[6];
	float sumPointsA = 0.0, sumPointsB = 0.0;
	for (int i = 0; i < countA; i++) { pointsA[i] = EloGetMatchPoints(teamA[i]); sumPointsA += pointsA[i]; }
	for (int i = 0; i < countB; i++) { pointsB[i] = EloGetMatchPoints(teamB[i]); sumPointsB += pointsB[i]; }
	float avgPointsA = (countA > 0) ? (sumPointsA / countA) : 0.0;
	float avgPointsB = (countB > 0) ? (sumPointsB / countB) : 0.0;

	for (int i = 0; i < countA; i++)
	{
		float denom = (avgPointsA > 1.0) ? avgPointsA : 1.0;
		float ratio = (pointsA[i] - avgPointsA) / denom;
		if (ratio > 1.0) ratio = 1.0;
		if (ratio < -1.0) ratio = -1.0;
		float playerDelta = deltaA + (ratio * nudgeMax);

		EloRecordMatchResult(teamA[i], format, ratingsA[i] + playerDelta, gamesA[i] + 1, teamAWon, pointsA[i]);
		EloLogRatingChange(teamA[i], format, ratingsA[i], ratingsA[i] + playerDelta, teamAWon ? "match win" : "match loss");
		EloRecordCareerStats(teamA[i]);
	}
	for (int i = 0; i < countB; i++)
	{
		float denom = (avgPointsB > 1.0) ? avgPointsB : 1.0;
		float ratio = (pointsB[i] - avgPointsB) / denom;
		if (ratio > 1.0) ratio = 1.0;
		if (ratio < -1.0) ratio = -1.0;
		float playerDelta = deltaB + (ratio * nudgeMax);

		EloRecordMatchResult(teamB[i], format, ratingsB[i] + playerDelta, gamesB[i] + 1, !teamAWon, pointsB[i]);
		EloLogRatingChange(teamB[i], format, ratingsB[i], ratingsB[i] + playerDelta, teamAWon ? "match loss" : "match win");
		EloRecordCareerStats(teamB[i]);
	}
}

// Ranked's OWN lifetime career totals - completely separate from soccer_mod's ungated
// soccer_mod_public_stats (that's the Unranked track's data source). Only ever called here, from
// a match that has already passed every Ranked qualification check, so this starts clean on a
// fresh install and only ever grows from real, qualifying matches. Gracefully skipped if
// soccer_mod isn't loaded or this player never registered a stat event this match.
void EloRecordCareerStats(const char[] steamid)
{
	if (GetFeatureStatus(FeatureType_Native, "SoccerMod_GetMatchStatBreakdown") != FeatureStatus_Available) return;

	int s[7]; // goals, assists, own_goals, saves, passes, interceptions, hits
	if (!SoccerMod_GetMatchStatBreakdown(steamid, s)) return;

	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);
	kv.JumpToKey("career", true);

	kv.SetNum("goals", kv.GetNum("goals", 0) + s[0]);
	kv.SetNum("assists", kv.GetNum("assists", 0) + s[1]);
	kv.SetNum("own_goals", kv.GetNum("own_goals", 0) + s[2]);
	kv.SetNum("saves", kv.GetNum("saves", 0) + s[3]);
	kv.SetNum("passes", kv.GetNum("passes", 0) + s[4]);
	kv.SetNum("interceptions", kv.GetNum("interceptions", 0) + s[5]);
	kv.SetNum("hits", kv.GetNum("hits", 0) + s[6]);
	kv.SetNum("gamesRated", kv.GetNum("gamesRated", 0) + 1);

	kv.GoBack();
	kv.Rewind();
	kv.ExportToFile(g_EloFile);
	delete kv;
}

// Reads back Ranked's own career totals - see EloRecordCareerStats. gamesRated is returned
// separately since it's the normalizer for the percentile-based card attributes below, not
// itself part of the raw stat breakdown array.
bool EloGetCareerStats(const char[] steamid, int outStats[7], int &gamesRated)
{
	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);
	kv.JumpToKey(steamid, true);
	if (!kv.JumpToKey("career", false))
	{
		delete kv;
		gamesRated = 0;
		return false;
	}

	outStats[0] = kv.GetNum("goals", 0);
	outStats[1] = kv.GetNum("assists", 0);
	outStats[2] = kv.GetNum("own_goals", 0);
	outStats[3] = kv.GetNum("saves", 0);
	outStats[4] = kv.GetNum("passes", 0);
	outStats[5] = kv.GetNum("interceptions", 0);
	outStats[6] = kv.GetNum("hits", 0);
	gamesRated = kv.GetNum("gamesRated", 0);
	delete kv;
	return true;
}

// Ranked's own percentile-based card attributes (SHO/PAS/DEF/TCH), computed purely from
// elo_ranking's own data file - no soccer_mod dependency at all for this calculation, unlike the
// Unranked track's SoccerMod_GetCardAttributes. Mirrors that function's exact weighting/scaling
// logic, just scoped to Ranked-qualifying matches only and normalized per rated game instead of
// per round (Ranked tracks games, not individual rounds).
bool EloGetRankedCardAttributes(const char[] targetSteamid, int outAttrs[4])
{
	int myStats[7], myGames;
	if (!EloGetCareerStats(targetSteamid, myStats, myGames) || myGames < 1) return false;

	float myShoot = float(myStats[0]) / float(myGames);
	float myPass  = (float(myStats[1]) * 3.0 + float(myStats[4])) / float(myGames);
	float myDef   = (float(myStats[3]) * 5.0 + float(myStats[5])) / float(myGames);
	float myTouch = float(myStats[6]) / float(myGames);

	KeyValues kv = new KeyValues("EloRatings");
	kv.ImportFromFile(g_EloFile);

	int totalPlayers = 0, belowShoot = 0, belowPass = 0, belowDef = 0, belowTouch = 0;
	if (kv.GotoFirstSubKey())
	{
		do
		{
			char steamid[32];
			kv.GetSectionName(steamid, sizeof(steamid));
			if (steamid[0] != '[') continue;
			if (!kv.JumpToKey("career", false)) continue;

			int games = kv.GetNum("gamesRated", 0);
			if (games < 1) { kv.GoBack(); continue; }

			float shoot = float(kv.GetNum("goals", 0)) / float(games);
			float pass  = (float(kv.GetNum("assists", 0)) * 3.0 + float(kv.GetNum("passes", 0))) / float(games);
			float def_  = (float(kv.GetNum("saves", 0)) * 5.0 + float(kv.GetNum("interceptions", 0))) / float(games);
			float touch = float(kv.GetNum("hits", 0)) / float(games);
			kv.GoBack();

			if (shoot < myShoot) belowShoot++;
			if (pass  < myPass)  belowPass++;
			if (def_  < myDef)   belowDef++;
			if (touch < myTouch) belowTouch++;
			totalPlayers++;
		}
		while (kv.GotoNextKey());
	}
	delete kv;
	if (totalPlayers < 1) return false;

	outAttrs[0] = 40 + RoundToNearest((float(belowShoot) / float(totalPlayers)) * 59.0);
	outAttrs[1] = 40 + RoundToNearest((float(belowPass)  / float(totalPlayers)) * 59.0);
	outAttrs[2] = 40 + RoundToNearest((float(belowDef)   / float(totalPlayers)) * 59.0);
	outAttrs[3] = 40 + RoundToNearest((float(belowTouch) / float(totalPlayers)) * 59.0);
	return true;
}

// Like EloSetRating, but also updates the win/loss record and cumulative MVP-points total for
// this format - used only for real rated match results, never for the admin manual-adjust menu
// (that one stays plain EloSetRating, since a manual points tweak isn't a "match" the player
// won or lost). Feeds the win-ratio and avg-points-per-game shown on the player detail page.
void EloRecordMatchResult(const char[] steamid, const char[] format, float newRating, int newGames, bool won, float matchPoints)
{
	KeyValues kv = EloOpenPlayer(steamid);
	kv.JumpToKey(format, false);
	kv.SetFloat("rating", newRating);
	kv.SetNum("games", newGames);

	int wins = kv.GetNum("wins", 0);
	int losses = kv.GetNum("losses", 0);
	float totalPoints = kv.GetFloat("totalpoints", 0.0);

	if (won) wins++;
	else losses++;
	totalPoints += matchPoints;

	kv.SetNum("wins", wins);
	kv.SetNum("losses", losses);
	kv.SetFloat("totalpoints", totalPoints);

	kv.GoBack();
	kv.Rewind();
	kv.ExportToFile(g_EloFile);
	delete kv;
}

// ****************************************************************************************************
// ******************************************** HALFTIME SAFETY NET ********************************************
// ****************************************************************************************************
// Triggers only when the score gap is >= ELO_SWAP_GAP_TRIGGER at halftime. Proposes up to 3 position-matched
// player swaps that bring the two teams' 6v6 ELO closest to balanced, plus a "keep teams as they are" option.
// Only the 12 players currently on CT/T get to vote. Majority rules; a tie (including a tie WITH "keep")
// always defaults to keeping teams as they are - the system never forces a swap without clear support.
//
// Called via the Elo_CheckHalftimeSwap native - scoreCT/scoreT/capCTClient/capTClient/capFirstPickCTClient/
// capFirstPickTClient are match.sp's/cap.sp's matchScoreCT, matchScoreT, capCT, capT, capFirstPickCT,
// capFirstPickT, passed in since this plugin no longer has direct access to those globals.
void EloReadPositionFlags(const char[] steamid, int flags[4])
{
	KeyValues kv = new KeyValues("capPositions");
	kv.ImportFromFile(pathCapPositionsFile);
	kv.JumpToKey(steamid, true);
	flags[0] = kv.GetNum("gk", 0);
	flags[1] = kv.GetNum("def", 0);
	flags[2] = kv.GetNum("mid", 0);
	flags[3] = kv.GetNum("wing", 0);
	delete kv;
}

bool EloPositionsOverlap(int flagsA[4], int flagsB[4])
{
	for (int i = 0; i < 4; i++) if (flagsA[i] == 1 && flagsB[i] == 1) return true;
	return false;
}

void EloCheckHalftimeSwap(int scoreCT, int scoreT, int capCTClient, int capTClient, int capFirstPickCTClient, int capFirstPickTClient)
{
	int gap = scoreCT - scoreT;
	if (gap < 0) gap = -gap;
	if (gap < ELO_SWAP_GAP_TRIGGER) return;

	int ctClients[6], tClients[6];
	char ctSteam[6][32], tSteam[6][32];
	int ctCount = 0, tCount = 0;
	float sumCT = 0.0, sumT = 0.0;

	for (int player = 1; player <= MaxClients; player++)
	{
		if (!IsClientInGame(player) || !IsClientConnected(player) || IsFakeClient(player)) continue;
		int team = GetClientTeam(player);
		char steamid[32];
		GetClientAuthId(player, AuthId_Engine, steamid, sizeof(steamid));

		if (team == 3 && ctCount < 6)
		{
			ctClients[ctCount] = player;
			strcopy(ctSteam[ctCount], 32, steamid);
			sumCT += EloGetRating(steamid, eloFormat6v6);
			ctCount++;
		}
		else if (team == 2 && tCount < 6)
		{
			tClients[tCount] = player;
			strcopy(tSteam[tCount], 32, steamid);
			sumT += EloGetRating(steamid, eloFormat6v6);
			tCount++;
		}
	}

	if (ctCount == 0 || tCount == 0) return;

	// candidates: top 3 swap pairs by resulting ELO-gap, smallest first
	float bestGaps[3] = {999999.0, 999999.0, 999999.0};
	int bestA[3], bestB[3];
	int found = 0;

	for (int i = 0; i < ctCount; i++)
	{
		if (ctClients[i] == capCTClient || ctClients[i] == capFirstPickCTClient) continue;

		int posA[4];
		EloReadPositionFlags(ctSteam[i], posA);
		float eloX = EloGetRating(ctSteam[i], eloFormat6v6);

		for (int j = 0; j < tCount; j++)
		{
			if (tClients[j] == capTClient || tClients[j] == capFirstPickTClient) continue;

			int posB[4];
			EloReadPositionFlags(tSteam[j], posB);
			if (!EloPositionsOverlap(posA, posB)) continue;

			float eloY = EloGetRating(tSteam[j], eloFormat6v6);
			float resultGap = FloatAbs((sumCT - eloX + eloY) - (sumT - eloY + eloX));

			// insertion into the top-3 (ascending by resultGap)
			for (int slot = 0; slot < 3; slot++)
			{
				if (resultGap < bestGaps[slot])
				{
					for (int shift = 2; shift > slot; shift--)
					{
						bestGaps[shift] = bestGaps[shift-1];
						bestA[shift] = bestA[shift-1];
						bestB[shift] = bestB[shift-1];
					}
					bestGaps[slot] = resultGap;
					bestA[slot] = ctClients[i];
					bestB[slot] = tClients[j];
					if (found < 3) found++;
					break;
				}
			}
		}
	}

	if (found == 0) return; // no valid position-matched swap exists - safety net can't fire this match

	eloSwapNumOptions = found;
	for (int k = 0; k < found; k++)
	{
		eloSwapCandidateA[k] = bestA[k];
		eloSwapCandidateB[k] = bestB[k];
	}
	for (int k = 0; k < 4; k++) eloSwapVoteCounts[k] = 0;
	for (int p = 1; p <= MaxClients; p++) eloSwapVoteVoted[p] = false;

	eloSwapMenu = new Menu(EloSwapVoteHandler);
	eloSwapMenu.SetTitle("Score gap >= 4 - swap players to rebalance?");

	char itemKey[8], itemLabel[96], nameA[MAX_NAME_LENGTH], nameB[MAX_NAME_LENGTH];
	for (int k = 0; k < found; k++)
	{
		GetClientName(bestA[k], nameA, sizeof(nameA));
		GetClientName(bestB[k], nameB, sizeof(nameB));
		Format(itemKey, sizeof(itemKey), "%d", k);
		Format(itemLabel, sizeof(itemLabel), "Swap %s (CT) <-> %s (T)", nameA, nameB);
		eloSwapMenu.AddItem(itemKey, itemLabel);
	}
	eloSwapMenu.AddItem("keep", "Keep teams as they are");

	eloSwapVoteActive = true;
	for (int i = 0; i < ctCount; i++) eloSwapMenu.Display(ctClients[i], ELO_SWAP_VOTE_SECONDS);
	for (int j = 0; j < tCount; j++) eloSwapMenu.Display(tClients[j], ELO_SWAP_VOTE_SECONDS);

	CPrintToChatAll("{%s}[%s] {%s}Score gap is %i - match participants are voting on a possible player swap (%i seconds).", prefixcolor, prefix, textcolor, gap, ELO_SWAP_VOTE_SECONDS);

	CreateTimer(float(ELO_SWAP_VOTE_SECONDS), EloTimer_TallySwapVote);
}

public int EloSwapVoteHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		if (!eloSwapVoteActive || eloSwapVoteVoted[client]) return 0;

		char menuItem[8];
		menu.GetItem(choice, menuItem, sizeof(menuItem));

		int idx = StrEqual(menuItem, "keep") ? 3 : StringToInt(menuItem);
		eloSwapVoteCounts[idx]++;
		eloSwapVoteVoted[client] = true;
		CPrintToChat(client, "{%s}[%s] {%s}Vote registered.", prefixcolor, prefix, textcolor);
	}
	else if (action == MenuAction_End)
	{
		// don't delete - same Menu handle is shown to many clients, freed once in the tally timer
	}
	return 0;
}

public Action EloTimer_TallySwapVote(Handle timer)
{
	if (!eloSwapVoteActive) return Plugin_Stop;
	eloSwapVoteActive = false;

	int best = 3;          // default: "keep" (index 3)
	int bestCount = eloSwapVoteCounts[3];
	bool tie = false;

	for (int k = 0; k < eloSwapNumOptions; k++)
	{
		if (eloSwapVoteCounts[k] > bestCount)
		{
			bestCount = eloSwapVoteCounts[k];
			best = k;
			tie = false;
		}
		else if (eloSwapVoteCounts[k] == bestCount && bestCount > 0)
		{
			tie = true;
		}
	}
	if (eloSwapVoteCounts[3] == bestCount && best != 3) tie = true;

	if (tie || best == 3 || bestCount == 0)
	{
		CPrintToChatAll("{%s}[%s] {%s}Vote result: teams stay as they are.", prefixcolor, prefix, textcolor);
	}
	else
	{
		int a = eloSwapCandidateA[best];
		int b = eloSwapCandidateB[best];
		if (IsClientInGame(a) && IsClientInGame(b))
		{
			int teamA = GetClientTeam(a);
			int teamB = GetClientTeam(b);
			ChangeClientTeam(a, teamB);
			ChangeClientTeam(b, teamA);
			CPrintToChatAll("{%s}[%s] {%s}Vote passed - swapping players to rebalance the teams.", prefixcolor, prefix, textcolor);
		}
	}

	delete eloSwapMenu;
	return Plugin_Stop;
}
