SERVER_State :: struct
{
  tick: Tick;
  users: [NET_MAX_PLAYERS] SERVER_UserState;
};

SERVER_UserState :: struct
{
  net: NET_User;
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

SERVER_ReceiveDatagram :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;

}

SERVER_ReceiveUserActions :: (player: *SERVER_UserState, net_msg: *NET_SendActions, client_tick: Tick)
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
    received := SERVER_UserState.ReceivedAction.{
      it, ElapsedSeconds(player.latest_received_timestamp, now, false)
    };
    player.latest_received_timestamp = now;

    QueuePush(*player.received_actions, received);
  }

  player.latest_client_tick = client_tick;
}

SERVER_GetNextUserAction :: (user: *SERVER_UserState) -> Action
{
  PerfFunc();
  top_delay: float;
  for user.received_actions
  {
    top_delay = max(it.delay_since_last_received_action, top_delay);
  }

  Post(.SERVER_GET_USER_ACTION_QUEUE_SIZE, user.received_actions.count);

  targeted_delay_in_count := min(floor(top_delay / TICK_FLOAT_STEP).(s64), user.received_actions.count);
  remove_old_items_count := targeted_delay_in_count - user.received_actions.count - 1;
  for MakeRange(remove_old_items_count)
  {
    log("remove_old_items_count = %; user.received_actions.count: %, top_delay %; TICK_FLOAT_STEP %", remove_old_items_count, user.received_actions.count, top_delay, TICK_FLOAT_STEP);
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

SERVER_IterateSend :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  client_count := 0;
  for G.server.users if it.net.address client_count += 1;

  // iterate over connected users
  player_number := 0;
  for *user, user_index: G.server.users
  {
    if !user.net.address continue;
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

      head: NET_SendHeader;
      head.tick = GetServerTick();
      head.kind = .AssignPlayerKey;
      NET_PayloadAppendType(head);

      assign: NET_SendAssignPlayerKey;
      assign.player_key = user.key;
      NET_PayloadAppendType(assign);

      NET_PacketSendAndResetPayload(user.net);
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

          head: NET_SendHeader;
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
  for G.obj.network_objects
  {
    if OBJ_HasData(it)
    {
      head: NET_SendHeader;
      head.tick = GetServerTick();
      head.kind = .ObjUpdate;
      NET_PayloadAppendType(head);

      update: NET_SendObjSync;
      update.net_index = xx it_index;
      update.sync = it.s;
      NET_PayloadAppendType(update);
    }
    else
    {
      head: NET_SendHeader;
      head.tick = GetServerTick();
      head.kind = .ObjEmpty;
      NET_PayloadAppendType(head);

      update: NET_SendObjEmpty;
      update.net_index = xx it_index;
      NET_PayloadAppendType(update);
    }

    NET_PacketSendAndResetPayloadBroadcast();
  }
}

SERVER_IterateTimeoutUsers :: ()
{
  for *G.server.users
  {
    if !it.net.address continue;
    if ElapsedSeconds(it.net.last_msg_timestamp, .FRAME) > NET_TIMEOUT_DISCONNECT
    {
      Nlog(LOG_NetInfo, "Timeout. Removing user #%", it_index);

      if G.server_exit_on_disconnect
      {
        Nlog(LOG_Important, "Quitting server on client disconnect because -exit-on-dc argument was used.");
        G.in_shutdown = true;
      }

      NET_RemoveUser(*it.net);
    }
  }
}

SERVER_IterateReceive :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;
  PerfFunc();

  while true
  {
    dgram: *SDLNet_Datagram;
    receive := SDLNet_ReceiveDatagram(G.net.socket, *dgram);
    if !receive || !dgram break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    user := NET_FindUser(dgram.addr, dgram.port);
    if !user
    {
      Nlog(LOG_NetInfo, "saving user with port: %", dgram.port);
      user = NET_AddUser(dgram.addr, dgram.port);
    }

    if user
    {
      user.net.last_msg_timestamp = GetTimestamp(.FRAME);
      user_id := PointerToIndex(G.server.users, user);
      player_id := user_id.(u16);

      packet := string.{dgram.buflen, dgram.buf};
      payload := NET_RawPacketToPayload(packet);
      SERVER_ReceivePayload(player_id, payload);
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

SERVER_ReceivePayload :: (player_id: u16, full_payload: string)
{
  PerfFunc();
  msg := full_payload;
  while msg.count
  {
    head := NET_Consume(NET_SendHeader, *msg);

    if head.kind == .Ping
    {
      ping := NET_Consume(NET_SendPing, *msg);
    }
    else if head.kind == .Actions
    {
      in_net := NET_Consume(NET_SendActions, *msg);
      user := *G.server.users[player_id];
      SERVER_ReceiveUserActions(user, *in_net, head.tick);
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload header kind: %d", head.kind);
      return;
    }
  }
}
