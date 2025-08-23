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

#scope_file;
ReserveFloatRange :: (init_floats: [] float) -> s64
{
  index := UniqueFloatCounter;
  UniqueFloatCounter += init_floats.count;
  assert(UniqueFloatCounter < UniqueFloatArray.count);

  memcpy(*UniqueFloatArray[index], init_floats.data, init_floats.count * size_of(float));
  return index;
}

#no_reset UniqueFloatCounter := 0;
#no_reset UniqueFloatArray: [1024] float;
