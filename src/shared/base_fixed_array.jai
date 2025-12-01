Fixed :: struct($CAPACITY: s64, $T: Type)
{
  ELEMENT_SIZE :: size_of(T);
  DATA_SIZE :: CAPACITY * ELEMENT_SIZE;
  buf: [CAPACITY] T = ---;
  count: s64;
}

to_view :: (f: Fixed) -> [] f.T
{
  res: [] f.T;
  res.data = f.buf.data;
  res.count = f.count;
  return res;
}

operator [] :: (f: Fixed, i: s64) -> f.T
{
  assert(i < f.count);
  return f.buf[i];
}

operator []= :: inline (f: *Fixed, i: int, value: f.T)
{
  assert(i < f.count);
  f.buf[i] = value;
}

for_expansion :: (f: $A/Fixed, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // @todo extend support
  `it_index := 0;
  while true
  {
    if it_index >= f.count break;
    defer it_index += 1;

    `it := f.buf[it_index];
    #insert body;
  }
}

array_size_bytes :: (f: Fixed) -> s64
{
  return f.count * f.ELEMENT_SIZE;
}

array_space_left :: (f: Fixed) -> s64
{
  return f.CAPACITY - f.count;
}

array_reset :: (f: *Fixed)
{
  f.count = 0;
}

array_add :: (f: *Fixed, item: f.T) -> bool
{
  added := false;
  if f.count < f.CAPACITY
  {
    added = true;
    f.buf[f.count] = item;
    f.count += 1;
  }
  return added;
}

array_add :: (f: *Fixed, $initialize := true) -> *f.T, bool
{
  if f.count < f.CAPACITY
  {
    result := *f.buf[f.count];
    f.count += 1;
    Initialize(result);
    return result, true;
  }
  return null, false;
}

array_add_many :: (f: *Fixed, alloc_count: s64, $initialize:=true) -> allocated_slice: [] f.T, bool
{
  truncated := false;
  space_left := f.CAPACITY - f.count;
  if alloc_count > space_left
  {
    alloc_count = space_left;
    truncated = true;
  }

  if alloc_count <= 0 then return .[], false;

  res: [] f.T;
  res.count = alloc_count;
  res.data = *f.buf[f.count];

  #if initialize {
    // @todo Call Ini if it exists for this type
    memset(res.data, 0, res.count);
  }

  f.count += alloc_count;
  return res, !truncated;
}
