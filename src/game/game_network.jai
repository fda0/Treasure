// @todo remove all NET_IsServer checks from this file
// @todo this file should become more functional/pure network manager/layer

NET_DEFAULT_SEVER_PORT :: 50523;
NET_CLIENT_MAX_SNAPSHOTS :: TICK_RATE;
NET_MAX_ACTION_COUNT :: TICK_RATE/8;
NET_MAX_PLAYERS :: 10;
NET_MAX_PACKET_SIZE :: 1200;
NET_MAX_PAYLOAD_SIZE :: NET_MAX_PACKET_SIZE - size_of(PACKET_Header);
NET_SIMULATE_PACKETLOSS :: 0; // doesn't seem to work on localhost
NET_INACTIVE :: 0.1;
NET_TIMEOUT_DISCONNECT :: 0.5;

NET_State :: struct
{
  err: bool; // tracks if network is in error state
  socket: *SDLNet_DatagramSocket;
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
  log(ifx NET_IsServer() then "[SERVER]" else "[CLIENT]");
  log(format_string, ..args, loc, flags, user_flags, section);
} @PrintLike

NET_LocalPackets :: Queue(1024, PACKET_Full); // @todo replace with thread-safe Queue

NET_ConnectionType :: enum u8
{
  EMPTY;
  NETWORK;
  LOCAL_SERVER;
  LOCAL_CLIENT;
}

NET_Connection :: struct
{
  type: NET_ConnectionType;
  address: *SDLNet_Address;
  port: u16;
  last_msg_timestamp: Timestamp;
};

NET_Init :: ()
{
  port: u16 = xx ifx NET_IsServer() /* @todo thats bad */ then NET_DEFAULT_SEVER_PORT else 0;
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

NET_ConnectionIsInactive :: (con: NET_Connection) -> bool
{
  return ElapsedSeconds(con.last_msg_timestamp) > NET_INACTIVE;
}

NET_SendPacket :: (packet: PACKET_Full, dest: NET_Connection, skip_inactive: bool)
{
  assert(PACKET_IsFinalized(packet));
  assert(packet.payload.count < 1280); // that seems to be a realistic reasonable max size? https://gafferongames.com/post/packet_fragmentation_and_reassembly/

  if skip_inactive && NET_ConnectionIsInactive(dest) {
    return;
  }

  msg := PACKET_FullAsString(packet);

  if dest.type == .NETWORK
  {
    send_res := SDLNet_SendDatagram(G.net.socket, dest.address, dest.port, msg.data, xx msg.count);
    if !send_res
    {
      Nlog(LOG_NetSend, "Sending buffer of size %lluB to %s:%d; %s",
        msg.count, to_string(SDLNet_GetAddressString(dest.address)),
        dest.port, ifx send_res then "success" else "fail");
    }
  }
  else if dest.type == .LOCAL_SERVER || dest.type == .LOCAL_CLIENT
  {
    packets := ifx dest.type == .LOCAL_SERVER then *G.server.local_user_packets else *G.client.local_server_packets;
    QueuePush(packets, packet);
  }
  else
  {
    assert(false);
  }
}

NET_MatchConnection :: (a: NET_Connection, b: NET_Connection) -> bool
{
  return (a.type == b.type &&
    a.port == b.port &&
    SDLNet_CompareAddresses(a.address, b.address) == 0);
}

NET_MatchConnection :: (user: NET_Connection, address: *SDLNet_Address, port: u16) -> bool
{
  if user.type != .NETWORK
    return false;

  return user.port == port && SDLNet_CompareAddresses(user.address, address) == 0;
}

SERVER_FindUser :: (address: *SDLNet_Address, port: u16) -> *SERVER_User
{
  // @todo move to SV_ prefix?
  for *G.server.users
  {
    if NET_MatchConnection(it.connection, address, port)
    {
      return it;
    }
  }
  return null;
}

NET_PreprocessRawPacket :: (raw_packet: string) -> payload: string, tick: Tick
{
  packet := raw_packet;
  if packet.count < size_of(PACKET_Header)
  {
    Nlog(LOG_NetPacket, "packet rejected - it's too small, size: %llu", packet.count);
    return "", 0;
  }

  header := PACKET_Consume(PACKET_Header, *packet);
  if (!packet.count)
  {
    Nlog(LOG_NetPacket, "packet rejected - empty payload",);
    return "", 0;
  }

  if (header.magic_value != PACKET_MAGIC_VALUE)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid magic value: %; expected: %", header.magic_value, PACKET_MAGIC_VALUE);
    return "", 0;
  }

  // validate hash
  hash64 := Hash64Any(packet);
  hash16 := hash64.(u16,trunc);
  if (hash16 != header.payload_hash)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid hash: %; calculated: %", header.payload_hash, hash16);
    return "", 0;
  }

  return packet, header.from_tick;
}

NET_IsServer :: () -> bool
{
  return G.server.enabled;
}
NET_IsClient :: () -> bool
{
  return G.client.enabled;
}
