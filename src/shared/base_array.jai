// Common string-like operations for array views
ArrayFirstLast :: (first: *$T, last: *T) -> [] T
{
  res: [] T;
  res.data = first;
  res.count = cast(s64)last - cast(s64)first;
  return res;
}
ArrayMinMax :: (array: [] $T, sub_min: s64, sub_max: s64) -> [] T
{
  sub_max = clamp(sub_max, 0, array.count);
  sub_min = clamp(sub_min, 0, array.count);
  if sub_min > sub_max  swap(*sub_min, *sub_max);

  res: [] T;
  res.count = sub_max - sub_min;
  res.data = array.data + sub_min;
  return res;
}
Subarray :: (array: [] $T, offset: s64, count: s64) -> [] T
{
  offset = clamp(offset, 0, array.count);
  count = min(count, array.count - offset);
  count = max(count, 0);

  res: [] T;
  res.count = count;
  res.data = array.data + offset;
  return res;
}
Skip :: (array: [] $T, distance: s64) -> [] T
{
  // Skip(.[1,2,3,4,5,6], 2) -> .[3, 4, 5, 6]
  distance = clamp(distance, 0, array.count);
  res := array;
  res.data += distance;
  res.count -= distance;
  return res;
}
Chop :: (array: [] $T, distance_from_end: s64) -> [] T
{
  // Chop(.[1,2,3,4,5,6], 2) -> .[1, 2, 3, 4]
  distance_from_end = clamp(distance_from_end, 0, array.count);
  res := array;
  res.count -= distance_from_end;
  return res;
}
Prefix :: (array: [] $T, count: s64) -> [] T
{
  // Prefix(.[1,2,3,4,5,6], 2) -> .[1, 2]
  count = clamp(count, 0, array.count);
  res := array;
  res.count = count;
  return res;
}
Suffix :: (array: [] $T, count: s64) -> [] T
{
  // Suffix(.[1,2,3,4,5,6], 2) -> .[5, 6]
  count = clamp(count, 0, array.count);
  distance := array.count - count;
  res := array;
  res.data += distance;
  res.count = count;
  return res;
}

is_index_in_bounds :: (array: [] $T, index: s64) -> bool {
  return index >= 0 && index < array.count;
}
is_pointer_in_bounds :: (array: [] $T, pointer: *T) -> bool {
  return array.data <= pointer && (array.data + array.count) > pointer;
}

array_size_bytes :: (array: [] $T) -> s64 {
  return array.count * size_of(T);
}

// Dynamic array helpers
array_alloc :: (array: *[..] $T, alloc_count: s64, $initialize:=true) -> allocated_slice: [] T
{
  initial_count := array.count;
  new_count := initial_count + alloc_count;
  array_resize(array, new_count, initialize);
  result := ArrayMinMax(array.*, initial_count, new_count);
  return result;
}

array_add_from_array :: (array: *[..] $T, src: [] T) -> new_elements: [] T
{
  dst := array_alloc(array, src.count, initialize=false);
  memcpy(dst.data, src.data, src.count*size_of(T));
  return dst;
}

array_add_many :: (array: *[..] $T, src: *T, count: s64) -> new_elements: [] T
{
  dst := array_alloc(array, count, initialize=false);
  memcpy(dst.data, src, count*size_of(T));
  return dst;
}

PointerToIndex :: (array: [] $T, pointer: *T) -> s64
{
  assert(pointer >= array.data && pointer < array.data + array.count);
  offset := (pointer.(u64) - array.data.(u64)).(s64);
  index := offset / size_of(T);
  return index;
}

ArrayMemcpy :: (dst: [] $D, src: [] $S)
{
  dst_size := size_of(D)*dst.count;
  src_size := size_of(S)*src.count;
  smaller_size := ifx dst_size > src_size then src_size else dst_size;
  memcpy(dst.data, src.data, smaller_size);
}

ArrayClear :: (dst: [] $T)
{
  size := size_of(T) * dst.count;
  memset(dst.data, 0, size);
}

#scope_file
#import "Basic"; // for clamp
