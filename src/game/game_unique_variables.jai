//
// Each call to UniqueFloat generates an unnamed global variable, initialized statically.
// Multiple calls to UniqueFloat from the same place in the source code will result in the same float being returned.
//

UniqueFloat :: ($init := 0.0) -> *float #expand
{
  index := #run -> s64 {
    number := init;
    array := []float.{data = *number, count = 1};
    return ReserveFloatRange(array);
  }
  return *UniqueFloatArray[index];
}

UniqueV2 :: ($init := V2.{}) -> *V2 #expand
{
  index := #run ReserveFloatRange(init.component);
  return (*UniqueFloatArray[index]).(*V2);
}

UniqueTimestamp :: ($init: Timestamp = 0) -> *Timestamp #expand
{
  index := #run -> s64 {
    number := init.(s64);
    array := []s64.{data = *number, count = 1};
    return ReserveS64Range(array);
  }
  return (*UniqueS64Array[index]).(*Timestamp);
}

#scope_file;
ReserveFloatRange :: (init_floats: [] float) -> s64
{
  index := UniqueFloatCounter;
  UniqueFloatCounter += init_floats.count;
  assert(UniqueFloatCounter < UniqueFloatArray.count);

  memcpy(*UniqueFloatArray[index], init_floats.data, init_floats.count * size_of(float));
  return index;
}

ReserveS64Range :: (init_s64s: [] s64) -> s64
{
  index := UniqueS64Counter;
  UniqueS64Counter += init_s64s.count;
  assert(UniqueS64Counter < UniqueS64Array.count);

  memcpy(*UniqueS64Array[index], init_s64s.data, init_s64s.count * size_of(float));
  return index;
}

#no_reset UniqueFloatCounter := 0;
#no_reset UniqueFloatArray: [1024] float;

#no_reset UniqueS64Counter := 0;
#no_reset UniqueS64Array: [1024] s64;
