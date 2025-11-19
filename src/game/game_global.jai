COMPS: ComponentState;
GLOBAL: GLOBAL_State;

ComponentState :: struct
{
  CL: CL_State;
  SV: SV_State;
}

GLOBAL_State :: struct
{
  in_shutdown: bool;
  is_server: bool;
  is_client: bool;

  server_exit_on_disconnect: bool;

  packets_for_local_user: NET_LocalPackets;
  packets_for_local_server: NET_LocalPackets;
}
