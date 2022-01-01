#include <sourcemod>
#include <oblivioustrafe>
#include <shavit>

public void Shavit_OnStyleChanged(int client, int oldstyle, int newstyle, int track, bool manual)
{
	//"oblivious-tas"
	//"oblivious-tasnorm"
	//"oblivious-tasnsl"

	char special[128];
	Shavit_GetStyleStrings(newstyle, sSpecialString, special, 128);

	if (StrContains(special, "tas-obliv") != -1)
	{
		set_autogain(client, true);
		set_prestrafe(client, true);
		set_tas_mode(client, 0);
	}
	else if (StrContains(special, "tasnsl-obliv") != -1)
	{
		set_autogain(client, true);
		set_prestrafe(client, true);
		set_tas_mode(client, 1);
	}
	else 
	{
		set_autogain(client, false);
		set_prestrafe(client, false);
		set_tas_mode(client, 0);
	}

	/*if(StrContains(special, "xutax") != -1)
	{
		set_autogain(client, true);
		set_prestrafe(client, true);
	}
	else
	{
		SetXutaxStrafe(client, false);
		set_prestrafe(client, false)
	}*/
}