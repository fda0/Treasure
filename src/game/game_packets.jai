PK_MAGIC_VALUE :: 0xfda0;

PacketBuffer :: Fixed(u8, 2048);
Packet :: struct {
  header: PK_Header;
  buffer: PacketBuffer #align 1;
}

PK_Header :: struct {
  magic_value: u16; // use this as seed for hash calculation instead
  buffer_hash: u16;
  tick: Tick;
}

PK_Kind :: enum u8 {
  None;
  // Server -> Client
  ObjUpdate;
  ObjEmpty;
  AssignPlayerKey;
  // Client -> Sever
  ActionQueue;
}

PK_GetType :: (kind: PK_Kind) -> Type {
  PK_KindTypeMap :: struct {
    kind: PK_Kind;
    type: Type;
  }

  PK_KindTypeMappings :: PK_KindTypeMap.[
    .{.ObjUpdate, Object},
    .{.ObjEmpty, ObjIdx},
    .{.AssignPlayerKey, OBJ_Key},
    .{.ActionQueue, ActionQueue},
  ];

  for PK_KindTypeMappings {
    if (it.kind == kind) return it.type;
  }
  assert(false);
  return u8;
}

PK_TypeGetter :: struct(kind: PK_Kind) {
  type :: #run PK_GetType(kind);
}


//
// Create
//
PK_AddDataRaw :: (packet: *Packet, data: *void, size: s64) {
  mem, success := array_add_many(*packet.buffer, size, initialize=false);
  if !success
  {
    assert(false);
    ArrayClear(mem);
    return;
  }
  memcpy(mem.data, data, size);
  packet.header.magic_value = 0; // invalidate header
}

PK_AddPair :: (packet: *Packet, kind: PK_Kind, value: $T) {
  assert(T == PK_GetType(kind));
  PK_AddDataRaw(packet, *kind, size_of(PK_Kind));
  PK_AddDataRaw(packet, *value, size_of(T));
}

PK_FinalizeHeader :: (tick: $T/AnyTick, packet: *Packet) {
  str := PK_BufferAsString(packet.buffer);
  packet.header.magic_value = PK_MAGIC_VALUE;
  packet.header.buffer_hash = Hash64Any(str).(u16,trunc);
  packet.header.tick = xx tick;
}

PK_IsFinalized :: (packet: Packet) -> bool {
  return !!packet.header.magic_value;
}

PK_Create :: (tick: $T/AnyTick, things: ..Any) -> Packet {
  packet: Packet;
  for things {
    PK_AddDataRaw(*packet, it.value_pointer, it.type.runtime_size);
  }
  PK_FinalizeHeader(tick, *packet);
  return packet;
}

PK_BufferAsString :: (payload: PacketBuffer) -> string {
  return string.{data = payload.buf.data, count = payload.count};
}

PK_PacketAsString :: (packet: Packet) -> string {
  size := size_of(PK_Header) + packet.buffer.count;
  return string.{data = (*packet).(*u8), count = size};
}

//
// Consume
//
PK_Peek :: ($T: Type, packet: string) -> T {
  value: T;
  if packet.count >= size_of(T) {
    memcpy(*value, packet.data, size_of(T));
  }
  return value;
}

PK_ConsumeRaw :: ($T: Type, packet: *string) -> T {
  value := PK_Peek(T, packet.*);
  packet.* = Skip(packet.*, size_of(T));
  return value;
}

PK_ConsumeKind :: (packet: *string) -> PK_Kind {
  return PK_ConsumeRaw(PK_Kind, packet);
}

PK_Consume :: ($kind: PK_Kind, packet: *string) -> PK_TypeGetter(kind).type {
  return PK_ConsumeRaw(#run PK_GetType(kind), packet);
}
