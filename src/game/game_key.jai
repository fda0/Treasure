#scope_file;
using,only(G) COMPS;
#scope_export;

KEY_Code :: enum u32
{
  using,except(COUNT) SDL_Scancode;
  START :: SDL_SCANCODE_COUNT + 1;
  MOUSE_LEFT;
  MOUSE_RIGHT;
  COUNT;

  // @todo write metaprogram that imports SDL_Scancodes but removes SDL_SCANCODE_...
  // W :: SDL_SCANCODE_W;
  // S :: SDL_SCANCODE_S;
  // A :: SDL_SCANCODE_A;
  // D :: SDL_SCANCODE_D;
}

KEY_Flags :: enum_flags u8
{
  HELD;
  PRESSED;
  RELEASED;
  // @todo DOUBLE_PRESSED, TRIPLE_PRESSED
  CONSUMED;
}

Key :: struct
{
  f: KEY_Flags;
  held_start: Timestamp;
}

KEY_Update :: (key_code: KEY_Code, is_down: bool)
{
  using KEY_Flags;

  key := *G.keys[key_code];
  is_held     := !!(key.f & HELD);
  is_pressed  := !!(key.f & PRESSED);
  is_released := !!(key.f & RELEASED);

  if is_down
  {
    is_pressed = (!is_held && !is_pressed);
    is_released = false;
  }
  else
  {
    is_released = (!is_held && !is_released);
    is_pressed = false;
  }
  is_held = is_down;

  key.f = 0;
  if is_held      key.f |= HELD;
  if is_pressed   key.f |= PRESSED;
  if is_released  key.f |= RELEASED;

  if is_pressed then key.held_start = G.frame_timestamp;
}

KEY_Consume  :: (key_codes: ..KEY_Code)
{
  for key_codes
  {
    G.keys[it].f |= .CONSUMED;
  }
}

KEY_CheckMany :: (flags: KEY_Flags, key_codes: ..KEY_Code, held_for := 0.0) -> bool
{
  res := false;
  for key_codes
  {
    key := G.keys[it];
    if key.f & .CONSUMED continue;
    test := (key.f & flags) && (Elapsed(G.frame_timestamp, key.held_start) >= held_for);
    res |= test;
  }
  return res;
}
KEY_Held     :: (key_codes: ..KEY_Code, held_for := 0.0) -> bool { return KEY_CheckMany(.HELD, ..key_codes, held_for); }
KEY_Pressed  :: (key_codes: ..KEY_Code) -> bool { return KEY_CheckMany(.PRESSED, ..key_codes); }
KEY_Released :: (key_codes: ..KEY_Code) -> bool { return KEY_CheckMany(.RELEASED, ..key_codes); }
