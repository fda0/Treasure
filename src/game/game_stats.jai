#scope_file;
using,only(G,STATS) COMPS;
#scope_export;

LOG_STAT_COUNTERS :: false;

STATS_State :: struct
{
  counters: [STATS_CounterCount] STATS_Counter;
}

STATS_CounterType :: enum
{
  DELTA_TIMESTMAP_MS;
  SV_GET_PLAYER_INPUT_QUEUE_SIZE;
  TEST_FRAME_NUMBER;
  NEXT_PLAYBACK_SV_TICK;
}
STATS_CounterCount :: #run EnumCount(STATS_CounterType);
STATS_CounterNames :: #run enum_names(STATS_CounterType);
STATS_CounterValues :: #run enum_values_as_enum(STATS_CounterType);

STATS_Counter :: struct
{
  paused: bool;
  increment_called: bool;

  accumulator: s64;
  history: Queue(64 * 4, s64);
  total_sum: s64;
  on_peak_frame: s64;
  peak_frame_number: s64;

  graph_scale: float;
}

Increment :: (type: STATS_CounterType, to_increment: s64)
{
  c := *STATS.counters[type];
  if c.paused return;
  c.increment_called = true;

  c.total_sum += to_increment;
  c.accumulator += to_increment;
}

Post :: (type: STATS_CounterType, to_increment_and_set: s64 = 0)
{
  c := *STATS.counters[type];
  label := STATS_CounterNames[type];
  if c.paused return;

  c.total_sum += to_increment_and_set;
  c.accumulator += to_increment_and_set;

  if c.on_peak_frame < c.accumulator
  {
    c.on_peak_frame = c.accumulator;
    c.peak_frame_number = G.frame_number;
  }

  if LOG_STAT_COUNTERS
  {
    log("[FRAME %; STATS %] total: %; this_frame: %; on_peak_frame: % (on %)",
      G.frame_number, label,
      c.total_sum, c.accumulator, c.on_peak_frame, c.peak_frame_number,, logger = LOG_FileLogger);
  }

  QueuePush(*c.history, c.accumulator);
  c.accumulator = 0;
}

STATS_PostFrame :: ()
{
  for STATS_CounterValues
  {
    c := *STATS.counters[it];
    if c.increment_called
    {
      Post(it);
      c.increment_called = false;
    }
  }
}
