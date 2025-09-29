main :: ()
{
  PLATFORM_Init();
  push_context PatchContext(.CLIENT)
  {
    PLATFORM_Iterate();
  }
}

PLATFORM_Init :: ()
{
  G.time_launch = current_time_monotonic();
  G.dpi_scaling = 1;

  PerfInit();

  ok := SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO);

  if ok
  {
    GAME_ParseCommandLineArguments(get_command_line_arguments());

    // Query display resolution and calculate default window dimensions
    if G.init_window_dim.x < 0 || G.init_window_dim.y < 0
    {
      // @todo use:
      //       SDL_DisplayID SDL_GetPrimaryDisplay(void);
      //       bool SDL_GetDisplayUsableBounds(SDL_DisplayID displayID, SDL_Rect *rect);
      if G.init_window_dim.x < 0
        G.init_window_dim.x = 1920/6*5;

      if G.init_window_dim.y < 0
        G.init_window_dim.y = 1080/6*5;
    }
  }

  ok &&= SDLNet_Init();

  if ok && !G.headless
  {
    G.audio.device = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null);
    ok = G.audio.device != 0;
  }

  if ok && !G.headless
  {
    G.gpu.device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_DXIL, debug_mode = true, name = null);
    ok = !!G.gpu.device;
  }

  if ok && !G.headless
  {
    G.window_dim = G.init_window_dim;
    window_flags: SDL_WindowFlags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIDDEN;
    if G.window_on_top      window_flags |= SDL_WINDOW_ALWAYS_ON_TOP;
    if G.window_borderless  window_flags |= SDL_WINDOW_BORDERLESS;

    G.window = SDL_CreateWindow("Treasure", xx G.window_dim.x, xx G.window_dim.y, window_flags);
    ok = !!G.window;
  }

  if ok && !G.headless
  {
    ok = SDL_ClaimWindowForGPUDevice(G.gpu.device, G.window);
  }

  if ok && !G.headless && (G.init_window_p.x > 0 || G.init_window_p.y)
  {
    x := ifx G.init_window_p.x > 0 then xx G.init_window_p.x else cast(s32) SDL_WINDOWPOS_UNDEFINED();
    y := ifx G.init_window_p.y > 0 then xx G.init_window_p.y else cast(s32) SDL_WINDOWPOS_UNDEFINED();
    SDL_SetWindowPosition(G.window, x, y);
  }
  G.time_init_sdl = current_time_monotonic();

  GAME_Init();
  G.time_init_game = current_time_monotonic();

  if ok && !G.headless
    SDL_ShowWindow(G.window);

  if !ok
  {
    log_error("Failed to initialize SDL window\n");
    exit(1);
  }

  G.time_init_finished = current_time_monotonic();
}

PLATFORM_Iterate :: ()
{
  while !G.in_shutdown
  {
    if !G.headless && G.window_fullscreen != G.sdl_is_fullscreen
    {
      G.sdl_is_fullscreen = G.window_fullscreen;
      SDL_SetWindowFullscreen(G.window, G.window_fullscreen);
    }

    // Poll input
    {
      ev: SDL_Event;
      while SDL_PollEvent(*ev)
      {
        if ev.type ==
        {
          case xx SDL_EventType.QUIT;
          G.in_shutdown = true;

          case xx SDL_EventType.WINDOW_RESIZED;
          window := ev.window;
          G.window_dim = V2.{xx window.data1, xx window.data2};
          G.window_resized = true;

          case xx SDL_EventType.KEY_DOWN;
          if ev.key.key == SDLK_ESCAPE  G.in_shutdown = true;

          case xx SDL_EventType.MOUSE_MOTION;
          motion := ev.motion;
          delta := V2.{motion.xrel, motion.yrel};
          G.mouse_delta += delta;

          case xx SDL_EventType.MOUSE_WHEEL;
          wheel := ev.wheel;
          delta := V2.{wheel.x, wheel.y};
          G.mouse_scroll += delta;
        }
      }

      SDL_SetWindowMouseGrab(G.window, G.grab_mouse);

      mouse_keys := SDL_GetMouseState(*G.mouse.x, *G.mouse.y);
      KEY_Update(.MOUSE_LEFT, !!(mouse_keys & SDL_BUTTON_LMASK));
      KEY_Update(.MOUSE_RIGHT, !!(mouse_keys & SDL_BUTTON_RMASK));

      num_keys: s32;
      key_states := SDL_GetKeyboardState(*num_keys);
      for MakeRange(num_keys)
        KEY_Update(xx it, key_states[it]);

      window_flags := SDL_GetWindowFlags(G.window);
      G.window_has_focus = !!(window_flags & SDL_WINDOW_MOUSE_FOCUS);
    }

    GAME_Iterate();

    // Poll input cleanup
    {
      G.mouse_scroll = V2.{};
      G.mouse_delta = V2.{};
      G.window_resized = false;
    }
  }
}

#load "game_core.jai";

//
// SDL THINGS
//

// @todo To support live window resizing without SDL3 callbacks one has to:
// 1. Use SDL_SetEventFilter + callback - PLATFORM_EventFilterSDL :: (userdata: *void, event: *SDL_Event) -> bool #c_call;
// 2. Detect SDL_EVENT_WINDOW_EXPOSED and then issue a draw call.
// 3. But to do this properly one has to do Dangerous Threads Crew kinds of shenanigans (callback might be called from a thread that's different than rendering thread).

/**
* A bitmask of pressed mouse buttons, as reported by SDL_GetMouseState, etc.
*
* - Button 1: Left mouse button
* - Button 2: Middle mouse button
* - Button 3: Right mouse button
* - Button 4: Side mouse button 1
* - Button 5: Side mouse button 2
*
* \since This datatype is available since SDL 3.2.0.
*
* \sa SDL_GetMouseState
* \sa SDL_GetGlobalMouseState
* \sa SDL_GetRelativeMouseState
SDL_MouseButtonFlags :: Uint32;
*/

// @todo improve generator so you don't need to define these here:
SDL_BUTTON_LMASK : SDL_MouseButtonFlags : (1 << 0);
SDL_BUTTON_RMASK : SDL_MouseButtonFlags : (1 << 2);
// @todo how to overwrite SDL_ASSERT_LEVEL :: 2; in sdl3 module?

using,map(ImportMapForSDL) SDL :: #import "sdl3_base+net";
ImportMapForSDL :: (names: [] string)
{
  S :: #import,file "../shared/base_string.jai";
  B :: #import "Basic";

  for *names
  {
    name := it.*;
    new_name: string;

    if S.StartsWith(name, "NET_")
      new_name = B.tprint("SDLNet_%", S.Skip(name, 4));
    else if !S.StartsWith(name, "SDL")
      new_name = B.tprint("SDL%", name);

    if new_name.count
    {
      // B.print("SDL RENAME % -> %\n", name, new_name);
      it.* = new_name;
    }
  }
}
