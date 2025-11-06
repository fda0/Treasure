Timestamp :: #type,distinct s64; // @todo make this a signed type?
TimeNow :: () -> Timestamp { return xx SDL_GetTicks(); }

Elapsed :: (start: Timestamp, finish: Timestamp, max_on_fail: bool) -> float
{
  delta := finish - start;
  if delta < 0 return FailTime(max_on_fail);
  return delta.(float) * 0.001;
}

FailTime :: (max_on_fail: bool) -> float
{
  return ifx max_on_fail then FLOAT32_MAX else 0;
}

GAME_ElapsedToFrame :: (since: Timestamp, max_on_fail: bool) -> float
{
  return Elapsed(since, G.frame_timestamp, max_on_fail);
}

ServerTick :: #type,distinct u16;
InputTick :: #type,distinct u16;

TickDistance :: (from: ServerTick, to: ServerTick) -> s64
{
  // Calculates distance between ticks with wrapping consideration.
  // Calculates unwrapped and wrapped scenario and picks one with smaller absolute distance.
  f := from.(s64);
  t := to.(s64);

  d0 := t - f;
  d1 := t + U16_MAX - f;

  abs_d0 := ifx d0 >= 0 then d0 else -d0;
  abs_d1 := ifx d1 >= 0 then d1 else -d1;

  result := ifx abs_d1 > abs_d0 then abs_d0 else abs_d1;
  return result;
}

//
// SLOP
//

TimeReference :: enum
{
  FRAME; // timestamp taken at the start of the frame
  NOW; // new timestamp measurement
}

ServerSecondsSinceServerTick :: (start_server_tick: Tick, max_on_fail: bool) -> float, bool
{
  return 0.0, false;
}

ElapsedSeconds :: (start: Timestamp, finish_reference := TimeReference.FRAME, max_on_fail := false) -> float, bool
{
  return 0.0, false;
}
ElapsedSeconds :: (start: Timestamp, finish: Timestamp, max_on_fail := false) -> float, bool
{
  return 0.0, false;
}

// Tick
Tick :: #type,distinct s64;
Tick_MAX :: cast(Tick) S64_MAX;


GetClientInputTick :: () -> Tick
{
  return 0;
}

GetClientPlaybackTick :: () -> Tick
{
  return 0;
}

GetServerTick :: () -> Tick
{
  return 0;
}

#if 0 {

TimeState :: struct
{
  frame_number: s64;
  frame_timestamp: Timestamp;
  frame_timestamp_accumulator: Timestamp;
  delta_timestamp: Timestamp;
  dt: float;
  at: float;
}

FrameNumber :: inline () -> s64 { return context.R.time.frame_number; }
DeltaTime :: inline () -> float { return context.R.time.dt; }
AnimTime :: inline () -> float { return context.R.time.at; }
DeltaTimestamp :: inline () -> Timestamp { return context.R.time.delta_timestamp; }

GetTimestamp :: (reference := TimeReference.FRAME) -> Timestamp
{
  if #complete reference == {
    case .FRAME; return context.R.time.frame_timestamp;
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

AdvanceFrameTimestamp :: ()
{
  new_timestamp := GetTimestamp(.NOW);
  context.R.time.delta_timestamp = min(new_timestamp - context.R.time.frame_timestamp, 200); // clamp dt to 200ms (5fps)
  context.R.time.frame_timestamp = new_timestamp;

  context.R.time.frame_number += 1;
  context.R.time.frame_timestamp_accumulator += context.R.time.delta_timestamp;

  context.R.time.dt = context.R.time.delta_timestamp * 0.001;
  context.R.time.at = WrapFloat(context.R.time.at + context.R.time.dt, 0, 1000);
}

InitFrameTimestamp :: ()
{
  AdvanceFrameTimestamp();
  AdvanceFrameTimestamp();
  context.R.time.frame_number = 1;
  context.R.time.frame_timestamp_accumulator = 0;
}



GetClientInputTick :: () -> Tick
{
  assert(context.role == .CLIENT);
  return G.cl.input_tick;
}

GetClientPlaybackTick :: () -> Tick
{
  assert(context.role == .CLIENT);
  return G.cl.playback_tick;
}

GetServerTick :: () -> Tick
{
  assert(context.role == .SERVER);
  return G.sv.tick;
}


ClientTimestampOfServerTick :: (server_tick: Tick, max_on_fail: bool) -> Timestamp, bool
{
  assert(context.role == .CLIENT);

  if !IndexInBounds(G.cl.server_tick_to_client_timestamps, server_tick) return FailTimestamp(max_on_fail), false;
  return G.cl.server_tick_to_client_timestamps[server_tick], true;
}

ClientSecondsSinceServerTick :: (start_server_tick: Tick, max_on_fail: bool) -> float, bool
{
  assert(context.role == .CLIENT);

  if !IndexInBounds(G.cl.server_tick_to_client_timestamps, start_server_tick) return FailSeconds(max_on_fail), false;
  start_client_timestamp := G.cl.server_tick_to_client_timestamps[start_server_tick];
  f, b := ElapsedSeconds(start_client_timestamp);
  return f, b;
}

ServerSecondsSinceServerTick :: (start_server_tick: Tick, max_on_fail: bool) -> float, bool
{
  assert(context.role == .SERVER);

  current_server_tick := G.sv.tick;
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
}