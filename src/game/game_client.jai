CLIENT_State :: struct
{
  enabled: bool;
  role_state: RoleState;

  server_connection: NET_Connection;
  local_server_packets: NET_LocalPackets;

  // client actions sent to the server
  action_tick: Tick;
  action: InputAction; // Accumulates actions. Flushed to client.action_queue once in a while.
  action_queue: Queue(NET_MAX_ACTION_COUNT, InputAction);

  // playback state received from the server
  playback_tick: Tick;
  snaps_of_objs: [OBJ_MAX_NETWORK_OBJECTS] CLIENT_ObjSnapshots;
  next_playback_server_tick: Tick;

  //
  player_key: OBJ_Key;
  player_key_latest_tick: Tick;

  // Lookup table for: Server tick -> Client receive timestamp
  server_tick_to_client_timestamps: [..] Timestamp;
};

CLIENT_ObjSnapshots :: struct
{
  tick_states: [NET_CLIENT_MAX_SNAPSHOTS] OBJ_Sync; // circle buf
  latest_server_tick: Tick;
  oldest_server_tick: Tick;
  recent_lerp_start_tick: Tick;
  recent_lerp_end_tick: Tick;
};

CLIENT_Init :: ()
{
  Nlog(LOG_NetInfo, "Launching as client");

  if GAME_ServerEnabled()
  {
    log("Client is starting local server connection");
    G.client.server_connection.type = .LOCAL_SERVER;
  }
  else
  {
    hostname := "localhost";
    Nlog(LOG_NetInfo, "Resolving server hostname '%s' ...", hostname);
    G.client.server_connection = .{
      type = .NETWORK,
      address = SDLNet_ResolveHostname(temp_c_string(hostname)),
      port = NET_DEFAULT_SEVER_PORT,
    };

    if G.client.server_connection.address
    {
      if SDLNet_WaitUntilResolved(G.client.server_connection.address, -1) < 0
      {
        SDLNet_UnrefAddress(G.client.server_connection.address);
        G.client.server_connection.address = null;
      }
    }

    if !G.client.server_connection.address
    {
      G.net.err = true;
      Nlog(LOG_NetInfo, "Failed to resolve server hostname '%s'", hostname);
    }
  }
}

CLIENT_FlushActionTick :: ()
{
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;

  G.client.action_tick += 1;
  QueuePush(*G.client.action_queue, G.client.action);
  // @todo clear skills queue once it exsits in Action
}

CLIENT_ObjSyncAtTick :: (snaps: *CLIENT_ObjSnapshots, tick: Tick) -> *OBJ_Sync
{
  state_index := tick % snaps.tick_states.count;
  return *snaps.tick_states[state_index];
}

CLIENT_ReconstructObjectSyncAtTick :: (net_index: u32, tick: Tick) -> OBJ_Sync
{
  PerfFunc();

  snaps := *G.client.snaps_of_objs[net_index];

  assert(tick <= snaps.latest_server_tick &&
         tick >= snaps.oldest_server_tick);

  exact_obj := CLIENT_ObjSyncAtTick(snaps, tick);
  if OBJ_SyncIsInit(exact_obj) // exact object found
    return exact_obj.*;

  // find nearest prev_id/next_id objects
  prev_id := tick;
  next_id := tick;
  while (prev_id > snaps.oldest_server_tick)
  {
    prev_id -= 1;
    if (OBJ_SyncIsInit(CLIENT_ObjSyncAtTick(snaps, prev_id)))
      break;
  }
  while (next_id < snaps.latest_server_tick)
  {
    next_id += 1;
    if (OBJ_SyncIsInit(CLIENT_ObjSyncAtTick(snaps, next_id)))
      break;
  }

  prev := CLIENT_ObjSyncAtTick(snaps, prev_id);
  next := CLIENT_ObjSyncAtTick(snaps, next_id);

  // handle cases where we can't interpolate
  if (!OBJ_SyncIsInit(prev) && !OBJ_SyncIsInit(next)) // disaster
    return exact_obj.*;

  if (!OBJ_SyncIsInit(prev))
    return next.*;

  if (!OBJ_SyncIsInit(next))
    return prev.*;

  // lock lerp range; new packets in this range will be rejected
  snaps.recent_lerp_start_tick = prev_id;
  snaps.recent_lerp_end_tick = next_id;

  // do the interpolation
  id_range := next_id - prev_id;
  id_offset := tick - prev_id;
  t := id_offset.(float) / id_range.(float);
  result := lerp(prev, next, t);
  return result;
}

CLIENT_InsertSnapshot :: (snaps: *CLIENT_ObjSnapshots, insert_at_tick: Tick, new_value: OBJ_Sync) -> bool
{
  PerfFunc();

  // function returns true on error
  #assert(snaps.tick_states.count == NET_CLIENT_MAX_SNAPSHOTS);
  last_to_first_tick_offset := NET_CLIENT_MAX_SNAPSHOTS.(Tick) - 1;

  if (snaps.recent_lerp_start_tick != snaps.recent_lerp_end_tick &&
      insert_at_tick >= snaps.recent_lerp_start_tick &&
      insert_at_tick <= snaps.recent_lerp_end_tick)
  {
    Nlog(LOG_NetClient,
        "Rejecting snapshot insert (in the middle, locked by lerp) - latest server tick: %; insert tick: %; diff: % (max: %)",
        snaps.latest_server_tick, insert_at_tick,
        snaps.latest_server_tick - insert_at_tick, NET_CLIENT_MAX_SNAPSHOTS);
    return true;
  }

  delta_from_latest := insert_at_tick - snaps.latest_server_tick;
  if delta_from_latest > 0
  {
    // save new latest server tick
    snaps.latest_server_tick = insert_at_tick;
  }

  minimum_server_tick := max(snaps.latest_server_tick - last_to_first_tick_offset, cast(Tick) 0);
  if (xx insert_at_tick < minimum_server_tick)
  {
    Nlog(LOG_NetClient,
        "Rejecting snapshot insert (underflow) - latest server tick: %; insert tick: %; diff: % (max: %)",
        snaps.latest_server_tick, insert_at_tick,
        insert_at_tick - snaps.latest_server_tick, NET_CLIENT_MAX_SNAPSHOTS);
    return true;
  }

  if delta_from_latest > 0
  {
    // tick is newer than latest_server_at_tick
    // zero-out the gap between newly inserted object and previous latest server tick

    if delta_from_latest >= NET_CLIENT_MAX_SNAPSHOTS
    {
      // optimized branch
      // tick is much-newer than latest_server_at_tick
      // we can safely clear the whole circle buffer
      ZeroArray(snaps.tick_states);
    }
    else
    {
      clearing_start := insert_at_tick - delta_from_latest + 1;
      for MakeRange(clearing_start, insert_at_tick)
      {
        obj := CLIENT_ObjSyncAtTick(snaps, it);
        Initialize(obj);
      }
    }


    // recalculate oldest_server_tick
    if snaps.oldest_server_tick < minimum_server_tick
    {
      // find new oldest
      for MakeRange(minimum_server_tick, insert_at_tick)
      {
        obj := CLIENT_ObjSyncAtTick(snaps, it);
        if OBJ_SyncIsInit(obj)
        {
          snaps.oldest_server_tick = it;
          break;
        }
      }

      // failed to find oldest
      if (snaps.oldest_server_tick < minimum_server_tick)
      {
        snaps.oldest_server_tick = insert_at_tick;
      }
    }
  }

  // update oldest if inserted obj is older than oldest
  if (snaps.oldest_server_tick > insert_at_tick)
  {
    snaps.oldest_server_tick = insert_at_tick;
  }

  // insert object
  {
    insert_at_obj := CLIENT_ObjSyncAtTick(snaps, insert_at_tick);
    insert_at_obj.* = new_value;
  }

  assert(snaps.oldest_server_tick >= minimum_server_tick);
  return false; // no error
}

CLIENT_IterateSend :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.016) return;
  PerfFunc();

  {
    ping: PACKET_Ping;
    packet := PACKET_Create(GetClientActionTick(), ping);
    NET_SendPacket(packet, G.client.server_connection, false);
  }

  {
    payload: PACKET_InputActions;
    for * payload.actions
    {
      it.* = QueuePeek(G.client.action_queue, it_index);
    }

    packet := PACKET_Create(GetClientActionTick(), payload);
    NET_SendPacket(packet, G.client.server_connection, false);
  }
}

CLIENT_IterateReceive :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  // Receive and process local messages
  if G.client.server_connection.type == .LOCAL_SERVER
  {
    while true
    {
      packet, got_packet := QueuePop(*G.client.local_server_packets);
      if !got_packet break;

      packet_str := PACKET_FullAsString(packet);
      payload, from_tick := NET_PreprocessRawPacket(packet_str);
      CLIENT_ReceivePayload(payload, from_tick);
    }

    return; // No need to check network anymore
  }

  // Receive and process network messages
  while true
  {
    dgram: *SDLNet_Datagram;
    receive := SDLNet_ReceiveDatagram(G.net.socket, *dgram);
    if !receive || !dgram break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    invalid_dgram := false;
    if !NET_MatchConnection(*G.client.server_connection, dgram.addr, dgram.port)
    {
      invalid_dgram = true;
      Nlog(LOG_NetDatagram, "dgram rejected - received from non-server address %:%",
        to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);
    }

    if !invalid_dgram
    {
      packet := string.{dgram.buflen, dgram.buf};
      payload, from_tick := NET_PreprocessRawPacket(packet);
      CLIENT_ReceivePayload(payload, from_tick);
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

CLIENT_ReceivePayload :: (full_payload: string, from_tick: Tick)
{
  PerfFunc();
  msg := full_payload;
  while msg.count
  {
    msg_type := PACKET_Peek(PACKET_Type, msg);

    if msg_type == .Ping
    {
      ping := PACKET_Consume(PACKET_Ping, *msg);
    }
    else if (msg_type == .ObjUpdate || msg_type == .ObjEmpty)
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

      if update.net_index >= OBJ_MAX_NETWORK_OBJECTS
      {
        Nlog(LOG_NetPayload, "Rejecting payload(%) - net index overflow: %", msg_type, update.net_index);
        continue;
      }

      if G.client.next_playback_server_tick > from_tick
      {
        Nlog(LOG_NetPayload, "Rejecting payload(%) - head tick at: % < next playback tick: %",
             msg_type, from_tick, G.client.next_playback_server_tick);
        continue;
      }

      snap := *G.client.snaps_of_objs[update.net_index];
      CLIENT_InsertSnapshot(snap, from_tick, update.sync);
    }
    else if msg_type == .AssignPlayerKey
    {
      assign := PACKET_Consume(PACKET_AssignPlayerKey, *msg);

      if G.client.player_key_latest_tick < from_tick
      {
        G.client.player_key = assign.player_key;
        G.client.player_key_latest_tick = from_tick;
      }
    }
    else if msg_type == .WindowLayout
    {
      layout := PACKET_Consume(PACKET_WindowLayout, *msg);
      if G.window_autolayout
      {
        // GAME_AutoLayoutApply(layout.user_count, layout.px, layout.py, layout.w, layout.h);
      }
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload head kind: %d", msg_type);
      return;
    }
  }
}

CLIENT_PlayTick :: ()
{
  PerfFunc();
  assert(context.role == .CLIENT);

  smallest_latest_server_tick: Tick = Tick_MAX;
  biggest_oldest_server_tick: Tick;

  for snap: G.client.snaps_of_objs
  {
    smallest_latest_server_tick = min(snap.latest_server_tick, smallest_latest_server_tick);
    biggest_oldest_server_tick = max(snap.oldest_server_tick, biggest_oldest_server_tick);
  }

  // @todo a system for smooth playback that tries to minimize latency
  // Currently we are picking the latest possible server tick.
  // This gives us minimal latency; but the playback won't be smooth on bad connection.
  G.client.next_playback_server_tick = smallest_latest_server_tick;

  for net_index: MakeRange(OBJ_MAX_NETWORK_OBJECTS.(u32))
  {
    interpolated_sync := CLIENT_ReconstructObjectSyncAtTick(net_index, G.client.next_playback_server_tick);
    net_obj := OBJ_FromNetIndex(net_index);
    net_obj.s = interpolated_sync;
  }
  G.client.next_playback_server_tick += 1;
}
