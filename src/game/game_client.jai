CLIENT_State :: struct
{
  tick: Tick;

  snaps_of_objs: [OBJ_MAX_NETWORK_OBJECTS] CLIENT_ObjSnapshots;
  next_playback_server_tick: Tick;

  current_playback_delay: u16;
  playable_tick_deltas: TickDeltas; // used to control playback catch-up

  // circular buffer with tick inputs
  action_queue: Queue(NET_MAX_ACTION_COUNT, Action);

  //
  player_key: OBJ_Key;
  player_key_latest_tick: Tick;

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

CLIENT_ObjSyncAtTick :: (snaps: *CLIENT_ObjSnapshots, tick: Tick) -> *OBJ_Sync
{
  state_index := tick % snaps.tick_states.count;
  return *snaps.tick_states[state_index];
}

CLIENT_LerpObjSync :: (net_index: u32, tick: Tick) -> OBJ_Sync
{
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

  {
    head: NET_SendHeader;
    head.tick = GetClientTick();
    head.kind = .Ping;
    NET_PayloadAppendType(head);

    ping: NET_SendPing;
    NET_PayloadAppendType(ping);
    NET_PacketSendAndResetPayloadToServer();
  }

  {
    head: NET_SendHeader;
    head.tick = GetClientTick();
    head.kind = .Actions;
    NET_PayloadAppendType(head);

    payload: NET_SendActions;
    for * payload.actions
    {
      it.* = QueuePeek(G.client.action_queue, it_index);
    }

    NET_PayloadAppendType(payload);
    NET_PacketSendAndResetPayloadToServer();
  }
}

CLIENT_IterateReceive :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;

  while true
  {
    dgram: *SDLNet_Datagram;
    receive := SDLNet_ReceiveDatagram(G.net.socket, *dgram);
    if !receive || !dgram break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    dgram_error := false;
    if !NET_UserMatchAddrPort(*G.net.server_user, dgram.addr, dgram.port)
    {
      dgram_error = true;
      Nlog(LOG_NetDatagram, "dgram rejected - received from non-server address %:%",
        to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);
    }

    if !dgram_error
    {
      packet := string.{dgram.buflen, dgram.buf};
      NET_ReceivePacket(NET_MAX_PLAYERS, packet);
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

CLIENT_PlayTick :: ()
{
  assert(NET_IsClient());

  smallest_latest_server_tick: Tick = Tick_MAX;
  biggest_oldest_server_tick: Tick;
  for snap: G.client.snaps_of_objs
  {
    if snap.latest_server_tick < smallest_latest_server_tick
      smallest_latest_server_tick = snap.latest_server_tick;

    if snap.oldest_server_tick > biggest_oldest_server_tick
      biggest_oldest_server_tick = snap.oldest_server_tick;
  }

  if biggest_oldest_server_tick > G.client.next_playback_server_tick
  {
    Nlog(LOG_NetTick, #run String.join(
      "Server is too ahead from the client;",
      "biggest_oldest_server_tick: %,",
      "smallest_latest_server_tick: %,",
      "client's next_playback_server_tick: %,",
      "playback delay: %,",
      "playback catchup %,",
      "[bumping client's next_playback_tick]"),
      biggest_oldest_server_tick,
      smallest_latest_server_tick,
      G.client.next_playback_server_tick,
      G.client.current_playback_delay,
      G.client.playable_tick_deltas.tick_catchup);

    G.client.next_playback_server_tick = biggest_oldest_server_tick;
  }

  if smallest_latest_server_tick < G.client.next_playback_server_tick
  {
    Nlog(LOG_NetTick, #run String.join(
      "Ran out of tick playback state; ",
      "next_playback_tick: %, ",
      "smallest_latest_server_tick: %, ",
      "playback delay: %, ",
      "playback catchup %"),
      G.client.next_playback_server_tick,
      smallest_latest_server_tick,
      G.client.current_playback_delay,
      G.client.playable_tick_deltas.tick_catchup);
    return;
  }

  // calc current delay
  {
    current_playback_delay_u64 := smallest_latest_server_tick - G.client.next_playback_server_tick;
    G.client.current_playback_delay = CastSaturate(u16, current_playback_delay_u64);
  }

  if TickDeltas_AddTick(*G.client.playable_tick_deltas, smallest_latest_server_tick)
  {
    TickDeltas_UpdateCatchup(*G.client.playable_tick_deltas, G.client.current_playback_delay);
    if G.client.playable_tick_deltas.tick_catchup
    {
      Nlog(LOG_NetCatchup, "Current playback delay: %d,  Setting playback catchup to %d",
        G.client.current_playback_delay, G.client.playable_tick_deltas.tick_catchup);
    }
  }

  for net_index: MakeRange(OBJ_MAX_NETWORK_OBJECTS.(u32))
  {
    interpolated_sync := CLIENT_LerpObjSync(net_index, G.client.next_playback_server_tick);
    net_obj := OBJ_FromNetIndex(net_index);
    net_obj.s = interpolated_sync;
  }
  G.client.next_playback_server_tick += 1;
}
