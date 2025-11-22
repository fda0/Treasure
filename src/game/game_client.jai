#scope_file;
using,only(CL) COMPS;
#scope_export;

CL_State :: struct
{
  server_connection: NET_Connection;

  // client inputs sent to the server
  input_tick: InputTick;
  input: PlayerInput; // Accumulates inputs. Flushed to client.input_queue once in a while.
  input_queue: Queue(NET_MAX_PLAYER_INPUT_COUNT, PlayerInput);

  // Queues of snapshots - playback states received from the server.
  // Queue contains snapshot in sorted (by tick) order.
  // received_time is guaranteed to be sorted as well (should to be faked if needed).
  snapshots: [OBJ_MAX_SHARED_OBJECTS] Queue(NET_CL_MAX_SNAPSHOTS, Snapshot);

  // Object keys
  player_key: OBJ_Key;
  player_key_latest_tick: ServerTick;

  sun: OBJ_Key;
  pathing_marker: OBJ_Key;
  pathing_marker_set: bool;

  // Objects
  local_objects_tick: ServerTick = 1;
  local_objects_creation_serials: [OBJ_MAX_LOCAL_OBJECTS] u8;

  shared_ghosts: [OBJ_MAX_SHARED_OBJECTS] Ghost;
  local_ghosts: [OBJ_MAX_LOCAL_OBJECTS] Ghost;
  #place shared_ghosts;
  all_ghosts: [OBJ_MAX_ALL_OBJECTS] Ghost = ---;
};

CL_Init :: ()
{
  Nlog(LOG_NetInfo, "Launching as client");

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
      G.net.err = true;
      Nlog(LOG_NetInfo, "Failed to resolve server hostname '%s'", hostname);
    }
  }
}

CL_FlushPlayerInput :: ()
{
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;

  CL.input_tick += 1;
  QueuePush(*CL.input_queue, CL.input);
  // @todo clear skills queue once it exsits in Action
}

CL_IterateSend :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.016) return;
  PerfFunc();

  {
    ping: PACKET_Ping;
    packet := PACKET_Create(CL.input_tick, ping);
    NET_SendPacket(packet, CL.server_connection, false);
  }

  {
    payload: PACKET_PlayerInput;
    for * payload.inputs
    {
      it.* = QueuePeek(CL.input_queue, it_index);
    }

    packet := PACKET_Create(CL.input_tick, payload);
    NET_SendPacket(packet, CL.server_connection, false);
  }
}

CL_IterateReceive :: ()
{
  if G.net.err return;
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
    receive := SDLNet_ReceiveDatagram(G.net.socket, *dgram);
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
  if insert_shared_idx >= CL.shared_ghosts.count
  {
    Nlog(LOG_NetPayload, "Snapshot insert rejected. insert_shared_idx % overflows %",
      insert_shared_idx, CL.shared_ghosts.count);
    return;
  }

  snaps := *CL.snapshots[insert_shared_idx];

  latest_saved_tick := QueuePeekReverse(snaps).tick;
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

      CL_ReceiveSnapshot(from_tick, update.sync, update.net_index);
    }
    else if msg_type == .AssignPlayerKey
    {
      assign := PACKET_Consume(PACKET_AssignPlayerKey, *msg);

      if CL.player_key_latest_tick < from_tick
      {
        CL.player_key = assign.player_key;
        CL.player_key_latest_tick = from_tick;
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
    obj := *CL.all_ghosts[key_index];
    if obj.key == key then result = obj;
  }
  return result;
}

CL_CreateLocalObject :: (flags: OBJ_Flags) -> *Object
{
  ghost: *Ghost;
  index: u32;

  for *CL.local_ghosts
  {
    if !OBJ_IsInit(it)
    {
      ghost = it;
      index = xx it_index;
      break;
    }
  }

  if (!ghost) return OBJ_NilObject();

  Initialize(ghost);

  CL.local_objects_creation_serials[index] = max(CL.local_objects_creation_serials[index] + 1, 1);
  index_in_all_objects := index + OBJ_MAX_SHARED_OBJECTS;
  ghost.key = OBJ_CreateKey(index_in_all_objects, CL.local_objects_creation_serials[index]);

  ghost.init = true;
  ghost.creation_tick = CL.local_objects_tick;
  ghost.flags = flags;
  return *ghost.at_obj;
}

CL_InitLocalObjects :: ()
{
  // Sun
  {
    sun := CL_CreateLocalObject(.DRAW_COLLIDERS);
    sun.material = MaterialKey("tex.Leather011");
    sun.height = 0.5;
    sun.collider = OBJ_ColliderFromRect(.{.5, .5});
    CL.sun = sun.key;
  }

  // Pathing marker
  {
    CL.pathing_marker = CL_CreateLocalObject(.ANIMATE_POSITION).key;
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
