PacketBuffer :: FixedArray(1024, u8);

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
  actions: [PACKET_MAX_ACTION_COUNT] Action;
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

PACKET_PacketHeader :: struct
{
  magic_value: u16; // use this as seed for hash calculation instead
  payload_hash: u16;
};

PACKET_PushData :: (pbuf: *PacketBuffer, data: *void, size: s64)
{
  mem, success := array_add_many(pbuf, size, initialize=false);
  if !success
  {
    assert(false);
    ArrayClear(mem);
    return;
  }
  memcpy(mem.data, data, size);
}

PACKET_PushType :: (value: $T)
{
  PACKET_PushData(*value, size_of(T));
}

PACKET_AsString :: (pbuf: *PacketBuffer) -> string
{
  return string.{data = pbuf.data.data, count = pbuf.count};
}

PACKET_CalculateHeader :: (pbuf: *PacketBuffer) -> PACKET_PacketHeader
{
  str := PACKET_AsString(pbuf);

  res: PACKET_PacketHeader;
  res.magic_value = PACKET_MAGIC_VALUE;
  res.payload_hash = Hash64Any(str).(u16, trunc);
  return res;
}
