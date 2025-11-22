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

  // Object data that's kept on client side only
  animated_rot: Quat; // animates towards rotation
  animated_p: V3; // animates towards (V3){p.x, p.y, p.z}

  anim: struct {
    is_walking: float; // 0=idle; 1=walking; 2=running
    walk_cycle: float;

    is_attacking: float;
    is_hit: float;

    tracks: [10] ANIMATION_Track;
  };

  #place at;
  using #as at_obj: Object; // @todo remove? rename?
};

IsTickDue :: (action_tick: ServerTick, ghost: Ghost) -> bool
{
  was_handled := action_tick < ghost.handled_tick;
  is_in_the_future := action_tick > ghost.at.tick;
  return !was_handled && !is_in_the_future;
}
