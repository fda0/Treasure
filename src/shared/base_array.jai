// Common string-like operations for array views
ArrayRange :: (first: *$T, last: *T) -> [] T
{
  res: [] T;
  res.data = first;
  res.count = cast(s64)last - cast(s64)first;
  return res;
}
ArraySubarray :: (array: [] $T, sub_min: s64, sub_max: s64) -> [] T
{
  sub_max = clamp(sub_max, 0, array.count);
  sub_min = clamp(sub_min, 0, array.count);
  if sub_min > sub_max  Swap(*sub_min, *sub_max);

  res: [] T;
  res.count = sub_max - sub_min;
  res.data = array.data + sub_min;
  return res;
}
ArraySkip :: (array: [] $T, distance: s64) -> [] T
{
  distance = clamp(distance, 0, array.count);

  res := array;
  res.data += distance;
  res.count -= distance;
  return res;
}
ArrayChop :: (array: [] $T, distance_from_end: s64) -> [] T
{
  distance_from_end = clamp(distance_from_end, 0, array.count);

  res := array;
  res.count -= distance_from_end;
  return res;
}
ArrayPrefix :: (array: [] $T, count: s64) -> [] T
{
  count = clamp(count, 0, array.count);

  res := array;
  res.count = count;
  return res;
}
ArraySuffix :: (array: [] $T, count: s64) -> [] T
{
  count = clamp(count, 0, array.count);
  distance := array.count - count;

  res := array;
  res.data += distance;
  res.count = count;
  return res;
}

IndexInBounds :: (array: [] $T, index: s64) -> bool
{
  return index >= 0 && index < array.count;
}

// Dynamic array helpers
array_add_many :: (array: *[..] $T, alloc_count: s64, $initialize:=true) -> allocated_slice: [] T
{
  initial_count := array.count;
  new_count := initial_count + alloc_count;
  array_resize(array, new_count, initialize);
  result := ArraySubarray(array.*, initial_count, new_count);
  return result;
}

array_add_copy :: (array: *[..] $T, copy_from: [] T) -> allocated_slice: [] T
{
  dst := array_add_many(array, copy_from.count, initialize=false);
  memcpy(dst.data, copy_from.data, copy_from.count*size_of(T));
  return dst;
}

#scope_file
#import "Basic"; // for clamp
