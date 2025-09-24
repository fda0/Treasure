FixedArray :: struct($CAPACITY: s64, $T: Type)
{
  data: [CAPACITY] T;
  count: s64;
}

operator [] :: (fa: *FixedArray, i: s64) -> fa.T
{
  assert(i < fa.count);
  return fa.data[i];
}

operator []= :: inline (fa: *FixedArray, i: int, value: fa.T)
{
  assert(i < fa.count);
  fa.data[i] = value;
}
