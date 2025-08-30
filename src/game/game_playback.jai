PLAYBACK_PlayTick :: ()
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
