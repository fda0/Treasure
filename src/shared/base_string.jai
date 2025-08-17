STR_MatchFlags :: enum_flags u32
{
  FindLast;
  RightSideSloppy;
  CaseInsensitive;
  SlashInsensitive;
};

STR_Range :: (first: *u8, last: *u8) -> string
{
  res: string;
  res.data = first;
  res.count = cast(s64)last - cast(s64)first;
  return res;
}
STR_Substring :: (str: string, sub_min: s64, sub_max: s64) -> string
{
  sub_max = clamp(sub_max, 0, str.count);
  sub_min = clamp(sub_min, 0, str.count);
  if sub_min > sub_max  Swap(*sub_min, *sub_max);

  res: string;
  res.count = sub_max - sub_min;
  res.data = str.data + sub_min;
  return res;
}
STR_Skip :: (str: string, distance: s64) -> string
{
  distance = clamp(distance, 0, str.count);

  res := str;
  res.data += distance;
  res.count -= distance;
  return res;
}
STR_Chop :: (str: string, distance_from_end: s64) -> string
{
  distance_from_end = clamp(distance_from_end, 0, str.count);

  res := str;
  res.count -= distance_from_end;
  return res;
}
STR_Prefix :: (str: string, count: s64) -> string
{
  count = clamp(count, 0, str.count);

  res := str;
  res.count = count;
  return res;
}
STR_Suffix :: (str: string, count: s64) -> string
{
  count = clamp(count, 0, str.count);
  distance := str.count - count;

  res := str;
  res.data += distance;
  res.count = count;
  return res;
}

STR_EndsWith :: (haystack: string, needle: string, flags: STR_MatchFlags = 0) -> bool
{
  h := STR_Suffix(haystack, needle.count);
  return STR_Match(h, needle, flags);
}

STR_Match :: (a: string, b: string, flags: STR_MatchFlags = 0) -> bool
{
  result := false;
  if (a.count == b.count || flags & .RightSideSloppy)
  {
    result = true;

    i := 0;
    while true
    {
      if !(i < a.count && i < b.count) break;
      defer i += 1;

      match := (a.data[i] == b.data[i]);

      // if (flags & .CaseInsensitive)
      //   match |= (ByteToLower(a.data[i]) == ByteToLower(b.data[i]));

      // if (flags & .SlashInsensitive)
      //   match |= (ByteToForwardSlash(a.data[i]) == ByteToForwardSlash(b.data[i]));

      if !match
      {
        result = false;
        break;
      }
    }
  }
  return result;
}

STR_StartsWith :: (haystack: string, needle: string, flags: STR_MatchFlags = 0) -> bool
{
  h := STR_Prefix(haystack, needle.count);
  return STR_Match(h, needle, flags);
}

STR_DecodeUTF8 :: (str: string) -> codepoint:u32, byte_length:s64
{
  codepoint: u32 = ~cast(u32)0;
  byte_length: s64 = 1;
  if str.count <= 0 then return codepoint, byte_length;

  BITMASK_3 :: 0b111;
  BITMASK_4 :: 0b1111;
  BITMASK_5 :: 0b111_11;
  BITMASK_6 :: 0b111_111;
  utf8_class: [32] u8 = .[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,2,2,2,2,3,3,4,5];

  byte := str[0];
  byte_class := utf8_class[byte >> 3];

  if byte_class <= str.count
  {
    if byte_class == {
      case 1;
      codepoint = byte;
      byte_length = 1;

      case 2;
      cont_byte := str[1];
      if utf8_class[cont_byte >> 3] == 0
      {
        codepoint  = (byte      & BITMASK_5).(u32) << 6;
        codepoint |= (cont_byte & BITMASK_6).(u32);
        byte_length = 2;
      }

      case 3;
      cont_byte: [2] u8 = .[str[1], str[2]];
      if utf8_class[cont_byte[0] >> 3] == 0 &&
         utf8_class[cont_byte[1] >> 3] == 0
      {
        codepoint  = (byte         & BITMASK_4).(u32) << 12;
        codepoint |= (cont_byte[0] & BITMASK_6).(u32) << 6;
        codepoint |= (cont_byte[1] & BITMASK_6).(u32);
        byte_length = 3;
      }

      case 4;
      cont_byte: [3] u8 = .[str[1], str[2], str[3]];
      if utf8_class[cont_byte[0] >> 3] == 0 &&
         utf8_class[cont_byte[1] >> 3] == 0 &&
         utf8_class[cont_byte[2] >> 3] == 0
      {
        codepoint  = (byte         & BITMASK_3).(u32) << 18;
        codepoint |= (cont_byte[0] & BITMASK_6).(u32) << 12;
        codepoint |= (cont_byte[1] & BITMASK_6).(u32) <<  6;
        codepoint |= (cont_byte[2] & BITMASK_6).(u32);
        byte_length = 4;
      }
    }
  }

  return codepoint, byte_length;
}

#scope_file
#import "Basic"; // for clamp
