#import "Bit_Operations";

Kilobyte :: v => v * 1024;
Megabyte :: v => v * 1024 * 1024;
Gigabyte :: v => v * 1024 * 1024 * 1024;

EnumCount :: ($t: Type) -> s64
{
  return enum_highest_value(t) + 1;
}

//
ZeroAddress :: (dst: *void, count: s64)
{
  memset(dst, 0, count);
}

ZeroArray :: (arr: [] $T)
{
  if arr.count
    memset(arr.data, 0, size_of(T)*arr.count);
}

ZeroType :: (ptr: *$T)
{
  memset(ptr, 0, size_of(T));
}


CalculateMipMapCount :: (width: $T, height: T) -> T // @todo test
#modify { return IsInteger(T), "Argument is not of an integer type."; }
{
  max_dim := max(width, height);
  msb_plus_one := bit_scan_reverse(max_dim);
  return cast(T) msb_plus_one;
}

IsPointerAligned :: (ptr: *void, alignment: s64) -> bool
{
  ptr_val := cast(s64) ptr;
  missaligned := ptr_val % alignment;
  return missaligned == 0;
}

offset_of :: ($T: Type, $member: string, $debug_print := false) -> int #expand
{
  return #run -> int {
    ti := type_info(T);
    assert(ti.type == .STRUCT, "offset_of(%, %) can be used on structs only.", T, member);
    ts := cast(*Type_Info_Struct) ti;

    for ts.members
    {
      if it.name == member
      {
        if debug_print print("offset_of(%, %) returned %.\n", T, member, it.offset_in_bytes);
        return it.offset_in_bytes;
      }
    }

    assert(false, "Struct member can't be found for call offset_of(%, %).", T, member);
    return -1;
  };
}

align_of :: ($T: Type) -> int #expand
{
  return #run -> int {
    info := type_info(struct{ p: u8; t: T; });
    return info.members[1].offset_in_bytes.(int);
  };
}
