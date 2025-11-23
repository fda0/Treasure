// Lane/Wavefront multithreading - raddebugger / cmuratori inspired
// https://www.rfleury.com/p/multi-core-by-default

#add_context lane: LaneContext;

LaneGroup :: struct
{
  threads: [] Thread;
  barrier: Barrier;
  broadcast_memory: u64;
}

LaneGroupCreate :: (thread_count: s64) -> *LaneGroup
{
  group := New(LaneGroup);
  group.threads = NewArray(thread_count, Thread);
  BarrierInit(*group.barrier, xx group.threads.count);

  for *group.threads
  {
    it.starting_context = context;
    it.starting_context.lane = .{
      lane_id = it_index,
      lane_count = group.threads.count,
      barrier = *group.barrier,
      broadcast_memory = *group.broadcast_memory,
    };
  }

  return group;
}

LaneGroupLaunch :: (proc: Thread_Proc, group: *LaneGroup, launch_lane0_on_this_thread: bool)
{
  for *group.threads
  {
    if it_index > 0 || !launch_lane0_on_this_thread
    {
      thread_init(it, G_LoopThreadEntry);
      thread_start(it);
    }
  }

  if launch_lane0_on_this_thread
  {
    push_context group.threads[0].starting_context
    {
      proc(null);
    }
  }
}

LaneContext :: struct
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
