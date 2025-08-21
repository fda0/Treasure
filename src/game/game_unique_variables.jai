#no_reset UniqueFloatCounter := 0;
UniqueFloatArray: [..] float;

UniqueInit :: ()
{
  array_resize(*UniqueFloatArray, UniqueFloatCounter);
}

//
// Each call to UniqueFloat in the source code generates a unique index
// and returns a pointer to unique float.
// Multiple calls to UniqueFloat from the same place in the source code
// will result in the same float being returned.
// It's a way to quickly get unnamed global variable.
//
UniqueFloat :: () -> *float #expand
{
  index := #run -> s64 {
    index := UniqueFloatCounter;
    UniqueFloatCounter += 1;
    return index;
  }
  return *UniqueFloatArray[index];
}
