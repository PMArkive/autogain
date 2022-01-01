#pragma semicolon 1

#define DEBUG

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <oblivioustrafe>
#include <kid_tas_api>
#include <convar_class>
#include <dhooks>

#pragma newdecls required

ConVar sv_air_accelerate;
ConVar sv_accelerate;
ConVar sv_friction;
ConVar sv_stopspeed;
int surface_friction_offs;

bool ag_enabled[MAXPLAYERS + 1];
bool psh_enabled[MAXPLAYERS + 1];
bool no_speed_loss[MAXPLAYERS + 1];

float g_fMaxMove = 400.0;
float g_flAirSpeedCap = 30.0;
EngineVersion g_Game;
bool g_bTASEnabled;

Convar g_ConVar_AutoFind_Offset;

public Plugin myinfo =
{
	name = "Autogain",
	author = "oblivious",
	description = "",
	version = "1.2",
	url = "https://steamcommunity.com/id/defiy/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("oblivious-strafe");
	return APLRes_Success;
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "kid-tas"))
	{
		g_bTASEnabled = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "kid-tas"))
	{
		g_bTASEnabled = false;
	}
}

public void OnPluginStart()
{
	CreateNative("set_autogain", native_set_autogain);
	CreateNative("get_autogain", native_get_autogain);
	CreateNative("set_prestrafe", native_set_prestrafe);
	CreateNative("get_prestrafe", native_get_prestrafe);
	CreateNative("set_tas_mode", native_set_tas_mode);

	g_Game = GetEngineVersion();
	sv_air_accelerate = FindConVar("sv_airaccelerate");
	sv_accelerate = FindConVar("sv_accelerate");
	sv_friction = FindConVar("sv_friction");
	sv_stopspeed = FindConVar("sv_stopspeed");

	GameData gamedata = new GameData("KiD-TAS.games");

	surface_friction_offs = gamedata.GetOffset("m_surfaceFriction");
	delete gamedata;

	if(surface_friction_offs == -1)
	{
		LogError("[XUTAX] Invalid offset supplied, defaulting friction values");
	}
	if(g_Game == Engine_CSGO)
	{
		g_fMaxMove = 450.0;
		ConVar sv_air_max_wishspeed = FindConVar("sv_air_max_wishspeed");
		sv_air_max_wishspeed.AddChangeHook(OnWishSpeedChanged);
		g_flAirSpeedCap = sv_air_max_wishspeed.FloatValue;
		if(surface_friction_offs != -1)
		{
			surface_friction_offs = FindSendPropInfo("CBasePlayer", "m_ubEFNoInterpParity") - surface_friction_offs;
		}
	}
	else if(g_Game == Engine_CSS)
	{
		if(surface_friction_offs != -1)
		{
			surface_friction_offs += FindSendPropInfo("CBasePlayer", "m_szLastPlaceName");
		}
	}
	else
	{
		SetFailState("This plugin is for CSGO/CSS only.");
	}

	load_dhooks();

	RegAdminCmd("sm_xutax_scan", Command_ScanOffsets, ADMFLAG_CHEATS, "Scan for possible offset locations");

	g_ConVar_AutoFind_Offset = new Convar("xutax_find_offsets", "1", "Attempt to autofind offsets", _, true, 0.0, true, 1.0);

	Convar.AutoExecConfig();
}

// doesn't exist in css so we have to cache the value
public void OnWishSpeedChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_flAirSpeedCap = StringToFloat(newValue);
}

public void OnClientConnected(int client)
{
	ag_enabled[client] = false;
}

float normalize_yaw(float _yaw)
{	
	while (_yaw > 180.0) _yaw -= 360.0;
	while (_yaw < -180.0) _yaw += 360.0; return _yaw;
}

float get_length_2d(float vec[3]) 
{
	return SquareRoot(vec[0] * vec[0] + vec[1] * vec[1]);
}

float ground_delta_opt(int client, float angles[3], float move[3])
{
	float fore[3], side[3], wishvel[3];
	float wishspeed;

	GetAngleVectors(angles, fore, side, NULL_VECTOR);

	fore[2] = 0.0;
	side[2] = 0.0; 
	NormalizeVector(fore, fore);
	NormalizeVector(side, side);
	
	wishvel[2] = 0.0;
	for(int i = 0; i < 2; i++)
		wishvel[i] = fore[i] * move[0] + side[i] * move[1];

	wishspeed = GetVectorLength(wishvel);

	if(wishspeed > GetEntPropFloat(client, Prop_Send, "m_flMaxspeed") && GetEntPropFloat(client, Prop_Send, "m_flMaxspeed") != 0.0) wishspeed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");

	float velocity[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
	float speed = GetVectorLength(velocity);

	float surface_friction = 1.0;
	if(surface_friction_offs > 0) surface_friction = GetEntDataFloat(client, surface_friction_offs);

	float accelerate = sv_accelerate.FloatValue;
	float friction = sv_friction.FloatValue;
	float stopspeed = sv_stopspeed.FloatValue;

	float interval_per_tick = GetTickInterval();

	float accelspeed = accelerate * wishspeed * interval_per_tick * surface_friction;
	
	float control = speed;
	if (control < stopspeed) control = stopspeed;
	float drop = control * friction * interval_per_tick * surface_friction;

	float newspeed = speed - drop;
	if (newspeed < 0.0) newspeed = 0.0;

	float tmp = wishspeed - accelspeed;
 
	if (tmp <= newspeed)
	{
		float gamma = RadToDeg(ArcCosine(tmp / newspeed));
		float vel_dir_ang = RadToDeg(ArcTangent2(velocity[1], velocity[0]));

		vel_dir_ang = normalize_yaw(vel_dir_ang);

		float accel_yaw = RadToDeg(ArcTangent2(wishvel[1], wishvel[0]));

		float diffm = vel_dir_ang - gamma;
		float diffp = vel_dir_ang + gamma;

		diffm = normalize_yaw(diffm - accel_yaw);
		diffp = normalize_yaw(diffp - accel_yaw);

		float delta_opt = 0.0;
		if (FloatAbs(diffm) <= FloatAbs(diffp))
			delta_opt = -diffm;
		else
			delta_opt = -diffp;
		delta_opt = normalize_yaw(delta_opt);

		return delta_opt;
	}

	return 0.0;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if((!ag_enabled[client] && !psh_enabled[client]))
	{
		return Plugin_Continue;
	}

	if(!ShouldProcessFrame(client))
	{
		return Plugin_Continue;
	}

	if (GetEntityMoveType(client) == MOVETYPE_NOCLIP || GetEntityMoveType(client) == MOVETYPE_LADDER || !(GetEntProp(client, Prop_Data, "m_nWaterLevel") <= 1))
		return Plugin_Continue;
	
	static int on_ground_count[MAXPLAYERS+1] = {1, ...};

	if(GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") != -1)
		on_ground_count[client]++;
	else
		on_ground_count[client] = 0;

	if (on_ground_count[client] > 1)
	{
		if (psh_enabled[client] && (vel[0] != 0.0 || vel[1] != 0.0))
		{
			float _delta_opt = ground_delta_opt(client, angles, vel);

			float _tmp[3]; _tmp[0] = angles[0]; _tmp[2] = angles[2];
			_tmp[1] = normalize_yaw(angles[1] - _delta_opt);

			angles[1] = _tmp[1];
			float _velocity[3];
			GetEntPropVector(client, Prop_Data, "m_vecVelocity", _velocity);
		}

		return Plugin_Continue;
	}

	if(!ag_enabled[client])// || vel[0] < 0.0)
	{
		return Plugin_Continue;
	}

	bool set_back = true;
	if (vel[0] != 0.0 || vel[1] != 0.0)
		set_back = false;
	if (set_back) 
		vel[1] = g_fMaxMove;

	float air_accelerate = sv_air_accelerate.FloatValue;
	float surface_friction = surface_friction_offs > 0 ? GetEntDataFloat(client, surface_friction_offs) : 1.0;

	float velocity[3], velocity_opt[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);

	velocity_opt[0] = velocity[0]; velocity_opt[1] = velocity[1]; velocity_opt[2] = velocity[2];

	float vel_yaw = ArcTangent2(velocity[1], velocity[0]) * 180.0 / FLOAT_PI;

	float delta_opt = -normalize_yaw(angles[1] - vel_yaw);

	if (vel[0] != 0.0 && vel[1] == 0.0) 
	{
		float sign = vel[0] > 0.0 ? -1.0 : 1.0;
		delta_opt = -normalize_yaw(angles[1] - (vel_yaw + (90.0 * sign)));
	}
	if (vel[0] != 0.0 && vel[1] != 0.0)
	{
		float sign = vel[1] > 0.0 ? -1.0 : 1.0;
		if (vel[0] < 0.0) 
			sign = -sign;
		delta_opt = -normalize_yaw(angles[1] - (vel_yaw + (45.0 * sign)));
	}
	
	float _addspeed = 0.0;
	if (!set_back)
	{
		float _fore[3], _side[3], _wishvel[3], _wishdir[3];
		float _wishspeed, _wishspd, _currentspeed;
	
		GetAngleVectors(angles, _fore, _side, NULL_VECTOR);
	
		_fore[2] = 0.0; _side[2] = 0.0;
		NormalizeVector(_fore, _fore); NormalizeVector(_side, _side);
	
		for(int i = 0; i < 2; i++)
			_wishvel[i] = _fore[i] * vel[0] + _side[i] * vel[1];

		_wishspeed = NormalizeVector(_wishvel, _wishdir);

		if(_wishspeed > GetEntPropFloat(client, Prop_Send, "m_flMaxspeed") && GetEntPropFloat(client, Prop_Send, "m_flMaxspeed") != 0.0) _wishspeed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");

		_wishspd = _wishspeed;
		if (_wishspd > g_flAirSpeedCap)
			_wishspd = g_flAirSpeedCap;

		_currentspeed = GetVectorDotProduct(velocity, _wishdir);
		_addspeed = _wishspd - _currentspeed;
		if (_addspeed < 0.0) 
			_addspeed = 0.0;
	}
	
	float fore[3], side[3], wishvel[3], wishdir[3];
	float wishspeed, wishspd, addspeed, currentspeed;
	
	float tmp[3];
	tmp[0] = 0.0; tmp[2] = 0.0;
	tmp[1] = normalize_yaw(angles[1] + delta_opt);
	GetAngleVectors(tmp, fore, side, NULL_VECTOR);
	
	fore[2] = 0.0; side[2] = 0.0;
	NormalizeVector(fore, fore); NormalizeVector(side, side);
	
	for(int i = 0; i < 2; i++)
		wishvel[i] = fore[i] * vel[0] + side[i] * vel[1];
	
	wishspeed = NormalizeVector(wishvel, wishdir);

	if(wishspeed > GetEntPropFloat(client, Prop_Send, "m_flMaxspeed") && wishspeed != 0.0) wishspeed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");

	wishspd = wishspeed;
	if (wishspd > g_flAirSpeedCap)
		wishspd = g_flAirSpeedCap;

	currentspeed = GetVectorDotProduct(velocity, wishdir);
	addspeed = wishspd - currentspeed;

	//if (_addspeed != 0.0 && addspeed != 0.0 && no_speed_loss[client])
	//{		
	//	if (addspeed > _addspeed) addspeed = addspeed - _addspeed;
	//	else if (_addspeed >= addspeed) addspeed = _addspeed - addspeed;
	//}

	if (no_speed_loss[client])
	{
		if (_addspeed > addspeed)
		{
			addspeed = _addspeed - addspeed;
		}
		else
		{
			addspeed -= _addspeed;
		}
	}
	else
	{
		addspeed = addspeed - _addspeed;

		if (addspeed > 30.0)
			addspeed = 30.0;
	}

	if (buttons & IN_DUCK)
	{
		float vel2d[3]; vel2d[0] = velocity[0]; vel2d[1] = velocity[1];
		//PrintToChat(client, "%f %f\n", GetVectorLength(vel2d), addspeed);
	}

	if (addspeed < 0.0)
		addspeed = 0.0;

	float accelspeed = wishspeed * air_accelerate * GetTickInterval() * surface_friction;

	if (accelspeed > addspeed)
		accelspeed = addspeed;

	for (int i = 0; i < 3; i++)
		velocity_opt[i] += accelspeed * wishdir[i];

	float new_vel[3];

	float numer = velocity_opt[0] * velocity[0] + velocity_opt[1] * velocity[1];
	float denom = SquareRoot(velocity_opt[0] * velocity_opt[0] + velocity_opt[1] * velocity_opt[1]) * SquareRoot(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
	float ang = 0.0;
	if (denom > numer)
		ang = ArcCosine(numer / denom) * 180.0 / FLOAT_PI;
	if (vel[1] < 0.0) ang = -ang;

	float st = Sine(ang * FLOAT_PI / 180.0);
	float ct = Cosine(ang * FLOAT_PI / 180.0);

	new_vel[0] = (velocity_opt[0] * ct) - (velocity_opt[1] * st);
	new_vel[1] = (velocity_opt[0] * st) + (velocity_opt[1] * ct);
	new_vel[2] = velocity_opt[2];

	float base_vel[3];
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", base_vel);

	//PrintToChat(client, "%.2f, %.2f, %.2f", base_vel[0], base_vel[1], base_vel[2]);
	
	// +0.005 to 0.1 
	//float diff = get_length_2d(new_vel) - get_length_2d(velocity_opt); 

	if (GetVectorLength(new_vel) < 99999.0 && GetVectorLength(new_vel) > 0.0)
	{
		SetEntPropVector(client, Prop_Data, "m_vecVelocity", new_vel);

		float _new_vel[3];
		for (int i = 0; i < 3; i++)
			_new_vel[i] = new_vel[i] + base_vel[i];

		SetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", _new_vel); // m_vecBaseVelocity+m_vecVelocity
		SetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", base_vel);
	}

	SetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", base_vel);

	if (set_back)
		vel[1] = 0.0;

	return Plugin_Continue;
}

public MRESReturn process_movement_hk(Handle h_params)
{
	int client = DHookGetParam(h_params, 1);
	//int b = view_as<Address>(DHookGetParam(h_params, 3));

	//PrintToChat(client, "%i\n", b);
	
	return MRES_Handled;
}

void load_dhooks()
{
	GameData gamedata = new GameData("shavit.games");
	//Address addr = gamedata.GetAddress("CategorizePosition");

	if(gamedata == null)
	{
		SetFailState("Failed to load gamedata");
	}
	
	StartPrepSDKCall(SDKCall_Static);
	if(!PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CreateInterface"))
	{
		SetFailState("Failed to get CreateInterface");
	}
	
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle CreateInterface = EndPrepSDKCall();

	if(CreateInterface == null)
	{
		SetFailState("Unable to prepare SDKCall for CreateInterface");
	}

	char interfaceName[64];
	if(!GameConfGetKeyValue(gamedata, "IGameMovement", interfaceName, sizeof(interfaceName)))
	{
		SetFailState("Failed to get IGameMovement interface name");
	}

	Address IGameMovement = SDKCall(CreateInterface, interfaceName, 0);
	if(!IGameMovement)
	{
		SetFailState("Failed to get IGameMovement pointer");
	}

	int offset = GameConfGetOffset(gamedata, "ProcessMovement");
	if(offset == -1)
	{
		SetFailState("Failed to get ProcessMovement offset");
	}

	Handle process_movement = DHookCreate(offset, HookType_Raw, ReturnType_Void, ThisPointer_Ignore, process_movement_hk);
	DHookAddParam(process_movement, HookParamType_CBaseEntity);
	DHookAddParam(process_movement, HookParamType_ObjectPtr);
	DHookRaw(process_movement, false, IGameMovement);

	delete CreateInterface;
	delete gamedata;
}

stock void FindNewFrictionOffset(int client, bool logOnly = false)
{
	if(g_Game == Engine_CSGO)
	{
		int startingOffset = FindSendPropInfo("CBasePlayer", "m_ubEFNoInterpParity");
		for(int i = 16; i >= -128; --i)
		{
			float friction = GetEntDataFloat(client, startingOffset + i);
			if(friction == 0.25 || friction == 1.0)
			{
				if(logOnly)
				{
					PrintToConsole(client, "Found offset canidate: %i", i * -1);
				}
				else
				{
					surface_friction_offs = startingOffset - i;
					LogError("[XUTAX] Current offset is out of date. Please update to new offset: %i", i * -1);
				}
			}
		}
	}
	else
	{
		int startingOffset = FindSendPropInfo("CBasePlayer", "m_szLastPlaceName");
		for(int i = 1; i <= 128; ++i)
		{
			float friction = GetEntDataFloat(client, startingOffset + i);
			if(friction == 0.25 || friction == 1.0)
			{
				if(logOnly)
				{
					PrintToConsole(client, "Found offset canidate: %i", i);
				}
				else
				{
					surface_friction_offs = startingOffset + i;
					LogError("[XUTAX] Current offset is out of date. Please update to new offset: %i", i);
				}
			}
		}
	}
}

public Action Command_ScanOffsets(int client, int args)
{
	FindNewFrictionOffset(client, .logOnly = true);

	return Plugin_Handled;
}

// natives
public any native_set_autogain(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool value = GetNativeCell(2);
	ag_enabled[client] = value;
	return 0;
}

public any native_get_autogain(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return ag_enabled[client];
}

public any native_set_prestrafe(Handle plugin, int num_params)
{
	int client = GetNativeCell(1);
	bool value = GetNativeCell(2);
	psh_enabled[client] = value;
	return 0;
}

public any native_get_prestrafe(Handle plugin, int num_params)
{
	int client = GetNativeCell(1);
	return psh_enabled[client];
}

public any native_set_tas_mode(Handle plugin, int num_params)
{
	int client = GetNativeCell(1);
	bool value = GetNativeCell(2);

	no_speed_loss[client] = value;
	return 0;
}

public bool TRFilter_NoPlayers(int entity, int mask, any data)
{
	return (entity != view_as<int>(data) || (entity < 1 || entity > MaxClients));
}

stock bool ShouldProcessFrame(int client)
{
	if(g_bTASEnabled)
	{
		if(TAS_Enabled(client))
		{
			return TAS_ShouldProcessFrame(client);
		}
	}

	return true;
}
