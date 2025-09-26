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
};

PACKET_Type :: enum u32
{
  None;
  Ping :: 10000;
  ObjUpdate;
  ObjEmpty;
  NetworkTest;
  Actions;
  AssignPlayerKey;
  WindowLayout;
};

PACKET_SendHeader :: struct
{
  tick: Tick; // this is already send via packet header
  kind: PACKET_Type;
};

PACKET_SendActions :: struct
{
  actions: [NET_MAX_ACTION_COUNT] Action;
};

PACKET_SendPing :: struct
{
  number: u64;
};

PACKET_SendObjSync :: struct
{
  net_index: u32;
  sync: OBJ_Sync;
};

PACKET_SendObjEmpty :: struct
{
  net_index: u32;
};

PACKET_SendAssignPlayerKey :: struct
{
  player_key: OBJ_Key;
};

PACKET_SendWindowLayout :: struct
{
  user_count: u32;
  px, py, w, h: s32;
};

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
  full.header = .{}; // invalidate header
}

PACKET_CopyType :: (full: *PACKET_Full, value: $T)
{
  PACKET_CopyData(full, *value, size_of(T));
}

PACKET_FinalizeHeader :: (full: *PACKET_Full)
{
  str := PACKET_PayloadAsString(full.payload);
  full.header.magic_value = PACKET_MAGIC_VALUE;
  full.header.payload_hash = Hash64Any(str).(u16,trunc);
}

PACKET_IsFinalized :: (full: PACKET_Full) -> bool
{
  return !!full.header.magic_value;
}

PACKET_Create :: (things: ..Any) -> PACKET_Full
{
  full: PACKET_Full;
  for things
  {
    PACKET_CopyData(*full, it.value_pointer, it.type.runtime_size);
  }
  PACKET_FinalizeHeader(*full);
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
