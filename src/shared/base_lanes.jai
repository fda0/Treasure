// Lane/Wavefront multithreading - raddebugger / cmuratori inspired
// https://www.rfleury.com/p/multi-core-by-default

// Per thread state
#add_context lane: LaneContext;

// Structures
LaneGroup :: struct
{
  threads: [] Thread;
  barrier: Barrier;
  broadcast_memory: u64;
}

LaneContext :: struct
{
  lane_id: s64;
  lane_count: s64;
  barrier: *Barrier;
  broadcast_memory: *u64;
}

// Create/Launch
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
      thread_init(it, proc);
      thread_start(it);
    }
  }

  if launch_lane0_on_this_thread
  {
    push_context group.threads[0].starting_context {
      proc(null);
    }
  }
}

//
// Basic
//
LaneIdx :: inline () -> s64 { return context.lane.lane_id; }
LaneCount :: inline () -> s64 { return context.lane.lane_count; }
LaneSync :: inline () { BarrierWait(context.lane.barrier); }

//
// TaskIdx
//
LaneFromTaskIdx :: inline (task_id: s64) -> s64
{
  return task_id % context.lane.lane_count;
}
IsLaneFromTaskIdx :: inline (i: s64) -> bool
{
  return LaneIdx() == LaneFromTaskIdx(i);
}

//
// Work range
//
LaneRangeFromIdxCount :: inline (work_count: s64, lane_idx: s64, lane_count: s64) -> Range(s64)
{
  work_per_lane := work_count / lane_count;
  work_left := work_count % lane_count;

  // busy_count & lazy_count are equal to the amount of busy/lazy lanes before lane_idx.
  // busy lanes are handling the reminder of work therefore they have have +1 of work
  // lazy lanes have regular amount of work
  busy_count := min(work_left, lane_idx);
  lazy_count := min(lane_count - work_left, lane_idx - busy_count);

  result: Range(s64);
  result.min = ((work_per_lane + 1) * busy_count) + (work_per_lane * lazy_count);
  result.max = result.min + work_per_lane + (ifx lane_idx < work_left then 1);
  return result;
}

LaneRange :: inline (work_count: s64) -> Range(s64)
{
  return LaneRangeFromIdxCount(work_count, LaneIdx(), LaneCount());
}

LaneRange :: inline (work_items: [] $T) -> [] T
{
  range_idx := LaneRange(work_items.count);
  return ArrayMinMax(work_items, range_idx.min, range_idx.max);
}

//
// Assert helpers
//
AssertThatOnlyOneLaneEverReachedThisCodepath :: () #expand {
  unique_s64 := #run UniqueS64(-1);
  lane_idx := LaneIdx();
  if unique_s64.* < 0 {
    unique_s64.* = lane_idx;
  }
  assert(unique_s64.* == lane_idx);
}

AssertThatScopeIsSingleThreaded :: () #expand {
  UNSET_VALUE : s64 : -1;
  unique_value := #run UniqueS64(UNSET_VALUE);
  lane_idx := LaneIdx();

  swapped, old_value := compare_and_swap(unique_value, UNSET_VALUE, lane_idx);
  if !swapped && old_value != lane_idx {
    assert(false);
  }

  `defer {
    unique_value.* = UNSET_VALUE;
  }
}

