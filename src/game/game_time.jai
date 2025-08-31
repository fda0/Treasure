Timestamp :: #type,distinct u64; // @todo make this a signed type?
Timestamp_MAX :: U64_MAX;

TimeReference :: enum
{
  FRAME; // timestamp taken at the start of the frame
  NOW; // new timestamp measurement
}

GetTimestamp :: (reference := TimeReference.FRAME) -> Timestamp
{
  if #complete reference == {
    case .FRAME; return G.frame_timestamp;
    case .NOW; return xx SDL_GetTicks();
  }
}

ElapsedTimestamp :: (start: Timestamp, finish: Timestamp, max_on_fail := false) -> Timestamp
{
  if start > finish return FailTimestamp(max_on_fail);
  return finish - start;
}

ElapsedTimestamp :: (start: Timestamp, finish_reference := TimeReference.FRAME, max_on_fail := false) -> Timestamp
{
  return ElapsedTimestamp(start, GetTimestamp(finish_reference), max_on_fail);
}

ElapsedSeconds :: (start: Timestamp, finish: Timestamp, max_on_fail := false) -> float, bool
{
  if start > finish return FailSeconds(max_on_fail), false;
  return (finish - start).(float) * 0.001, true;
}

ElapsedSeconds :: (start: Timestamp, finish_reference := TimeReference.FRAME, max_on_fail := false) -> float, bool
{
  f, b := ElapsedSeconds(start, GetTimestamp(finish_reference), max_on_fail);
  return f, b;
}

FailTimestamp :: (max_on_fail: bool) -> Timestamp
{
  return cast(Timestamp) (ifx max_on_fail then Timestamp_MAX else 0);
}

FailSeconds :: (max_on_fail: bool) -> float
{
  return ifx max_on_fail then FLOAT32_MAX else 0.0;
}


// Tick
Tick :: #type,distinct s64;
Tick_MAX :: cast(Tick) S64_MAX;

GetClientTick :: () -> Tick
{
  assert(NET_IsClient());
  return G.client.tick;
}

GetServerTick :: () -> Tick
{
  assert(NET_IsServer());
  return G.server.tick;
}


ClientTimestampOfServerTick :: (server_tick: Tick, max_on_fail: bool) -> Timestamp, bool
{
  // assert(NET_IsClient());
  // @todo debug mode assert to check that this is called from client thread

  if !IndexInBounds(G.client.server_tick_to_client_timestamps, server_tick) return FailTimestamp(max_on_fail), false;
  return G.client.server_tick_to_client_timestamps[server_tick], true;
}

ClientSecondsSinceServerTick :: (start_server_tick: Tick, max_on_fail: bool) -> float, bool
{
  // assert(NET_IsClient());
  // @todo debug mode assert to check that this is called from client thread

  if !IndexInBounds(G.client.server_tick_to_client_timestamps, start_server_tick) return FailSeconds(max_on_fail), false;
  start_client_timestamp := G.client.server_tick_to_client_timestamps[start_server_tick];
  f, b := ElapsedSeconds(start_client_timestamp);
  return f, b;
}

ServerSecondsSinceServerTick :: (start_server_tick: Tick, max_on_fail: bool) -> float, bool
{
  // @todo debug mode assert to check that this is called from server thread
  assert(NET_IsServer());

  current_server_tick := G.server.tick;
  if start_server_tick > current_server_tick return FailSeconds(max_on_fail), false;

  ticks_delta := current_server_tick - start_server_tick;
  return ticks_delta.(float) * TICK_FLOAT_STEP, true;
}



// TimeBetweenTicksMS :: (start: Tick, end: Tick, max_on_fail := false) -> TimestampMS
// {
//   if start > end
//   {
//     if max_on_fail return TimestampMS_MAX;
//     else           return 0;
//   }
//   delta := end - start;
//   return xx (delta * TICK_MILLISECONDS_STEP);
// }
// TimeSinceTickMS :: (start: Tick, max_on_fail := false) -> TimestampMS
// {
//   return TimeBetweenTicksMS(start, GetTick(), max_on_fail);
// }
// TimeBetweenTicksS :: (start: Tick, end: Tick, max_on_fail := false) -> float
// {
//   if start > end
//   {
//     if max_on_fail return FLOAT32_MAX;
//     else           return 0.0;
//   }
//   delta := end - start;
//   return delta * TICK_FLOAT_STEP;
// }
// TimeSinceTickS :: (start: Tick, max_on_fail := false) -> float
// {
//   return TimeBetweenTicksS(start, GetTick(), max_on_fail);
// }
