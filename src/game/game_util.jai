TickDeltas :: struct
{
  // This tracks things like every-increasing U64 ticks
  // last_tick == 0 is a special case that will trigger
  // init code
  last_tick: Tick;
  deltas: [64] u16;
  next_delta_index: u16;
  tick_catchup: u16;
};

TickDeltas_AddTick :: (td: *TickDeltas, tick: Tick) -> bool
{
  if td.last_tick == tick
    return false;

  first_init := !td.last_tick;
  td.last_tick = tick;

  if first_init
    return false;

  delta_u64 := ifx td.last_tick > tick then 0 else tick - td.last_tick;
  delta := CastSaturate(u16, delta_u64);

  index := td.next_delta_index;
  td.next_delta_index = (td.next_delta_index + 1) % td.deltas.count;

  td.deltas[index] = delta;
  return true;
}

TickDeltas_UpdateCatchup :: (td: *TickDeltas, current_delta: u16)
{
  if (!td.last_tick)
  return;

  max_delta: u16;
  for td.deltas
    max_delta = max(max_delta, it);

  target_delta := max_delta + (max_delta / 16) + 4;
  if current_delta > target_delta
    td.tick_catchup = current_delta - target_delta;
  else
    td.tick_catchup = 0;
}
