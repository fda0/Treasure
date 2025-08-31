SERVER_State :: struct
{
  tick: Tick;
  users: [NET_MAX_PLAYERS] NET_User;
  player_keys: [NET_MAX_PLAYERS] OBJ_Key;
  player_actions: [NET_MAX_PLAYERS] SERVER_PlayerActions;
};

SERVER_PlayerActions :: struct
{
  action_queue: Queue(NET_MAX_ACTION_COUNT, Action);
  latest_client_tick: Tick;
  last_action: Action;
  receive_deltas: TickDeltas;
};

SERVER_ReceiveDatagram :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;

}

SERVER_ReceivePlayerActions :: (player: *SERVER_PlayerActions, net_msg: *NET_SendActions, client_tick: Tick)
{
  if player.latest_client_tick >= client_tick then return;

  log("Client tick %; actions: %", client_tick, net_msg.actions);

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

  pre_insert_action_queue_count := player.action_queue.count;
  for new_actions
  {
    QueuePush(*player.action_queue, it);
  }

  player.latest_client_tick = client_tick;


  // @todo THIS code might require refactor; This system could be a separate thing living on top of action queue.
  if TickDeltas_AddTick(*player.receive_deltas, client_tick)
  {
    TickDeltas_UpdateCatchup(*player.receive_deltas, xx pre_insert_action_queue_count);
    if player.receive_deltas.tick_catchup
    {
      Nlog(LOG_NetCatchup,
          "Client (?) current action delay: % Setting action playback catchup to %",
          pre_insert_action_queue_count, player.receive_deltas.tick_catchup);
    }
  }
}

SERVER_PopPlayerAction :: (player: *SERVER_PlayerActions) -> Action
{
  popped := QueuePop(*player.action_queue);
  player.last_action = popped;
  return popped;
}

SERVER_GetPlayerAction :: (player_index: u32) -> Action
{
  result: Action;
  if player_index >= G.server.player_actions.count
    return result;

  player := *G.server.player_actions[player_index];
  starting_action_count := player.action_queue.count;

  if starting_action_count > 0
    result = SERVER_PopPlayerAction(player);
  else
  {
    Nlog(LOG_NetTick,
        "Ran out of action playback (player %) -> extrapolating; playback catchup %",
        player_index, player.receive_deltas.tick_catchup);

    // extrapolation using last action!
    result = player.last_action;
  }

  if starting_action_count > 1 && player.receive_deltas.tick_catchup > 0
  {
    player.receive_deltas.tick_catchup -= 1;
    next := SERVER_PopPlayerAction(player); // @todo previously 2 actions were merged; do that in the future?
    result = next;
  }

  return result;
}

SERVER_IterateSend :: ()
{
  if G.net.err return;
  if NET_HackyRatelimitting(UniqueTimestamp(), 0.008) return;

  client_count := 0;
  for G.server.users
    if it.address client_count += 1;

  // iterate over connected users
  player_number := 0;
  for user, user_index: G.server.users
  {
    if !user.address continue;
    player_number += 1;

    // create player characters and send them to users
    {
      player_key := *G.server.player_keys[user_index];

      if OBJ_KeyIsZero(player_key)
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
        player_key.* = player.s.key;
      }

      head: NET_SendHeader;
      head.tick = GetServerTick();
      head.kind = .AssignPlayerKey;
      NET_PayloadAppendType(head);

      assign: NET_SendAssignPlayerKey;
      assign.player_key = player_key.*;
      NET_PayloadAppendType(assign);

      NET_PacketSendAndResetPayload(user);
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
    if !it.address continue;
    if ElapsedSeconds(it.last_msg_timestamp, .FRAME) > NET_TIMEOUT_DISCONNECT
    {
      Nlog(LOG_NetInfo, "Timeout. Removing user #%", it_index);

      if G.server_exit_on_disconnect
      {
        Nlog(LOG_Important, "Quitting server on client disconnect because -exit-on-dc argument was used.");
        G.in_shutdown = true;
      }

      NET_RemoveUser(it);
    }
  }
}

SERVER_IterateReceive :: ()
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

    user := NET_FindUser(dgram.addr, dgram.port);
    if !user
    {
      Nlog(LOG_NetInfo, "saving user with port: %", dgram.port);
      user = NET_AddUser(dgram.addr, dgram.port);
    }

    if user
    {
      user.last_msg_timestamp = GetTimestamp(.FRAME);
      user_id: u64 = (user.(u64) - G.server.users.data.(u64)) / size_of(NET_User);
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
      player := *G.server.player_actions[player_id];
      SERVER_ReceivePlayerActions(player, *in_net, head.tick);
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload header kind: %d", head.kind);
      return;
    }
  }
}
