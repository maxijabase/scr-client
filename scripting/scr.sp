#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <autoexecconfig>
#include <socket>
#include <updater>
#include <steamworks>

#tryinclude <morecolors> // Morecolors defines a max buffer as well as bytebuffer but bytebuffer does if defined check
#if !defined _colors_included
  #include <multicolors>
#endif

#include <bytebuffer>

#define PLUGIN_VERSION "1.0"
#define UPDATE_URL "https://raw.githubusercontent.com/maxijabase/scr-client/main/updatefile.txt"

char g_sHostname[64];
char g_sHost[64] = "127.0.0.1";
char g_sToken[64];
char g_sPrefix[8];

int g_iPort = 57452;
int g_iFlag;

bool g_bFlag;

// Core convars
ConVar g_cHost;
ConVar g_cPort;
ConVar g_cPrefix;
ConVar g_cFlag;
ConVar g_cHostname;

// Event convars
ConVar g_cPlayerEvent;
ConVar g_cBotPlayerEvent;
ConVar g_cMapEvent;

// Socket connection handle
Handle g_hSocket;

// Forward handles
Handle g_hMessageSendForward;
Handle g_hMessageReceiveForward;
Handle g_hEventSendForward;
Handle g_hEventReceiveForward;

EngineVersion g_evEngine;

#include "include/scr"

public Plugin myinfo = 
{
  name = "Source Chat Relay", 
  author = "Fishy, updates by ampere", 
  description = "Communicate between Discord & In-Game, monitor server without being in-game, control the flow of messages and user base engagement!", 
  version = "1.0", 
  url = "https://keybase.io/RumbleFrog"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  RegPluginLibrary("Source-Chat-Relay");
  
  CreateNative("SCR_SendMessage", Native_SendMessage);
  CreateNative("SCR_SendEvent", Native_SendEvent);
  
  return APLRes_Success;
}

public void OnPluginStart()
{
  AutoExecConfig_SetCreateFile(true);
  AutoExecConfig_SetFile("scr");
  
  AutoExecConfig_CreateConVar("scr_version", PLUGIN_VERSION, "Source Chat Relay Version", FCVAR_REPLICATED | FCVAR_SPONLY | FCVAR_DONTRECORD | FCVAR_NOTIFY);
  
  g_cHost = AutoExecConfig_CreateConVar("scr_host", "127.0.0.1", "Relay Server Host", FCVAR_PROTECTED);
  g_cPort = AutoExecConfig_CreateConVar("scr_port", "57452", "Relay Server Port", FCVAR_PROTECTED);
  g_cPrefix = AutoExecConfig_CreateConVar("scr_prefix", "", "Prefix required to send message to Discord. If empty, none is required.", FCVAR_NONE);
  g_cFlag = AutoExecConfig_CreateConVar("scr_flag", "", "If prefix is enabled, this admin flag is required to send message using the prefix", FCVAR_PROTECTED);
  g_cHostname = AutoExecConfig_CreateConVar("scr_hostname", "", "The hostname/displayname to send with messages. If left empty, it will use the server's hostname", FCVAR_NONE);
  
  AutoExecConfig_CleanFile();
  AutoExecConfig_ExecuteFile();

  // Start basic event convars
  g_cPlayerEvent = AutoExecConfig_CreateConVar("scr_event_player", "0", "Enable player connect/disconnect events", FCVAR_NONE, true, 0.0, true, 1.0);
  g_cBotPlayerEvent = AutoExecConfig_CreateConVar("scr_event_botplayer", "0", "Enable bot player connect/disconnect events", FCVAR_NONE, true, 0.0, true, 1.0);
  g_cMapEvent = AutoExecConfig_CreateConVar("scr_event_map", "0", "Enable map start/end events", FCVAR_NONE, true, 0.0, true, 1.0);
  
  AutoExecConfig(true, "Source-Server-Relay");
  
  g_hSocket = SocketCreate(SOCKET_TCP, OnSocketError);
  
  SocketSetOption(g_hSocket, SocketReuseAddr, 1);
  SocketSetOption(g_hSocket, SocketKeepAlive, 1);
  
  #if defined DEBUG
    SocketSetOption(g_hSocket, DebugMode, 1);
  #endif
  
  g_hMessageSendForward = CreateGlobalForward("SCR_OnMessageSend", ET_Event, Param_Cell, Param_String, Param_String);
  g_hMessageReceiveForward = CreateGlobalForward("SCR_OnMessageReceive", ET_Event, Param_String, Param_Cell, Param_String, Param_String, Param_String);
  g_hEventSendForward = CreateGlobalForward("SCR_OnEventSend", ET_Event, Param_String, Param_String);
  g_hEventReceiveForward = CreateGlobalForward("SCR_OnEventReceive", ET_Event, Param_String, Param_String);
  
  g_evEngine = GetEngineVersion();
  
  // Hook player connect and disconnect events separately
  HookEvent("player_connect", Event_OnPlayerConnectionChange);
  HookEvent("player_disconnect", Event_OnPlayerConnectionChange);
}

public void OnConfigsExecuted()
{
  g_cHostname.GetString(g_sHostname, sizeof g_sHostname);
  
  if (strlen(g_sHostname) == 0)
  {
    FindConVar("hostname").GetString(g_sHostname, sizeof g_sHostname);
  }
  
  g_cHost.GetString(g_sHost, sizeof g_sHost);
  g_cPrefix.GetString(g_sPrefix, sizeof g_sPrefix);
  g_iPort = g_cPort.IntValue;
  
  char flag[8];
  g_cFlag.GetString(flag, sizeof flag);
  
  if (strlen(flag) != 0)
  {
    AdminFlag adminFlag;
    g_bFlag = FindFlagByChar(flag[0], adminFlag);
    g_iFlag = FlagToBit(adminFlag);
  }
  
  int ip[4];
  SteamWorks_GetPublicIP(ip);
  char sIP[64];
  Format(sIP, sizeof sIP, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
  
  File file;
  char configPath[PLATFORM_MAX_PATH];
  BuildPath(Path_SM, configPath, sizeof configPath, "data/%s_%d.data", sIP, Server_GetPort());
  
  if (FileExists(configPath, false))
  {
    file = OpenFile(configPath, "r", false);
    file.ReadString(g_sToken, sizeof g_sToken, -1);
  } else
  {
    file = OpenFile(configPath, "w", false);
    GenerateRandomChars(g_sToken, sizeof g_sToken, 64);
    file.WriteString(g_sToken, true);
  }
  
  delete file;
  
  if (!SocketIsConnected(g_hSocket))
  {
    ConnectRelay();
    return;
  }
  
  if (g_cMapEvent.BoolValue)
  {
    char map[64];
    GetCurrentMap(map, sizeof map);
    EventMessage("Map Start", map).Dispatch();
  }
}

void ConnectRelay()
{
  if (!SocketIsConnected(g_hSocket))
  {
    SocketConnect(g_hSocket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, g_sHost, g_iPort);
  }
  else
  {
    LogMessage("Socket already connected");
  }
}

public Action Timer_Reconnect(Handle timer)
{
  ConnectRelay();
  return Plugin_Continue;
}

void StartReconnectTimer()
{
  if (SocketIsConnected(g_hSocket))
  {
    SocketDisconnect(g_hSocket);
  }
  
  CreateTimer(10.0, Timer_Reconnect);
}

public void OnSocketDisconnected(Handle socket, any arg)
{
  StartReconnectTimer();
  LogMessage("Socket disconnected");
}

public void OnSocketError(Handle socket, int errorType, int errorNum, any ary)
{
  StartReconnectTimer();
  LogError("Socket error %i (errno %i) %s", errorType, errorNum, ary);
}

public void OnSocketConnected(Handle socket, any arg)
{
  AuthenticateMessage(g_sToken).Dispatch();
  LogMessage("Socket Connected");
}

public void OnSocketReceive(Handle socket, const char[] receiveData, int dataSize, any arg)
{
  HandlePackets(receiveData, dataSize);
}

public void HandlePackets(const char[] sBuffer, int iSize)
{
  BaseMessage base = view_as<BaseMessage>(CreateByteBuffer(true, sBuffer, iSize));
  
  switch (base.Type)
  {
    case MessageChat:
    {
      ChatMessage msg = view_as<ChatMessage>(base);
      
      Action result;
      
      char entity[64];
      char id[64];
      char name[MAX_NAME_LENGTH];
      char message[MAX_COMMAND_LENGTH];
      
      msg.GetEntityName(entity, sizeof entity);
      msg.GetUsername(name, sizeof name);
      msg.GetMessage(message, sizeof message);
      
      // Strip anything beyond 3 bytes for character as chat can't render it
      StripCharsByBytes(entity, sizeof entity);
      StripCharsByBytes(name, sizeof name);
      StripCharsByBytes(message, sizeof message);
      
      Call_StartForward(g_hMessageReceiveForward);
      Call_PushString(entity);
      Call_PushCell(msg.IDType);
      Call_PushString(id);
      Call_PushStringEx(name, sizeof name, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
      Call_PushStringEx(message, sizeof message, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
      Call_Finish(result);
      
      if (result >= Plugin_Handled)
      {
        base.Close();
        return;
      }
      
      if (SupportsHexColor(g_evEngine))
      {
        CPrintToChatAll("{gold}[%s] {azure}%s{white}: {grey}%s", entity, name, message);
      }
      else
      {
        CPrintToChatAll("\x10[%s] \x0C%s\x01: \x08%s", entity, name, message);
      }
    }
    case MessageEvent:
    {
      EventMessage msg = view_as<EventMessage>(base);
      
      Action result;
      
      char event[MAX_EVENT_NAME_LENGTH];
      char data[MAX_COMMAND_LENGTH];
      
      msg.GetEvent(event, sizeof event);
      msg.GetData(data, sizeof data);
      
      // Strip anything beyond 3 bytes for character as chat can't render it
      StripCharsByBytes(event, sizeof event);
      StripCharsByBytes(data, sizeof data);
      
      Call_StartForward(g_hEventReceiveForward);
      Call_PushStringEx(event, sizeof event, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
      Call_PushStringEx(data, sizeof data, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
      Call_Finish(result);
      
      if (result >= Plugin_Handled)
      {
        base.Close();
        return;
      }
      
      if (SupportsHexColor(g_evEngine))
      {
        CPrintToChatAll("{gold}[%s]{white}: {grey}%s", event, data);
      }
      else
      {
        CPrintToChatAll("\x10[%s]\x01: \x08%s", event, data);
      }
    }
    case MessageAuthenticateResponse:
    {
      AuthenticateMessageResponse msg = view_as<AuthenticateMessageResponse>(base);
      
      if (msg.Response == AuthenticateDenied)
      {
        SetFailState("Server denied our token. Stopping.");
      }
      
      LogMessage("Successfully authenticated");
      
      // If socket wasn't connected prior, do time check see if we are close to map start
      if (GetGameTime() <= 20.0 && g_cMapEvent.BoolValue)
      {
        char map[64];
        GetCurrentMap(map, sizeof map);
        EventMessage("Map Start", map).Dispatch();
      }
    }
    default:
    {
      // They crazy
    }
  }
  
  base.Close();
}

public void Event_OnPlayerConnectionChange(Event event, const char[] name, bool dontBroadcast)
{
  bool isConnecting = StrEqual(name, "player_connect");
  
  int client;
  bool bot;
  
  if (isConnecting)
  {
    client = event.GetInt("index") + 1;
    bot = event.GetInt("bot") != 0;
  }
  else
  {
    int userid = event.GetInt("userid");
    client = GetClientOfUserId(userid);
    bot = event.GetInt("bot") != 0;
  }
  
  if (!IsValidClient(client, false) || !g_cPlayerEvent.BoolValue || (!g_cBotPlayerEvent.BoolValue && bot))
  {
    return;
  }
  
  char clientName[MAX_NAME_LENGTH];
  event.GetString("name", clientName, sizeof(clientName));
  
  if (clientName[0] == '\0')
  {
    LogMessage("Client has no name");
    return;
  }
  
  char eventType[32];
  Format(eventType, sizeof(eventType), "Player %s", isConnecting ? "Connected" : "Disconnected");
  EventMessage(eventType, clientName).Dispatch();
}

public void OnMapEnd()
{
  if (!g_cMapEvent.BoolValue)
  {
    return;
  }
  
  char map[64];
  GetCurrentMap(map, sizeof map);
  EventMessage("Map Ended", map).Dispatch();
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
  if (!IsValidClient(client))
  {
    return;
  }
  
  if (!SocketIsConnected(g_hSocket))
  {
    return;
  }
  
  if (StrEqual(g_sPrefix, ""))
  {
    DispatchMessage(client, sArgs);
  }
  else
  {
    if (g_bFlag && !CheckCommandAccess(client, "arandomcommandthatsnotregistered", g_iFlag, true))
    {
      return;
    }
    
    if (StrContains(sArgs, g_sPrefix) != 0)
    {
      return;
    }
    
    char buffer[MAX_COMMAND_LENGTH];
    
    for (int i = strlen(g_sPrefix); i < strlen(sArgs); i++)
    {
      Format(buffer, sizeof buffer, "%s%c", buffer, sArgs[i]);
    }
    
    DispatchMessage(client, buffer);
  }
}

void DispatchMessage(int client, const char[] sMessage)
{
  char id[64];
  char name[MAX_NAME_LENGTH];
  char message[MAX_COMMAND_LENGTH];
  
  Action result;
  
  strcopy(message, MAX_COMMAND_LENGTH, sMessage);
  
  if (!GetClientAuthId(client, AuthId_SteamID64, id, sizeof id))
  {
    return;
  }
  
  if (!GetClientName(client, name, sizeof name))
  {
    return;
  }
  
  Call_StartForward(g_hMessageSendForward);
  Call_PushCell(client);
  Call_PushStringEx(name, MAX_NAME_LENGTH, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
  Call_PushStringEx(message, MAX_COMMAND_LENGTH, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
  Call_Finish(result);
  
  if (result >= Plugin_Handled)
  {
    return;
  }
  
  ChatMessage(IdentificationSteam, id, name, message).Dispatch();
}

public any Native_SendMessage(Handle plugin, int numParams)
{
  if (numParams < 2)
  {
    return ThrowNativeError(SP_ERROR_NATIVE, "Insufficient parameters");
  }
  
  char buffer[512];
  int client = GetNativeCell(1);
  FormatNativeString(0, 2, 3, sizeof buffer, _, buffer);
  DispatchMessage(client, buffer);
  return;
}

public any Native_SendEvent(Handle plugin, int numParams)
{
  if (numParams < 2)
  {
    ThrowNativeError(SP_ERROR_NATIVE, "Insufficient parameters");
  }
  
  Action result;
  
  char event[MAX_EVENT_NAME_LENGTH];
  char data[MAX_COMMAND_LENGTH];
  
  GetNativeString(1, event, sizeof event);
  FormatNativeString(0, 2, 3, sizeof data, _, data);
  
  Call_StartForward(g_hEventSendForward);
  Call_PushStringEx(event, sizeof event, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
  Call_PushStringEx(data, sizeof data, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
  Call_Finish(result);
  
  if (result >= Plugin_Handled)
    return 0;
  
  EventMessage(event, data).Dispatch();
  
  return 0;
}

void GenerateRandomChars(char[] buffer, int buffersize, int len)
{
  char charset[] = "adefghijstuv6789!@#$%^klmwxyz01bc2345nopqr&+=";
  
  for (int i = 0; i < len; i++)
  Format(buffer, buffersize, "%s%c", buffer, charset[GetRandomInt(0, sizeof charset - 1)]);
}

void StripCharsByBytes(char[] sBuffer, int iSize, int iMaxBytes = 3)
{
  int iBytes;
  
  char[] sClone = new char[iSize];
  
  int i = 0;
  int j = 0;
  int iBSize = 0;
  
  while (i < iSize)
  {
    iBytes = IsCharMB(sBuffer[i]);
    
    if (iBytes == 0)
      iBSize = 1;
    else
      iBSize = iBytes;
    
    if (iBytes <= iMaxBytes)
    {
      for (int k = 0; k < iBSize; k++)
      {
        sClone[j] = sBuffer[i + k];
        j++;
      }
    }
    
    i += iBSize;
  }
  
  Format(sBuffer, iSize, "%s", sClone);
}

static int localIPRanges[] = 
{
  10 << 24,  // 10.
  127 << 24 | 1,  // 127.0.0.1
  127 << 24 | 16 << 16,  // 127.16.
  192 << 24 | 168 << 16,  // 192.168.
};

int Server_GetPort()
{
  static ConVar cvHostport;
  
  if (cvHostport == null) {
    cvHostport = FindConVar("hostport");
  }
  
  if (cvHostport == null) {
    return 0;
  }
  
  int port = cvHostport.IntValue;
  
  return port;
}

bool IsValidClient(int client, bool checkConnected = true)
{
  if (client > 4096) {
    client = EntRefToEntIndex(client);
  }
  
  if (client < 1 || client > MaxClients) {
    return false;
  }
  
  if (checkConnected && !IsClientConnected(client)) {
    return false;
  }
  
  return true;
}

bool SupportsHexColor(EngineVersion e)
{
  switch (e)
  {
    case Engine_CSS, Engine_HL2DM, Engine_DODS, Engine_TF2, Engine_Insurgency, Engine_Unknown:
    {
      return true;
    }
    default:
    {
      return false;
    }
  }
}
