PACKET_MAGIC_VALUE :: 0xfda0;

PACKET_Payload :: FixedArray(2048, u8, false);
PACKET_Full :: struct
{
  header: PACKET_Header;
  payload: PACKET_Payload #align 1;
}

PACKET_Header :: struct
{
  magic_value: u16; // use this as seed for hash calculation instead
  payload_hash: u16;
  from_tick: Tick;
};

PACKET_Type :: enum u32
{
  None;
  Ping :: 10000;
  ObjUpdate;
  ObjEmpty;
  NetworkTest;
  InputActions;
  AssignPlayerKey;
  WindowLayout;
};

PACKET_Ping :: struct
{
  PT := PACKET_Type.Ping;
  number: u64;
};

PACKET_ObjUpdate :: struct
{
  PT := PACKET_Type.ObjUpdate;
  net_index: u32;
  sync: OBJ_Sync;
};

PACKET_ObjEmpty :: struct
{
  PT := PACKET_Type.ObjEmpty;
  net_index: u32;
};

PACKET_InputActions :: struct
{
  PT := PACKET_Type.InputActions;
  actions: [NET_MAX_ACTION_COUNT] InputAction;
};

PACKET_AssignPlayerKey :: struct
{
  PT := PACKET_Type.AssignPlayerKey;
  player_key: OBJ_Key;
};

PACKET_WindowLayout :: struct
{
  PT := PACKET_Type.WindowLayout;
  user_count: u32;
  px, py, w, h: s32;
};

//
// Create
//

PACKET_CopyData :: (full: *PACKET_Full, data: *void, size: s64)
{
  mem, success := array_add_many(*full.payload, size, initialize=false);
  if !success
  {
    assert(false);
    ArrayClear(mem);
    return;
  }
  memcpy(mem.data, data, size);
  full.header.magic_value = 0; // invalidate header
}

PACKET_CopyType :: (full: *PACKET_Full, value: $T)
{
  PACKET_CopyData(full, *value, size_of(T));
}

PACKET_FinalizeHeader :: (from_tick: Tick, full: *PACKET_Full)
{
  str := PACKET_PayloadAsString(full.payload);
  full.header.magic_value = PACKET_MAGIC_VALUE;
  full.header.payload_hash = Hash64Any(str).(u16,trunc);
  full.header.from_tick = from_tick;
}

PACKET_IsFinalized :: (full: PACKET_Full) -> bool
{
  return !!full.header.magic_value;
}

PACKET_Create :: (from_tick: Tick, things: ..Any) -> PACKET_Full
{
  full: PACKET_Full;
  for things
  {
    PACKET_CopyData(*full, it.value_pointer, it.type.runtime_size);
  }
  PACKET_FinalizeHeader(from_tick, *full);
  return full;
}

PACKET_PayloadAsString :: (payload: PACKET_Payload) -> string
{
  return string.{data = payload.data.data, count = payload.count};
}

PACKET_FullAsString :: (full: PACKET_Full) -> string
{
  size := size_of(PACKET_Header) + full.payload.count;
  return string.{data = (*full).(*u8), count = size};
}

//
// Consume
//
PACKET_Peek :: ($T: Type, packet: string) -> T
{
  value: T;
  if packet.count >= size_of(T)
  {
    memcpy(*value, packet.data, size_of(T));
  }
  return value;
}

PACKET_Consume :: ($T: Type, packet: *string) -> T
{
  value := PACKET_Peek(T, packet.*);
  packet.* = Skip(packet.*, size_of(T));
  return value;
}
