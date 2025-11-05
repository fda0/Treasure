GLOBAL_State :: struct
{
  in_shutdown: bool;
  is_server: bool;
  is_client: bool;

  server_exit_on_disconnect: bool;

  local_user_packets: NET_LocalPackets;
  local_server_packets: NET_LocalPackets;
}
GLOBAL: GLOBAL_State;
