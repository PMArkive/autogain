#if defined _oblivious_strafe_included
 #endinput
#endif
#define _oblivious_strafe_included

native void set_autogain(int client, bool value);
native bool get_autogain(int client);
native void set_prestrafe(int client, bool value);
native bool get_prestrafe(int client);

native void set_tas_mode(int client, int value);
