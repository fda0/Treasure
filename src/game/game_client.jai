CLIENT_State :: struct
{
  snaps_of_objs: [OBJ_MAX_NETWORK_OBJECTS] CLIENT_ObjSnapshots;
  next_playback_tick: u64;

  current_playback_delay: u16;
  playable_tick_deltas: TickDeltas; // used to control playback catch-up

  // circular buffer with tick inputs
  action_queue: Queue(NET_MAX_ACTION_COUNT, Action);

  //
  player_key: OBJ_Key;
  player_key_latest_tick_id: u64;
};

CLIENT_ObjSnapshots :: struct
{
  tick_states: [NET_CLIENT_MAX_SNAPSHOTS] OBJ_Sync; // circle buf
  latest_server_tick: u64;
  oldest_server_tick: u64;
  recent_lerp_start_tick: u64;
  recent_lerp_end_tick: u64;
};

CLIENT_ObjSyncAtTick :: (snaps: *CLIENT_ObjSnapshots, tick_id: u64) -> *OBJ_Sync
{
  state_index := tick_id % snaps.tick_states.count;
  return *snaps.tick_states[state_index];
}

CLIENT_LerpObjSync :: (net_index: u32, tick_id: u64) -> OBJ_Sync
{
  snaps := *G.client.snaps_of_objs[net_index];

  assert(tick_id <= snaps.latest_server_tick &&
         tick_id >= snaps.oldest_server_tick);

  exact_obj := CLIENT_ObjSyncAtTick(snaps, tick_id);
  if OBJ_SyncIsInit(exact_obj) // exact object found
    return exact_obj.*;

  // find nearest prev_id/next_id objects
  prev_id := tick_id;
  next_id := tick_id;
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
  id_offset := tick_id - prev_id;
  t := id_offset.(float) / id_range.(float);
  result := lerp(prev, next, t);
  return result;
}

CLIENT_InsertSnapshot :: (snaps: *CLIENT_ObjSnapshots, insert_at_tick_id: u64, new_value: OBJ_Sync) -> bool
{
  // function returns true on error
  #assert(snaps.tick_states.count == NET_CLIENT_MAX_SNAPSHOTS);
  last_to_first_tick_offset := NET_CLIENT_MAX_SNAPSHOTS.(u64) - 1;

  if (snaps.recent_lerp_start_tick != snaps.recent_lerp_end_tick &&
      insert_at_tick_id >= snaps.recent_lerp_start_tick &&
      insert_at_tick_id <= snaps.recent_lerp_end_tick)
  {
    Nlog(LOG_NetClient,
        "Rejecting snapshot insert (in the middle, locked by lerp) - latest server tick: %; insert tick: %; diff: % (max: %)",
        snaps.latest_server_tick, insert_at_tick_id,
        snaps.latest_server_tick - insert_at_tick_id, NET_CLIENT_MAX_SNAPSHOTS);
    return true;
  }

  delta_from_latest := insert_at_tick_id.(s64) - snaps.latest_server_tick.(s64);
  if delta_from_latest > 0
  {
    // save new latest server tick
    snaps.latest_server_tick = insert_at_tick_id;
  }

  minimum_server_tick := max(cast(u64) 0, snaps.latest_server_tick - last_to_first_tick_offset);
  if (xx insert_at_tick_id < minimum_server_tick)
  {
    Nlog(LOG_NetClient,
        "Rejecting snapshot insert (underflow) - latest server tick: %; insert tick: %; diff: % (max: %)",
        snaps.latest_server_tick, insert_at_tick_id,
        insert_at_tick_id - snaps.latest_server_tick, NET_CLIENT_MAX_SNAPSHOTS);
    return true;
  }

  if delta_from_latest > 0
  {
    // tick_id is newer than latest_server_at_tick
    // zero-out the gap between newly inserted object and previous latest server tick

    if delta_from_latest >= NET_CLIENT_MAX_SNAPSHOTS
    {
      // optimized branch
      // tick_id is much-newer than latest_server_at_tick
      // we can safely clear the whole circle buffer
      ZeroArray(snaps.tick_states);
    }
    else
    {
      clearing_start := insert_at_tick_id - delta_from_latest.(u64) + 1;
      for MakeRange(clearing_start, insert_at_tick_id)
      {
        obj := CLIENT_ObjSyncAtTick(snaps, it);
        Initialize(obj);
      }
    }


    // recalculate oldest_server_tick
    if snaps.oldest_server_tick < minimum_server_tick
    {
      // find new oldest
      for MakeRange(minimum_server_tick, insert_at_tick_id)
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
        snaps.oldest_server_tick = insert_at_tick_id;
      }
    }
  }

  // update oldest if inserted obj is older than oldest
  if (snaps.oldest_server_tick > insert_at_tick_id)
  {
    snaps.oldest_server_tick = insert_at_tick_id;
  }

  // insert object
  {
    insert_at_obj := CLIENT_ObjSyncAtTick(snaps, insert_at_tick_id);
    insert_at_obj.* = new_value;
  }

  assert(snaps.oldest_server_tick >= minimum_server_tick);
  return false; // no error
}
