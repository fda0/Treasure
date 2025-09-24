
NET_SendKind :: enum u32
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

NET_SendHeader :: struct
{
  tick: Tick; // this is already send via packet header
  kind: NET_SendKind;
};

NET_SendActions :: struct
{
  actions: [NET_MAX_ACTION_COUNT] Action;
};

NET_SendPing :: struct
{
  number: u64;
};

NET_SendObjSync :: struct
{
  net_index: u32;
  sync: OBJ_Sync;
};

NET_SendObjEmpty :: struct
{
  net_index: u32;
};

NET_SendAssignPlayerKey :: struct
{
  player_key: OBJ_Key;
};

NET_SendWindowLayout :: struct
{
  user_count: u32;
  px, py, w, h: s32;
};

NET_PacketHeader :: struct
{
  magic_value: u16; // use this as seed for hash calculation instead
  payload_hash: u16;
};

NET_PayloadAlloc :: (size: u32) -> *u8
{
  buf_start := G.net.packet_payload_buf.data;

  if G.net.payload_used + size > G.net.packet_payload_buf.count
  {
    assert(false);
    return buf_start;
  }

  result := buf_start + G.net.payload_used;
  G.net.payload_used += size;
  return result;
}

NET_PayloadMemcpy :: (data: *void, size: u32) -> *u8
{
  result := NET_PayloadAlloc(size);
  memcpy(result, data, size);
  return result;
}

NET_PayloadAppendType :: (value: $T)
{
  NET_PayloadMemcpy(*value, size_of(T));
}

NET_RecalculatePacketHeader :: ()
{
  using G.net;
  payload := string.{payload_used, packet_payload_buf.data};
  packet_header.magic_value = NET_MAGIC_VALUE;
  packet_header.payload_hash = Hash64Any(payload).(u16, trunc);
}

NET_GetPacketString :: () -> string
{
  // there should be no padding between these
  #assert(offset_of(NET_State, "packet_header") + size_of(type_of(G.net.packet_header)) == offset_of(NET_State, "packet_payload_buf"));

  total_size := size_of(type_of(G.net.packet_header)) + G.net.payload_used;
  result := string.{total_size, (*G.net.packet_header).(*u8)};
  return result;
}
