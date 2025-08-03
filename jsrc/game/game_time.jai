// TimestampMS
TimestampMS :: #type,distinct u64;

TimestampType :: enum
{
  FRAME; // timestamp taken at the start of the frame
  NOW; // new timestamp measurement
}

GetTimestampMS :: (type := TimestampType.FRAME) -> TimestampMS
{
  if #complete type == {
    case .FRAME; return G.frame_timestamp;
    case .NOW; return xx SDL_GetTicks();
  }
}

ElapsedTimeMS :: (from: TimestampMS, to: TimestampMS, max_on_fail := false) -> TimestampMS
{
  if from > to return cast(TimestampMS) ifx max_on_fail then ~0 else 0;
  return to - from;
}

ElapsedTimeMS :: (from: TimestampMS, to_type := TimestampType.FRAME, max_on_fail := false) -> TimestampMS
{
  return ElapsedTimeMS(from, GetTimestampMS(to_type), max_on_fail);
}

ElapsedTimeS :: (from: TimestampMS, to: TimestampMS, max_on_fail := false) -> float
{
  if from > to return ifx max_on_fail then FLOAT32_MAX else 0;
  if (to - from) > FLOAT32_MAX.(u64) return FLOAT32_MAX;
  return (to - from).(float) * 0.001;
}

ElapsedTimeS :: (from: TimestampMS, to_type := TimestampType.FRAME, max_on_fail := false) -> float
{
  return ElapsedTimeS(from, GetTimestampMS(to_type), max_on_fail);
}

// Tick
Tick :: #type,distinct u64;

GetTick :: () -> Tick
{
  return xx G.tick_number;
}

TimeBetweenTicksMS :: (start: Tick, end: Tick, max_on_fail := false) -> TimestampMS
{
  if start > end
  {
    if max_on_fail return ~0;
    else           return  0;
  }
  delta := end - start;
  return xx (delta * TICK_MILLISECONDS_STEP);
}

TimeSinceTickMS :: (start: Tick, max_on_fail := false) -> TimestampMS
{
  return TimeBetweenTicksMS(start, GetTick(), max_on_fail);
}

TimeBetweenTicksS :: (start: Tick, end: Tick, max_on_fail := false) -> float
{
  if start > end
  {
    if max_on_fail return FLOAT32_MAX;
    else           return 0.0;
  }
  delta := end - start;
  return delta * TICK_FLOAT_STEP;
}

TimeSinceTickS :: (start: Tick, max_on_fail := false) -> float
{
  return TimeBetweenTicksS(start, GetTick(), max_on_fail);
}
