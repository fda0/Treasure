Snapshot :: struct
{
  obj: Object;
  tick: ServerTick;
  received_time: Timestamp;
}

Ghost :: struct
{
  at: Snapshot;
  from: Snapshot;
  dest: Snapshot;

  tick_t: float = 1.0; // 0 = from_tick; 1 = to_tick
  tick_speed := 1.0;

  handled_tick: ServerTick;
  creation_time: Timestamp;
  death_time: Timestamp;

  anim: AnimationState;

  #overlay(at) using #as at_obj: Object;
}

IsTickDue :: (tick: ServerTick, ghost: Ghost) -> bool
{
  was_handled := tick < ghost.handled_tick;
  is_in_the_future := tick > ghost.at.tick;
  return !was_handled && !is_in_the_future;
}
