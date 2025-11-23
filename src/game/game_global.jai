COMPS: ComponentState;
GLOBAL: GLOBAL_State;

ComponentState :: struct
{
  AST: ASSET_State;
  AUDIO: AUDIO_State;
  CL: ClientState;
  DEV: DEV_State;
  FONT: FONT_State;
  G: GameState;
  GPU: GPU_State;
  HR: HotReloadState;
  LOG: LOG_State;
  NET: NET_State;
  STATS: STATS_State;
  SV: ServerState;
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
