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

  anim: struct {
    rotation: Quat; // animates towards at.obj.rotation
    position: V3; // animates towards at.obj.p

    idle_cycle: float;
    walk_cycle: float;
    is_walking_weight: float; // 0=idle; 1=walking; 2=running
    is_attacking_weight: float;
    is_hit_weight: float;
  };

  #place at;
  using #as at_obj: Object;
};

IsTickDue :: (action_tick: ServerTick, ghost: Ghost) -> bool
{
  was_handled := action_tick < ghost.handled_tick;
  is_in_the_future := action_tick > ghost.at.tick;
  return !was_handled && !is_in_the_future;
}
