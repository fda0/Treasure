main :: ()
{
  // Initialize client / server
  PLATFORM_PreInit();
  GLOBAL.is_client |= !GLOBAL.is_server;

  if GLOBAL.is_client push_context CreateContextWithRole(.CLIENT)
  {
    GAME_Init();
  }
  if GLOBAL.is_server
  {
    SV_Start();
  }
  NET_Init();

  PLATFORM_PostInit();

  // Setup lane multithreading; Start client game loop.
  client_ctx := CreateContextWithRole(.CLIENT);

  threads: [4] Thread;
  barrier: Barrier;
  BarrierInit(*barrier, xx threads.count);
  broadcast_memory: u64;

  for *threads
  {
    it.starting_context = client_ctx;
    it.starting_context.lane.lane_id = it_index;
    it.starting_context.lane.lane_count = threads.count;
    it.starting_context.lane.barrier = *barrier;
    it.starting_context.lane.broadcast_memory = *broadcast_memory;

    if it_index > 0
    {
      thread_init(it, GAME_LoopThreadEntry);
      thread_start(it);
    }
    else
    {
      context = it.starting_context;
    }
  }

  GAME_LoopThreadEntry(null);
}

GAME_LoopThreadEntry :: (thread: *Thread) -> s64
{
  thread_name := sprint("Client_%", LaneIdx());
  PerfThreadName(thread_name);
  LaneSync();

  while !GLOBAL.in_shutdown
  {
    if (LaneIdx() == 0) PLATFORM_PreIterate();
    GAME_Iterate();
    LaneSync();
  }
  return 0;
}

// Mostly all program includes
#load "game_core.jai";
#load "game_global.jai";
#load "game_sdl_platform.jai";
#load "game_context.jai";
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
#load "game_object_collider.jai";
#load "game_network_packet.jai";
#load "game_network.jai";
#load "game_client.jai";
#load "game_server.jai";
#load "game_audio.jai";
#load "game_gpu.jai";
#load "game_gpu_batch.jai";
#load "game_render_world.jai";
#load "game_render_ui.jai";
#load "game_font.jai";
#load "game_util.jai";
#load "game_tests.jai";
#load "game_pie_loader.jai";
#load "game_stats.jai";
#load "game_logging.jai";
#load "game_unique_variables.jai";

#load "../shared/base_utils.jai";
#load "../shared/base_string.jai";
#load "../shared/base_array.jai";
#load "../shared/base_fixed_array.jai";
#load "../shared/base_memory.jai";
#load "../shared/base_hash.jai";
#load "../shared/base_math.jai";
#load "../shared/base_random.jai";
#load "../shared/base_queue.jai";
#load "../shared/base_barrier.jai";
#load "../shared/base_color.jai";
#load "../shared/pie_file_format.jai";
#load "../shared/game_render_world_shared.jai";
#import "tr_hash_table";

#import "superluminal"()(ENABLE_PROFILER = true);
BOX :: #import "tr_box_layout"(Color=Color32);

#import "Basic";
#import "File";
#import "Thread";
#import "Atomics";
String :: #import "String";
