TickDeltas :: struct
{
  // This tracks things like every-increasing U64 ticks
  // last_tick == 0 is a special case that will trigger
  // init code
  last_tick: u64;
  deltas: [64] u16;
  next_delta_index: u16;
  tick_catchup: u16;
};

TickDeltas_AddTick :: (td: *TickDeltas, tick: u64) -> bool
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

Queue :: struct($MAX_CAPACITY: s64, $T: Type)
{
  count: s64;
  start_offset: s64;
  buffer: [MAX_CAPACITY] T;
}

for_expansion :: (using queue: Queue, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // @todo extend support
  `it_index := 0;
  while true
  {
    if it_index >= count break;
    `it := buffer[(start_offset + it_index) % MAX_CAPACITY];
    defer it_index += 1;
    #insert body;
  }
}

QueueIsFull :: (using queue: Queue) -> bool
{
  return count == MAX_CAPACITY;
}

QueueIsEmpty :: (using queue: Queue) -> bool
{
  return count <= 0;
}

QueuePush :: (using queue: *Queue, $initialize := true) -> *queue.T
{
  push_at_index := (start_offset + count) % MAX_CAPACITY;
  count += 1;
  if count > MAX_CAPACITY
  {
    push_at_index = start_offset % MAX_CAPACITY;
    start_offset = (start_offset + 1) % MAX_CAPACITY;
    count = MAX_CAPACITY;
  }

  result := *buffer[push_at_index];
  #if initialize Initialize(result);
  return result;
}

QueuePush :: (queue: *Queue, value: queue.T)
{
  QueuePush(queue).* = value;
}

QueuePeekPointer :: (using queue: *Queue, depth := 0) -> *queue.T
{
  if count <= depth then return null;
  peek_index := (start_offset + depth) % MAX_CAPACITY;
  return *buffer[peek_index];
}

QueuePeek :: (using queue: Queue, depth := 0) -> queue.T
{
  default: T;
  if count <= depth then return default;
  peek_index := (start_offset + depth) % MAX_CAPACITY;
  return buffer[peek_index];
}

QueuePop :: (using queue: *Queue) -> queue.T
{
  result := QueuePeek(queue);
  if count > 0
  {
    start_offset = (start_offset + 1) % MAX_CAPACITY;
    count -= 1;
  }
  return result;
}
