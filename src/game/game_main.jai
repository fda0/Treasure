main :: ()
{
  // Initialize client / server
  PLATFORM_PreInit();
  GLOBAL.core_count = get_number_of_processors();
  GLOBAL.is_client |= !GLOBAL.is_server;

  NET_Init();
  if (GLOBAL.is_server) SV_LaunchServerThread();
  G_Init();

  PLATFORM_PostInit();

  // Setup lane multithreading; Start client game loop.
  lane_group := LaneGroupCreate(GLOBAL.core_count);
  LaneGroupLaunch(G_LoopThreadEntry, lane_group, true);
  exit(0);
}

G_LoopThreadEntry :: (thread: *Thread) -> s64
{
  thread_name := sprint("Client_%", LaneIdx());
  PerfThreadName(thread_name);

  RD_InitializeWorldBatch(*RD.world_batches[LaneIdx()]);
  LaneSync();

  while !GLOBAL.in_shutdown
  {
    if (LaneIdx() == 0) PLATFORM_PreIterate();
    G_Iterate();
    LaneSync();
  }
  exit(0);
  return 0;
}

// Mostly all program includes
#load "game_core.jai";
#load "game_global.jai";
#load "game_sdl_platform.jai";
#load "game_text.jai";
#load "game_ui_core.jai";
#load "game_ui_developer.jai";
#load "game_ui_player.jai";
#load "game_time.jai";
#load "game_key.jai";
#load "game_animation.jai";
#load "game_asset.jai";
#load "game_asset_loading.jai";
#load "game_asset_hot_reload.jai";
#load "game_object.jai";
#load "game_ghost.jai";
#load "game_packets.jai";
#load "game_network.jai";
#load "game_client.jai";
#load "game_server.jai";
#load "game_audio.jai";
#load "game_gpu.jai";
#load "game_render.jai";
#load "game_font.jai";
#load "game_tests.jai";
#load "game_stats.jai";
#load "game_logging.jai";
#load "game_unique_variables.jai";
#load "game_simulation.jai";

#load "../shared/base_system.jai";
#load "../shared/base_utils.jai";
#load "../shared/base_string.jai";
#load "../shared/base_array.jai";
#load "../shared/base_fixed_array.jai";
#load "../shared/base_memory.jai";
#load "../shared/base_hash.jai";
#load "../shared/base_math.jai";
#load "../shared/base_random.jai";
#load "../shared/base_queue.jai";
#load "../shared/base_lanes.jai";
#load "../shared/base_color.jai";
#load "../shared/pie_file_format.jai";
#import "tr_hash_table";

#import "superluminal"()(ENABLE_PROFILER = false);
BOX :: #import "tr_box_layout"(Color=Color32);

#import "Basic";
#import "File";
#import "Thread";
#import "Atomics";
#import "System";
String :: #import "String";
