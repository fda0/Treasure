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
  if count <= depth return null;
  peek_index := (start_offset + depth) % MAX_CAPACITY;
  return *buffer[peek_index];
}

QueuePeek :: (using queue: Queue, depth := 0) -> queue.T
{
  default: T;
  if count <= depth return default;
  peek_index := (start_offset + depth) % MAX_CAPACITY;
  return buffer[peek_index];
}

QueuePeekLast :: (using queue: Queue, depth := 0) -> queue.T
{
  default: T;
  if count <= depth return default;
  peek_index := (start_offset + MAX_CAPACITY - 1 - depth) % MAX_CAPACITY;
  return buffer[peek_index];
}

QueuePop :: (using queue: *Queue) -> queue.T, bool
{
  item := QueuePeek(queue);
  success := false;
  if count > 0
  {
    start_offset = (start_offset + 1) % MAX_CAPACITY;
    count -= 1;
    success = true;
  }
  return item, success;
}

//
