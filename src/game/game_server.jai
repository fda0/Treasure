SERVER_State :: struct
{
  enabled: bool;
  occ: RoleState;

  thread: Thread;
  local_user_packets: NET_LocalPackets;

  tick: Tick;
  users: [NET_MAX_PLAYERS] SERVER_User;
};

SERVER_Start :: ()
{
  push_context PatchContext(.SERVER)
  {
    log("Launching as server");
    OBJ_Init();

    if GAME_ClientEnabled()
    {
      local_user := SERVER_AddUser(.LOCAL_CLIENT, null, 0);
    }

    G.server.thread.starting_context = context;
    thread_init(*G.server.thread, SERVER_ThreadEntry);
    thread_start(*G.server.thread);
  }
}

SERVER_GetNextUserAction :: (user: *SERVER_User) -> Action
{
  PerfFunc();
  top_delay: float;
  for user.received_actions
  {
    top_delay = max(it.delay_since_last_received_action, top_delay);
  }

  Post(.SERVER_GET_USER_ACTION_QUEUE_SIZE, QueueCount(user.received_actions));

  targeted_delay_in_count := min(floor(top_delay / TICK_FLOAT_STEP).(s64), QueueCount(user.received_actions));
  remove_old_items_count := targeted_delay_in_count - QueueCount(user.received_actions) - 1;
  for MakeRange(remove_old_items_count)
  {
    log("remove_old_items_count = %; QueueCount(user.received_actions): %, top_delay %; TICK_FLOAT_STEP %",
        remove_old_items_count, QueueCount(user.received_actions), top_delay, TICK_FLOAT_STEP);
    // @todo merging
    QueuePop(*user.received_actions);
  }

  received_action, did_pop := QueuePop(*user.received_actions);

  result := received_action.action;
  if did_pop then user.last_action = received_action.action;
  else
  {
    // @todo more advanced extrapolation?
    result = user.last_action;
  }
  return result;
}

#scope_file;
SERVER_User :: struct
{
  connection: NET_Connection;
  key: OBJ_Key;

  received_actions: Queue(NET_MAX_ACTION_COUNT, ReceivedAction);
  last_action: Action;
  latest_received_timestamp: Timestamp;
  latest_client_tick: Tick;

  ReceivedAction :: struct
  {
    action: Action;
    delay_since_last_received_action: float;
  }
};

SERVER_ThreadEntry :: (thread: *Thread) -> s64
{
  assert(context.role == .SERVER);
  timestamp_accumulator: Timestamp;

  while true
  {
    SERVER_IterateReceive();

    simulation_tick_count: Timestamp;
    {
      now_timestamp := GetTimestamp(.NOW);
      delta_timestamp := now_timestamp - context.R.frame_timestamp;
      context.R.frame_timestamp = now_timestamp;
      timestamp_accumulator += delta_timestamp;

      #assert((1000 % TICK_MILLISECONDS_STEP) == 0);
      #assert((1000 / TICK_MILLISECONDS_STEP) == TICK_RATE);
      simulation_tick_count = timestamp_accumulator / TICK_MILLISECONDS_STEP;
      timestamp_accumulator -= simulation_tick_count * TICK_MILLISECONDS_STEP;
    }

    for MakeRange(simulation_tick_count)
    {
      G.server.tick += 1;
      SIM_AdvanceByTick();

      if simulation_tick_count > 1
      {
        log("Server is falling behind! Ticks clamped from % to 1. This avoids server death-spiral but causes simulation slowdown.", simulation_tick_count);
        break;
      }
    }

    SERVER_IterateTimeoutUsers();
    SERVER_IterateSend();

    SDL_Delay(0); // @todo sleep on network
  }

  return 0;
}

SERVER_IterateSend :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  client_count := 0;
  for G.server.users if it.connection.type  client_count += 1;

  // iterate over connected users
  player_number := 0;
  for *user, user_index: G.server.users
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
        player := OBJ_CreateHero(.NETWORK, model, team);
        if !OBJ_IsNil(player)
        {
          player.s.p.y = -1.5 + user_index * 0.7;
          r := ifx user_index & 4 then 0.3 else 0.8;
          g := ifx user_index & 2 then 0.3 else 0.8;
          b := ifx user_index & 1 then 0.3 else 0.8;
          player.s.color = Color32_RGBf(r, g, b);
        }
        user.key = player.s.key;
      }

      assign: PACKET_AssignPlayerKey;
      assign.player_key = user.key;
      packet := PACKET_Create(GetServerTick(), assign);
      NET_SendPacket(*packet, user.connection, true);
    }

    // calculate autolayout for clients
    // @todo this doesn't have to be done on iterate send
    if G.window_autolayout
    {
      window_count := 1 + client_count;

      rows := 1;
      cols := 1;
      for 0..15
      {
        total_slots := rows * cols;
        if total_slots >= window_count
          break;

        if rows > cols  cols += 1;
        else            rows += 1;
      }

      #if 0 // @impl
      {
        win_x := G.init_window_px;
        win_y := G.init_window_py;
        win_w := G.init_window_width / cols;
        win_h := G.init_window_height / rows;

        // calc server window
        GAME_AutoLayoutApply(client_count, win_x, win_y, win_w, win_h);

        // calc client window
        {
          window_index := player_number;
          x := window_index / rows;
          y := window_index % rows;

          head: PACKET_Header;
          head.tick_id = G.tick_id;
          head.kind = .WindowLayout;
          NET_PayloadMemcpy(*head, sizeof(head));

          body: NET_SendWindowLayout;
          body.user_count = client_count;
          body.px = win_x + x*win_w;
          body.py = win_y + y*win_h;
          body.w = win_w;
          body.h = win_h;
          NET_PayloadMemcpy(*body, sizeof(body));

          NET_PacketSendAndResetPayload(user);
        }
      }
    }
  }

  // iterate over network objects
  for context.R.obj.network_objects
  {
    packet: PACKET_Full;

    if OBJ_HasData(it)
    {
      update: PACKET_ObjUpdate;
      update.net_index = xx it_index;
      update.sync = it.s;
      PACKET_CopyType(*packet, update);
    }
    else
    {
      update: PACKET_ObjEmpty;
      update.net_index = xx it_index;
      PACKET_CopyType(*packet, update);
    }

    PACKET_FinalizeHeader(GetServerTick(), *packet);

    for G.server.users
    {
      if !it.connection.type continue;
      NET_SendPacket(packet, it.connection, true);
    }
  }
}

SERVER_IterateTimeoutUsers :: ()
{
  for *G.server.users
  {
    if it.connection.type != .NETWORK continue;
    if ElapsedSeconds(it.connection.last_msg_timestamp, .FRAME) > NET_TIMEOUT_DISCONNECT
    {
      Nlog(LOG_NetInfo, "Timeout. Removing user #%", it_index);

      if G.server_exit_on_disconnect
      {
        Nlog(LOG_Important, "Quitting server on client disconnect because -exit-on-dc argument was used.");
        G.in_shutdown = true;
      }

      SERVER_RemoveUser(it);
    }
  }
}

SERVER_IterateReceive :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  // Receive and process local messages
  local_user := SERVER_FindLocalUser();
  if local_user
  {
    player_id := PointerToIndex(G.server.users, local_user).(u16);

    while true
    {
      packet, got_packet := QueuePop(*G.server.local_user_packets);
      if !got_packet break;

      packet_str := PACKET_FullAsString(packet);
      payload, from_tick := NET_PreprocessRawPacket(packet_str);
      SERVER_ReceivePayload(player_id, payload, from_tick);
    }
  }

  // Receive and process network messages
  while true
  {
    dgram: *SDLNet_Datagram;
    receive := SDLNet_ReceiveDatagram(G.net.socket, *dgram);
    if !receive || !dgram break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    user := SERVER_FindUser(dgram.addr, dgram.port);
    if !user
    {
      Nlog(LOG_NetInfo, "saving user with port: %", dgram.port);
      user = SERVER_AddUser(.NETWORK, dgram.addr, dgram.port);
    }

    if user
    {
      user.connection.last_msg_timestamp = GetTimestamp(.FRAME);
      player_id := PointerToIndex(G.server.users, user).(u16);

      packet := string.{dgram.buflen, dgram.buf};
      payload, from_tick := NET_PreprocessRawPacket(packet);
      SERVER_ReceivePayload(player_id, payload, from_tick);
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

SERVER_ReceiveUserActions :: (player: *SERVER_User, net_msg: *PACKET_Actions, client_tick: Tick)
{
  if player.latest_client_tick >= client_tick then return;
  PerfFunc();

  // log("Client tick %; actions: %", client_tick, net_msg.actions);

  new_actions := ArrayPrefix(net_msg.actions, xx client_tick); // For initial client ticks only the first elements of action buffer will be filled. Truncate the array to skip these unitialized elements.

  end_tick := client_tick;
  start_tick := end_tick - xx new_actions.count;

  if player.latest_client_tick >= start_tick
  {
    stale_ticks_count := player.latest_client_tick - start_tick + 1;

    new_actions = ArraySkip(new_actions, xx stale_ticks_count);
    start_tick += stale_ticks_count;
  }

  if !new_actions.count then return; // no new actions

  for new_actions
  {
    now := GetTimestamp();
    received := SERVER_User.ReceivedAction.{
      it, ElapsedSeconds(player.latest_received_timestamp, now, false)
    };
    player.latest_received_timestamp = now;

    QueuePush(*player.received_actions, received);
  }

  player.latest_client_tick = client_tick;
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

SERVER_RemoveUser :: (user: *SERVER_User)
{
  assert(user.connection.type == .NETWORK);
  SDLNet_UnrefAddress(user.connection.address);
  user.* = .{};
}

SERVER_ReceivePayload :: (player_id: u16, full_payload: string, from_tick: Tick)
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
    else if msg_type == .Actions
    {
      in_net := PACKET_Consume(PACKET_Actions, *msg);
      user := *G.server.users[player_id];
      SERVER_ReceiveUserActions(user, *in_net, from_tick);
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload header kind: %d", msg_type);
      return;
    }
  }
}

SERVER_FindLocalUser :: () -> *SERVER_User
{
  for *G.server.users
  {
    if it.connection.type == .LOCAL_CLIENT
    {
      return it;
    }
  }
  return null;
}

SERVER_AddUser :: (type: NET_ConnectionType, address: *SDLNet_Address, port: u16) -> *SERVER_User
{
  // @todo move to SV_ prefix?
  new_user_slot: *SERVER_User;
  for *G.server.users
  {
    if !it.connection.type
    {
      new_user_slot = it;
      break;
    }
  }

  if new_user_slot
  {
    Initialize(new_user_slot);
    new_user_slot.connection.type = type;
    if type == .NETWORK
    {
      new_user_slot.connection.address = SDLNet_RefAddress(address);
      new_user_slot.connection.port = port;
    }
  }
  return new_user_slot;
}
