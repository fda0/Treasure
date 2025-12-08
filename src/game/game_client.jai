#scope_file;
using,only(CL,G,NET) COMPS; // @todo remove G from here in the future
#scope_export;

ClientState :: struct
{
  server_connection: NET_Connection;

  // Queues of snapshots - playback states received from the server.
  // Queue contains snapshot in sorted (by tick) order.
  // received_time is guaranteed to be sorted as well (should to be faked if needed).
  snapshots: [] Queue(NET_CL_MAX_SNAPSHOTS, Snapshot);
};

CL_Init :: ()
{
  Nlog(LOG_NetInfo, "Launching as client");

  // Allocate snapshots
  CL.snapshots = NewArray(OBJ_SHARED_COUNT, Queue(NET_CL_MAX_SNAPSHOTS, Snapshot));

  if GLOBAL.is_server
  {
    log("Client is starting local server connection");
    CL.server_connection.type = .LOCAL;
    CL.server_connection.local_packets = *GLOBAL.packets_for_local_server;
  }
  else
  {
    hostname := "localhost";
    Nlog(LOG_NetInfo, "Resolving server hostname '%s' ...", hostname);
    CL.server_connection = .{
      type = .NETWORK,
      address = SDLNet_ResolveHostname(temp_c_string(hostname)),
      port = NET_DEFAULT_SEVER_PORT,
    };

    if CL.server_connection.address
    {
      if SDLNet_WaitUntilResolved(CL.server_connection.address, -1) < 0
      {
        SDLNet_UnrefAddress(CL.server_connection.address);
        CL.server_connection.address = null;
      }
    }

    if !CL.server_connection.address
    {
      NET.err = true;
      Nlog(LOG_NetInfo, "Failed to resolve server hostname '%s'", hostname);
    }
  }
}

CL_SendPlayerActions :: ()
{
  PerfFunc();
  wrapped := PACKET_ActionQueue.{actions = G.action_queue};
  packet := PACKET_Create(G.action_tick, wrapped);
  NET_SendPacket(packet, CL.server_connection, false);
}

CL_IterateReceive :: ()
{
  if NET_HasError() return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  // Receive and process local messages
  if CL.server_connection.type == .LOCAL
  {
    while true
    {
      packet, got_packet := QueuePop(*GLOBAL.packets_for_local_user);
      if !got_packet break;

      packet_str := PACKET_FullAsString(packet);
      payload, from_tick := NET_PreprocessRawPacket(packet_str);
      CL_ReceivePayload(payload, from_tick.(ServerTick));
    }

    return; // No need to check network anymore
  }

  // Receive and process network messages
  while true
  {
    dgram: *SDLNet_Datagram;
    receive := SDLNet_ReceiveDatagram(NET.socket, *dgram);
    if !receive || !dgram break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    invalid_dgram := false;
    if !NET_MatchConnection(CL.server_connection, dgram.addr, dgram.port)
    {
      invalid_dgram = true;
      Nlog(LOG_NetDatagram, "dgram rejected - received from non-server address %:%",
        to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);
    }

    if !invalid_dgram
    {
      packet := string.{dgram.buflen, dgram.buf};
      payload, from_tick := NET_PreprocessRawPacket(packet);
      CL_ReceivePayload(payload, from_tick.(ServerTick));
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

CL_ReceiveSnapshot :: (from_tick: ServerTick, insert_obj: Object, insert_shared_idx: u32)
{
  if insert_shared_idx >= OBJ_SHARED_COUNT
  {
    Nlog(LOG_NetPayload, "Snapshot insert rejected. insert_shared_idx % overflows %",
      insert_shared_idx, OBJ_SHARED_COUNT);
    return;
  }

  snaps := *CL.snapshots[insert_shared_idx];

  latest_saved_tick := QueuePeekLast(snaps).tick;
  if latest_saved_tick >= from_tick
  {
    // @todo support this case?
    Nlog(LOG_NetPayload, "Snapshot insert rejected. insert_shared_idx %; Tick out of order %. Latest saved tick: %",
      insert_shared_idx, from_tick, latest_saved_tick);
    return;
  }

  snapshot: Snapshot;
  snapshot.obj = insert_obj;
  snapshot.tick = from_tick;
  snapshot.received_time = G.client_timestamp;
  QueuePush(snaps, snapshot);
}

CL_ReceivePayload :: (full_payload: string, from_tick: ServerTick)
{
  PerfFunc();
  msg := full_payload;
  while msg.count
  {
    msg_type := PACKET_Peek(PACKET_Type, msg);

    if (msg_type == .ObjUpdate || msg_type == .ObjEmpty)
    {
      update: PACKET_ObjUpdate;
      if (msg_type == .ObjUpdate)
      {
        update = PACKET_Consume(PACKET_ObjUpdate, *msg);
      }
      else
      {
        empty := PACKET_Consume(PACKET_ObjEmpty, *msg);
        update.net_index = empty.net_index;
        update.sync.init = true;
      }

      CL_ReceiveSnapshot(from_tick, update.sync, update.net_index);
    }
    else if msg_type == .AssignPlayerKey
    {
      // If the server was ever going to dynamically change player key
      // We should use IsTickDue kind of tracking to apply it on the side of GameState.
      assign := PACKET_Consume(PACKET_AssignPlayerKey, *msg);

      if G.player_key_latest_tick < from_tick
      {
        G.player_key = assign.player_key;
        G.player_key_latest_tick = from_tick;
      }
    }
    else if msg_type == .WindowLayout
    {
      layout := PACKET_Consume(PACKET_WindowLayout, *msg);
      if G.window_autolayout
      {
        // G_AutoLayoutApply(layout.user_count, layout.px, layout.py, layout.w, layout.h);
      }
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload head kind: %d", msg_type);
      return;
    }
  }
}
