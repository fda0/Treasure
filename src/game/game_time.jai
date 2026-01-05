Timestamp :: #type,distinct s64; // @todo make this a signed type?
TimeNow :: () -> Timestamp { return xx SDL_GetTicks(); }

ToSeconds :: inline (t: Timestamp) -> float
{
  return t.(float) * 0.001;
}

Elapsed :: (current: Timestamp, since: Timestamp, max_on_fail := false) -> float
{
  delta := current - since;
  if !since || delta < 0 return FailTime(max_on_fail);
  return ToSeconds(delta);
}

FailTime :: (max_on_fail: bool) -> float
{
  return ifx max_on_fail then FLOAT32_MAX else 0;
}

SecondsBetweenTicks :: (current: ServerTick, since: ServerTick, max_on_fail := false) -> float
{
  if current < since return FailTime(max_on_fail);
  result := (current - since).(float) * TICK_FLOAT_STEP;
  return result;
}

Tick :: u32;
ServerTick :: #type,distinct Tick;
ActionTick :: #type,distinct Tick;
AnyTick :: Type.[Tick, ServerTick, ActionTick];

ServerTick_ZERO :: cast(ServerTick) 0;
ServerTick_ONE :: cast(ServerTick) 1;
ServerTick_MAX :: cast(ServerTick) U32_MAX;
