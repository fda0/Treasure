Queue :: struct($CAPACITY: s64, $T: Type, OVERWRITE_ON_OVERFLOW := true)
{
  min: u64;
  max: u64;
  buffer: [CAPACITY] T = ---;
  #assert(CAPACITY > 0);
}

for_expansion :: (q: Queue, body: Code, flags: For_Flags) #expand
{
  #assert((flags & ~.POINTER) == 0); // @todo extend support

  count := QueueCount(q);
  `it_index := 0;
  while true
  {
    if it_index >= count break;
    defer it_index += 1;

    #if flags & .POINTER {
      `it := *q.buffer[(q.min + it_index.(u64)) % q.CAPACITY];
    } else  {
      `it := q.buffer[(q.min + it_index.(u64)) % q.CAPACITY];
    }

    #insert body;
  }
}

QueueCount :: (q: Queue) -> s64
{
  result := (q.max - q.min);
  if q.min > q.max {
    result = q.max + (U64_MAX - q.min + 1);
  }
  if result > q.CAPACITY {
    assert(false);
    result = q.CAPACITY;
  }
  return xx result;
}

QueueEmptyCount :: (q: Queue) -> s64
{
  return q.CAPACITY - QueueCount(q);
}

QueueIsEmpty :: (q: Queue) -> bool
{
  return QueueCount(q) == 0;
}

QueueIsFull :: (q: Queue) -> bool
{
  return QueueCount(q) == q.CAPACITY;
}

QueuePush :: (q: *Queue, $initialize := true) -> *q.T
{
  is_full := QueueIsFull(q);
  if !q.OVERWRITE_ON_OVERFLOW && is_full return null;

  push_idx := q.max % q.CAPACITY;
  q.max += 1;

  if is_full {
    q.min += 1;
  }

  result := *q.buffer[push_idx];
  #if initialize Initialize(result);
  return result;
}

QueuePush :: (q: *Queue, value: q.T)
{
  is_full := QueueIsFull(q);
  if !q.OVERWRITE_ON_OVERFLOW && is_full return;
  QueuePush(q, false).* = value;
}

QueuePush :: (q: *Queue, values: [] q.T)
{
  for values QueuePush(q, it);
}
QueuePush :: (q: *Queue, values: ..q.T) { QueuePush(q, values); }

QueuePeekPtr :: (q: *Queue, depth := 0) -> *q.T
{
  if q.min == q.max return null;

  peek_idx := (q.min + depth.(u64)) % q.CAPACITY;
  return *q.buffer[peek_idx];
}

QueuePeek :: (q: Queue, depth := 0) -> q.T, bool
{
  default: q.T;
  if q.min == q.max return default, false;

  peek_idx := (q.min + depth.(u64)) % q.CAPACITY;
  return q.buffer[peek_idx], true;
}

QueuePeekReverse :: (q: Queue, depth := 0) -> q.T, bool
{
  default: q.T;
  if q.min == q.max return default, false;

  peek_idx := (q.max - 1 - depth.(u64)) % q.CAPACITY;
  return q.buffer[peek_idx], true;
}

QueuePop :: (q: *Queue) -> q.T, bool
{
  item, has_items := QueuePeek(q);
  if !has_items return item, false;

  q.min += 1;
  return item, true;
}
