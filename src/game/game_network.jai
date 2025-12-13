#scope_file;
using,only(NET) COMPS;
#scope_export;
// @todo remove all NET_IsServer checks from this file
// @todo this file should become more functional/pure network manager/layer

NET_DEFAULT_SEVER_PORT :: 50523;
NET_CL_MAX_SNAPSHOTS :: TICK_RATE;
NET_MAX_PLAYER_INPUT_COUNT :: 32; // @todo setting this high introduces a lot of input lag - fix!
NET_MAX_PLAYERS :: 10;
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
  // if net_category != LOG_NetPacket return;
  // @todo do something with net_category and logging in general
  // @todo add "NET_Label()" before every net log?, or do that for logs globally
  if (GLOBAL.is_server && GLOBAL.is_client) log("[SERVER+CLIENT][%]", loc);
  else if (GLOBAL.is_server) log("[SERVER][%]", loc);
  else if (GLOBAL.is_client) log("[CLIENT][%]", loc);

  log(format_string, ..args, loc, flags, user_flags, section);
} @PrintLike

NET_LocalPackets :: Queue(512, Packet, false);

NET_ConnectionType :: enum u8
{
  EMPTY;
  NETWORK;
  LOCAL;
}

NET_Connection :: struct
{
  type: NET_ConnectionType;
  last_msg_timestamp: Timestamp;

  // NETWORK
  address: *SDLNet_Address;
  port: u16;

  // LOCAL
  local_packets: *NET_LocalPackets;
};

NET_Init :: ()
{
  port: u16;
  if (GLOBAL.is_server) port = NET_DEFAULT_SEVER_PORT;
  NET.socket = SDLNet_CreateDatagramSocket(null, port);

  if !NET.socket
  {
    // NET.err = true;
    Nlog(LOG_NetInfo, "Failed to create socket");
  }
  else
  {
    Nlog(LOG_NetInfo, "Created socket");

    #if NET_SIMULATE_PACKETLOSS
    {
      SDLNet_SimulateDatagramPacketLoss(NET.socket, NET_SIMULATE_PACKETLOSS);
      Nlog(LOG_NetInfo, "%s: Simulating packetloss: %d", NET_SIMULATE_PACKETLOSS);
    }
  }
}

NET_HasError :: () -> bool { return NET.err; }

NET_HackyRatelimitting :: (last_accepted: *Timestamp, minimal_delay_seconds: float) -> bool
{
  now := TimeNow();
  if Elapsed(now, last_accepted.*) < minimal_delay_seconds return true;
  last_accepted.* = now;
  return false;
}

NET_ConnectionIsInactive :: (con: NET_Connection) -> bool
{
  return con.type == .NETWORK && Elapsed(TimeNow(), con.last_msg_timestamp) > NET_INACTIVE;
}

NET_ReceiveDatagram :: (dgram: **SDLNet_Datagram) -> bool
{
  return SDLNet_ReceiveDatagram(NET.socket, dgram);
}

NET_SendPacket :: (packet: Packet, dest: NET_Connection, skip_inactive: bool)
{
  assert(PK_IsFinalized(packet));

  msg := PK_PacketAsString(packet);
  assert(msg.count < 1280); // that seems to be a realistic reasonable max size? https://gafferongames.com/post/packet_fragmentation_and_reassembly/

  if skip_inactive && NET_ConnectionIsInactive(dest) {
    return;
  }

  if dest.type == .NETWORK
  {
    send_res := SDLNet_SendDatagram(NET.socket, dest.address, dest.port, msg.data, xx msg.count);
    if !send_res
    {
      Nlog(LOG_NetSend, "Sending buffer of size %lluB to %s:%d; %s",
        msg.count, to_string(SDLNet_GetAddressString(dest.address)),
        dest.port, ifx send_res then "success" else "fail");
    }
  }
  else if dest.type == .LOCAL
  {
    QueuePush(dest.local_packets, packet);
  }
  else assert(false);
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

NET_PreprocessRawPacket :: (raw_packet: string) -> payload: string, tick: Tick
{
  packet := raw_packet;
  if packet.count < size_of(PK_Header)
  {
    Nlog(LOG_NetPacket, "packet rejected - it's too small, size: %llu", packet.count);
    return "", 0;
  }

  header := PK_ConsumeRaw(PK_Header, *packet);
  if (!packet.count)
  {
    Nlog(LOG_NetPacket, "packet rejected - empty payload",);
    return "", 0;
  }

  if (header.magic_value != PK_MAGIC_VALUE)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid magic value: %; expected: %", header.magic_value, PK_MAGIC_VALUE);
    return "", 0;
  }

  // validate hash
  hash64 := Hash64Any(packet);
  hash16 := hash64.(u16,trunc);
  if (hash16 != header.buffer_hash)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid hash: %; calculated: %", header.buffer_hash, hash16);
    return "", 0;
  }

  return packet, header.tick;
}
