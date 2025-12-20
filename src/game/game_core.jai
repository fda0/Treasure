#scope_file;
using,only(CL,DEV,G,RD) COMPS;
#scope_export;

GameState :: struct
{
  // startup profiling
  time_launch: Apollo_Time;
  time_init_sdl: Apollo_Time;
  time_init_game: Apollo_Time;
  time_init_finished: Apollo_Time;
  time_finished_first_iterate: Apollo_Time;

  // Time
  frame_timestamp: Timestamp;
  client_timestamp: Timestamp; // Same as frame_timestamp for now; Usages of this will have to be replaced in the future when client network gets a separate thread (if that ever happens)
  delta_timestamp: Timestamp;
  dt: float;
  at: float;
  frame_number: s64;

  // SDL, window stuff
  window: *SDL_Window;
  dpi_scaling: float;
  headless: bool; // no window mode
  init_window_p: V2 = .{-1, -1};
  init_window_dim: V2 = .{-1, -1};
  window_dim: V2;
  window_resized: bool; // window resized on this frame
  window_fullscreen: bool;
  window_borderless: bool;
  window_on_top: bool;
  window_autolayout: bool;
  server_exit_on_disconnect: bool;
  grab_mouse: bool;
  sdl_is_fullscreen: bool;
  // SDL audio

  // user input
  window_has_focus: bool;
  mouse: V2;
  mouse_delta: V2;
  mouse_scroll: V2;
  world_mouse_valid: bool;
  world_mouse: V3;
  is_pathing_by_holding: bool;
  keys: [KEY_Code.COUNT] Key;
  hover_object: OBJ_Key;

  rng: Entropy = .{~12234, 92389123}; // @todo Replace with specific purpose Entropy seeds.

  // sun
  sun_dir: V3; // normalized
  sun_camera_p: V3;
  sun_camera_transform: Mat4;

  // camera
  camera_p: V3 = .{-10, 0, 1};
  camera_angles: V3;
  camera_fov_y: float = 0.111;
  camera_transform: Mat4;

  // Accumulates actions (player inputs). Sent to server.
  action_queue: ActionQueue;
  action_tick: ActionTick;

  // Object keys
  sun: OBJ_Key;

  player_key: OBJ_Key;
  player_key_latest_tick: ServerTick;

  // Objects
  local_objects_tick: ServerTick = 1;
  local_objects_creation_serials: [] u8;

  shared_ghosts: [] Ghost;
  local_ghosts: [] Ghost;
  all_ghosts: [] Ghost;
}

Direction3D :: enum u8
{
  E; // +X
  W; // -X
  N; // +Y
  S; // -Y
  T; // +Z
  B; // -Z
  COUNT;
}

G_Init :: ()
{
  PerfFunc();

  AST_LoadAssetFile();
  GPU_Init();
  AST_LaunchTextureUploadThread();
  AN_InitSkeletons();
  FONT_Init();
  RD_UIClearRenderCounters();
  HR_InitWatcher();
  CL_Init();
  RD_Init();

  // Allocate objects
  {
    G.local_objects_creation_serials = NewArray(OBJ_LOCAL_COUNT, u8);

    G.all_ghosts = NewArray(OBJ_SHARED_COUNT + OBJ_LOCAL_COUNT, Ghost);
    G.shared_ghosts = Prefix(G.all_ghosts, OBJ_SHARED_COUNT);
    G.local_ghosts = Suffix(G.all_ghosts, OBJ_LOCAL_COUNT);
  }

  G_InitLocalObjects();
}

G_Iterate :: ()
{
  PerfFunc();

  // Advance time
  if IsLaneFromTaskIdx(0)
  {
    now := TimeNow();
    G.delta_timestamp = now - G.frame_timestamp;
    G.frame_timestamp = now;
    G.client_timestamp = G.frame_timestamp; // Same as frame_timestamp for now; Usages of this will have to be replaced in the future when client network gets a separate thread (if that ever happens)
    G.dt = G.delta_timestamp.(float) * 0.001;
    G.at = WrapFloat(G.at + G.dt, 0.0, 1000.0);
    G.frame_number += 1;

    Post(.DELTA_TIMESTMAP_MS, xx G.delta_timestamp);
    Post(.TEST_FRAME_NUMBER, G.frame_number);
  }

  // Mouse input things
  if IsLaneFromTaskIdx(0)
  {
    if KEY_Pressed(.F11) G.window_fullscreen = !G.window_fullscreen;
    if DEV.show || DEV.noclip || !G.window_has_focus {
      G.grab_mouse = false;
    } else if KEY_Held(.MOUSE_LEFT, .MOUSE_RIGHT) && OverlapsRange(MakeRange(G.window_dim), G.mouse) {
      G.grab_mouse = true;
    }
  }

  // Pre frame inits
  if IsLaneFromTaskIdx(0)
  {
    if !G.headless
    {
      AUDIO_CloseFinishedStreams();
      GPU_ReadbackMousePickingTexture();
    }

    // pre frame calls
    if G.window_resized
    {
      GPU_ResizeFramebuffer();
      FONT_MaybeResizeAtlasTexture();
    }
  }

  // Hacky font testing
  if IsLaneFromTaskIdx(0)
  {
    if !G.headless && KEY_Pressed(.F)
    {
      print("@todo remove this temporary code\n");
      for scale_part: 8 .. 12
      {
        scale := 16 + scale_part * 4;
        for codepoint: 33 .. 126 + 255
        {
          g0 := FONT_GetGlyph(xx codepoint, .Jacquard24,      xx scale);
          g1 := FONT_GetGlyph(xx codepoint, .PlayfairDisplay, xx scale);
        }
      }
    }
  }

  // Client network
  if IsLaneFromTaskIdx(0)
  {
    CL_IterateReceive();
    CL_SendPlayerActions();
  }

  if IsLaneFromTaskIdx(0) && !G.headless
  {
    G_CalculateCameraAndMouseInput();
    G_AdvanceLocalObjects();
  }

  LaneSync();

  {
    PerfScope("Update ghosts scope");

    worker_count := max(LaneCount() - 1, 1);
    if LaneIdx() < worker_count
    {
      per_lane := OBJ_ALL_COUNT / worker_count;

      work_count := per_lane;
      if LaneIdx() == worker_count - 1 {
        reminder := OBJ_ALL_COUNT % worker_count;
        work_count += reminder;
      }

      work_start := per_lane * LaneIdx();
      work_range := MakeRangeMinDim(work_start.(ObjIdx), work_count.(ObjIdx));

      G_UpdateGhostsInRange(work_range);
    }
  }

  // UI work
  if LaneIdx() == LaneCount()-1 && !G.headless
  {
    PerfScope("UI workload");
    UI_DeveloperKeyShortcuts();
    UI_BeginBoxLayout();
    UI_BuildDeveloperWindow();
  }

  LaneSync();

  if IsLaneFromTaskIdx(0)
  {
    RD_UploadWorldBatchesToGPUTransferBuffers();
  }

  if IsLaneFromTaskIdx(1) && !G.headless
  {
    UI_BuildHUD();
    UI_FinishBoxLayout();
  }

  // Prepare client player input and send it
  if IsLaneFromTaskIdx(2) && !G.headless
  {
    G_ProcessInputAndSendToClient();
  }

  // Play sounds
  if IsLaneFromTaskIdx(3) && !G.headless
  {
    // Play debug sound
    if KEY_Pressed(.M) AUDIO_PlaySound(.HIT);
    AUDIO_PlayObjectSounds();
  }

  // Update marker object
  if IsLaneFromTaskIdx(4) && !G.headless
  {
    for * G.local_ghosts
    {
      if it.flags & .IS_MARKER
      {
        if it.anim.position.z < -0.049 {
          G_DeleteGhost(it);
        }
      }
    }
  }

  LaneSync();

  // Post frame work
  if IsLaneFromTaskIdx(0) && !G.headless
  {
    RD_UITranslate3DShapes();
    UI_ProcessBoxRenderCommands();
    UI_DrawDeveloperFontAtlas();

    GPU_Iterate();

    // Post frame calls
    RD_UIClearRenderCounters();
    ASSET_PostFrame();

    HR_Iterate();
  }

  // Post frame logic
  if IsLaneFromTaskIdx(0)
  {
    STATS_PostFrame();
    LOG_FileFlush();
  }

  if IsLaneFromTaskIdx(0) && !G.time_finished_first_iterate
  {
    G.time_finished_first_iterate = current_time_monotonic();
    ms :: to_milliseconds;

    init_total := G.time_init_finished - G.time_launch;
    init_sdl := G.time_init_sdl - G.time_launch;
    init_game := G.time_init_game - G.time_init_sdl;
    log("[TIMING] Init Total: %ms; Init SDL: %ms; Init Game: %ms", ms(init_total), ms(init_sdl), ms(init_game));

    first_iter := G.time_finished_first_iterate - G.time_init_finished;
    log("[TIMING] First iteration (excluding init): %ms", ms(first_iter));
  }

  LaneSync();
  reset_temporary_storage();

  if G.headless
  {
    // Since we don't wait for v-sync in headless mode
    // we will wait here to avoid using 100% of the CPU.
    // This should be solved in a better way (waiting on network msg or something)
    // once scheduling and multithreading is further along.
    SDL_Delay(0);
  }
}

G_UpdateGhostsInRange :: (range: Range(ObjIdx))
{
  batch := RD_GetLaneWorldBatch();
  for ghost_index: range
  {
    ghost := *G.all_ghosts[ghost_index];

    is_shared := ghost_index < OBJ_SHARED_COUNT;
    if is_shared && !DEV.pause_ghosts_interpolation {
      inline G_InterpolateSnapshotsForGhost(ghost, ghost_index);
    }
    inline AN_UpdateGhostTimers(ghost);
    inline RD_DrawGhost(ghost, batch);
  }
}

G_CalculateCameraAndMouseInput :: ()
{
  if DEV.noclip
  {
    if KEY_Held(.MOUSE_LEFT)
    {
      rot_speed := 0.0004;
      G.camera_angles.z += rot_speed * G.mouse_delta.x;
      G.camera_angles.y += rot_speed * G.mouse_delta.y * (-2.0 / 3.0);
      G.camera_angles.z = WrapFloat(G.camera_angles.z, -0.5, 0.5);
      G.camera_angles.y = clamp(G.camera_angles.y, -0.2, 0.2);
    }

    move_dir: V3;
    if (KEY_Held(.W)) move_dir.x += 1;
    if (KEY_Held(.S)) move_dir.x -= 1;
    if (KEY_Held(.A)) move_dir.y += 1;
    if (KEY_Held(.D)) move_dir.y -= 1;
    if (KEY_Held(.SPACE)) move_dir.z += 1;
    if (KEY_Held(.LSHIFT) || KEY_Held(.RSHIFT)) move_dir.z -= 1;
    move_dir = normalize(move_dir);
    move_dir = Math.rotate(move_dir, RotationAroundAxis(-AxisV3(.Z)/* @todo why negation fixes things? */, G.camera_angles.z));
    G.camera_p += move_dir * 12.0 * G.dt;
  }
  else
  {
    G.camera_p.z = 12.5;
    G.camera_angles = V3.{0, -0.138, 0};

    // Mouse window edge camera scroll
    if G.grab_mouse
    {
      window_margin := min(G.window_dim.x, G.window_dim.y) * 0.025;
      ratio := 1.0 / window_margin;

      dir: V2;
      dir.y += max(window_margin - G.mouse.x, 0) * ratio;
      dir.x += max(window_margin - G.mouse.y, 0) * ratio;
      dir.y -= max(G.mouse.x - (G.window_dim.x - window_margin), 0) * ratio;
      dir.x -= max(G.mouse.y - (G.window_dim.y - window_margin), 0) * ratio;

      dir.x = Smoothstep(abs(dir.x), max=0.9) * Sign(dir.x);
      dir.y = Smoothstep(abs(dir.y), max=0.9) * Sign(dir.y);

      dir_len := length(dir);
      if dir_len > 1.0 then dir /= dir_len;
      G.camera_p.xy += dir * G.dt * 16.0;
    }

    player := G_GetGhost(.SHARED, G.player_key);
    if KEY_Held(.SPACE) || G.frame_number < 10 // temp hack to center camera on player on startup
    {
      G.camera_p.xy = player.p.xy;
      G.camera_p.x -= 8.5;
    }
  }

  // calculate camera transform matrices
  {
    transl := TranslationMatrix(-G.camera_p);
    rot := RotationMatrixAroundAxis(AxisV3(.X), G.camera_angles.x);
    rot = RotationMatrixAroundAxis(AxisV3(.Z), G.camera_angles.z) * rot;
    rot = RotationMatrixAroundAxis(AxisV3(.Y), G.camera_angles.y) * rot;
    aspect := G.window_dim.x / G.window_dim.y;
    projection := PerspectiveMatrix(G.camera_fov_y, aspect, 0.25, 250.0);
    G.camera_transform = projection * (rot * transl);
  }

  // calculate mouse in screen space -> mouse in world space (at Z == 0)
  {
    view_mouse := V2.{
      (G.mouse.x / G.window_dim.x) *  2.0 - 1.0,
      (G.mouse.y / G.window_dim.y) * -2.0 + 1.0,
    };

    plane_origin: V3;
    plane_normal := V3.{0,0,1};

    aspect := G.window_dim.x / G.window_dim.y;
    tan := Tan(G.camera_fov_y * 0.5);
    aspect *= aspect;
    tan    *= tan;

    x := tan * view_mouse.x * aspect;
    y := tan * view_mouse.y;
    aim_dir := V3.{
      x * G.camera_transform.elem[0][0] + y * G.camera_transform.elem[0][1] + G.camera_transform.elem[0][2],
      x * G.camera_transform.elem[1][0] + y * G.camera_transform.elem[1][1] + G.camera_transform.elem[1][2],
      x * G.camera_transform.elem[2][0] + y * G.camera_transform.elem[2][1] + G.camera_transform.elem[2][2],
    };

    t_numerator := dot(plane_origin - G.camera_p, plane_normal);
    t_denominator := dot(aim_dir, plane_normal);

    G.world_mouse_valid = t_denominator < 0.0;
    if G.world_mouse_valid
    {
      t := t_numerator / t_denominator;
      world_off := aim_dir * t;
      world_mouse := G.camera_p + world_off;
      G.world_mouse = V3.{xy = world_mouse.xy, z = 0}; // @todo pass real Z?
    }
  }
}

G_AdvanceLocalObjects :: ()
{
  // Move sun
  sun_time := G.at*4.0;
  sun_time = 6.0;

  sun_x := Sin(0.5 + sun_time * 0.03);
  sun_y := Cos(0.5 + sun_time * 0.03);
  towards_sun_dir := normalize(V3.{sun_x, sun_y, 2.0});
  G.sun_dir = -towards_sun_dir;
  G.sun_camera_p = G.camera_p + towards_sun_dir * 40.0;

  transl := TranslationMatrix(-G.sun_camera_p);
  rot := RotationMatrix(RotationFromPair(G.sun_dir, AxisV3(.X)));

  dim := 20.0;
  projection := OrthographicMatrix(-dim, dim, -dim, dim, 30.0, 100.0);
  G.sun_camera_transform = projection * (rot * transl);

  sun := G_GetGhost(.LOCAL, G.sun);
  if !OBJ_IsNil(sun)
  {
    sun.p = G.sun_camera_p;
  }
}

G_ProcessInputAndSendToClient :: ()
{
  move_buttons := KEY_Code.[.MOUSE_RIGHT, .Z, .X];
  move_pressed := KEY_Pressed(..move_buttons);
  move_held_at_all := KEY_Held(..move_buttons, held_for = 0.0);
  move_held_for_a_while := KEY_Held(..move_buttons, held_for = 0.25);

  if !move_held_at_all {
    G.is_pathing_by_holding = false;
  }

  player := G_GetGhost(.SHARED, G.player_key);

  hover_target := OBJ_NilGhost();
  hovers_enemy: bool;
  if G.world_mouse_valid {
    hover_target = G_GetGhost(.ALL, G.hover_object);
    hovers_enemy = OBJ_Test2(hover_target, player, .{require_flags = .TARGETABLE, common = .IS_ALIVE, common2 = .ARE_ENEMIES});
  }

  skill_key_bind := KEY_Code.[.Q, .W, .E, .R];
  for skill: player.skills
  {
    if KEY_Pressed(skill_key_bind[it_index])
    {
      action: Action;
      action.tick = G.action_tick;
      action.type = xx (xx Action.Type.SKILL_0 + it_index);

      if skill.flags & .TARGETS_OBJECT {
        action.target = hover_target.key;
      } else if skill.flags & .TARGETS_POSITION {
        action.position = G.world_mouse;
      }

      QueuePush(*G.action_queue, action);
    }
  }

  if G.world_mouse_valid
  {
    if move_pressed && hovers_enemy
    {
      G.is_pathing_by_holding = false;

      action: Action;
      action.tick = G.action_tick;
      action.type = .ATTACK;
      action.target = G.hover_object;
      QueuePush(*G.action_queue, action);
    }

    if (move_pressed && !hovers_enemy) || (move_held_for_a_while && G.is_pathing_by_holding)
    {
      G.is_pathing_by_holding = true;

      action: Action;
      action.tick = G.action_tick;
      action.type = .PATHING;
      action.position = G.world_mouse;
      QueuePush(*G.action_queue, action);

      if move_pressed
      {
        marker := G_CreateLocalGhost(.ANIMATE_POSITION | .ANIMATE_ROTATION | .IS_MARKER | .DRAW_MODEL | .DISABLE_MOUSE);
        if !OBJ_IsNil(marker)
        {
          marker.model = .Cross;
          marker.hue_shift = 0.4;
          marker.p = G.world_mouse;
          marker.p.z = -0.05;
          marker.rotation = RotationAroundAxis(AxisV3(.Z), 0.5);
          marker.anim.position.xy = marker.p.xy;
          marker.anim.position.z = 0.3;
        }
      }
    }
  }

  G.action_tick += 1;
}

G_InterpolateSnapshotsForGhost :: (ghost: *Ghost, ghost_index: ObjIdx)
{
  // PerfFunc();
  PLAYER_LOGS :: false;

  snapshot_queue := *CL.snapshots[ghost_index];
  if QueueIsEmpty(snapshot_queue) {
    return;
  }

  first_update := !ghost.handled_tick;

  #if PLAYER_LOGS {
    is_player_index := ghost_index == OBJ_IndexOfKey(G_GetGhost(.SHARED, CL.player_key).key);
  }

  // Advance handled_tick, lerp_t and calculate new at_tick
  ghost.handled_tick = ghost.at.tick;
  ghost.tick_t += G.dt * TICK_RATE.(float) * ghost.tick_speed;
  {
    full_ticks_in_tick_t := ghost.tick_t.(ServerTick);
    ghost.at.tick += full_ticks_in_tick_t;
    ghost.tick_t -= full_ticks_in_tick_t.(float);
  }

  // We reached a destination tick - pick a new destination.
  if ghost.at.tick >= ghost.dest.tick || first_update
  {
    // Calculate ghost.tick_speed + snap to latest tick if we are too far behind.
    {
      prev_received_time: Timestamp;
      highest_time_delta: Timestamp;

      highest_tick := ServerTick_ZERO;
      smallest_tick := ServerTick_MAX;

      for snapshot_queue
      {
        smallest_tick = min(smallest_tick, it.tick);
        highest_tick = max(highest_tick, it.tick);

        // This method requires queue to be sorted.
        if prev_received_time > 0 && it.received_time > prev_received_time
        {
          delta := it.received_time - prev_received_time;
          highest_time_delta = max(highest_time_delta, delta);
        }
        prev_received_time = it.received_time;
      }

      // Snap to latest if we are too far behind.
      if highest_tick < ghost.at.tick || smallest_tick > ghost.at.tick || first_update
      {
        #if PLAYER_LOGS if is_player_index {
          log("[RESET PLAYER PLAYBACK] old at: %, from: %, dest: %, tick_t: %; smallest: %, highest: %, new at: %",
            ghost.at.tick, ghost.from.tick, ghost.dest.tick,
            ghost.tick_t, smallest_tick, highest_tick, highest_tick - 1);
        }

        ghost.at.tick = xx (highest_tick - 1);
        ghost.tick_t = 0.0;
      }

      // Calculate new tick_speed
      ghost.tick_speed = 1.0;
      if highest_tick > ghost.at.tick && highest_time_delta > 0
      {
        tick_dist := highest_tick - ghost.at.tick;
        // @todo This has an issue currently where we oscillate between 0.8 and 1.2 speeds constantly.
        //       Needs a stabilization where we aim to keep playback at 1.0.
        //       Temp solution for now is to check for tick_dist > 1
        if tick_dist > 1
        {
          tick_dist_seconds := tick_dist.(float) * TICK_FLOAT_STEP;
          time_dist_seconds := ToSeconds(highest_time_delta);

          ratio := tick_dist_seconds / time_dist_seconds;
          ghost.tick_speed = lerp(1.0, ratio, 0.1 * G.dt);

          #if PLAYER_LOGS if is_player_index {
            log("highest_time_delta: %, tick_dist: %, tick_dist_s: %, time_dist_s: %, ratio: %, ghost.tick_speed: %",
              highest_time_delta, tick_dist, tick_dist_seconds, time_dist_seconds, ratio, ghost.tick_speed);
          }
        }
        else
        {
          #if PLAYER_LOGS if is_player_index {
            log("highest_time_delta: %, tick_dist: %", highest_time_delta, tick_dist);
          }
        }
      }
      else
      {
        #if PLAYER_LOGS if is_player_index {
          log("highest_time_delta: %", highest_time_delta);
        }
      }
    }

    // Calculate desired from/dest tick values.
    desired_from_tick := ghost.at.tick;
    desired_dest_tick := (desired_from_tick + 1).(ServerTick);

    best_from := *ghost.from;
    best_dest := *ghost.dest;

    // @todo simplify the loop by assuming queue is sorted.
    for * snapshot_queue
    {
      // - Pick FROM -
      if it.tick > best_from.tick && it.tick <= desired_from_tick
      {
        // We are getting prefect hit or at least we are getting closer to it.
        best_from = it;
      }

      // - Pick DEST-
      if it.tick == desired_dest_tick
      {
        // Perfect case.
        best_dest = it;
      }

      if best_dest.tick < desired_dest_tick
      {
        // If BEST is under desired_dest_tick -> pick IT if it's larger.
        if it.tick > best_dest.tick
        {
          best_dest = it;
        }
      }
      else if best_dest.tick > desired_dest_tick
      {
        // If BEST and IT are over desired_dest_tick -> pick IT if it's smaller.
        if it.tick > desired_dest_tick
        {
          if it.tick < best_dest.tick
          {
            best_dest = it;
          }
        }
      }
    }

    if best_from != *ghost.from || best_dest != *ghost.dest
    {
      // @todo check if dest is under desired_dest_tick -> this means we are extrapolating.
      // If we are extraplating a lot we should stop and signal dropped connection to the user.
      // Also what if the server was slow/client is too fast and we got ahead -> this case needs a fixup!

      // Update lerp_speed and lerp_t.
      tick_range := best_dest.tick.(s64) - best_from.tick.(s64);
      if tick_range >= 1
      {
        // Overwrite ghost from, dest
        ghost.from = best_from.*;
        ghost.dest = best_dest.*;
      }
    }

    #if PLAYER_LOGS if is_player_index {
      log("[player playback] SQ.min=%; SQ.count=%; at: %, from: %, dest: %, tick_t: %",
        snapshot_queue.min, QueueCount(snapshot_queue),
        ghost.at.tick, ghost.from.tick, ghost.dest.tick,
        ghost.tick_t);
    }
  }


  // If from / dest is nil - don't use it in interpolation.
  if !OBJ_HasData(ghost.from.obj) || !OBJ_HasData(ghost.dest.obj)
  {
    ghost.at.obj = .{};
  }
  else
  {
    snap_range := max(ghost.dest.tick - ghost.from.tick, 1);
    snap_progress := ghost.at.tick - ghost.from.tick;
    snap_t := snap_progress / snap_range;

    tick_t := ghost.tick_t / snap_range;
    lerp_t := snap_t + tick_t;

    ghost.at.obj = OBJ_LerpObject(ghost.from.obj, ghost.dest.obj, lerp_t);

    init_ghost_anim := false;

    if (!ghost.at.obj.creation_tick) ghost.creation_time = 0;
    if (!ghost.at.obj.death_tick)    ghost.death_time = 0;
    if IsTickDue(ghost.at.obj.creation_tick, ghost) {
      ghost.creation_time = G.frame_timestamp;
      init_ghost_anim = true;
    }
    if IsTickDue(ghost.at.obj.death_tick, ghost)    ghost.death_time = G.frame_timestamp;

    if init_ghost_anim
    {
      ghost.anim = .{
        rotation = ghost.rotation,
        position = ghost.p,
      };
    }
  }
}

G_ParseCommandLineArguments :: (args: [] string)
{
  parse_target: *float;
  for args
  {
    if it_index == 0  continue; // skip arg with executable path
    arg := it;

    if parse_target
    {
      value, success := string_to_int(arg);
      if !success
      {
        log_error("Failed to parse % as an integer number.\n", arg);
        exit(1);
      }
      parse_target.* = cast(float) value;
      parse_target = null;
    }
    else
    {
      if arg ==
      {
        case "-headless";   G.headless = true;
        case "-w";          parse_target = *G.init_window_dim.x;
        case "-h";          parse_target = *G.init_window_dim.y;
        case "-px";         parse_target = *G.init_window_p.x;
        case "-py";         parse_target = *G.init_window_p.y;
        case "-fullscreen"; G.window_fullscreen = true;
        case "-borderless"; G.window_borderless = true;
        case "-top";        G.window_on_top = true;
        case "-autolayout"; G.window_autolayout = true;
        case "-server";     GLOBAL.is_server = true;
        case "-client";     GLOBAL.is_client = true;
        case "-exit-on-dc"; GLOBAL.server_exit_on_disconnect = true;

        case;
        log_error("Invalid command line argument %s.\n", arg);
        exit(1);
      }
    }

    print("arg%: %\n", it_index, it);
  }
}

//
// Local objects
//

G_InitLocalObjects :: ()
{
  // Sun
  {
    sun := G_CreateLocalGhost(.DRAW_COLLIDERS);
    sun.material = .Leather011;
    sun.height = 0.5;
    sun.collider = OBJ_ColliderFromRect(.{.5, .5});
    G.sun = sun.key;
  }

  // Ground
  {
    r := 32;
    d := 1.0;
    grass := MaterialID.Grass004;
    ground1 := MaterialID.Ground075;

    for y: MakeRange(-r, r)
    {
      for x: MakeRange(-r, r)
      {
        tile := G_CreateLocalGhost(.DRAW_COLLIDERS);
        if !OBJ_IsNil(tile)
        {
          tile.p = .{x = d * x, y = d * y};
          tile.collider = OBJ_ColliderFromRect(.{d, d});
          tile.texture_texels_per_m = 1.0 / d;
          tile.material = grass;
          if x < -r+5 || x >r-5 then tile.material = ground1;
          if y < -r+5 || y >r-5 then tile.material = ground1;
          if abs(x+y) < 4 then tile.material = ground1;
        }
      }
    }
  }

  // blocks thing
  {
    for wall: 0..3
    {
      len := 64;
      for i: MakeRange(len)
      {
        d := 1.0;

        x, y: float;
        if wall == 0 y = d*i;
        if wall == 1 {x = d*i; y = d * len;}
        if wall == 2 {x = d * len; y = len - d*i;}
        if wall == 3 x = len - d*i;
        x -= (0.5*d*len);
        y -= (0.5*d*len);

        block := G_CreateLocalGhost(.DRAW_COLLIDERS | .COLLIDE);
        if !OBJ_IsNil(block)
        {
          block.p = V3.{x, y, 0};
          block.collider = OBJ_ColliderFromRect(.{d,d});
          block.height = d;
          block.material = .Clay002;
          block.texture_texels_per_m = 1.0 / d;
        }
      }
    }
  }

  // Add trees
  {
    x_count := 4;
    y_count := 4;

    for y: MakeRange(y_count)
    {
      for x: MakeRange(x_count)
      {
        x_half_count := x_count/2;
        y_half_count := y_count/2;

        pos: V3;
        if ((x^y)&1) pos.x = 4.70;
        else         pos.y = 6.90;

        pos.x += 7 + 4.0*(x % x_half_count);
        pos.y += 5 + 2.4*(y % y_half_count);

        pos.x *= ifx x < x_half_count then -1 else 1;
        pos.y *= ifx y < y_half_count then -1 else 1;

        tree := G_CreateLocalGhost(.DRAW_MODEL);
        if !OBJ_IsNil(tree)
        {
          tree.p = pos;
          tree.model = .Tree;
        }
      }
    }
  }
}

G_DeleteGhost :: (ghost: *Ghost)
{
  ghost.* = .{};
}

G_CreateLocalGhost :: (flags: OBJ_Flags) -> *Ghost
{
  ghost: *Ghost;
  index: u32;

  for *G.local_ghosts
  {
    if !OBJ_HasData(it)
    {
      ghost = it;
      index = xx it_index;
      break;
    }
  }

  if (!ghost) return OBJ_NilGhost();

  Initialize(ghost);

  G.local_objects_creation_serials[index] = max(G.local_objects_creation_serials[index] + 1, 1);
  index_in_all_objects := index + OBJ_SHARED_COUNT;
  ghost.key = OBJ_CreateKey(index_in_all_objects, G.local_objects_creation_serials[index]);

  ghost.creation_tick = G.local_objects_tick;
  ghost.flags = flags;
  return ghost;
}

G_GetGhost :: (storage_mask: OBJ_Storage, key: OBJ_Key) -> *Ghost
{
  key_index := OBJ_IndexOfKey(key);

  index_in_valid_storage := false;
  {
    min: u32 = 0;
    max: u32 = OBJ_SHARED_COUNT;
    if (storage_mask & .SHARED)
      index_in_valid_storage |= (key_index >= 0 && key_index < max);

    min = max;
    max += OBJ_LOCAL_COUNT;
    if (storage_mask & .LOCAL)
      index_in_valid_storage |= (key_index >= min && key_index < max);
  }

  result := OBJ_NilGhost();
  if index_in_valid_storage
  {
    obj := *G.all_ghosts[key_index];
    if obj.key == key then result = obj;
  }
  return result;
}
