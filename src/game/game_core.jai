G: GAME_State;
GAME_State :: struct
{
  // startup profiling
  time_launch: Apollo_Time;
  time_init_sdl: Apollo_Time;
  time_init_game: Apollo_Time;
  time_init_finished: Apollo_Time;
  time_finished_first_iterate: Apollo_Time;

  // Time
  frame_timestamp: Timestamp;
  delta_timestamp: Timestamp;
  timestamp_accumulator: Timestamp;
  dt: float;
  at: float;
  frame_number: s64;

  // component states
  gpu: GPU_State;
  ast: ASSET_State;
  audio: AUDIO_State;
  hr: HOT_RELOAD_State;
  font: FONT_State;
  net: NET_State;
  cl: CL_State;
  dev: DEV_State;
  stats: STATS_State;
  log: LOG_State;

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
}

GAME_Init :: ()
{
  PerfFunc();

  ASSET_InitPreGPU();
  GPU_Init();
  GPU_BATCH_Init();
  ASSET_InitPostGPU();
  ANIMATION_InitSkeletons();
  FONT_Init();
  UI_ClearRenderCounters();
  HOT_RELOAD_InitWatcher();

  CL_Init();
  CL_InitObjects();
}

GAME_Iterate :: ()
{
  assert(context.role == .CLIENT);
  PerfFunc();

  // Advance time
  if LaneIdx() == 0
  {
    now := TimeNow();
    G.delta_timestamp = now - G.frame_timestamp;
    G.frame_timestamp = now;
    G.timestamp_accumulator += G.delta_timestamp;
    G.dt = G.delta_timestamp.(float) * 0.001;
    G.at = WrapFloat(G.at + G.dt, 0.0, 1000.0);
    G.frame_number += 1;

    Post(.DELTA_TIMESTMAP_MS, xx G.delta_timestamp);
    Post(.TEST_FRAME_NUMBER, G.frame_number);
  }

  // Mouse input things
  if LaneIdx() == 0
  {
    if KEY_Pressed(.F11) then G.window_fullscreen = !G.window_fullscreen;

    if G.dev.show || G.dev.noclip || !G.window_has_focus
    {
      G.grab_mouse = false;
    }
    else if KEY_Held(.MOUSE_LEFT, .MOUSE_RIGHT) && OverlapsRange(MakeRange(G.window_dim), G.mouse)
    {
      G.grab_mouse = true;
    }
  }

  // Pre frame inits
  if LaneIdx() == 0
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
  if LaneIdx() == 0
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

  // Client network / playback
  if LaneIdx() == 0
  {
    CL_IterateReceive();

    {
      #assert((1000 % TICK_MILLISECONDS_STEP) == 0);
      #assert((1000 / TICK_MILLISECONDS_STEP) == TICK_RATE);
      tick_count := G.timestamp_accumulator / TICK_MILLISECONDS_STEP;
      G.timestamp_accumulator -= tick_count * TICK_MILLISECONDS_STEP;

      for MakeRange(tick_count)
      {
        G.cl.playback_tick += 1;
        CL_PlayTick();
      }
      Post(.NEXT_PLAYBACK_SV_TICK, xx G.cl.next_playback_server_tick);
    }

    CL_IterateSend();
  }

  LaneSync();

  // UI work
  if LaneIdx() == LaneFromTaskIdx(1)
  {
    if !G.headless
    {
      PerfScope("UI workload");
      UI_DeveloperKeyShortcuts();
      UI_BeginBoxLayout();
      UI_BuildHUD();
      UI_BuildDeveloperWindow();
      UI_FinishBoxLayout();
    }
  }

  // Play sounds
  if LaneIdx() == LaneFromTaskIdx(3) && !G.headless
  {
    // Play debug sound
    if KEY_Pressed(.M) AUDIO_PlaySound(.HIT);
    AUDIO_PlayObjectSounds();
  }

  // Calculate mouse input and camera
  if LaneIdx() == 0 && !G.headless
  {
    GAME_CalculateCameraAndMouseThings();
  }

  // Move the sun object
  if LaneIdx() == 0
  {
    GAME_UpdateOfflineObjects();
  }

  // Prepare client player input and send it
  if LaneIdx() == 0 && !G.headless
  {
    GAME_CollectClientInput();
  }

  // Update marker object
  if LaneIdx() == 0 && !G.headless
  {
    marker := CL_GetGhost(.LOCAL, G.cl.pathing_marker);
    if !OBJ_IsNil(marker)
    {
      if G.cl.input.type == .PATHING
      {
        marker.o.flags |= .DRAW_MODEL;
        marker.o.model = ModelKey("Flag");
        marker.o.p = G.cl.input.world_p;
        marker.animated_p.xy = marker.o.p.xy;
        G.cl.pathing_marker_set = true;
      }
      else
      {
        marker.o.p.z = -2.0;
        G.cl.pathing_marker_set = false;
      }
    }
  }

  // Calculate animations
  if LaneIdx() == LaneFromTaskIdx(2) && !G.headless
  {
    // @todo This actually has a race condition vs WORLD_DrawObjects
    //       Most animations will be actually one frame old.
    //       Needs redesign.
    ANIMATION_AnimateObjects();
  }

  // Draw objects
  if LaneIdx() == 0 && !G.headless
  {
    WORLD_DrawObjects();
  }

  LaneSync();

  // Post frame work
  if LaneIdx() == 0 && !G.headless
  {
    UI_Translate3DShapes();
    UI_ProcessBoxRenderCommands();
    UI_DrawDeveloperFontAtlas();

    GPU_Iterate();

    // Post frame calls
    GPU_BATCH_PostFrame();
    UI_ClearRenderCounters();
    ASSET_PostFrame();

    HOT_RELOAD_Iterate();
  }

  // Post frame logic
  if LaneIdx() == 0
  {
    STATS_PostFrame();
    LOG_FileFlush();
  }

  if !G.time_finished_first_iterate
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

GAME_CalculateCameraAndMouseThings :: ()
{
  if G.dev.noclip
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

      easing :: (x: float) -> float {
        // return 1.0 - pow(1 - x, 4); // easeOutQuart
        return x*x*x;
      }
      dir.x = Smoothstep(abs(dir.x), max=0.9) * Sign(dir.x);
      dir.y = Smoothstep(abs(dir.y), max=0.9) * Sign(dir.y);

      dir_len := length(dir);
      if dir_len > 1.0 then dir /= dir_len;
      G.camera_p.xy += dir * G.dt * 16.0;
    }

    player := CL_GetGhost(.SHARED, G.cl.player_key);
    if KEY_Held(.SPACE) || G.frame_number < 10 // temp hack to center camera on player on startup
    {
      G.camera_p.xy = player.o.p.xy;
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

GAME_UpdateOfflineObjects :: ()
{
  // Move sun
  sun_time := G.at*4.0;
  sun_time = 6.0;

  sun_x := Sin(0.5 + sun_time * 0.03);
  sun_y := Cos(0.5 + sun_time * 0.03);
  towards_sun_dir := normalize(V3.{sun_x, sun_y, 2.0});
  G.sun_dir = -towards_sun_dir;

  sun_dist := towards_sun_dir * 40.0;
  G.sun_camera_p = G.camera_p + sun_dist;
  CL_GetGhost(.LOCAL, G.cl.sun).o.p = G.sun_camera_p;

  transl := TranslationMatrix(-G.sun_camera_p);
  rot := RotationMatrix(RotationFromPair(G.sun_dir, AxisV3(.X)));

  dim := 20.0;
  projection := OrthographicMatrix(-dim, dim, -dim, dim, 30.0, 100.0);
  G.sun_camera_transform = projection * (rot * transl);
}

GAME_CollectClientInput :: ()
{
  input := *G.cl.input;
  input.skills = 0;

  move_buttons := KEY_Code.[.MOUSE_RIGHT, .Z, .X];
  move_pressed := KEY_Pressed(..move_buttons);
  move_held := KEY_Held(..move_buttons, held_for = 0.25);

  if KEY_Pressed(.Q) input.skills |= .Q;
  if KEY_Pressed(.W) input.skills |= .W;
  if KEY_Pressed(.E) input.skills |= .E;
  if KEY_Pressed(.R) input.skills |= .R;

  if G.world_mouse_valid
  {
    self := CL_GetGhost(.SHARED, G.cl.player_key);
    hovered_obj := CL_GetGhost(.ALL, G.hover_object);
    hovers_enemy := OBJ_Test2(hovered_obj.o, self.o,
                              .{require_flags = .TARGETABLE,
                                common = .IS_ALIVE,
                                common2 = .ARE_ENEMIES});

    if move_pressed && hovers_enemy
    {
      input.type = .ATTACK;
      input.target_object = G.hover_object;
      input.world_p = G.world_mouse;
    }

    if (move_pressed && !hovers_enemy) || (move_held && input.type == .PATHING)
    {
      input.type = .PATHING;
      input.world_p = G.world_mouse;
      input.target_object = .{};
      if move_pressed
      {
        marker := CL_GetGhost(.LOCAL, G.cl.pathing_marker);
        if !OBJ_IsNil(marker) marker.animated_p.z = 0.5;
      }
    }
  }

  CL_FlushPlayerInput();
}

GAME_ParseCommandLineArguments :: (args: [] string)
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
