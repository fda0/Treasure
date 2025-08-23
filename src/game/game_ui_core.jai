#scope_file
using BOX;
#scope_export;

UI_BeginBoxLayout :: ()
{
  spec := LayoutSpec.{
    root_dim_px = G.window_dim,
    rem_to_px = 12.0 + 2.0 * floor(G.window_dim.y / 256.0),
    measure_text_callback = UI_MeasureText,
    mouse = G.mouse,
  };

  dump_logs := G.frame_number == 1 && false;
  if KEY_Pressed(.F4) dump_logs = true;

  spec.log_flags = ifx dump_logs then .ALL else .NONE;
  spec.log_flags &= ~(.POSITIONS);

  using ButtonType;
  spec.are_buttons_down[MOUSE_LEFT]   = KEY_Held(.MOUSE_LEFT);
  spec.are_buttons_down[MOUSE_MIDDLE] = false;
  spec.are_buttons_down[MOUSE_RIGHT]  = KEY_Held(.MOUSE_RIGHT);

  LayoutBegin(spec);
}

UI_FinishBoxLayout :: ()
{
  LayoutEnd();

  if !!layout_state.active_key
  {
    KEY_Consume(.MOUSE_LEFT, .MOUSE_RIGHT);
  }
}

UI_ProcessBoxRenderCommands :: ()
{
  for cmd: layout_state.render_commands
  {
    // if G.frame_number == 1
    //   print("[frame: %] render_command: % (%)\n", G.frame_number, cmd, cmd.box.loc);

    c4 := ColorV4_32(cmd.color);
    c32 := Color32_RGBAf(c4);

    shape := UI_Shape.{
      rect = MakeRangeMinDim(cmd.p, cmd.dim),
      color = c32,
      corner_radius = cmd.corner_radius,
      tex_layer = -1.0,
    };
    draw_shape := false;

    if cmd.type == {
      case .RECTANGLE;
      draw_shape = true;

      // case .BORDER;
      // shape.border_thickness = cmd.border_width;
      // draw_shape = true;

      case .TEXT;
      UI_DrawTextLine(cmd.text, xx cmd.font, xx cmd.font_size_px, cmd.color, cmd.p);

      case .CLIP;
      // shape.color = Color32_RGBAf(1.0, Sin01(it_index.(float) * 0.37),  Cos01(it_index.(float) * 0.21), 0.1);
      // draw_shape = true;
      UI_SetClipRect(shape.rect);
    }

    if draw_shape
    UI_Draw2D(shape);
  }

  UI_SetActiveClipIndex(0);
}
