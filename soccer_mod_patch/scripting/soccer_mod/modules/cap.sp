// ************************************************************************************************************
// ************************************************** EVENTS **************************************************
// ************************************************************************************************************
public void CapOnPluginStart()
{
	capFirstPickCT = 0;
	capFirstPickT = 0;
}

public void CapEventPlayerDeath(Event event)
{
	if (capFightStarted)
	{
		int attacker = event.GetInt("attacker");

		if (attacker == 0) CPrintToChatAll("{%s}[%s]Cap fight invalid. Please restart the fight.", prefixcolor, prefix);
		else
		{
			if (attacker)
			{
				int attackerid = GetClientOfUserId(attacker);
				capPicker = attackerid;

				int userid = event.GetInt("userid");
				int deadid = GetClientOfUserId(userid);
				int team = GetClientTeam(attackerid);

				if (team == 2)
				{
					capCT = deadid;
					capT = attackerid;
				}
				else if (team == 3)
				{
					capCT = attackerid;
					capT = deadid;
				}
			}
			
			//Check for Cap only mode in ffvote			
			if(ForfeitCapMode == 1) 
			{
				ForfeitEnabled = 1;
				ForfeitRRCheck = true;
				CPrintToChatAll("{%s}[%s]CapFight detected. Forfeit vote will be enabled for the match", prefixcolor, prefix);
				UpdateConfigInt("Forfeit Settings", "soccer_mod_forfeitvote", ForfeitEnabled);
			}
		}
	}
}

public void CapEventRoundEnd(Event event)
{
	if (capFightStarted)
	{
		capFightStarted = false;
		
		HostName_Change_Status("Picking");
		
		//reenable sprint
		if (tempSprint)		bSPRINT_ENABLED = 1;

		int winner = event.GetInt("winner");
		if (winner == 2) 
		{
			OpenCapPickMenu(capT);
		}
		else if (winner == 3) 
		{
			OpenCapPickMenu(capCT);
		}
	}
}

// **************************************************************************************************************
// ************************************************** CAP MENU **************************************************
// **************************************************************************************************************
bool capForceKnifeMode = false;

public void OpenCapMenu(int client)
{
	char capString[48];
	if (capForceKnifeMode) Format(capString, sizeof(capString), "Start cap fight (knife - forced)");
	else Format(capString, sizeof(capString), "Start cap fight (ELO-based)");
	Menu menu = new Menu(CapMenuHandler);

	menu.SetTitle("Soccer - Admin - Cap");

	menu.AddItem("spec", "Put all players to spectator");

	menu.AddItem("random", "Add random player");

	menu.AddItem("start", capString);

	char modeString[48];
	if (capForceKnifeMode) Format(modeString, sizeof(modeString), "Cap mode: Force knife duel (click for ELO)");
	else Format(modeString, sizeof(modeString), "Cap mode: ELO-based (click to force knife)");
	menu.AddItem("elomode", modeString);

	menu.AddItem("capweap", "Weapon selection");
	
	//menu.AddItem("autocap", "[BETA] Auto Cap");

	if(publicmode == 0 || publicmode == 2) menu.ExitBackButton = true;
	else if(publicmode == 1) 
	{
		if(CheckCommandAccess(client, "generic_admin", ADMFLAG_GENERIC) || IsSoccerAdmin(client, "cap")) menu.ExitBackButton = true;
		else menu.ExitBackButton = false;
	}
	menu.Display(client, MENU_TIME_FOREVER);
}

public int CapMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char menuItem[32];
		menu.GetItem(choice, menuItem, sizeof(menuItem));
		if (!matchStarted)
		{
			if (StrEqual(menuItem, "spec"))		 CapPutAllToSpec(client);
			else if (StrEqual(menuItem, "random"))  CapAddRandomPlayer(client);
			else if (StrEqual(menuItem, "capweap"))	OpenWeaponMenu(client);
			else if (StrEqual(menuItem, "elomode"))
			{
				capForceKnifeMode = !capForceKnifeMode;
				CPrintToChat(client, "{%s}[%s] {%s}Cap mode set to: %s", prefixcolor, prefix, textcolor, capForceKnifeMode ? "Force knife duel" : "ELO-based");
			}
			else if (StrEqual(menuItem, "start"))
			{
				CapStartFight(client);
				if(GetClientCount() >= PWMAXPLAYERS+1 && passwordlock == 1 && pwchange == true)
				{
					CPrintToChatAll("{%s}[%s] {%s}At least %i players when the capfight started; Changing the pw...", prefixcolor, prefix, textcolor, PWMAXPLAYERS+1);
					RandPass();
				}
			}
			/*else if (StrEqual(menuItem, "autocap"))
			{
				AutoCapStart(client);
				if(GetClientCount() >= PWMAXPLAYERS+1 && passwordlock == 1 && pwchange == true)
				{
					CPrintToChatAll("{%s}[%s] {%s}At least %i players when the capfight started; Changing the pw...", prefixcolor, prefix, textcolor, PWMAXPLAYERS+1);
					RandPass();
				}
			}*/
		}
		else CPrintToChat(client, "{%s}[%s]{%s}You can not use this option during a match", prefixcolor, prefix, textcolor);

		if (!(StrEqual(menuItem, "capweap")))	OpenCapMenu(client);	
	}
	else if (action == MenuAction_Cancel && choice == -6)   OpenMenuAdmin(client);
	else if (action == MenuAction_End)					  menu.Close();
}


// **************************************************************************************************************
// ************************************************ WEAPON MENU *************************************************
// **************************************************************************************************************
public void OpenWeaponMenu(int client)
{

	Menu menu = new Menu(WeaponMenuHandler);

	menu.SetTitle("Soccer - Cap - Weapons");

	menu.AddItem("knife", 	"Knife");
	//Pistols
	menu.AddItem("glock", 	"Glock 18");
	menu.AddItem("usp", 	"USP Tactical");
	menu.AddItem("p228", 	"P228");
	menu.AddItem("deagle", 	"Desert Eagle .50");
	menu.AddItem("57", 		"Five-seveN");
	menu.AddItem("dual", 	"Dual Elite Berettas");
	//Sub-Machine Guns
	menu.AddItem("mac10", 	"MAC10");
	menu.AddItem("tmp", 	"TMP");
	menu.AddItem("mp5", 	"MP5 Navy");
	menu.AddItem("ump", 	"UMP");
	menu.AddItem("p90", 	"P90");
	//Shotguns
	menu.AddItem("m3", 		"M3 Super 90");
	menu.AddItem("xm1014", 	"XM1014");
	//Rifles
	menu.AddItem("galil", 	"Galil");
	menu.AddItem("famas", 	"FAMAS");
	menu.AddItem("ak47", 	"AK47");
	menu.AddItem("m4a1", 	"M4A1 Carbine");
	menu.AddItem("sg552", 	"SG-552 Commando");
	menu.AddItem("aug", 	"AUG");
	//MG
	menu.AddItem("m249", 	"M249-SAW");
	//Sniper
	menu.AddItem("scout", 	"Scout");
	menu.AddItem("g3sg1", 	"G3/SG-1");
	menu.AddItem("sg550", 	"SG-550 Commando");
	menu.AddItem("awp", 	"AWP");
	//Grenades
	menu.AddItem("he", 		"HE grenade");
	menu.AddItem("flash", 	"Flashbang");
	//menu.AddItem("smoke", 	"Smoke grenade");
	//Misc
	menu.AddItem("randwp", 	"Random");

	menu.ExitBackButton = true;

	menu.Display(client, MENU_TIME_FOREVER);
}

public int WeaponMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		if (!matchStarted)
		{
			char menuItem[32];
			menu.GetItem(choice, menuItem, sizeof(menuItem));

			if (StrEqual(menuItem, "knife"))		 	capweapon = "knife";
			else if (StrEqual(menuItem, "glock"))  		capweapon = "glock";
			else if (StrEqual(menuItem, "usp"))  		capweapon = "usp";
			else if (StrEqual(menuItem, "p228"))  		capweapon = "p228";
			else if (StrEqual(menuItem, "deagle"))  	capweapon = "deagle";
			else if (StrEqual(menuItem, "57"))  		capweapon = "fiveseven";
			else if (StrEqual(menuItem, "dual"))  		capweapon = "elite";
			else if (StrEqual(menuItem, "mac10"))  		capweapon = "mac10";
			else if (StrEqual(menuItem, "tmp"))  		capweapon = "tmp";
			else if (StrEqual(menuItem, "mp5"))  		capweapon = "mp5navy";
			else if (StrEqual(menuItem, "ump"))  		capweapon = "ump45";
			else if (StrEqual(menuItem, "p90"))  		capweapon = "p90";
			else if (StrEqual(menuItem, "m3"))  		capweapon = "m3";
			else if (StrEqual(menuItem, "xm1014"))  	capweapon = "xm1014";
			else if (StrEqual(menuItem, "galil"))  		capweapon = "galil";
			else if (StrEqual(menuItem, "famas"))  		capweapon = "famas";
			else if (StrEqual(menuItem, "ak47"))  		capweapon = "ak47";
			else if (StrEqual(menuItem, "m4a1"))  		capweapon = "m4a1";
			else if (StrEqual(menuItem, "sg552"))  		capweapon = "sg552";
			else if (StrEqual(menuItem, "aug"))  		capweapon = "aug";
			else if (StrEqual(menuItem, "m249"))  		capweapon = "m249";
			else if (StrEqual(menuItem, "scout"))  		capweapon = "scout";
			else if (StrEqual(menuItem, "g3sg1"))  		capweapon = "g3sg1";
			else if (StrEqual(menuItem, "sg550"))  		capweapon = "sg550";
			else if (StrEqual(menuItem, "awp"))  		capweapon = "awp";
			else if (StrEqual(menuItem, "flash"))  		capweapon = "flashbang";
			//else if (StrEqual(menuItem, "smoke"))  		capweapon = "smokegrenade";
			else if (StrEqual(menuItem, "he"))  		capweapon = "hegrenade";
			else if (StrEqual(menuItem, "randwp"))  	capweapon = "random";

		}
		else CPrintToChat(client, "{%s}[%s]{%s}You can not use this option during a match", prefixcolor, prefix, textcolor);

		OpenCapMenu(client);
	}
	else if (action == MenuAction_Cancel && choice == -6)   OpenCapMenu(client);
	else if (action == MenuAction_End)					  menu.Close();
}

// ***************************************************************************************************************
// ************************************************** PICK MENU **************************************************
// ***************************************************************************************************************
public void OpenCapPickMenu(int client)
{
	if (client)
	{
		if (client == capT || client == capCT)
		{
			if (client == capPicker)
			{
				int count;
				for (int player = 1; player <= MaxClients; player++)
				{
					if (IsClientInGame(player) && IsClientConnected(player) && GetClientTeam(player) < 2 && !IsClientSourceTV(player)) count++;
				}

				if (count > 0)
				{
					capPicker = client;
					CapCreatePickMenu(client);
				}
				else CPrintToChat(client, "{%s}[%s] {%s}No players available to pick", prefixcolor, prefix, textcolor);
			}
			else CPrintToChat(client, "{%s}[%s] {%s}It is not your turn to pick", prefixcolor, prefix, textcolor);
		}
		else CPrintToChat(client, "{%s}[%s] {%s}You are not a cap", prefixcolor, prefix, textcolor);
	}
}

public int CapPickMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char menuItem[32];
		menu.GetItem(choice, menuItem, sizeof(menuItem));

		int target = StringToInt(menuItem);
		if (IsClientInGame(target) && IsClientConnected(target))
		{
			char steamid[32];
			GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));

			char targetSteamid[32];
			GetClientAuthId(target, AuthId_Engine, targetSteamid, sizeof(targetSteamid));
			capPicksLeft--;

			// remember each captain's very first pick - protected from halftime swaps later
			if (client == capCT && capFirstPickCT == 0) capFirstPickCT = target;
			else if (client == capT && capFirstPickT == 0) capFirstPickT = target;

			if (client == capCT)
			{
				int team = GetClientTeam(capCT);
				ChangeClientTeam(target, team);
				if(GetClientMenu(target) != MenuSource_None)
				{
					CancelClientMenu(target, false);
					InternalShowMenu(target, "\10", 1); 
				}

				for (int player = 1; player <= MaxClients; player++)
				{
					if (IsClientInGame(player) && IsClientConnected(player)) CPrintToChat(player, "{%s}[%s] {%s}%N has picked %N", prefixcolor, prefix, textcolor, client, target);
				}

				LogMessage("%N <%s> has picked %N <%s>", client, steamid, target, targetSteamid);

				capPicker = capT;
				if (capPicksLeft > 0) OpenCapPickMenu(capT);
			}
			else if (client == capT)
			{
				int team = GetClientTeam(capT);
				ChangeClientTeam(target, team);
				if(GetClientMenu(target) != MenuSource_None)
				{
					CancelClientMenu(target, false);
					InternalShowMenu(target, "\10", 1); 
				}

				for (int player = 1; player <= MaxClients; player++)
				{
					if (IsClientInGame(player) && IsClientConnected(player)) CPrintToChat(player, "{%s}[%s] {%s}%N has picked %N", prefixcolor, prefix, textcolor, client, target);
				}

				LogMessage("%N <%s> has picked %N <%s>", client, steamid, target, targetSteamid);

				capPicker = capCT;
				if (capPicksLeft > 0) OpenCapPickMenu(capCT);
			}
		}
		else
		{
			CPrintToChat(client, "{%s}[%s] {%s}Player is no longer on the server", prefixcolor, prefix, textcolor);

			if (client == capCT) OpenCapPickMenu(capCT);
			else if (client == capT) OpenCapPickMenu(capT);
		}
	}
	else if (action == MenuAction_End) menu.Close();
}

// *******************************************************************************************************************
// ************************************************** POSITION MENU **************************************************
// *******************************************************************************************************************
public void OpenCapPositionMenu(int client)
{
	// A stale/competing menu handle (e.g. the engine's own team-join menu still technically
	// "open" right after connect) can silently block a brand new menu from displaying - same
	// fix already used elsewhere in this codebase (see the pick-menu team assignment code).
	if (GetClientMenu(client) != MenuSource_None) CancelClientMenu(client, false);

	KeyValues keygroup = new KeyValues("capPositions");
	keygroup.ImportFromFile(pathCapPositionsFile);
	char langString[64], langString1[64], langString2[64];
	char steamid[32];
	GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
	keygroup.JumpToKey(steamid, true);

	Menu menu = new Menu(CapPositionMenuHandler);

	int curCount = keygroup.GetNum("gk", 0) + keygroup.GetNum("def", 0) + keygroup.GetNum("mid", 0) + keygroup.GetNum("wing", 0);
	char titleString[80];
	if (curCount >= 2) Format(titleString, sizeof(titleString), "Positions - %i/2 selected, you're pick-eligible", curCount);
	else Format(titleString, sizeof(titleString), ">>> SELECT AT LEAST 2 (you have %i/2) <<<", curCount);
	menu.SetTitle(titleString);

	int keyValue = keygroup.GetNum("gk", 0);
	Format(langString1, sizeof(langString1), "Goalkeeper", client);
	if (keyValue) Format(langString2, sizeof(langString2), "Yes", client);
	else Format(langString2, sizeof(langString2), "No", client);
	Format(langString, sizeof(langString), "%s: %s", langString1, langString2);
	menu.AddItem("gk", langString);

	keyValue = keygroup.GetNum("def", 0);
	Format(langString1, sizeof(langString1), "Defender", client);
	if (keyValue) Format(langString2, sizeof(langString2), "Yes", client);
	else Format(langString2, sizeof(langString2), "No", client);
	Format(langString, sizeof(langString), "%s: %s", langString1, langString2);
	menu.AddItem("def", langString);

	keyValue = keygroup.GetNum("mid", 0);
	Format(langString1, sizeof(langString1), "Midfielder", client);
	if (keyValue) Format(langString2, sizeof(langString2), "Yes", client);
	else Format(langString2, sizeof(langString2), "No", client);
	Format(langString, sizeof(langString), "%s: %s", langString1, langString2);
	menu.AddItem("mid", langString);

	keyValue = keygroup.GetNum("wing", 0);
	Format(langString1, sizeof(langString1), "Wing", client);
	if (keyValue) Format(langString2, sizeof(langString2), "Yes", client);
	else Format(langString2, sizeof(langString2), "No", client);
	Format(langString, sizeof(langString), "%s: %s", langString1, langString2);
	menu.AddItem("wing", langString);

	keyValue = keygroup.GetNum("spec", 0);
	Format(langString1, sizeof(langString1), "Spec only", client);
	if (keyValue) Format(langString2, sizeof(langString2), "Yes", client);
	else Format(langString2, sizeof(langString2), "No", client);
	Format(langString, sizeof(langString), "%s: %s", langString1, langString2);
	menu.AddItem("spec", langString);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);

	keygroup.Close();
}

public int CapPositionMenuHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		char menuItem[32];
		menu.GetItem(choice, menuItem, sizeof(menuItem));

		char steamid[32];
		GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));

		KeyValues keygroup = new KeyValues("capPositions");
		keygroup.ImportFromFile(pathCapPositionsFile);

		keygroup.JumpToKey(steamid, true);

		int keyValue = keygroup.GetNum(menuItem, 0);
		if (keyValue) keygroup.SetNum(menuItem, 0);
		else keygroup.SetNum(menuItem, 1);

		keygroup.Rewind();
		keygroup.ExportToFile(pathCapPositionsFile);
		keygroup.Close();

		OpenCapPositionMenu(client);
	}
	else if (action == MenuAction_Cancel && choice == -6)   OpenMenuSoccer(client);
	else if (action == MenuAction_End)					  menu.Close();
}

// ************************************************************************************************************
// ************************************************** TIMERS **************************************************
// ************************************************************************************************************
public Action TimerCapFightCountDown(Handle timer, any seconds)
{
	for (int player = 1; player <= MaxClients; player++)
	{
		if (IsClientInGame(player) && IsClientConnected(player)) PrintCenterText(player, "Cap fight will start in %i seconds", seconds);
	}
}

public Action TimerCapFightCountDownEnd(Handle timer)
{
	//Prepare selected weapon
	if (StrEqual(capweapon, "random"))
	{
		int randint = GetRandomInt(0, sizeof(capwparray[])-1);
		capweapon = capwparray[randint];
		Format(weaponName, sizeof(weaponName), "weapon_%s", capweapon);
		capweapon = "random";
	}
	else 
	{
		Format(weaponName, sizeof(weaponName), "weapon_%s", capweapon);
	}

	for (int player = 1; player <= MaxClients; player++)
	{
		if (IsClientInGame(player) && IsClientConnected(player))
		{
			PrintCenterText(player, "[%s] FIGHT!", prefix);
			if (GetClientTeam(player) > 1  && IsPlayerAlive(player)) 
			{
				SetEntProp(player, Prop_Data, "m_takedamage", 2, 1);
				//Set Armor to 0 and cancel Timer
				SetEntProp(player, Prop_Send, "m_ArmorValue", 0.0);
				//Remove weapon/knife
				int iWeapon = -1;
				while((iWeapon = GetPlayerWeaponSlot(player, CS_SLOT_KNIFE)) != -1)
				{
					if(iWeapon > 0)
					{
						RemovePlayerItem(player, iWeapon);
						AcceptEntityInput(iWeapon, "kill");
					}
				}				
				//If weapon == grenade refill whenever it's thrown
				if (StrEqual(weaponName, "weapon_smokegrenade") || StrEqual(weaponName, "weapon_flashbang") || StrEqual(weaponName, "weapon_hegrenade"))
				{
					//Refill
					GivePlayerItem(player, weaponName);
					CreateTimer(0.5, GrenadeRefillTimer, _,TIMER_REPEAT);
				}
				else if (StrEqual(weaponName, "weapon_knife")) 
				{
					GivePlayerItem(player, weaponName);
				}
				else
				{
					GivePlayerItem(player, "weapon_knife");
					GivePlayerItem(player, weaponName);
				}
				
				if (StrEqual(weaponName, "weapon_smokegrenade") || StrEqual(weaponName, "weapon_flashbang"))	SetEntProp(player, Prop_Send, "m_iHealth", 1)
				else if (StrEqual(weaponName, "weapon_hegrenade")) SetEntProp(player, Prop_Send, "m_iHealth", 98)
				else	SetEntProp(player, Prop_Send, "m_iHealth", 101)
			}
		}
	}

	UnfreezeAll();
}

public Action GrenadeRefillTimer(Handle timer)
{
	if (capFightStarted)
	{
		for (int player = 1; player <= MaxClients; player++)
		{
			if (IsClientInGame(player) && IsClientConnected(player))
			{
				if (GetClientTeam(player) > 1  && IsPlayerAlive(player)) 
				{
					char playerweapon[64];
					GetClientWeapon(player, playerweapon, sizeof(playerweapon));
					if (!(StrEqual(playerweapon, "weapon_smokegrenade") || StrEqual(playerweapon, "weapon_flashbang") || StrEqual(playerweapon, "weapon_hegrenade")))
					{
						GivePlayerItem(player, weaponName);
					}
				}
			}
		}
		return Plugin_Continue;
	}
	else return Plugin_Stop;
}

// ***************************************************************************************************************
// ************************************************** FUNCTIONS **************************************************
// ***************************************************************************************************************
public void CapPutAllToSpec(int client)
{
	if(trainingModeEnabled) trainingModeEnabled = false;
	
	if(!matchStarted)
	{
		for (int player = 1; player <= MaxClients; player++)
		{
			if (IsClientInGame(player) && IsClientConnected(player))
			{
				CPrintToChat(player, "{%s}[%s] {%s}%N has put all players to spectator", prefixcolor, prefix, textcolor, client);
				if (GetClientTeam(player) != 1) ChangeClientTeam(player, 1);
			}
		}
		
		HostName_Change_Status("Specced");
		if(first12Set == 1)				CapPrep = true;

		char steamid[32];
		GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
		LogMessage("%N <%s> has put all players to spectator", client, steamid);
	}
}

public void CapAddRandomPlayer(int client)
{
	int players[32], count;
	for (int player = 1; player <= MaxClients; player++)
	{
		if (IsClientInGame(player) && IsClientConnected(player) && GetClientTeam(player) < 2 && !IsClientSourceTV(player))
		{
			players[count] = player;
			count++;
		}
	}

	if (count)
	{
		int randomPlayer = players[GetRandomInt(0, count - 1)];
		if (GetTeamClientCount(2) < GetTeamClientCount(3)) ChangeClientTeam(randomPlayer, 2);
		else ChangeClientTeam(randomPlayer, 3);

		for (int player = 1; player <= MaxClients; player++)
		{
			if (IsClientInGame(player) && IsClientConnected(player)) CPrintToChat(player, "{%s}[%s] {%s}%N has forced %N as random player", prefixcolor, prefix, textcolor, client, randomPlayer);
		}

		char steamid[32], targetSteamid[32];
		GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
		GetClientAuthId(client, AuthId_Engine, targetSteamid, sizeof(targetSteamid));
		LogMessage("%N <%s> has forced %N <%s> as random player", client, steamid, randomPlayer, targetSteamid);
		
		if((first12Set == 1) && CapPrep)
		{
			if (ImportJoinNumber(targetSteamid) > 12) CPrintToChatAll("{%s}[%s] {%s}NOTICE: %N joined on position %i.", prefixcolor, prefix, textcolor, randomPlayer, ImportJoinNumber(targetSteamid));
		}
		if((first12Set == 2) && CapPrep)
		{
			if (ImportJoinNumber(targetSteamid) > capnr) CPrintToChatAll("{%s}[%s] {%s}NOTICE: %N joined on position %i.", prefixcolor, prefix, textcolor, randomPlayer, ImportJoinNumber(targetSteamid));
		}
	}
	else CPrintToChat(client, "{%s}[%s] {%s}No players in spectator", prefixcolor, prefix, textcolor);
}

public void CapStartFight(int client)
{
	if (!capFightStarted)
	{
		if(passwordlock == 1)
		{
			pwchange = true;
			CPrintToChatAll("{%s}[%s] {%s}AFK Kick enabled.", prefixcolor, prefix, textcolor);
			AFKKick();
		}
		
		if(bSPRINT_ENABLED == 1)
		{
			bSPRINT_ENABLED = 0;
			tempSprint = true;
		}
		else tempSprint = false;
		
		// count players
		capnr = GetClientCount();
		if(first12Set == 1)
		{
			if(nrhelper >= capnr)
			{
				first12Set = 2;
				tempRule = true;
			}
		}
		if(first12Set == 2)
		{
			if (capnr < 12)	capnr = 12;
		}
		nrhelper = 0;
		
		capFightStarted = true;
		capPicksLeft = (matchMaxPlayers - 1) * 2;
		capFirstPickCT = 0;
		capFirstPickT = 0;

		bool noPos[MAXPLAYERS+1] = false;
		int posnr[MAXPLAYERS+1];
		int ctClient = 0, tClient = 0;

		KeyValues keygroup = new KeyValues("capPositions");
		keygroup.ImportFromFile(pathCapPositionsFile);

		for (int player = 1; player <= MaxClients; player++)
		{
			if (IsClientInGame(player) && IsClientConnected(player))
			{
				char playerSteamid[32];
				GetClientAuthId(player, AuthId_Engine, playerSteamid, sizeof(playerSteamid));

				int team = GetClientTeam(player);
				if (team == 3) ctClient = player;
				else if (team == 2) tClient = player;

				if (team > 1  && IsPlayerAlive(player)) SetEntityMoveType(player, MOVETYPE_NONE);
				else
				{
					noPos[player] = false;


					keygroup.JumpToKey(playerSteamid, true);

					int gk = keygroup.GetNum("gk", 0);
					int def = keygroup.GetNum("def", 0);
					int mid = keygroup.GetNum("mid", 0);
					int wing = keygroup.GetNum("wing", 0);
					int spec = keygroup.GetNum("spec", 0);
					int posCount = gk + def + mid + wing;

					// same >=2-positions rule as the pick menu - nag anyone still short here too
					if (spec == 1 || posCount < 2)
					{
						noPos[player] = true;
					}
				}

				posnr[player] = ImportJoinNumber(playerSteamid)
			}
		}

		keygroup.Close();

		// prompt EVERYONE still under the position minimum, not just whoever started the fight
		for (int player = 1; player <= MaxClients; player++)
		{
			if (IsClientInGame(player) && IsClientConnected(player) && noPos[player] == true)
			{
				CPrintToChat(player, "{%s}[%s] {%s}Please select at least 2 positions to be pick-eligible", prefixcolor, prefix, textcolor);
				OpenCapPositionMenu(player);
			}
		}

		for (int player = 1; player <= MaxClients; player++)
		{
			if (IsClientInGame(player) && IsClientConnected(player))
			{
				//PrintToServer("%N : %i", player, posnr[player]);
				CPrintToChat(player, "{%s}[%s] {%s}%N has started a cap fight", prefixcolor, prefix, textcolor, client);
				CPrintToChat(player, "{%s}[%s] {%s}You joined this cap on position number {%s}%i.", prefixcolor, prefix, textcolor, prefixcolor, posnr[player]);
			}
		}

		HostName_Change_Status("Capfight");

		char steamid[32];
		GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
		LogMessage("%N <%s> has started a cap fight", client, steamid);

		// ELO decides who picks first: lowest 6v6 ELO auto-picks, unless the two candidate
		// captains are within the configured tiebreak percentage of each other, in which case
		// fall back to the traditional knife duel (capweapon).
		bool useKnifeDuel = true;

		if (ctClient > 0 && tClient > 0 && !capForceKnifeMode)
		{
			float eloCT = Elo_GetCapRating(ctClient);
			float eloT = Elo_GetCapRating(tClient);
			float avgElo = (eloCT + eloT) / 2.0;
			float diffPct = (avgElo > 0.0) ? (FloatAbs(eloCT - eloT) / avgElo * 100.0) : 0.0;

			if (diffPct > cv_EloCapTiebreakPct.FloatValue)
			{
				useKnifeDuel = false;

				int firstPicker; char firstPickerSide[8];
				if (eloCT < eloT)
				{
					capCT = ctClient;
					capT = tClient;
					firstPicker = ctClient;
					strcopy(firstPickerSide, sizeof(firstPickerSide), "CT");
				}
				else
				{
					capT = tClient;
					capCT = ctClient;
					firstPicker = tClient;
					strcopy(firstPickerSide, sizeof(firstPickerSide), "T");
				}

				CPrintToChatAll("{%s}[%s] {%s}%s cap has the lowest ELO and will pick first.", prefixcolor, prefix, textcolor, firstPickerSide);

				capFightStarted = false;
				capPicker = firstPicker;
				if (tempSprint) bSPRINT_ENABLED = 1;
				UnfreezeAll();

				HostName_Change_Status("Picking");
				OpenCapPickMenu(firstPicker);
			}
			else
			{
				CPrintToChatAll("{%s}[%s] {%s}CT ELO %.0f vs T ELO %.0f (%.1f%% apart, within the %.1f%% tiebreak) - deciding first pick with the knife duel.", prefixcolor, prefix, textcolor, eloCT, eloT, diffPct, cv_EloCapTiebreakPct.FloatValue);
			}
		}

		if (useKnifeDuel)
		{
			CreateTimer(0.0, TimerCapFightCountDown, 3);
			CreateTimer(1.0, TimerCapFightCountDown, 2);
			CreateTimer(2.0, TimerCapFightCountDown, 1);
			CreateTimer(3.0, TimerCapFightCountDownEnd);
		}
	}
	else CPrintToChat(client, "{%s}[%s] {%s}Cap fight already started", prefixcolor, prefix, textcolor);
}

public void CapCreatePickMenu(int client)
{
	Menu menu = new Menu(CapPickMenuHandler);

	menu.SetTitle("[Join Nr] Name [Positions]");

	KeyValues keygroup = new KeyValues("capPositions");
	keygroup.ImportFromFile(pathCapPositionsFile);

	for (int player = 1; player <= MaxClients; player++)
	{
		if (IsClientInGame(player) && IsClientConnected(player) && !IsFakeClient(player) && !IsClientSourceTV(player))
		{
			int team = GetClientTeam(player);
			if (team < 2)
			{
				char playerid[4];
				IntToString(player, playerid, sizeof(playerid));

				char steamid[32];
				GetClientAuthId(player, AuthId_Engine, steamid, sizeof(steamid));

				char liveName[MAX_NAME_LENGTH], playerName[MAX_NAME_LENGTH];
				GetClientName(player, liveName, sizeof(liveName));
				Elo_GetDisplayName(steamid, liveName, playerName, sizeof(playerName));

				keygroup.JumpToKey(steamid, true);

				int posGk = keygroup.GetNum("gk", 0);
				int posDef = keygroup.GetNum("def", 0);
				int posMid = keygroup.GetNum("mid", 0);
				int posWing = keygroup.GetNum("wing", 0);
				int posSpec = keygroup.GetNum("spec", 0);
				int posCount = posGk + posDef + posMid + posWing;

				char positions[32] = "";
				if (posGk) Format(positions, sizeof(positions), "%s[GK]", positions);
				if (posDef) Format(positions, sizeof(positions), "%s[DEF]", positions);
				if (posMid) Format(positions, sizeof(positions), "%s[MID]", positions);
				if (posWing) Format(positions, sizeof(positions), "%s[WING]", positions);
				if (posSpec) Format(positions, sizeof(positions), "[SPEC ONLY]");

				int posnr = ImportJoinNumber(steamid);
				int posElo = RoundToNearest(Elo_GetRating(steamid, "6v6"));

				char menuString[96];
				if (positions[0]) Format(menuString, sizeof(menuString), "[%i] %s (%i) %s", posnr, playerName, posElo, positions);
				else Format(menuString, sizeof(menuString), "[%i] %s (%i)", posnr, playerName, posElo);
				//menuString = playerName;

				// Must have selected at least 2 positions (and not be spec-only) to be pick-eligible at all.
				bool positionEligible = (posSpec == 0 && posCount >= 2);

				if(first12Set == 1)
				{
					if(posnr > 12 || !positionEligible)	menu.AddItem(playerid, menuString, ITEMDRAW_DISABLED);
					else			menu.AddItem(playerid, menuString);
				}
				else if (first12Set == 2)
				{
					if(posnr > capnr || !positionEligible)	menu.AddItem(playerid, menuString, ITEMDRAW_DISABLED);
					else				menu.AddItem(playerid, menuString);
				}
				else if (!positionEligible) menu.AddItem(playerid, menuString, ITEMDRAW_DISABLED);
				else				menu.AddItem(playerid, menuString);
				keygroup.Rewind();
			}
		}
	}

	delete keygroup;

	menu.Display(client, MENU_TIME_FOREVER);
}

public int ImportJoinNumber(char steamid[32])
{
	int nr = 0;
	int entries = 0;
	char buffer[32];
	
	//kvConnectlist = new KeyValues("connectlist");
	kvConnectlist.ImportFromFile(DCListKV);
	
	if (kvConnectlist.GotoFirstSubKey())
	{
		entries++;
		while (kvConnectlist.GotoNextKey())
		{
			entries++;
		}
	}
	kvConnectlist.Rewind();
	
	kvConnectlist.GotoFirstSubKey();
	kvConnectlist.SavePosition();
	
	for (int i = 1; i <= entries; i++)
	{
		kvConnectlist.GetSectionName(buffer, sizeof(buffer));
		
		if(bIsOnServer(buffer))	nr++;
		
		kvConnectlist.GotoNextKey();
		kvConnectlist.SavePosition();
		
		if (StrEqual(buffer, steamid)) 
		{
			kvConnectlist.Rewind();
			//kvConnectlist.Close();
			return nr; 
		}
	}
	kvConnectlist.Rewind();
	//kvConnectlist.Close();
	
	return 0;
}


/*public void AutoCapStart(int client)
{
	if (!capFightStarted)
	{
		if(passwordlock == 1)
		{
			pwchange = true;
			CPrintToChatAll("{%s}[%s] {%s}AFK Kick enabled.", prefixcolor, prefix, textcolor);
			AFKKick();
		}
		
		// count players
		capnr = GetClientCount();
		if(first12Set == 1)
		{
			if(nrhelper >= capnr)
			{
				first12Set = 2;
				tempRule = true;
			}
		}
		if(first12Set == 2)
		{
			if (capnr < 12)	capnr = 12;
		}
		nrhelper = 0;
		
		capFightStarted = true;
		capPicksLeft = (matchMaxPlayers - 1) * 2;
		
		int posnr[MAXPLAYERS+1];
		gkArray.Clear();
		dfArray.Clear();
		mfArray.Clear();
		wgArray.Clear();
		nPArray.Clear();
		
		KeyValues keygroup = new KeyValues("capPositions");
		keygroup.ImportFromFile(pathCapPositionsFile);

		for (int player = 1; player <= MaxClients; player++)
		{
			if (IsClientInGame(player) && IsClientConnected(player))
			{
				char playerSteamid[32];
				GetClientAuthId(player, AuthId_Engine, playerSteamid, sizeof(playerSteamid));
				
				noPos[player] = false;
					
				keygroup.JumpToKey(playerSteamid, true);

				int gk = keygroup.GetNum("gk", 0);
				int lb = keygroup.GetNum("lb", 0);
				int rb = keygroup.GetNum("rb", 0);
				int mf = keygroup.GetNum("mf", 0);
				int lw = keygroup.GetNum("lw", 0);
				int rw = keygroup.GetNum("rw", 0);
				int spec = keygroup.GetNum("spec", 0);
				
				//Fill arrays
				if(gk == 1)
				{
					gkArray.Push(player);
				}
				if((lb == 1 && rb == 1) || lb == 1 || rb == 1)
				{
					dfArray.Push(player);
				}
				if(mf = 1)
				{
					mfArray.Push(player);
				}
				if((lw == 1 && rw == 1) || lw == 1 || rw == 1)
				{
					wgArray.Push(player);
				}
				if(gk == 0 && lb == 0 && rb == 0 && mf == 0 && lw == 0 && rw == 0)
				{
					nPArray.Push(player);
				}
				
				posnr[player] = ImportJoinNumber(playerSteamid)
			}
		}

		//Pick Team
		PickTeams();
	}
	else CPrintToChat(client, "{%s}[%s] {%s}Cap fight already started", prefixcolor, prefix, textcolor);
}


public void PickTeams()
{
	//CoinToss for starting team
	int firstpick = GetRandomInt(2, 3);
	int secondpick, picker;
	if(firstpick == CS_TEAM_T) secondpick = CS_TEAM_CT;
	else secondpick = CS_TEAM_T;
	
	ArrayList priorityList = CreateArray(MAXPLAYERS+1);
	priorityList.ClearArray();
	
	for(int player = 0
}*/