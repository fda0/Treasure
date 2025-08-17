SERVER_PlayerActions :: struct
{
  action_queue: Queue(NET_MAX_ACTION_COUNT, Action);
  latest_client_tick_id: u64;
  last_action: Action;
  receive_deltas: TickDeltas;
};

SERVER_State :: struct
{
  users: [NET_MAX_PLAYERS] NET_User;
  player_keys: [NET_MAX_PLAYERS] OBJ_Key;
  player_actions: [NET_MAX_PLAYERS] SERVER_PlayerActions;
};

SERVER_InsertPlayerAction :: (player: *SERVER_PlayerActions, net_msg: *NET_SendActions, net_msg_tick_id: u64)
{
  // @refactor this is dumb and complicated!
  if net_msg_tick_id <= player.latest_client_tick_id
    return; // no new actions

  pre_insert_action_queue_count := player.action_queue.count;

  assert(net_msg_tick_id >= net_msg.actions.count);
  first_action_tick_id := net_msg_tick_id - net_msg.actions.count;

  for action_index: MakeRange(net_msg.actions.count)
  {
    action_tick := first_action_tick_id + xx action_index;
    if action_tick <= player.latest_client_tick_id
    {
      // reject old actions
      continue;
    }

    // store action
    QueuePush(*player.action_queue, net_msg.actions[action_index]);
  }

  player.latest_client_tick_id = net_msg_tick_id;

  if TickDeltas_AddTick(*player.receive_deltas, net_msg_tick_id)
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
