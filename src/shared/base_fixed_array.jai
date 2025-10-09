FixedArray :: struct($CAPACITY: s64, $T: Type, $zero_init := false)
{
  #if zero_init  data: [CAPACITY] T;
  else           data: [CAPACITY] T = ---;
  count: s64;
}

to_view :: (array: *FixedArray) -> [] array.T
{
  res: [] array.T;
  res.data = array.data;
  res.count = array.count;
  return res;
}

operator [] :: (array: *FixedArray, i: s64) -> array.T
{
  assert(i < array.count);
  return array.data[i];
}

operator []= :: inline (array: *FixedArray, i: int, value: array.T)
{
  assert(i < array.count);
  array.data[i] = value;
}

for_expansion :: (array: $A/FixedArray, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // @todo extend support
  `it_index := 0;
  while true
  {
    if it_index >= range.count break;
    defer it_index += 1;

    `it := array.data[it_index];
    #insert body;
  }
}

array_space_left :: (array: *FixedArray) -> s64
{
  return array.CAPACITY - array.count;
}

array_add :: (array: *FixedArray, item: array.T) -> bool
{
  added := false;
  if array.count < array.CAPACITY
  {
    added = true;
    array.data[array.count] = item;
    array.count += 1;
  }
  return added;
}

array_add :: (array: *FixedArray) -> *array.T, bool
{
  if array.count < array.CAPACITY
  {
    result := *array.data[array.count];
    array.count += 1;
    return result, true;
  }
  return null, false;
}

array_add_many :: (array: *FixedArray, alloc_count: s64, $initialize:=true) -> allocated_slice: [] array.T, bool
{
  truncated := false;
  space_left := array.CAPACITY - array.count;
  if alloc_count > space_left
  {
    alloc_count = space_left;
    truncated = true;
  }

  if alloc_count <= 0 then return .[], false;

  res: [] array.T;
  res.count = alloc_count;
  res.data = *array.data[array.count];

  // @todo Call Ini if it exists for this type
  memset(res.data, 0, res.count);

  array.count += alloc_count;
  return res, !truncated;
}
