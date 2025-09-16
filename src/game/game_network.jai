NET_DEFAULT_SEVER_PORT :: 50523;
NET_MAGIC_VALUE :: 0xfda0;
NET_CLIENT_MAX_SNAPSHOTS :: TICK_RATE;
NET_MAX_ACTION_COUNT :: TICK_RATE/8;
NET_MAX_PLAYERS :: 10;
NET_MAX_PACKET_SIZE :: 1200;
NET_MAX_PAYLOAD_SIZE :: NET_MAX_PACKET_SIZE - size_of(NET_PacketHeader);
NET_SIMULATE_PACKETLOSS :: 0; // doesn't seem to work on localhost
NET_INACTIVE :: 0.1;
NET_TIMEOUT_DISCONNECT :: 0.5;

NET_State :: struct
{
  err: bool; // tracks if network is in error state
  is_server: bool;
  socket: *SDLNet_DatagramSocket;

  server_user: NET_User;

  // msg payload
  packet_err: bool; // set on internal buffer overflow errors etc
  packet_header: NET_PacketHeader;
  packet_payload_buf: [1024 * 1024 * 1] u8; // 1 MB scratch buffer for network payload construction
  payload_used: u32;
};


// @impl
LOG_NetInfo :: 0;
LOG_NetDatagram :: 1;
LOG_NetPacket :: 2;
LOG_NetPayload :: 3;
LOG_NetClient :: 4;
LOG_NetCatchup :: 5;
LOG_NetTick :: 6;
LOG_NetSend :: 7;
LOG_Important :: 8;

Nlog :: (net_category: s64 /* @todo use user flags instead in the future */, format_string: string, args: .. Any, loc := #caller_location, flags := Log_Flags.NONE, user_flags : u32 = 0, section : *Log_Section = null)
{
  if net_category != LOG_NetPacket return;
  // @todo do something with net_category and logging in general
  // @todo add "NET_Label()" before every net log?, or do that for logs globally
  log(ifx G.net.is_server then "[SERVER]" else "[CLIENT]");
  log(format_string, ..args, loc, flags, user_flags, section);
} @PrintLike

NET_User :: struct
{
  address: *SDLNet_Address;
  port: u16;
  last_msg_timestamp: Timestamp;
};

NET_SendKind :: enum u32
{
  None;
  Ping :: 10000;
  ObjUpdate;
  ObjEmpty;
  NetworkTest;
  Actions;
  AssignPlayerKey;
  WindowLayout;
};

NET_SendHeader :: struct
{
  tick: Tick; // this is already send via packet header
  kind: NET_SendKind;
};

NET_SendActions :: struct
{
  actions: [NET_MAX_ACTION_COUNT] Action;
};

NET_SendPing :: struct
{
  number: u64;
};

NET_SendObjSync :: struct
{
  net_index: u32;
  sync: OBJ_Sync;
};

NET_SendObjEmpty :: struct
{
  net_index: u32;
};

NET_SendAssignPlayerKey :: struct
{
  player_key: OBJ_Key;
};

NET_SendWindowLayout :: struct
{
  user_count: u32;
  px, py, w, h: s32;
};

NET_PacketHeader :: struct
{
  magic_value: u16; // use this as seed for hash calculation instead
  payload_hash: u16;
};

NET_Init :: ()
{
  is_server := G.net.is_server;
  is_client := !G.net.is_server;

  Nlog(LOG_NetInfo, ifx is_server then "Launching as server" else "Launching as client");

  if is_client
  {
    hostname := "localhost";
    Nlog(LOG_NetInfo, "Resolving server hostname '%s' ...", hostname);
    G.net.server_user.address = SDLNet_ResolveHostname(temp_c_string(hostname));
    G.net.server_user.port = NET_DEFAULT_SEVER_PORT;
    if G.net.server_user.address
    {
      if SDLNet_WaitUntilResolved(G.net.server_user.address, -1) < 0
      {
        SDLNet_UnrefAddress(G.net.server_user.address);
        G.net.server_user.address = null;
      }
    }

    if !G.net.server_user.address
    {
      G.net.err = true;
      Nlog(LOG_NetInfo, "Failed to resolve server hostname '%s'", hostname);
    }
  }

  port: u16 = xx ifx is_server then NET_DEFAULT_SEVER_PORT else 0;
  G.net.socket = SDLNet_CreateDatagramSocket(null, port);
  if !G.net.socket
  {
    G.net.err = true;
    Nlog(LOG_NetInfo, "Failed to create socket");
  }
  else
  {
    Nlog(LOG_NetInfo, "Created socket");

    #if NET_SIMULATE_PACKETLOSS
    {
      SDLNet_SimulateDatagramPacketLoss(G.net.socket, NET_SIMULATE_PACKETLOSS);
      Nlog(LOG_NetInfo, "%s: Simulating packetloss: %d", NET_SIMULATE_PACKETLOSS);
    }
  }
}

NET_HackyRatelimitting :: (last_accepted: *Timestamp, minimal_delay_seconds: float) -> bool
{
  if ElapsedSeconds(last_accepted.*) < 0.008 return true;
  last_accepted.* = GetTimestamp(.FRAME);
  return false;
}

NET_PayloadAlloc :: (size: u32) -> *u8
{
  buf_start := G.net.packet_payload_buf.data;

  if G.net.payload_used + size > G.net.packet_payload_buf.count
  {
    assert(false);
    G.net.packet_err = true;
    return buf_start;
  }

  result := buf_start + G.net.payload_used;
  G.net.payload_used += size;
  return result;
}

NET_PayloadMemcpy :: (data: *void, size: u32) -> *u8
{
  result := NET_PayloadAlloc(size);
  memcpy(result, data, size);
  return result;
}

NET_PayloadAppendType :: (value: $T)
{
  NET_PayloadMemcpy(*value, size_of(T));
}

NET_RecalculatePacketHeader :: ()
{
  using G.net;
  payload := string.{payload_used, packet_payload_buf.data};
  packet_header.magic_value = NET_MAGIC_VALUE;
  packet_header.payload_hash = Hash64Any(payload).(u16, trunc);
}

NET_GetPacketString :: () -> string
{
  // there should be no padding between these
  #assert(offset_of(NET_State, "packet_header") + size_of(type_of(G.net.packet_header)) == offset_of(NET_State, "packet_payload_buf"));

  total_size := size_of(type_of(G.net.packet_header)) + G.net.payload_used;
  result := string.{total_size, (*G.net.packet_header).(*u8)};
  return result;
}

NET_UserIsInactive :: (user: NET_User) -> bool
{
  return ElapsedSeconds(user.last_msg_timestamp) > NET_INACTIVE;
}

NET_SendString :: (destination: NET_User, msg: string)
{
  assert(msg.count < 1280); // that seems to be a realistic reasonable max size? https://gafferongames.com/post/packet_fragmentation_and_reassembly/

  if G.net.is_server && NET_UserIsInactive(destination)
    return;

  send_res := SDLNet_SendDatagram(G.net.socket, destination.address, destination.port, msg.data, xx msg.count);
  if !send_res
  {
    Nlog(LOG_NetSend, "Sending buffer of size %lluB to %s:%d; %s",
        msg.count, to_string(SDLNet_GetAddressString(destination.address)),
        destination.port, ifx send_res then "success" else "fail");
  }
}

NET_PacketSendAndResetPayload :: (destination: NET_User)
{
  NET_RecalculatePacketHeader();
  packet := NET_GetPacketString();
  NET_SendString(destination, packet);
  G.net.payload_used = 0;
}

NET_PacketSendAndResetPayloadToServer :: ()
{
  if NET_IsClient()
  {
    NET_RecalculatePacketHeader();
    packet := NET_GetPacketString();
    NET_SendString(G.net.server_user, packet);
    G.net.payload_used = 0;
  }
}

NET_PacketSendAndResetPayloadBroadcast :: ()
{
  if G.net.is_server
  {
    NET_RecalculatePacketHeader();
    packet := NET_GetPacketString();

    for G.server.users
    {
      if !it.net.address continue;
      NET_SendString(it.net, packet);
    }
    G.net.payload_used = 0;
  }
}

NET_RemoveUser :: (user: *NET_User)
{
  SDLNet_UnrefAddress(user.address);
  user.* = .{};
}

NET_UserMatch :: (a: *NET_User, b: *NET_User) -> bool
{
  return (a.port == b.port && SDLNet_CompareAddresses(a.address, b.address) == 0);
}

NET_UserMatchAddrPort :: (user: NET_User, address: *SDLNet_Address, port: u16) -> bool
{
  if (!user.address)
    return false;

  return (user.port == port && SDLNet_CompareAddresses(user.address, address) == 0);
}

NET_FindUser :: (address: *SDLNet_Address, port: u16) -> *SERVER_UserState
{
  // @todo move to SV_ prefix?
  for *G.server.users
  {
    if (NET_UserMatchAddrPort(it.net, address, port))
      return it;
  }
  return null;
}

NET_AddUser :: (address: *SDLNet_Address, port: u16) -> *SERVER_UserState
{
  // @todo move to SV_ prefix?
  new_user_slot: *SERVER_UserState;
  for *G.server.users
  {
    if !it.net.address
    {
      new_user_slot = it;
      break;
    }
  }

  if (new_user_slot)
  {
    new_user_slot.net.address = SDLNet_RefAddress(address);
    new_user_slot.net.port = port;
  }
  return new_user_slot;
}

NET_Consume:: ($T: Type, packet: *string) -> T
{
  value: T;
  to_copy := Prefix(packet.*, size_of(T));
  memcpy(*value, to_copy.data, to_copy.count);
  packet.* = Skip(packet.*, to_copy.count);
  return value;
}

NET_RawPacketToPayload :: (raw_packet: string) -> payload: string
{
  packet := raw_packet;
  if packet.count < size_of(NET_PacketHeader)
  {
    Nlog(LOG_NetPacket, "packet rejected - it's too small, size: %llu", packet.count);
    return "";
  }

  header := NET_Consume(NET_PacketHeader, *packet);
  if (!packet.count)
  {
    Nlog(LOG_NetPacket, "packet rejected - empty payload",);
    return  "";
  }

  if (header.magic_value != NET_MAGIC_VALUE)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid magic value: %; expected: %", header.magic_value, NET_MAGIC_VALUE);
    return "";
  }

  // validate hash
  hash64 := Hash64Any(packet);
  hash16 := cast,no_check(u16) hash64;
  if (hash16 != header.payload_hash)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid hash: %; calculated: %", header.payload_hash, hash16);
    return "";
  }

  return packet;
}

NET_IsServer :: () -> bool
{
  return G.net.is_server;
}
NET_IsClient :: () -> bool
{
  return !G.net.is_server;
}
