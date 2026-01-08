#scope_file;
using,only(SIM,SV) COMPS;
#scope_export;

ServerState :: struct
{
  thread: Thread;

  iteration_timestamp: Timestamp;
  timestamp_accumulator: Timestamp;
  tick: ServerTick;
  last_broadcasted_tick: ServerTick;

  users: [NET_MAX_PLAYERS] SV_User;
}

SV_LaunchServerThread :: ()
{
  log("Launching as server");
  SV.thread.starting_context = context;
  thread_init(*SV.thread, SV_ThreadEntry);
  thread_start(*SV.thread);
}

SV_User :: struct
{
  connection: NET_Connection;
  key: OBJ_Key;

   // @todo currently we are not doing any playback delay for these actions
  action_queue: ActionQueue;
  received_action_tick: ActionTick;
};

#scope_file;
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
        models := ModelAlias.[
          .Dude,
          .Zombie,
          // .Worker,
          // .Formal,
          // .Casual,
        ];

        model := models[user_index % models.count];
        team := (user_index % 2 + 1).(OBJ_Team);
        player := SIM_CreateHero(model, team);
        if !OBJ_IsNil(player)
        {
          player.p.y = -1.5 + user_index * 0.7;
          r := ifx user_index & 4 then 0.3 else 0.8;
          g := ifx user_index & 2 then 0.3 else 0.8;
          b := ifx user_index & 1 then 0.3 else 0.8;
          player.color = ColorPack(ColorRGB(r, g, b));
        }
        user.key = player.key;
      }

      packet := PK_Create(SV.tick, PK_Kind.AssignPlayerKey, user.key);
      NET_SendPacket(packet, user.connection, true);
    }
  }

  // iterate over network objects
  for SIM.objects
  {
    packet: Packet;
    if OBJ_HasData(it) PK_AddPair(*packet, .ObjUpdate, it);
    else               PK_AddPair(*packet, .ObjEmpty, it_index.(ObjIdx));
    PK_FinalizeHeader(SV.tick, *packet);

    for SV.users {
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

      packet_str := PK_PacketAsString(packet);
      payload, from_tick := NET_PreprocessRawPacket(packet_str);
      SV_ReceivePayload(player_id, payload, xx from_tick);
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
      SV_ReceivePayload(player_id, payload, xx from_tick);
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

SV_ReceiveActions :: (user: *SV_User, actions: ActionQueue, action_tick: ActionTick)
{
  if (user.received_action_tick >= action_tick) return;
  PerfFunc();

  for actions {
    if it.tick >= user.received_action_tick {
      QueuePush(*user.action_queue, it);
    }
  }

  user.received_action_tick = action_tick;
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

SV_ReceivePayload :: (player_id: u16, packet_buffer: string, packet_tick: ActionTick)
{
  PerfFunc();
  msg := packet_buffer;
  while msg.count
  {
    packet_kind := PK_ConsumeKind(*msg);
    if packet_kind == .ActionQueue
    {
      user := *SV.users[player_id];
      actions_packet := PK_Consume(.ActionQueue, *msg);
      SV_ReceiveActions(user, actions_packet, packet_tick);
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload header kind: %", packet_kind);
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
    SIM.objects = NewArray(OBJ_SHARED_COUNT, Object);
    SIM.creation_serials = NewArray(OBJ_SHARED_COUNT, u8);
  }
  SIM.rng = .{0xdeadbeef_12349876, 0xfda0fda0_87654321};
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
