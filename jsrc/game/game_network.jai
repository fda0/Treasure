NET_DEFAULT_SEVER_PORT :: 50523;
NET_MAGIC_VALUE :: 0xfda0;
NET_CLIENT_MAX_SNAPSHOTS :: TICK_RATE;
NET_MAX_ACTION_COUNT :: TICK_RATE/8;
NET_MAX_PLAYERS :: 10;
NET_MAX_PACKET_SIZE :: 1200;
NET_MAX_PAYLOAD_SIZE :: NET_MAX_PACKET_SIZE - size_of(NET_PacketHeader);
NET_SIMULATE_PACKETLOSS :: 0; // doesn't seem to work on localhost
NET_INACTIVE_MS :: 100;
NET_TIMEOUT_DISCONNECT_MS :: 500;

NET_State :: struct
{
  err: bool; // tracks if network is in error state
  is_server: bool;
  socket: *SDLNet_DatagramSocket;

  hacky_last_receive_timestamp: TimestampMS;
  hacky_last_send_timestamp: TimestampMS;

  server_user: NET_User;

  // msg payload
  packet_err: bool; // set on internal buffer overflow errors etc
  packet_header: NET_PacketHeader;
  packet_payload_buf: [1024 * 1024 * 1] u8; // 1 MB scratch buffer for network payload construction
  payload_used: u32;
};


// @impl
LOG_NetInfo :: 0;
LOG_NetDatagram :: 1;
LOG_NetPacket :: 2;
LOG_NetPayload :: 3;
LOG_NetClient :: 4;
LOG_NetCatchup :: 5;
LOG_NetTick :: 6;
LOG_NetSend :: 7;
LOG_Important :: 8;

Nlog :: (net_category: s64 /* @todo use user flags instead in the future */, format_string: string, args: .. Any, loc := #caller_location, flags := Log_Flags.NONE, user_flags : u32 = 0, section : *Log_Section = null)
{
  if net_category != LOG_NetPacket return;
  // @todo do something with net_category and logging in general
  // @todo add "NET_Label()" before every net log?, or do that for logs globally
  log(ifx G.net.is_server then "[SERVER]" else "[CLIENT]");
  log(format_string, ..args, loc, flags, user_flags, section);
} @PrintLike

NET_User :: struct
{
  address: *SDLNet_Address;
  port: u16;
  last_msg_timestamp: TimestampMS;
};

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
  tick_id: u64; // this is already send via packet header
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

NET_Init :: ()
{
  is_server := G.net.is_server;
  is_client := !G.net.is_server;

  Nlog(LOG_NetInfo, ifx is_server then "Launching as server" else "Launching as client");

  if is_client
  {
    hostname := "localhost";
    Nlog(LOG_NetInfo, "Resolving server hostname '%s' ...", hostname);
    G.net.server_user.address = SDLNet_ResolveHostname(temp_c_string(hostname));
    G.net.server_user.port = NET_DEFAULT_SEVER_PORT;
    if G.net.server_user.address
    {
      if SDLNet_WaitUntilResolved(G.net.server_user.address, -1) < 0
      {
        SDLNet_UnrefAddress(G.net.server_user.address);
        G.net.server_user.address = null;
      }
    }

    if !G.net.server_user.address
    {
      G.net.err = true;
      Nlog(LOG_NetInfo, "Failed to resolve server hostname '%s'", hostname);
    }
  }

  port: u16 = xx ifx is_server then NET_DEFAULT_SEVER_PORT else 0;
  G.net.socket = SDLNet_CreateDatagramSocket(null, port);
  if !G.net.socket
  {
    G.net.err = true;
    Nlog(LOG_NetInfo, "Failed to create socket");
  }
  else
  {
    Nlog(LOG_NetInfo, "Created socket");

    #if NET_SIMULATE_PACKETLOSS
    {
      SDLNet_SimulateDatagramPacketLoss(G.net.socket, NET_SIMULATE_PACKETLOSS);
      Nlog(LOG_NetInfo, "%s: Simulating packetloss: %d", NET_SIMULATE_PACKETLOSS);
    }
  }
}

NET_IterateReceive :: ()
{
  is_server := G.net.is_server;
  is_client := !G.net.is_server;
  if G.net.err return;

  {
    // hacky temporary network activity rate-limitting
    if ElapsedTimeMS(G.net.hacky_last_receive_timestamp, .FRAME) < 8 then return;
    G.net.hacky_last_receive_timestamp = GetTimestampMS(.FRAME);
  }

  while true
  {
    dgram: *SDLNet_Datagram;
    receive := SDLNet_ReceiveDatagram(G.net.socket, *dgram);
    if !receive break;
    if !dgram   break;

    Nlog(LOG_NetDatagram, "got %-byte datagram from %:%",
      dgram.buflen, to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);

    dgram_error := false;
    if is_client
    {
      if !NET_UserMatchAddrPort(*G.net.server_user, dgram.addr, dgram.port)
      {
        dgram_error = true;
        Nlog(LOG_NetDatagram, "dgram rejected - received from non-server address %:%",
          to_string(SDLNet_GetAddressString(dgram.addr)), dgram.port);
      }
    }

    if !dgram_error
    {
      player_id: u16 = NET_MAX_PLAYERS;

      // save user
      if is_server
      {
        user := NET_FindUser(dgram.addr, dgram.port);
        if !user
        {
          Nlog(LOG_NetInfo, "saving user with port: %", dgram.port);
          user = NET_AddUser(dgram.addr, dgram.port);
        }

        if user
        {
          user.last_msg_timestamp = GetTimestampMS(.FRAME);
          user_id: u64 = (user.(u64) - G.server.users.data.(u64)) / size_of(NET_User);
          player_id = user_id.(u16);
        }
      }

      packet := string.{dgram.buflen, dgram.buf};
      NET_ReceivePacket(player_id, packet);
    }

    SDLNet_DestroyDatagram(dgram);
  }
}

NET_IterateSend :: ()
{
  is_server := G.net.is_server;
  is_client := !G.net.is_server;
  if G.net.err return;

  {
    // hacky temporary network activity rate-limitting
    if ElapsedTimeMS(G.net.hacky_last_send_timestamp, .FRAME) < 16 then return;
    G.net.hacky_last_send_timestamp = GetTimestampMS(.FRAME);
  }

  if (is_server)
  {
    client_count := 0;
    for G.server.users
      if it.address client_count += 1;

    // iterate over connected users
    player_number := 0;
    for user, user_index: G.server.users
    {
      if !user.address continue;
      player_number += 1;

      // create player characters and send them to users
      {
        player_key := *G.server.player_keys[user_index];

        if OBJ_KeyIsZero(player_key)
        {
          model_keys := MODEL_Key.[
            ModelKey("Dude"),
            ModelKey("Zombie"),
            // ModelKey("Worker"),
            // ModelKey("Formal"),
            // ModelKey("Casual"),
          ];

          model := model_keys[user_index % model_keys.count];
          team := (user_index % 2 + 1).(OBJ_Team);
          player := OBJ_CreateHero(.NETWORK, model, team);
          if !OBJ_IsNil(player)
          {
            player.s.p.y = -1.5 + user_index * 0.7;
            r := ifx user_index & 4 then 0.3 else 0.8;
            g := ifx user_index & 2 then 0.3 else 0.8;
            b := ifx user_index & 1 then 0.3 else 0.8;
            player.s.color = Color32_RGBf(r, g, b);
          }
          player_key.* = player.s.key;
        }

        head: NET_SendHeader;
        head.tick_id = G.tick_number;
        head.kind = .AssignPlayerKey;
        NET_PayloadAppendType(head);

        assign: NET_SendAssignPlayerKey;
        assign.player_key = player_key.*;
        NET_PayloadAppendType(assign);

        NET_PacketSendAndResetPayload(user);
      }

      // calculate autolayout for clients
      // @todo this doesn't have to be done on iterate send
      if G.window_autolayout
      {
        window_count := 1 + client_count;

        rows := 1;
        cols := 1;
        for 0..15
        {
          total_slots := rows * cols;
          if total_slots >= window_count
            break;

          if rows > cols  cols += 1;
          else            rows += 1;
        }

        #if 0 // @impl
        {
          win_x := G.init_window_px;
          win_y := G.init_window_py;
          win_w := G.init_window_width / cols;
          win_h := G.init_window_height / rows;

          // calc server window
          GAME_AutoLayoutApply(client_count, win_x, win_y, win_w, win_h);

          // calc client window
          {
            window_index := player_number;
            x := window_index / rows;
            y := window_index % rows;

            head: NET_SendHeader;
            head.tick_id = G.tick_id;
            head.kind = .WindowLayout;
            NET_PayloadMemcpy(*head, sizeof(head));

            body: NET_SendWindowLayout;
            body.user_count = client_count;
            body.px = win_x + x*win_w;
            body.py = win_y + y*win_h;
            body.w = win_w;
            body.h = win_h;
            NET_PayloadMemcpy(*body, sizeof(body));

            NET_PacketSendAndResetPayload(user);
          }
        }
      }
    }

    // iterate over network objects
    for G.obj.network_objects
    {
      if OBJ_HasData(it)
      {
        head: NET_SendHeader;
        head.tick_id = G.tick_number;
        head.kind = .ObjUpdate;
        NET_PayloadAppendType(head);

        update: NET_SendObjSync;
        update.net_index = xx it_index;
        update.sync = it.s;
        NET_PayloadAppendType(update);
      }
      else
      {
        head: NET_SendHeader;
        head.tick_id = G.tick_number;
        head.kind = .ObjEmpty;
        NET_PayloadAppendType(head);

        update: NET_SendObjEmpty;
        update.net_index = xx it_index;
        NET_PayloadAppendType(update);
      }

      NET_PacketSendAndResetPayloadBroadcast();
    }
  }

  if is_client
  {
    {
      head: NET_SendHeader;
      head.tick_id = G.tick_number;
      head.kind = .Ping;
      NET_PayloadAppendType(head);

      ping: NET_SendPing;
      NET_PayloadAppendType(ping);
      NET_PacketSendAndResetPayloadToServer();
    }

    {
      head: NET_SendHeader;
      head.tick_id = G.tick_number;
      head.kind = .Actions;
      NET_PayloadAppendType(head);

      payload: NET_SendActions;
      for * payload.actions
      {
        it.* = QueuePeek(G.client.action_queue, it_index);
      }

      NET_PayloadAppendType(payload);
      NET_PacketSendAndResetPayloadToServer();
    }
  }
}

NET_PayloadAlloc :: (size: u32) -> *u8
{
  buf_start := G.net.packet_payload_buf.data;

  if G.net.payload_used + size > G.net.packet_payload_buf.count
  {
    assert(false);
    G.net.packet_err = true;
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

NET_UserIsInactive :: (user: NET_User) -> bool
{
  return ElapsedTimeMS(user.last_msg_timestamp, .FRAME) > NET_INACTIVE_MS;
}

NET_SendString :: (destination: NET_User, msg: string)
{
  assert(msg.count < 1280); // that seems to be a realistic reasonable max size? https://gafferongames.com/post/packet_fragmentation_and_reassembly/

  if G.net.is_server && NET_UserIsInactive(destination)
    return;

  send_res := SDLNet_SendDatagram(G.net.socket, destination.address, destination.port, msg.data, xx msg.count);
  if !send_res
  {
    Nlog(LOG_NetSend, "Sending buffer of size %lluB to %s:%d; %s",
        msg.count, to_string(SDLNet_GetAddressString(destination.address)),
        destination.port, ifx send_res then "success" else "fail");
  }
}

NET_PacketSendAndResetPayload :: (destination: NET_User)
{
  NET_RecalculatePacketHeader();
  packet := NET_GetPacketString();
  NET_SendString(destination, packet);
  G.net.payload_used = 0;
}

NET_PacketSendAndResetPayloadToServer :: ()
{
  if NET_IsClient()
  {
    NET_RecalculatePacketHeader();
    packet := NET_GetPacketString();
    NET_SendString(G.net.server_user, packet);
    G.net.payload_used = 0;
  }
}

NET_PacketSendAndResetPayloadBroadcast :: ()
{
  if G.net.is_server
  {
    NET_RecalculatePacketHeader();
    packet := NET_GetPacketString();

    for G.server.users
    {
      if !it.address continue;
      NET_SendString(it, packet);
    }
    G.net.payload_used = 0;
  }
}

NET_IterateTimeoutUsers :: ()
{
  if NET_IsServer()
  {
    for *G.server.users
    {
      if !it.address continue;
      if ElapsedTimeMS(it.last_msg_timestamp, .FRAME) > NET_TIMEOUT_DISCONNECT_MS
      {
        Nlog(LOG_NetInfo, "Timeout. Removing user #%", it_index);

        if G.server_exit_on_disconnect
        {
          Nlog(LOG_Important, "Quitting server on client disconnect because -exit-on-dc argument was used.");
          G.in_shutdown = true;
        }

        NET_RemoveUser(it);
      }
    }
  }
}

NET_RemoveUser :: (user: *NET_User)
{
  SDLNet_UnrefAddress(user.address);
  user.* = .{};
}

NET_UserMatch :: (a: *NET_User, b: *NET_User) -> bool
{
  return (a.port == b.port && SDLNet_CompareAddresses(a.address, b.address) == 0);
}

NET_UserMatchAddrPort :: (user: *NET_User, address: *SDLNet_Address, port: u16) -> bool
{
  if (!user.address)
    return false;

  return (user.port == port && SDLNet_CompareAddresses(user.address, address) == 0);
}

NET_FindUser :: (address: *SDLNet_Address, port: u16) -> *NET_User
{
  // @todo move to SV_ prefix?
  for * G.server.users
  {
    if (NET_UserMatchAddrPort(it, address, port))
      return it;
  }
  return null;
}

NET_AddUser :: (address: *SDLNet_Address, port: u16) -> *NET_User
{
  // @todo move to SV_ prefix?
  new_user_slot: *NET_User;
  for * G.server.users
  {
    if (!it.address)
    {
      new_user_slot = it;
      break;
    }
  }

  if (new_user_slot)
  {
    new_user_slot.address = SDLNet_RefAddress(address);
    new_user_slot.port = port;
  }
  return new_user_slot;
}

NET_Consume:: ($T: Type, packet: *string) -> T
{
  value: T;
  to_copy := STR_Prefix(packet.*, size_of(T));
  memcpy(*value, to_copy.data, to_copy.count);
  packet.* = STR_Skip(packet.*, to_copy.count);
  return value;
}

NET_ReceivePacket :: (player_id: u16, original_packet: string)
{
  packet := original_packet;

  if G.net.is_server && player_id >= NET_MAX_PLAYERS
    return;

  if packet.count < size_of(NET_PacketHeader)
  {
    Nlog(LOG_NetPacket, "packet rejected - it's too small, size: %llu", packet.count);
    return;
  }

  header := NET_Consume(NET_PacketHeader, *packet);

  if (!packet.count)
  {
    Nlog(LOG_NetPacket, "packet rejected - empty payload",);
    return;
  }

  if (header.magic_value != NET_MAGIC_VALUE)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid magic value: %; expected: %", header.magic_value, NET_MAGIC_VALUE);
    return;
  }

  // validate hash
  hash64 := Hash64Any(packet);
  hash16 := cast,no_check(u16) hash64;
  if (hash16 != header.payload_hash)
  {
    Nlog(LOG_NetPacket, "packet rejected - invalid hash: %; calculated: %", header.payload_hash, hash16);
    return;
  }

  NET_ProcessReceivedPayload(player_id, packet);
}

NET_ProcessReceivedPayload :: (player_id: u16, full_message: string)
{
  msg := full_message;
  while msg.count
  {
    head := NET_Consume(NET_SendHeader, *msg);

    if head.kind == .Ping
    {
      ping := NET_Consume(NET_SendPing, *msg);
    }
    else if (head.kind == .ObjUpdate ||
             head.kind == .ObjEmpty)
    {
      update: NET_SendObjSync;
      if (head.kind == .ObjUpdate)
      {
        update = NET_Consume(NET_SendObjSync, *msg);
      }
      else
      {
        empty := NET_Consume(NET_SendObjEmpty, *msg);
        update.net_index = empty.net_index;
        update.sync.init = true;
      }

      if update.net_index >= OBJ_MAX_NETWORK_OBJECTS
      {
        Nlog(LOG_NetPayload, "Rejecting payload(%) - net index overflow: %", head.kind, update.net_index);
        continue;
      }

      if G.client.next_playback_tick > head.tick_id
      {
        Nlog(LOG_NetPayload, "Rejecting payload(%) - head tick at: % < next playback tick: %",
            head.kind, head.tick_id, G.client.next_playback_tick);
        continue;
      }

      snap := *G.client.snaps_of_objs[update.net_index];
      CLIENT_InsertSnapshot(snap, head.tick_id, update.sync);
    }
    else if head.kind == .Actions
    {
      in_net := NET_Consume(NET_SendActions, *msg);
      player := *G.server.player_actions[player_id];
      SERVER_InsertPlayerAction(player, *in_net, head.tick_id);
    }
    else if head.kind == .AssignPlayerKey
    {
      assign := NET_Consume(NET_SendAssignPlayerKey, *msg);

      if G.client.player_key_latest_tick_id < head.tick_id
      {
        G.client.player_key = assign.player_key;
        G.client.player_key_latest_tick_id = head.tick_id;
      }
    }
    else if head.kind == .WindowLayout
    {
      layout := NET_Consume(NET_SendWindowLayout, *msg);
      if G.window_autolayout
        GAME_AutoLayoutApply(layout.user_count, layout.px, layout.py, layout.w, layout.h);
    }
    else
    {
      Nlog(LOG_NetPayload, "Unsupported payload head kind: %d", head.kind);
      return;
    }
  }
}

NET_IsServer :: () -> bool
{
  return G.net.is_server;
}
NET_IsClient :: () -> bool
{
  return !G.net.is_server;
}
