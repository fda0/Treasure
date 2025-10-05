#add_context role: Role;
#add_context R: *RoleState;
#add_context lane: LaneState;

Role :: enum
{
  NOT_SET;
  SERVER;
  CLIENT;
}

RoleState :: struct
{
  frame_timestamp: Timestamp;
  obj: OBJ_State;
}

CreateContextWithRole :: (role: Role) -> (result: #Context)
{
  ctx := context;
  ctx.role = role;

  if      role == .SERVER  ctx.R = *G.client.role_state;
  else if role == .CLIENT  ctx.R = *G.server.role_state;
  else                             assert(false);
  return ctx;
}

// Lane/Wavefront multithreading - raddebugger / cmuratori inspired
LaneState :: struct
{
  lane_id: s64;
  lane_count: s64;
  barrier: *Barrier;
  broadcast_memory: *u64;
}

LaneIdx :: () -> s64
{
  assert(context.lane.lane_count > 0);
  return context.lane.lane_id;
}

LaneCount :: () -> s64
{
  return context.lane.lane_count;
}

LaneFromTaskIdx :: (task_id: s64) -> s64
{
  return task_id % context.lane.lane_count;
}

LaneSync :: ()
{
  BarrierWait(context.lane.barrier);
}

AssertThatSingleThreadReachesThisCodepath :: () #expand
{
  unique_s64 := #run UniqueS64(-1);
  lane_idx := LaneIdx();
  if unique_s64.* < 0
  {
    unique_s64.* = lane_idx;
  }
  assert(unique_s64.* == lane_idx);
}

AssertThatScopeIsSingleThreaded :: () #expand
{
  UNSET_VALUE : s64 : -1;
  unique_value := #run UniqueS64(UNSET_VALUE);
  lane_idx := LaneIdx();

  swapped, old_value := compare_and_swap(unique_value, UNSET_VALUE, lane_idx);
  if !swapped && old_value != lane_idx
  {
    assert(false);
  }

  `defer {
    unique_value.* = UNSET_VALUE;
  }
}
