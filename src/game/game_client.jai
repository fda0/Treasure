CL_State :: struct
{
  server_connection: NET_Connection;

  // client inputs sent to the server
  input_tick: InputTick;
  input: PlayerInput; // Accumulates inputs. Flushed to client.input_queue once in a while.
  input_queue: Queue(NET_MAX_PLAYER_INPUT_COUNT, PlayerInput);

  // playback state received from the server
  playback_tick: ServerTick;
  snaps_of_objs: [OBJ_MAX_SHARED_OBJECTS] CL_ObjSnapshots;
  next_playback_server_tick: ServerTick;

  // Object keys
  player_key: OBJ_Key;
  player_key_latest_tick: ServerTick;

  sun: OBJ_Key;
  pathing_marker: OBJ_Key;
  pathing_marker_set: bool;

  // Objects
  local_objects_tick: ServerTick = 1;
  shared_objects: [OBJ_MAX_SHARED_OBJECTS] Ghost;
  local_objects: [OBJ_MAX_LOCAL_OBJECTS] Ghost;
  #place shared_objects;
  all_objects: [OBJ_MAX_ALL_OBJECTS] Ghost = ---;

  local_objects_creation_serials: [OBJ_MAX_LOCAL_OBJECTS] u8;
};

CL_ObjSnapshots :: struct
{
  tick_states: [NET_CL_MAX_SNAPSHOTS] Object; // circle buf
  latest_server_tick: ServerTick;
  oldest_server_tick: ServerTick;
  recent_lerp_start_tick: ServerTick;
  recent_lerp_end_tick: ServerTick;
};

CL_Init :: ()
{
  Nlog(LOG_NetInfo, "Launching as client");

  if GLOBAL.is_server
  {
    log("Client is starting local server connection");
    G.cl.server_connection.type = .LOCAL;
    G.cl.server_connection.local_packets = *GLOBAL.packets_for_local_server;
  }
  else
  {
    hostname := "localhost";
    Nlog(LOG_NetInfo, "Resolving server hostname '%s' ...", hostname);
    G.cl.server_connection = .{
      type = .NETWORK,
      address = SDLNet_ResolveHostname(temp_c_string(hostname)),
      port = NET_DEFAULT_SEVER_PORT,
    };

    if G.cl.server_connection.address
    {
      if SDLNet_WaitUntilResolved(G.cl.server_connection.address, -1) < 0
      {
        SDLNet_UnrefAddress(G.cl.server_connection.address);
        G.cl.server_connection.address = null;
      }
    }

    if !G.cl.server_connection.address
    {
      G.net.err = true;
      Nlog(LOG_NetInfo, "Failed to resolve server hostname '%s'", hostname);
    }
  }
}

CL_FlushPlayerInput :: ()
{
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;

  G.cl.input_tick += 1;
  QueuePush(*G.cl.input_queue, G.cl.input);
  // @todo clear skills queue once it exsits in Action
}

CL_ObjSyncAtTick :: (snaps: *CL_ObjSnapshots, tick: ServerTick) -> *Object
{
  state_index := tick % snaps.tick_states.count;
  return *snaps.tick_states[state_index];
}

CL_ReconstructObjectAtTick :: (net_index: u32, tick: ServerTick) -> Object
{
  PerfFunc();

  snaps := *G.cl.snaps_of_objs[net_index];

  assert(tick <= snaps.latest_server_tick &&
         tick >= snaps.oldest_server_tick);

  exact_obj := CL_ObjSyncAtTick(snaps, tick);
  if OBJ_IsInit(exact_obj) // exact object found
    return exact_obj.*;

  // find nearest prev_id/next_id objects
  prev_id := tick;
  next_id := tick;
  while (prev_id > snaps.oldest_server_tick)
  {
    prev_id -= 1;
    if (OBJ_IsInit(CL_ObjSyncAtTick(snaps, prev_id)))
      break;
  }
  while (next_id < snaps.latest_server_tick)
  {
    next_id += 1;
    if (OBJ_IsInit(CL_ObjSyncAtTick(snaps, next_id)))
      break;
  }

  prev := CL_ObjSyncAtTick(snaps, prev_id);
  next := CL_ObjSyncAtTick(snaps, next_id);

  // handle cases where we can't interpolate
  if (!OBJ_IsInit(prev) && !OBJ_IsInit(next)) // disaster
    return exact_obj.*;

  if (!OBJ_IsInit(prev))
    return next.*;

  if (!OBJ_IsInit(next))
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

CL_InsertSnapshot :: (snaps: *CL_ObjSnapshots, insert_at_tick: ServerTick, new_value: Object) -> bool
{
  PerfFunc();

  // function returns true on error
  #assert(snaps.tick_states.count == NET_CL_MAX_SNAPSHOTS);

  if (snaps.recent_lerp_start_tick != snaps.recent_lerp_end_tick &&
      insert_at_tick >= snaps.recent_lerp_start_tick &&
      insert_at_tick <= snaps.recent_lerp_end_tick)
  {
    Nlog(LOG_NetClient,
        "Rejecting snapshot insert (in the middle, locked by lerp) - latest server tick: %; insert tick: %; diff: % (max: %)",
        snaps.latest_server_tick, insert_at_tick,
        snaps.latest_server_tick - insert_at_tick, NET_CL_MAX_SNAPSHOTS);
    return true;
  }

  delta_from_latest := insert_at_tick - snaps.latest_server_tick;
  if delta_from_latest > 0
  {
    // save new latest server tick
    snaps.latest_server_tick = insert_at_tick;
  }

  last_to_first_tick_offset := (NET_CL_MAX_SNAPSHOTS - 1).(ServerTick);
  minimum_server_tick: ServerTick;
  if snaps.latest_server_tick > last_to_first_tick_offset
  {
    minimum_server_tick = snaps.latest_server_tick - last_to_first_tick_offset;
  }

  if insert_at_tick < minimum_server_tick
  {
    Nlog(LOG_NetClient,
        "Rejecting snapshot insert (underflow) - latest server tick: %; insert tick: %; diff: % (max: %)",
        snaps.latest_server_tick, insert_at_tick,
        insert_at_tick - snaps.latest_server_tick, NET_CL_MAX_SNAPSHOTS);
    return true;
  }

  if delta_from_latest > 0
  {
    // tick is newer than latest_server_at_tick
    // zero-out the gap between newly inserted object and previous latest server tick

    if delta_from_latest >= NET_CL_MAX_SNAPSHOTS
    {
      // optimized branch
      // tick is much-newer than latest_server_at_tick
      // we can safely clear the whole circle buffer
      ZeroArray(snaps.tick_states);
    }
    else
    {
      clearing_start := (insert_at_tick - delta_from_latest + 1).(ServerTick);
      for MakeRange(clearing_start, insert_at_tick)
      {
        obj := CL_ObjSyncAtTick(snaps, it);
        Initialize(obj);
      }
    }


    // recalculate oldest_server_tick
    if snaps.oldest_server_tick < minimum_server_tick
    {
      // find new oldest
      for MakeRange(minimum_server_tick, insert_at_tick)
      {
        obj := CL_ObjSyncAtTick(snaps, it);
        if OBJ_IsInit(obj)
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
    insert_at_obj := CL_ObjSyncAtTick(snaps, insert_at_tick);
    insert_at_obj.* = new_value;
  }

  assert(snaps.oldest_server_tick >= minimum_server_tick);
  return false; // no error
}

CL_IterateSend :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.016) return;
  PerfFunc();

  {
    ping: PACKET_Ping;
    packet := PACKET_Create(G.cl.input_tick, ping);
    NET_SendPacket(packet, G.cl.server_connection, false);
  }

  {
    payload: PACKET_PlayerInput;
    for * payload.inputs
    {
      it.* = QueuePeek(G.cl.input_queue, it_index);
    }

    packet := PACKET_Create(G.cl.input_tick, payload);
    NET_SendPacket(packet, G.cl.server_connection, false);
  }
}

CL_IterateReceive :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  // Receive and process local messages
  if G.cl.server_connection.type == .LOCAL
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
    receive := SDLNet_ReceiveDatagram(G.net.socket, *dgram);
    if !receive || !dgram break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    invalid_dgram := false;
    if !NET_MatchConnection(*G.cl.server_connection, dgram.addr, dgram.port)
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

CL_ReceivePayload :: (full_payload: string, from_tick: ServerTick)
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

      if update.net_index >= OBJ_MAX_SHARED_OBJECTS
      {
        Nlog(LOG_NetPayload, "Rejecting payload(%) - net index overflow: %", msg_type, update.net_index);
        continue;
      }

      if G.cl.next_playback_server_tick > from_tick
      {
        Nlog(LOG_NetPayload, "Rejecting payload(%) - head tick at: % < next playback tick: %",
             msg_type, from_tick, G.cl.next_playback_server_tick);
        continue;
      }

      snap := *G.cl.snaps_of_objs[update.net_index];
      CL_InsertSnapshot(snap, from_tick, update.sync);
    }
    else if msg_type == .AssignPlayerKey
    {
      assign := PACKET_Consume(PACKET_AssignPlayerKey, *msg);

      if G.cl.player_key_latest_tick < from_tick
      {
        G.cl.player_key = assign.player_key;
        G.cl.player_key_latest_tick = from_tick;
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

CL_PlayTick :: ()
{
  PerfFunc();
  assert(context.role == .CLIENT);

  smallest_latest_server_tick: ServerTick = ServerTick_MAX;
  biggest_oldest_server_tick: ServerTick;

  for snap: G.cl.snaps_of_objs
  {
    smallest_latest_server_tick = min(snap.latest_server_tick, smallest_latest_server_tick);
    biggest_oldest_server_tick = max(snap.oldest_server_tick, biggest_oldest_server_tick);
  }

  // @todo a system for smooth playback that tries to minimize latency
  // Currently we are picking the latest possible server tick.
  // This gives us minimal latency; but the playback won't be smooth on bad connection.
  G.cl.next_playback_server_tick = smallest_latest_server_tick;

  for *ghost, ghost_index: G.cl.shared_objects
  {
    interpolated_object := CL_ReconstructObjectAtTick(xx ghost_index, G.cl.next_playback_server_tick);
    ghost.o = interpolated_object;
    ghost.server_tick = G.cl.next_playback_server_tick;
  }
  G.cl.next_playback_server_tick += 1;
}

CL_GetGhost :: (storage_mask: OBJ_Storage, key: OBJ_Key) -> *Ghost
{
  key_index := OBJ_IndexOfKey(key);

  index_in_valid_storage := false;
  {
    min: u32 = 0;
    max: u32 = OBJ_MAX_SHARED_OBJECTS;
    if (storage_mask & .SHARED)
      index_in_valid_storage |= (key_index >= 0 && key_index < max);

    min = max;
    max += OBJ_MAX_LOCAL_OBJECTS;
    if (storage_mask & .LOCAL)
      index_in_valid_storage |= (key_index >= min && key_index < max);
  }

  result := OBJ_NilGhost();
  if index_in_valid_storage
  {
    obj := *G.cl.all_objects[key_index];
    if obj.o.key == key then result = obj;
  }
  return result;
}

CL_CreateLocalObject :: (flags: OBJ_Flags) -> *Object
{
  obj: *Ghost;
  index: u32;

  for *G.cl.local_objects
  {
    if !OBJ_IsInit(it.o)
    {
      obj = it;
      index = xx it_index;
      break;
    }
  }

  if (!obj) return OBJ_NilObject();

  Initialize(obj);

  G.cl.local_objects_creation_serials[index] = max(G.cl.local_objects_creation_serials[index] + 1, 1);
  index_in_all_objects := index + OBJ_MAX_SHARED_OBJECTS;
  obj.o.key = OBJ_CreateKey(index_in_all_objects, G.cl.local_objects_creation_serials[index]);

  obj.o.init = true;
  obj.o.creation_tick = G.cl.local_objects_tick;
  obj.o.flags = flags;
  return *obj.o;
}

CL_InitObjects :: ()
{
  // Sun
  {
    sun := CL_CreateLocalObject(.DRAW_COLLIDERS);
    sun.material = MaterialKey("tex.Leather011");
    sun.height = 0.5;
    sun.collider = OBJ_ColliderFromRect(.{.5, .5});
    G.cl.sun = sun.key;
  }

  // Pathing marker
  {
    G.cl.pathing_marker = CL_CreateLocalObject(.ANIMATE_POSITION).key;
  }

  // Ground
  {
    r := 32;
    d := 1.0;
    grass := MaterialKey("tex.Grass004");
    ground1 := MaterialKey("tex.Ground075");

    for y: MakeRange(-r, r)
    {
      for x: MakeRange(-r, r)
      {
        tile := CL_CreateLocalObject(.DRAW_COLLIDERS);
        if !OBJ_IsNil(tile)
        {
          tile.p = .{x = d * x, y = d * y};
          tile.collider = OBJ_ColliderFromRect(.{d, d});
          tile.texture_texels_per_m = 1.0 / d;
          tile.material = grass;
          if x < -r+5 || x >r-5 then tile.material = ground1;
          if y < -r+5 || y >r-5 then tile.material = ground1;
          if abs(x+y) < 4 then tile.material = ground1;
        }
      }
    }
  }

  // blocks thing
  {
    for wall: 0..3
    {
      len := 64;
      for i: MakeRange(len)
      {
        d := 1.0;

        x, y: float;
        if wall == 0 y = d*i;
        if wall == 1 {x = d*i; y = d * len;}
        if wall == 2 {x = d * len; y = len - d*i;}
        if wall == 3 x = len - d*i;
        x -= (0.5*d*len);
        y -= (0.5*d*len);

        block := CL_CreateLocalObject(.DRAW_COLLIDERS | .COLLIDE);
        if !OBJ_IsNil(block)
        {
          block.p = V3.{x, y, 0};
          block.collider = OBJ_ColliderFromRect(.{d,d});
          block.height = d;
          block.material = MaterialKey("tex.Clay002");
          block.texture_texels_per_m = 1.0 / d;
        }
      }
    }
  }

  // Add trees
  {
    x_count := 4;
    y_count := 4;

    for y: MakeRange(y_count)
    {
      for x: MakeRange(x_count)
      {
        x_half_count := x_count/2;
        y_half_count := y_count/2;

        pos: V3;
        if ((x^y)&1) pos.x = 4.70;
        else         pos.y = 6.90;

        pos.x += 7 + 4.0*(x % x_half_count);
        pos.y += 5 + 2.4*(y % y_half_count);

        pos.x *= ifx x < x_half_count then -1 else 1;
        pos.y *= ifx y < y_half_count then -1 else 1;

        tree := CL_CreateLocalObject(.DRAW_MODEL);
        if !OBJ_IsNil(tree)
        {
          tree.p = pos;
          tree.model = ModelKey("Tree");
        }
      }
    }
  }

}
