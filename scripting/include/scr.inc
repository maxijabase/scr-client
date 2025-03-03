#if defined _scr_included
#endinput
#endif
#define _scr_included

#if !defined MAX_EVENT_NAME_LENGTH
#define MAX_EVENT_NAME_LENGTH 128
#endif

#if !defined MAX_COMMAND_LENGTH
#define MAX_COMMAND_LENGTH 512
#endif

enum MessageType
{
  MessageInvalid = 0, 
  MessageAuthenticate, 
  MessageAuthenticateResponse, 
  MessageChat, 
  MessageEvent, 
  MessageTypeCount, 
}

enum AuthenticateResponse
{
  AuthenticateInvalid = 0, 
  AuthenticateSuccess, 
  AuthenticateDenied, 
  AuthenticateResponseCount, 
}

enum IdentificationType
{
  IdentificationInvalid = 0, 
  IdentificationSteam, 
  IdentificationDiscord, 
  IdentificationTypeCount, 
}

/**
 * Base message structure
 * 
 * @note The type is declared on every derived message type
 * 
 * @field type - byte - The message type (enum MessageType)
 * @field EntityName - string - Entity name that's sending the message
 */
methodmap BaseMessage < ByteBuffer
{
  public BaseMessage()
  {
    return view_as<BaseMessage>(CreateByteBuffer());
  }
  
  property MessageType Type
  {
    public get()
    {
      MessageType tByte = view_as<MessageType>(this.ReadByte());
      
      return tByte >= MessageTypeCount ? MessageInvalid : tByte;
    }
  }
  
  public int ReadDiscardString()
  {
    char cByte;
    
    for (int i = 0; i < MAX_BUFFER_LENGTH; i++) {
      cByte = this.ReadByte();
      
      if (cByte == '\0') {
        return i + 1;
      }
    }
    
    return MAX_BUFFER_LENGTH;
  }
  
  public void DataCursor()
  {
    // Skip the message type field
    this.Cursor = 1;
    
    this.ReadDiscardString();
  }
  
  public void GetEntityName(char[] sEntityName, int iSize)
  {
    // Skip the message type field
    this.Cursor = 1;
    
    this.ReadString(sEntityName, iSize);
  }
  
  public void WriteEntityName() {
    this.WriteString(g_sHostname);
  }
  
  public void Dispatch()
  {
    char sDump[MAX_BUFFER_LENGTH];
    
    int iLen = this.Dump(sDump, MAX_BUFFER_LENGTH);
    
    this.Close();
    
    if (!SocketIsConnected(g_hSocket))
      return;
    
    // Len required
    // If len is not included, it will stop at the first \0 terminator
    SocketSend(g_hSocket, sDump, iLen);
  }
}

/**
 * Should only sent by clients
 * 
 * @field Token - string - The authentication token
 */
methodmap AuthenticateMessage < BaseMessage
{
  public int GetToken(char[] sToken, int iSize)
  {
    this.DataCursor();
    
    return this.ReadString(sToken, iSize);
  }
  
  public AuthenticateMessage(const char[] sToken)
  {
    BaseMessage m = BaseMessage();
    
    m.WriteByte(view_as<int>(MessageAuthenticate));
    m.WriteEntityName();
    
    m.WriteString(sToken);
    
    return view_as<AuthenticateMessage>(m);
  }
}

/**
 * This message is only received from the server
 * 
 * @field Response - byte - The state of the authentication request (enum AuthenticateResponse)
 */
methodmap AuthenticateMessageResponse < BaseMessage
{
  property AuthenticateResponse Response
  {
    public get()
    {
      this.DataCursor();
      
      AuthenticateResponse tByte = view_as<AuthenticateResponse>(this.ReadByte());
      
      return tByte >= AuthenticateResponseCount ? AuthenticateInvalid : tByte;
    }
  }
}

/**
 * Bi-directional messaging structure
 * 
 * @field IDType - byte - Type of ID (enum IdentificationType)
 * @field ID - string - The unique identification of the user (SteamID/Discord Snowflake/etc)
 * @field Username - string - The name of the user
 * @field Message - string - The message
 */
methodmap ChatMessage < BaseMessage
{
  property IdentificationType IDType
  {
    public get()
    {
      this.DataCursor();
      
      IdentificationType tByte = view_as<IdentificationType>(this.ReadByte());
      
      return tByte >= IdentificationTypeCount ? IdentificationInvalid : tByte;
    }
  }
  
  public int GetUserID(char[] sID, int iSize)
  {
    this.DataCursor();
    
    // Skip ID type
    this.Cursor++;
    
    return this.ReadString(sID, iSize);
  }
  
  public int GetUsername(char[] sUsername, int iSize)
  {
    this.DataCursor();
    
    // Skip ID type
    this.Cursor++;
    
    // Skip UserID
    this.ReadDiscardString();
    
    return this.ReadString(sUsername, iSize);
  }
  
  public int GetMessage(char[] sMessage, int iSize)
  {
    this.DataCursor();
    
    // Skip ID type
    this.Cursor++;
    
    // Skip UserID
    this.ReadDiscardString();
    
    // Skip Name
    this.ReadDiscardString();
    
    return this.ReadString(sMessage, iSize);
  }
  
  public ChatMessage(
    IdentificationType IDType, 
    const char[] sUserID, 
    const char[] sUsername, 
    const char[] sMessage)
  {
    BaseMessage m = BaseMessage();
    
    m.WriteByte(view_as<int>(MessageChat));
    m.WriteEntityName();
    
    m.WriteByte(view_as<int>(IDType));
    m.WriteString(sUserID);
    m.WriteString(sUsername);
    m.WriteString(sMessage);
    
    return view_as<ChatMessage>(m);
  }
}

/**
 * Bi-directional event data
 * 
 * @field Event - string - The name of the event
 * @field Data - string - The data of the event
 */
methodmap EventMessage < BaseMessage
{
  public int GetEvent(char[] sEvent, int iSize)
  {
    this.DataCursor();
    
    return this.ReadString(sEvent, iSize);
  }
  
  public int GetData(char[] sData, int iSize)
  {
    this.DataCursor();
    
    // Skip event string
    this.ReadDiscardString();
    
    return this.ReadString(sData, iSize);
  }
  
  public EventMessage(const char[] sEvent, const char[] sData)
  {
    BaseMessage m = BaseMessage();
    
    m.WriteByte(view_as<int>(MessageEvent));
    m.WriteEntityName();
    
    m.WriteString(sEvent);
    m.WriteString(sData);
    
    return view_as<EventMessage>(m);
  }
}

/**
 * Called upon sending a message via chat triggers
 * 
 * @param iClient 		Index of client that is sending the message
 * @param sClientName	Name of the client sending the message. The size of which is MAX_NAME_LENGTH
 * @param sMessage		Message content. The size of which is MAX_COMMAND_LENGTH
 */
forward Action SCR_OnMessageSend(int iClient, char[] sClientName, char[] sMessage);

/**
 * Called upon receiving a message
 * 
 * @param sEntityName	Entity name/hostname of the sending client
 * @param iIDType 		The IdentificationType of the ID
 * @param sID			String variant of the ID
 * @param sClientName	Name of the client that sent the message. The size of which is MAX_NAME_LENGTH
 * @param sMessage		Message content. The size of which is MAX_COMMAND_LENGTH
 */
forward Action SCR_OnMessageReceive(const char[] sEntityName, IdentificationType iIDType, const char[] sID, char[] sClientName, char[] sMessage);

/**
 * Called upon sending an event
 * 
 * @param sEvent		Name of the event. The size of which is MAX_EVENT_NAME_LENGTH
 * @param sData			Data of the event. The size of which is MAX_COMMAND_LENGTH
 */
forward Action SCR_OnEventSend(char[] sEvent, char[] sData);

/**
 * Called upon receiving an event
 * 
 * @param sEvent		Name of the event. The size of which is MAX_EVENT_NAME_LENGTH
 * @param sData			Data of the event. The size of which is MAX_COMMAND_LENGTH
 */
forward Action SCR_OnEventReceive(char[] sEvent, char[] sData);

/**
 * Sends a message to the router
 * 
 * @param iClient   Client ID to use as name display (If left at 0, it will display "CONSOLE")
 * @param fmt       Format string
 * @param ...       Format arguments
 */
native void SCR_SendMessage(int iClient = 0, const char[] fmt, any...);

/**
 * Sends an event to the router
 * 
 * @param sEvent	Name of the event
 * @param sData		Data format string
 * @param ...		Format arguments
 */
native void SCR_SendEvent(const char[] sEvent, const char[] sData, any...);

#if !defined REQUIRE_PLUGIN
public __pl_scr_SetNTVOptional()
{
  MarkNativeAsOptional("SCR_SendMessage");
  MarkNativeAsOptional("SCR_SendEvent");
}
#endif

public SharedPlugin __pl_scr = 
{
  name = "scr", 
  file = "scr.smx", 
  #if defined REQUIRE_PLUGIN
  required = 1, 
  #else
  required = 0, 
  #endif
};
