Queue :: struct($CAPACITY: s64, $T: Type)
{
  count: s64;
  start_offset: s64;
  buffer: [CAPACITY] T;
}

for_expansion :: (using queue: Queue, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // @todo extend support
  `it_index := 0;
  while true
  {
    if it_index >= count break;
    `it := buffer[(start_offset + it_index) % CAPACITY];
    defer it_index += 1;
    #insert body;
  }
}

QueueIsFull :: (using queue: Queue) -> bool
{
  return count == CAPACITY;
}

QueueSpaceLeft :: (using queue: Queue) -> s64
{
  return CAPACITY - count;
}

QueueIsEmpty :: (using queue: Queue) -> bool
{
  return count <= 0;
}

QueuePush :: (using queue: *Queue, $initialize := true) -> *queue.T
{
  push_at_index := (start_offset + count) % CAPACITY;
  count += 1;
  if count > CAPACITY
  {
    push_at_index = start_offset % CAPACITY;
    start_offset = (start_offset + 1) % CAPACITY;
    count = CAPACITY;
  }

  result := *buffer[push_at_index];
  #if initialize Initialize(result);
  return result;
}

QueuePush :: (q: *Queue, value: q.T)
{
  QueuePush(q).* = value;
}

QueuePush :: (q: *Queue, values: [] q.T)
{
  for values QueuePush(q, it);
}
QueuePush :: (q: *Queue, values: ..q.T)
{
  for values QueuePush(q, it);
}

QueuePeekPointer :: (using queue: *Queue, depth := 0) -> *queue.T
{
  if count <= depth return null;
  peek_index := (start_offset + depth) % CAPACITY;
  return *buffer[peek_index];
}

QueuePeek :: (using queue: Queue, depth := 0) -> queue.T
{
  default: T;
  if count <= depth return default;
  peek_index := (start_offset + depth) % CAPACITY;
  return buffer[peek_index];
}

QueuePeekLast :: (using queue: Queue, depth := 0) -> queue.T
{
  default: T;
  if count <= depth return default;
  peek_index := (start_offset + count - 1 - depth) % CAPACITY;
  return buffer[peek_index];
}

QueuePop :: (using queue: *Queue) -> queue.T, bool
{
  item := QueuePeek(queue);
  success := false;
  if count > 0
  {
    start_offset = (start_offset + 1) % CAPACITY;
    count -= 1;
    success = true;
  }
  return item, success;
}
