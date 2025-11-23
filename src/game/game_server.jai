#scope_file;
using,only(SV) COMPS;
#scope_export;

ServerState :: struct
{
  thread: Thread;

  iteration_timestamp: Timestamp;
  timestamp_accumulator: Timestamp;
  tick: ServerTick;
  last_broadcasted_tick: ServerTick;

  users: [NET_MAX_PLAYERS] SV_User;

  objects: [] Object;
  creation_serials: [] u8;

  rng: Entropy;

  last_sleeper_group_spawn: ServerTick;
  last_sleeper_spawn: ServerTick;
  sleepers_spawned_in_group_count: s64;
}

SV_LaunchServerThread :: ()
{
  log("Launching as server");
  SV.thread.starting_context = context;
  thread_init(*SV.thread, SV_ThreadEntry);
  thread_start(*SV.thread);
}

SV_GetNextPlayerInput :: (user: *SV_User) -> PlayerInput
{
  PerfFunc();

  top_delay: float;
  for user.received_inputs
  {
    top_delay = max(it.delay_since_last_received_input, top_delay);
  }
  target_input_delay_count := min(floor(top_delay / TICK_FLOAT_STEP).(s64) + 1, QueueCount(user.received_inputs));

  inputs_to_drop_count := QueueCount(user.received_inputs) - target_input_delay_count;
  for MakeRange(inputs_to_drop_count)
  {
    // @todo merge one-off data from dropped inputs
    QueuePop(*user.received_inputs);
  }
  Post(.SV_GET_PLAYER_INPUT_QUEUE_SIZE, QueueCount(user.received_inputs));

  received_input, did_pop := QueuePop(*user.received_inputs);

  result := received_input.input;
  if did_pop then user.last_input = received_input.input;
  else
  {
    // @todo more advanced extrapolation?
    result = user.last_input;
  }
  return result;
}


SV_GetObject :: (key: OBJ_Key) -> *Object
{
  result := OBJ_NilObject();
  key_index := OBJ_IndexOfKey(key);

  if key_index < SV.objects.count
  {
    obj := *SV.objects[key_index];
    if (obj.key == key) result = obj;
  }
  return result;
}

SV_DeleteObject :: (obj: *Object)
{
  obj.* = .{};
}

SV_CreateObject :: (flags: OBJ_Flags, team: OBJ_Team = .NO_TEAM) -> *Object
{
  obj: *Object;
  index: u32;

  for *SV.objects
  {
    if !OBJ_IsInit(it)
    {
      obj = it;
      index = xx it_index;
      break;
    }
  }

  if (!obj) return OBJ_NilObject();

  Initialize(obj);

  SV.creation_serials[index] = max(SV.creation_serials[index] + 1, 1);
  obj.key = OBJ_CreateKey(index, SV.creation_serials[index]);

  obj.init = true;
  obj.creation_tick = SV.tick;
  obj.flags = flags;
  obj.team = team;
  return obj;
}

SV_FindNearestToObject :: (obj: *Object, params: OBJ_TestParams) -> *Object
{
  nearest := OBJ_NilObject();
  nearest_distsq := FLOAT32_MAX;

  for *candidate: SV.objects
  {
    if (candidate == obj) continue;
    if !OBJ_Test2(candidate, obj, params) continue;

    distsq := OBJ_Distance2DSquared(obj, candidate);
    if distsq < nearest_distsq
    {
      nearest = candidate;
      nearest_distsq = distsq;
    }
  }

  return nearest;
}

SV_CreateHero :: (model: MODEL_Key, team: OBJ_Team) -> *Object
{
  obj := SV_CreateObject(
    .MOVE | .COLLIDE | .DRAW_MODEL | .ANIMATE_ROTATION | .ANIMATE_TRACKS |
    .HAS_HP | .TARGETABLE | .PLAY_SOUNDS | .HAS_ACTIVITY | .RESPAWN);

  if !OBJ_IsNil(obj)
  {
    dim := 0.4;
    obj.collider = OBJ_ColliderFromRect(.{dim,dim});
    obj.height = dim;
    obj.model = model;
    obj.color = Color32_Grayf(1);
    obj.rotation = RotationAroundAxis(AxisV3(.Z), -0.5);

    obj.max_hp = 40;
    obj.hp = 40;
    obj.move_speed = 1.5;

    obj.team = team;
  }
  return obj;
}

#scope_file;
SV_User :: struct
{
  connection: NET_Connection;
  key: OBJ_Key;

  received_inputs: Queue(NET_MAX_PLAYER_INPUT_COUNT, ReceivedInput);
  last_input: PlayerInput;
  latest_received_timestamp: Timestamp;
  latest_client_tick: InputTick;

  ReceivedInput :: struct
  {
    input: PlayerInput;
    delay_since_last_received_input: float;
  }
};

SV_ThreadEntry :: (thread: *Thread) -> s64
{
  PerfThreadName("TR server");
  SV_Init();

  while true
  {
    PerfScope("Server iteration");
    SV_IterateReceive();

    #assert(1000 % TICK_MILLISECONDS_STEP == 0);
    #assert(1000 / TICK_MILLISECONDS_STEP == TICK_RATE);

    now := TimeNow();
    timestamp_delta := now - SV.iteration_timestamp;
    SV.iteration_timestamp = now;

    SV.timestamp_accumulator += timestamp_delta;
    simulation_tick_count := SV.timestamp_accumulator / TICK_MILLISECONDS_STEP;
    SV.timestamp_accumulator -= simulation_tick_count * TICK_MILLISECONDS_STEP;

    for MakeRange(simulation_tick_count)
    {
      SV.tick += 1;
      SIM_AdvanceByTick();

      if it >= 2
      {
        log("Server lag. Simulation ticks clamped from % to 2 to avoid death-spiral.", simulation_tick_count);
        break;
      }
    }

    SV_IterateTimeoutUsers();
    SV_IterateSend();

    SDL_Delay(0); // @todo sleep on network
  }

  return 0;
}

SV_IterateSend :: ()
{
  if NET_HasError() return;
  if SV.tick <= SV.last_broadcasted_tick return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.001) return;

  PerfFunc();
  SV.last_broadcasted_tick = SV.tick;

  client_count := 0;
  for SV.users if it.connection.type  client_count += 1;

  // iterate over connected users
  player_number := 0;
  for *user, user_index: SV.users
  {
    if !user.connection.type continue;
    player_number += 1;

    // create player characters and send them to users
    {
      if OBJ_KeyIsZero(user.key)
      {
        model_keys := MODEL_Key.[
          ModelKey("Dude"),
          ModelKey("Zombie"),
          // ModelKey("Worker"),
          // ModelKey("Formal"),
          // ModelKey("Casual"),
        ];

        model := model_keys[user_index % model_keys.count];
        team := (user_index % 2 + 1).(OBJ_Team);
        player := SV_CreateHero(model, team);
        if !OBJ_IsNil(player)
        {
          player.p.y = -1.5 + user_index * 0.7;
          r := ifx user_index & 4 then 0.3 else 0.8;
          g := ifx user_index & 2 then 0.3 else 0.8;
          b := ifx user_index & 1 then 0.3 else 0.8;
          player.color = Color32_RGBf(r, g, b);
        }
        user.key = player.key;
      }

      assign: PACKET_AssignPlayerKey;
      assign.player_key = user.key;
      packet := PACKET_Create(SV.tick, assign);
      NET_SendPacket(packet, user.connection, true);
    }
  }

  // iterate over network objects
  for SV.objects
  {
    packet: PACKET_Full;

    if OBJ_HasData(it)
    {
      update: PACKET_ObjUpdate;
      update.net_index = xx it_index;
      update.sync = it;
      PACKET_CopyType(*packet, update);
    }
    else
    {
      update: PACKET_ObjEmpty;
      update.net_index = xx it_index;
      PACKET_CopyType(*packet, update);
    }

    PACKET_FinalizeHeader(SV.tick, *packet);

    for SV.users
    {
      if !it.connection.type continue;
      NET_SendPacket(packet, it.connection, true);
    }
  }
}

SV_IterateTimeoutUsers :: ()
{
  for *SV.users
  {
    if it.connection.type != .NETWORK continue;
    if Elapsed(SV.iteration_timestamp, it.connection.last_msg_timestamp) > NET_TIMEOUT_DISCONNECT
    {
      Nlog(LOG_NetInfo, "Timeout. Removing user #%", it_index);

      if GLOBAL.server_exit_on_disconnect
      {
        Nlog(LOG_Important, "Quitting server on client disconnect because -exit-on-dc argument was used.");
        GLOBAL.in_shutdown = true;
      }

      SV_RemoveUser(it);
    }
  }
}

SV_IterateReceive :: ()
{
  if NET_HasError() return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  // Receive and process local messages
  local_user := SV_FindLocalUser();
  if local_user
  {
    player_id := PointerToIndex(SV.users, local_user).(u16);

    while true
    {
      packet, got_packet := QueuePop(*GLOBAL.packets_for_local_server);
      if !got_packet break;

      packet_str := PACKET_FullAsString(packet);
      payload, from_tick := NET_PreprocessRawPacket(packet_str);
      SV_ReceivePayload(player_id, payload, from_tick.(InputTick));
    }
  }

  // Receive and process network messages
  while true
  {
    dgram: *SDLNet_Datagram;
    received := NET_ReceiveDatagram(*dgram);
    if !received || !dgram break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    user := SV_FindUser(dgram.addr, dgram.port);
    if !user
    {
      Nlog(LOG_NetInfo, "saving user with port: %", dgram.port);
      user = SV_AddNetworkUser(dgram.addr, dgram.port);
    }

    if user
    {
      user.connection.last_msg_timestamp = SV.iteration_timestamp;
      player_id := PointerToIndex(SV.users, user).(u16);

      packet := string.{dgram.buflen, dgram.buf};
      payload, from_tick := NET_PreprocessRawPacket(packet);
      SV_ReceivePayload(player_id, payload, from_tick.(InputTick));
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

SV_ReceiveUserPlayerInputs :: (player: *SV_User, net_msg: *PACKET_PlayerInput, client_tick: InputTick)
{
  if player.latest_client_tick >= client_tick then return;
  PerfFunc();

  // log("Client tick %; inputs: %", client_tick, net_msg.inputs);

  new_inputs := Prefix(net_msg.inputs, xx client_tick); // For initial client ticks only the first elements of input buffer will be filled. Truncate the array to skip these unitialized elements.

  end_tick := client_tick;
  start_tick := end_tick - xx new_inputs.count;

  if player.latest_client_tick >= start_tick
  {
    stale_ticks_count := player.latest_client_tick - start_tick + 1;
    new_inputs = Skip(new_inputs, xx stale_ticks_count);
    start_tick += xx stale_ticks_count;
  }

  if !new_inputs.count then return; // no new inputs

  for new_inputs
  {
    now := TimeNow();
    received := SV_User.ReceivedInput.{it, Elapsed(now, player.latest_received_timestamp)};
    player.latest_received_timestamp = now;
    QueuePush(*player.received_inputs, received);
  }

  player.latest_client_tick = client_tick;
}

SV_FindUser :: (address: *SDLNet_Address, port: u16) -> *SV_User
{
  // @todo move to SV_ prefix?
  for *SV.users
  {
    if NET_MatchConnection(it.connection, address, port)
    {
      return it;
    }
  }
  return null;
}

SV_RemoveUser :: (user: *SV_User)
{
  assert(user.connection.type == .NETWORK);
  SDLNet_UnrefAddress(user.connection.address);
  user.* = .{};
}

SV_ReceivePayload :: (player_id: u16, full_payload: string, from_tick: InputTick)
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
    else if msg_type == .PlayerInput
    {
      in_net := PACKET_Consume(PACKET_PlayerInput, *msg);
      user := *SV.users[player_id];
      SV_ReceiveUserPlayerInputs(user, *in_net, from_tick);
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload header kind: %", msg_type);
      return;
    }
  }
}

SV_FindLocalUser :: () -> *SV_User
{
  for *SV.users
    if it.connection.type == .LOCAL
      return it;

  return null;
}

SV_FindEmptyUserSlot :: () -> *SV_User
{
  slot: *SV_User;
  for *SV.users
  {
    if !it.connection.type
    {
      slot = it;
      break;
    }
  }
  return slot;
}

SV_AddNetworkUser :: (address: *SDLNet_Address, port: u16) -> *SV_User
{
  slot := SV_FindEmptyUserSlot();
  if slot
  {
    Initialize(slot);
    slot.connection.type = .NETWORK;
    slot.connection.address = SDLNet_RefAddress(address);
    slot.connection.port = port;
  }
  return slot;
}

SV_Init :: ()
{
  PerfFunc();

  // Allocate data
  {
    SV.objects = NewArray(OBJ_MAX_SHARED_OBJECTS, Object);
    SV.creation_serials = NewArray(OBJ_MAX_SHARED_OBJECTS, u8);
  }
  SV.rng = .{0xdeadbeef_12349876, 0xfda0fda0_87654321};
  SIM_InitObjects();

  if GLOBAL.is_client
  {
    local_user := SV_FindEmptyUserSlot();
    if local_user
    {
      Initialize(local_user);
      local_user.connection.type = .LOCAL;
      local_user.connection.local_packets = *GLOBAL.packets_for_local_user;
    }
  }
}
