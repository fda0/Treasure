#scope_file;
using,only(AUDIO,DEV,FONT,G,STATS) COMPS;
#scope_export;

#scope_file;
using BOX;
UI_RED1      :: #run PackedRGB(0xcc, 0x24, 0x1d);
UI_RED2      :: #run PackedRGB(0xfb, 0x49, 0x34);
UI_GREEN1    :: #run PackedRGB(0x98, 0x97, 0x1a);
UI_GREEN2    :: #run PackedRGB(0xb8, 0xbb, 0x26);
UI_YELLOW1   :: #run PackedRGB(0xd7, 0x99, 0x21);
UI_YELLOW2   :: #run PackedRGB(0xfa, 0xbd, 0x2f);
UI_BLUE1     :: #run PackedRGB(0x45, 0x85, 0x88);
UI_BLUE2     :: #run PackedRGB(0x83, 0xa5, 0x98);
UI_ORANGE1   :: #run PackedRGB(0xd6, 0x5d, 0x0e);
UI_ORANGE2   :: #run PackedRGB(0xfe, 0x80, 0x19);
UI_BG        :: UI_BG0;
UI_BG0       :: #run PackedRGB(40, 40, 40);
UI_BG1       :: #run PackedRGB(0x3c3836);
UI_BG2       :: #run PackedRGB(0x504945);
UI_FG        :: UI_FG1;
UI_FG0       :: #run PackedRGB(0xfbf1c7);
UI_FG1       :: #run PackedRGB(235, 219, 178);
UI_FG2       :: #run PackedRGB(0xd5c4a1);
UI_FG3       :: #run PackedRGB(0xbdae93);
UI_BORDER_BG :: #run PackedRGB(29, 32, 33);
UI_BUTTON_BG :: #run PackedRGB(80, 73, 69);
UI_BUTTON_HOVER_BG :: #run PackedRGB(102, 92, 84);
UI_SHADOW    :: #run PackedRGBA(29, 32, 33, 96);
UI_DARKER    :: #run PackedRGBA(0, 0, 0, 64);

UI_RADIUS :: #run RadiusAll(Px(2));
UI_BORDER_WIDTH :: #run BorderOutside(Px(1));
UI_WINDOW_GAP :: #run Rem(0.5);
UI_WINDOW_PAD :: #run PaddingAll(UI_WINDOW_GAP);
UI_BUTTON_PAD :: #run Padding.{UI_WINDOW_GAP, UI_WINDOW_GAP, UI_WINDOW_GAP*0.5, UI_WINDOW_GAP*0.5};

UI_EDGE_SOFTNESS :: #run Px(1);

UI_HEADER_TEXT  :: #run BoxSpec.{text = .{font = xx FONT_Family.PlayfairDisplay, font_size = Rem(1.5)},
                                 layout.padding = PaddingV(Rem(0.2), Rem(0.6))};
UI_REGULAR_TEXT :: #run BoxSpec.{text = .{font = xx FONT_Family.PlayfairDisplay, font_size = Rem(1)}};
UI_MONO_TEXT    :: #run BoxSpec.{text = .{font = xx FONT_Family.Inconsolata, font_size = Rem(0.85)},
                                 layout.padding = PaddingV(Em(0.4))};

UI_WINDOW_LOOK :: BoxSpec.{bg_color = UI_BG,
                           border = .{color = UI_BORDER_BG, widths = UI_BORDER_WIDTH},
                           corner_radius = UI_RADIUS};
UI_WINDOW_LAYOUT :: BoxSpec.{layout = .{child_gap = UI_WINDOW_GAP, padding = UI_BUTTON_PAD}};

#scope_export;

DEV_State :: struct // @todo serialize this struct to disk
{
  show := true;

  atlas_boxes: [FONT_ATLAS_LAYERS] *Box;
  atlas_clip_box: *Box;

  // switches
  show_stats: bool;
  noclip: bool;
  sun_camera: bool;
  show_colliders: bool;
  pause_ghosts_interpolation: bool;
  mouse_picking: enum_flags { ENABLED; ONE_PIXEL; } = .ENABLED;

  // object
  inspected_object: OBJ_Key;

  // window
  windows: DEV_Window;
}

DEV_Window :: struct
{
  Category :: enum
  {
    STATS;
    SWITCHES;
    ASSETS;
    NETWORK;
    SOUNDS;
    OBJECT;
    FONTS;
  }
  CATEGORY_NAMES :: #run enum_names(Category);
  CATEGORY_COUNT :: #run EnumCount(Category);

  prev, next: *DEV_Window;
  to_be_closed: bool;

  category: Category;
  position: V2;
  size: V2;

  selected: OBJ_Key;
}

DEV_Init :: ()
{
  DEV.windows.prev = *DEV.windows;
  DEV.windows.next = *DEV.windows;
}

DEV_FindWindow :: (category: DEV_Window.Category, selected := OBJ_Key.{}) -> *DEV_Window
{
  window := DEV.windows.next;
  while window != *DEV.windows
  {
    match := window.category == category;
    if match && category == .OBJECT && !OBJ_KeyIsZero(selected) {
      match = window.selected == selected;
    }

    if match {
      break;
    }
    window = window.next;
  }
  return window;
}

DEV_OpenWindow :: (category: DEV_Window.Category, selected := OBJ_Key.{}) -> *DEV_Window, did_open: bool
{
  window := DEV_FindWindow(category, selected);
  did_open := false;
  if window == *DEV.windows
  {
    did_open = true;
    window = New(DEV_Window);

    // Link
    window.next = *DEV.windows;
    window.prev = DEV.windows.prev;
    DEV.windows.prev.next = window;
    DEV.windows.prev = window;

    // Init data
    window.category = category;
    window.position = V2.{100, 100} + V2.{40, 20} * category.(float);
    window.size = .{400, 400};
    window.selected = selected;
  }
  return window, did_open;
}

DEV_CloseWindow :: (window: *DEV_Window)
{
  if (window == *DEV.windows) return;
  window.next.prev = window.prev;
  window.prev.next = window.next;
  free(window);
}

UI_DeveloperKeyShortcuts :: ()
{
  if (KEY_Pressed(.GRAVE)) DEV.show = !DEV.show;
  if (KEY_Pressed(.RETURN)) DEV.noclip = !DEV.noclip;
  if (KEY_Pressed(.BACKSPACE)) DEV.sun_camera = !DEV.sun_camera;
}

UI_BuildDeveloperWindow :: ()
{
  ArrayClear(DEV.atlas_boxes);
  DEV.atlas_clip_box = null;
  inspected_object: OBJ_Key;
  defer DEV.inspected_object = inspected_object;

  if !DEV.show return;
  PerfFunc();

  Layer(.{text.color = UI_FG});
  Layer(UI_REGULAR_TEXT);

  // Category menu on left side.
  {
    Parent(CreateBox(.{layout = .{child_order = .TOP_TO_BOTTOM,
                                  size.min = Fit2(), size.pref.y = Grow(),
                                  child_align.x = .CENTER},
                       floating = .{attach_to = .ROOT}},
                     UI_WINDOW_LOOK, UI_WINDOW_LAYOUT));

    for DEV_Window.CATEGORY_NAMES
    {
      if UI_Button(it)
      {
        window, did_open := DEV_OpenWindow(xx it_index);
        if !did_open {
          window.to_be_closed = true;
        }
      }
    }
  }

  // Object window
  if KEY_Pressed(.T) && !OBJ_KeyIsZero(G.hover_object) {
    DEV_OpenWindow(.OBJECT, G.hover_object);
  }

  // Create window for each active category
  window := DEV.windows.next;
  while window != *DEV.windows
  {
    defer window = window.next;

    Layer(.{seed = xx window});

    category_name := DEV_Window.CATEGORY_NAMES[window.category];

    window_body, window_outer := UI_FloatingWindow(category_name, window);
    Parent(window_body);

    // Per category imlementation
    if #complete window.category == {
      case .STATS;
      Layers(UI_MONO_TEXT);
      CreateText(tprint("dt: %ms; fps: %", Round(G.dt*1000), Round(1.0 / G.dt)));
      CreateText(tprint("is_server: %, is_client: %", GLOBAL.is_server, GLOBAL.is_client));

      CreateText(tprint("Mouse: %", G.mouse));
      CreateText(tprint("World Camera: %", G.camera_p));
      CreateText(tprint("Camera - Player: %", G.camera_p - G_GetGhost(.SHARED, G.player_key).p));
      CreateText(tprint("Camera angles: %", G.camera_angles));

      CreateText("more random data 1");
      CreateText("more random data 2");

      for STATS_CounterValues
      {
        c := *STATS.counters[it];
        label := STATS_CounterNames[it];

        CreateText("");
        CreateText(label);
        UI_ToggleButton("Pause", *c.paused);

        recent_peak := S64_MIN;
        for c.history recent_peak = max(recent_peak, it);

        stats := tprint("total: %; recent: %; recent peak: %, all time peak: % (on frame %)",
          c.total_sum, QueuePeekLast(c.history), recent_peak, c.on_peak_frame, c.peak_frame_number);
        CreateText(stats);

        // Create graph background
        Layer(.{layout.padding = PaddingAll(Px(0))});
        graph_box := Parent(CreateBox(.{is_persistent = true,
                                        track_signal = .WITHOUT_ACTIVATION,
                                        layout.size.min.y = Rem(1),
                                        snap_to_full_pixel = true,
                                        bg_color = PackedRGB(0)}));

        // Calculate graph width
        bar_width_px := max(1.0, floor(window_outer.inner.x / c.history.CAPACITY));
        graph_box.layout.size.min.x = Px(bar_width_px * c.history.CAPACITY);

        // Update graph bar height scale
        {
          target_graph_scale := 1.0 / recent_peak.(float);
          if c.graph_scale <= 0.0
          {
            c.graph_scale = target_graph_scale;
          }
          else
          {
            c.graph_scale = lerp(c.graph_scale, target_graph_scale, min(1.0, G.dt * 2.0));
            c.graph_scale = min(c.graph_scale, target_graph_scale);
          }
        }

        // Create bars
        parent_height_px := graph_box.inner.y;
        for c.history
        {
          height_px := 0.0;
          if c.on_peak_frame
          {
            height_pct := it.(float) * c.graph_scale;
            height_px = parent_height_px * height_pct;
          }

          // Checking hover on graph_box before enabling hover tracking on each bar saves quite a lot of perfomance.
          signal_on_bars := ifx graph_box.signal & .HOVER_ON_CHILD then TrackSignal.WITHOUT_ACTIVATION else .NONE;
          total := Parent(CreateBox(.{layout.size = .{min.x = Px(bar_width_px), pref.y = Grow()},
                                      track_signal = signal_on_bars}));
          filled := CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Px(height_px)},
                                bg_color = UI_YELLOW1});

          if it_index % 2 == 0 then filled.bg_color = UI_YELLOW2;

          if total.signal & .HOVER
          {
            Parent(CreateBox(.{layout.child_order = .TOP_TO_BOTTOM,
                               layout.size.min = Fit2(),
                               floating = .{attach_to = .PARENT,
                                            z_index = 1,
                                            anchors.itself = .{horizontal = .CENTER, vertical = .BOTTOM},
                                            anchors.parent = .{horizontal = .CENTER, vertical = .TOP}}},
                             UI_WINDOW_LOOK, UI_WINDOW_LAYOUT));
            CreateText(tprint("Index: %", it_index));
            CreateText(tprint("Value: %", it));

            total.bg_color = PackedWhite();
            filled.bg_color = PackedNegativeRGB(filled.bg_color);
          }
        }
      }

      case .SWITCHES;
      UI_Checkbox("Noclip camera", *DEV.noclip);
      UI_Checkbox("Sun camera", *DEV.sun_camera);
      UI_Checkbox("Show colliders", *DEV.show_colliders);
      UI_Checkbox("Pause ghosts interpolation", *DEV.pause_ghosts_interpolation);
      UI_Checkbox("Enable mouse picking", *DEV.mouse_picking, .ENABLED);
      UI_Checkbox("Mouse picking - one pixel mode", *DEV.mouse_picking, .ONE_PIXEL);
      UI_Checkbox("Render normals", null);

      case .ASSETS;
      Layers(UI_MONO_TEXT);
      CreateText("what got loaded from .pie file?");
      CreateText("hot-reload state");

      case .NETWORK;
      Layers(UI_MONO_TEXT);
      CreateText("network stuff here");

      case .SOUNDS;
      Layers(UI_MONO_TEXT);
      // @todo Master volume slider
      CreateText("Active sounds:");
      for AUDIO.actives
      {
        // @todo not related to dev_ui but add data driver way to tweak volume, pitch etc
        CreateText(tprint("%, %ms / %ms", it.type, Elapsed(G.frame_timestamp, it.start_time)*1000, it.duration));
      }
      // @todo log recently finished sounds too

      case .OBJECT;
      Layers(UI_MONO_TEXT);
      CreateText(tprint("Seletected: % {index: %, serial: %}",
        window.selected, OBJ_IndexOfKey(window.selected), OBJ_SerialOfKey(window.selected)));

      {
        _, signal := UI_Button("hover me", dont_grow = true);
        if signal & .HOVER {
          inspected_object = window.selected;
        }
      }

      ghost := G_GetGhost(.ALL, window.selected);
      if OBJ_IsNil(ghost) CreateText("ghost is nil");

      push_context{
        push_allocator(temp);
        context.print_style.default_format_struct.use_newlines_if_long_form = true;

        builder: String_Builder;
        print_to_builder(*builder, "%\nhandled_tick = %\ncreation_time = %\ndeath_time = %\nanim = %\n",
          ghost.at.obj, ghost.handled_tick, ghost.creation_time, ghost.death_time, ghost.anim);

        node := ghost.anim.node;
        while !IsNil(node) {
          print_to_builder(*builder, "%\n", node.*);
          node = node.next;
        }

        txt := builder_to_string(*builder);
        lines := String.split(txt, "\n");
        for lines
        {
          CreateText(it);
        }
      }

      case .FONTS;
      CreateText(tprint("Active atlas layer: %/%", FONT.active_layer_index, FONT.layers.count));
      side_size_px := window_outer.inner.x * 0.8;

      DEV.atlas_clip_box = window_outer;
      for *DEV.atlas_boxes
      {
        it.* = CreateBox(.{layout.size.min = Px2(side_size_px),
                           border = .{color = UI_FG, widths = UI_BORDER_WIDTH}});
      }
    }
  }

  // handle closed windows
  {
    window := DEV.windows.next;
    while window != *DEV.windows
    {
      next := window.next;
      if window.to_be_closed
      {
        DEV_CloseWindow(window);
      }
      window = next;
    }
  }
}

UI_DrawDeveloperFontAtlas :: ()
{
  if !DEV.atlas_clip_box return;

  tex_dim := V2.{xx FONT.texture_dim, xx FONT.texture_dim};

  clip_min, clip_dim := FinalInnerMinDim(DEV.atlas_clip_box);
  clip := MakeRectMinDim(clip_min, clip_dim);

  for box: DEV.atlas_boxes
  {
    if !box continue;

    p := box.abs_p + BOX.PaddingLower2(box);
    dim := box.inner;
    shade := ifx it_index == FONT.active_layer_index then 1.0 else 0.7;

    shape := RD_UIShape.{
      rect = MakeRectMinDim(p, dim),
      clip_rect = clip,
      tex_rect = MakeRectMinDim(.{}, tex_dim),
      tex_layer = xx it_index,
      color = ColorPack(ColorWhite(shade)),
    };
    RD_UIDraw2D(shape);
  }
}

UI_FloatingWindow :: (label: string, dev_window: *DEV_Window) -> content: *Box, window: *Box
{
  Layer(.{seed = xx dev_window});

  window := Parent(CreateBox(.{is_persistent = true,
                               layout.child_order = .TOP_TO_BOTTOM,
                               floating.attach_to = .ROOT},
                             UI_WINDOW_LOOK));

  // Window bar
  {
    window_bar := Parent(CreateBox(.{layout = .{size.pref.x = Grow(), size.min.y = Fit(),
                                                padding = PaddingAll(Rem(0.4)),
                                                child_align = .{x = .CENTER, y = .CENTER}},
                                     bg_color = UI_ORANGE2,
                                     corner_radius = UI_RADIUS,
                                     track_signal = .ALL}));

    if (window_bar.signal & .DRAG) dev_window.position += G.mouse_delta;
    clamped_win_p := clamp(dev_window.position, .{}, G.window_dim - dev_window.size);
    window.floating.offset = Px2(clamped_win_p);
    if !(window_bar.signal & .DRAG) dev_window.position = clamped_win_p;

    CreateText(label, .{text.color = UI_BG});

    {
      x_button := CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                         padding = UI_BUTTON_PAD, child_align.x = .RIGHT,
                                         child_align.y = .CENTER, child_gap = UI_WINDOW_GAP},
                              floating = .{attach_to = .PARENT, anchors = GetAnchor2(.RIGHT, .CENTER)},
                              track_signal = .ALL});

      Parent(x_button);
      x_label := CreateText("X");
      x_label.text.color = ifx x_button.signal & .HOVER then UI_RED2 else UI_RED1;

      if x_button.signal & .CLICK
      {
        dev_window.to_be_closed = true;
      }
    }

  }

  Parent(CreateBox(.{layout = .{size.min.x = Fit(), size.pref = Grow2()}}));

  // Scrolling
  scrollable: *Box;
  resize_button: *Box;
  {
    BAR_THICKNESS :: #run Rem(0.75);
    color_bar_bg := PackedSetAlphaI(UI_FG, 24);
    color_scroll := PackedSetAlphaI(UI_FG, 128);
    color_scroll_active := PackedSetAlphaI(UI_FG, 220);

    Layer(.{layout.padding = PaddingAll(Px(0))}); // @todo Add something that allows the user to disable Layers for a while?
    default_spec := BoxSpec.{layout = .{size.pref = Grow2()}};

    // Prepare a bunch of boxes with correct hierarchy.
    container_x := CreateBox(.{layout.child_order = .TOP_TO_BOTTOM}, default_spec);

    Parent(container_x);
    container_y := CreateBox(.{layout.child_order = .LEFT_TO_RIGHT}, default_spec);

    scroll_area_x: *Box;
    {
      container_scroll_area_x := CreateBox(.{layout.size.min = Fit2(),
                                             layout.size.pref.x = Grow()});
      Parent(container_scroll_area_x);
      scroll_area_x = CreateBox(.{track_signal = .WITHOUT_ACTIVATION});

      resize_button = CreateBox(.{layout.size.min = Len2(Rem(0.5)),
                                  layout.padding = PaddingAll(Rem(0.125)),
                                  bg_color = color_bar_bg,
                                  track_signal = .ALL});

      decoration_color := ifx resize_button.signal & .HOVER then color_scroll_active else color_scroll;

      Parent(resize_button);
      Parent(CreateBox(.{layout.size.min = Len2(Rem(0.25)),
                         layout.padding = PaddingAll(Rem(0.125)),
                         border.color = decoration_color,
                         border.widths = .{right = Rem(0.0625), bottom = Rem(0.0625)}}));
      Parent(CreateBox(.{layout.size.min = Len2(Rem(0.125)),
                         layout.padding = PaddingAll(Rem(0.0625)),
                         border.color = decoration_color,
                         border.widths = .{right = Rem(0.0625), bottom = Rem(0.0625)}}));
    }

    Parent(container_y);
    scrollable = CreateBox(.{layout = .{size.pref = Grow2(), child_order = .TOP_TO_BOTTOM},
                             track_signal = .WITHOUT_ACTIVATION,
                             scroll.enable = .SCROLL_X | .SCROLL_Y});
    scroll_area_y := CreateBox(.{track_signal = .WITHOUT_ACTIVATION});

    for axis: Axis2.X .. Axis2.Y
    {
      other_axis := (!axis).(Axis2);
      scroll_area := ifx axis == .X then scroll_area_x else scroll_area_y;

      scroll_area.bg_color = color_bar_bg;
      scroll_area.layout.child_order = ifx axis == .X then .LEFT_TO_RIGHT else .TOP_TO_BOTTOM;
      scroll_area.layout.size.pref.axes[axis] = Grow();
      scroll_area.layout.size.min.axes[other_axis] = BAR_THICKNESS;
      Parent(scroll_area);

      bar_size_pct := scrollable.scroll_children_ratio.component[axis];
      if bar_size_pct > 1.0 then bar_size_pct = clamp(bar_size_pct*0.1, 0.2, 0.8);

      box_margin0 := CreateBox(.{layout.size.pref = Grow2()});
      box_bar := CreateBox(.{bg_color = color_scroll, track_signal = .ALL});
      box_margin1 := CreateBox(.{layout.size.pref = Grow2()});
      box_bar.layout.size.pref.axes[axis] = Pct(bar_size_pct);
      box_bar.layout.size.pref.axes[other_axis] = Grow();

      // @feature(box_layout) a way to check "is this or its children hovered"
      is_scroll_area_hovered := scroll_area.signal & .HOVER || box_bar.signal & .HOVER;
      if is_scroll_area_hovered || (scrollable.signal & .HOVER_ON_SCROLL_CHILD && axis == .Y)
      {
        scrollable.scroll.delta_px.component[axis] -= G.mouse_scroll.y * 128.0;
      }

      if bar_size_pct < 1.0
      {
        if box_bar.signal & .HOVER
        {
          box_bar.bg_color = color_scroll_active;
        }
        if box_bar.signal & .DRAG
        {
          scrollable_size_px := Inner(scroll_area, axis) - Inner(box_bar, axis);
          if scrollable_size_px > 0.0
          {
            scrollable_position_px := (G.mouse - scroll_area.abs_p - layout_state.drag_box_abs_p_offset).component[axis];
            scrollable_position_01 := clamp(scrollable_position_px / scrollable_size_px, 0.0, 1.0);
            scrollable.scroll.set_pct.component[axis] = scrollable_position_01;
          }
        }

        box_margin0.layout.size.pref.axes[axis] = Pct(scrollable.scroll_pct.component[axis] * (1.0 - bar_size_pct));
      }
      else box_bar.bg_color = 0;
    }
  }
  Parent(scrollable);

  // Content box
  content := CreateBox(.{is_persistent = true,
                         layout = .{child_order = .TOP_TO_BOTTOM,
                                    size.min = Fit2(), size.pref = Grow2(),
                                    padding = UI_WINDOW_PAD},
                         corner_radius = UI_RADIUS});

  // Resize button signal
  if (resize_button.signal & .DRAG) dev_window.size += G.mouse_delta;
  clamped_window_size := clamp(dev_window.size, .{200, 100}, G.window_dim);
  if !(resize_button.signal & .DRAG) dev_window.size = clamped_window_size;
  window.layout.size.min = Px2(clamped_window_size);

  return content, window;
}


// UI element library
UI_ToggleButton :: (label: string, value: *bool)
{
  Layer(.{seed = Hash64Any(label, value.(u64))});

  button := CreateText(label, .{layout.padding = UI_BUTTON_PAD,
                                border = .{color = UI_BUTTON_HOVER_BG, widths = BorderOutside(Px(1))},
                                track_signal = .ALL});
  if button.signal & .HOVER
  {
    button.border.color = UI_FG3;
  }
  if value
  {
    if button.signal & .CLICK then value.* = !value.*;

    button.bg_color = ifx value.* then UI_BG2 else UI_BG;
    button.text.color = ifx value.* then UI_FG0 else UI_FG3;
  }
}

UI_Checkbox :: (label: string, checkbox_value: *$T, set_flags: T)
#modify { return IsEnumFlags(T); }
{
  Layer(.{seed = Hash64Any(label, checkbox_value.(u64))});

  button := CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                   padding = UI_BUTTON_PAD,
                                   child_align.y = .CENTER,
                                   child_gap = UI_WINDOW_GAP},
                        track_signal = .ALL});
  Parent(button);

  if button.signal & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  square_text := "";
  if checkbox_value
  {
    is_active := (checkbox_value.* & set_flags) == set_flags;
    if button.signal & .CLICK
    {
      if is_active checkbox_value.* &= ~set_flags;
      else         checkbox_value.* |= set_flags;
    }
    if is_active square_text = "X";
  }
  else square_text = "/";

  {
    square_length := Rem(1.5);
    Parent(CreateBox(.{layout = .{size.min = Len2(square_length),
                                  child_align = .{x = .CENTER, y = .CENTER}},
                       bg_color = UI_BUTTON_BG,
                       border = .{color = UI_FG, widths = UI_BORDER_WIDTH},
                       corner_radius = UI_RADIUS,
                       edge_softness = UI_EDGE_SOFTNESS},));
    CreateText(square_text, .{text.font_size = square_length});
  }
  CreateText(label);
}

UI_Checkbox :: (label: string, checkbox_value: *bool)
{
  Layer(.{seed = Hash64Any(label, checkbox_value.(u64))});

  button := CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                   padding = UI_BUTTON_PAD,
                                   child_align.y = .CENTER,
                                   child_gap = UI_WINDOW_GAP},
                        track_signal = .ALL});
  Parent(button);

  if button.signal & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  square_text := "";
  if checkbox_value
  {
    if button.signal & .CLICK then checkbox_value.* = !checkbox_value.*;
    square_text = ifx checkbox_value.* then "X" else "";
  }
  else square_text = "/";

  {
    square_length := Rem(1.5);
    Parent(CreateBox(.{layout = .{size.min = Len2(square_length),
                                  child_align = .{x = .CENTER, y = .CENTER}},
                       bg_color = UI_BUTTON_BG,
                       border = .{color = UI_FG, widths = UI_BORDER_WIDTH},
                       corner_radius = UI_RADIUS},));
    CreateText(square_text, .{text.font_size = square_length});
  }
  CreateText(label);
}

UI_ButtonRadio :: (label: string, button_value: *$T, set_value: T)
{
  Layer(.{seed = Hash64Any(label, button_value.(u64), set_value)});

  button := CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                   padding = UI_BUTTON_PAD,
                                   child_align.x = .RIGHT,
                                   child_align.y = .CENTER,
                                   child_gap = UI_WINDOW_GAP},
                        track_signal = .ALL});
  Parent(button);

  button.bg_color = UI_BUTTON_BG;
  if button.signal & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  label_box := CreateText(label);

  if button_value
  {
    if button.signal & .CLICK then button_value.* = set_value;
    if button_value.* == set_value
    {
      button.bg_color = UI_FG;
      label_box.text.color = UI_BG;
    }
  }
  else label_box.text.color = UI_RED2;
}

UI_Button :: (label: string, dont_grow := false) -> clicked: bool, signal: SignalFlags
{
  Layer(.{seed = Hash64Any(label)});

  button := CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                   padding = UI_BUTTON_PAD,
                                   child_align.x = .RIGHT,
                                   child_align.y = .CENTER,
                                   child_gap = UI_WINDOW_GAP},
                        track_signal = .ALL});
  if (dont_grow) button.layout.size.pref.x = .{};
  Parent(button);

  button.bg_color = UI_BUTTON_BG;
  if button.signal & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  label_box := CreateText(label);
  return !!(button.signal & .CLICK), button.signal;
}

UI_ScrollableContainer :: (scroll_x: *float, scroll_y: *float, spec := BoxSpec.{}) -> *Box
{
  Layer(.{seed = Hash64Any(scroll_x.(u64), scroll_y.(u64))});

  BAR_THICKNESS :: #run Rem(0.75);
  color_bar_bg := PackedSetAlphaI(UI_FG, 24);
  color_scroll := PackedSetAlphaI(UI_FG, 128);
  color_scroll_active := PackedSetAlphaI(UI_FG, 220);

  Layer(.{layout.padding = PaddingAll(Px(0))}); // @todo Add something that allows the user to disable Layers for a while?
  default_spec := BoxSpec.{layout = .{size.pref = Grow2()}};

  // Prepare a bunch of boxes with correct hierarchy.
  container_x := CreateBox(spec, .{layout.child_order = .TOP_TO_BOTTOM}, default_spec);

  Parent(container_x);
  container_y := CreateBox(spec, .{layout.child_order = .LEFT_TO_RIGHT}, default_spec);
  scroll_area_x := CreateBox(.{track_signal = .WITHOUT_ACTIVATION});

  Parent(container_y);
  body := CreateBox(.{track_signal = .WITHOUT_ACTIVATION});
  scroll_area_y := CreateBox(.{track_signal = .WITHOUT_ACTIVATION});

  body.layout = .{size.pref = Grow2(), child_order = .TOP_TO_BOTTOM};
  if scroll_x then body.scroll.enable |= .SCROLL_X;
  if scroll_y then body.scroll.enable |= .SCROLL_Y;

  for axis: Axis2.X .. Axis2.Y
  {
    other_axis := (!axis).(Axis2);
    scroll      := ifx axis == .X then scroll_x else scroll_y;
    scroll_area := ifx axis == .X then scroll_area_x else scroll_area_y;
    if !scroll continue;

    scroll_area.bg_color = color_bar_bg;
    scroll_area.layout.child_order = ifx axis == .X then .LEFT_TO_RIGHT else .TOP_TO_BOTTOM;
    scroll_area.layout.size.pref.axes[axis] = Grow();
    scroll_area.layout.size.min.axes[other_axis] = BAR_THICKNESS;
    Parent(scroll_area);

    bar_size_pct := 0.0;
    children_outer_sum := SumOutersOfChildren(body, axis);
    if children_outer_sum > 0.0
    {
      bar_size_pct = Inner(body, axis) / children_outer_sum;
      if bar_size_pct < 1.0 then bar_size_pct = clamp(bar_size_pct, 0.2, 0.8);
    }

    box_margin0 := CreateBox(.{layout.size.pref = Grow2()});
    box_bar := CreateBox(.{bg_color = color_scroll, track_signal = .ALL});
    box_margin1 := CreateBox(.{layout.size.pref = Grow2()});
    box_bar.layout.size.pref.axes[axis] = Pct(bar_size_pct);
    box_bar.layout.size.pref.axes[other_axis] = Grow();

    // @feature(box_layout) a way to check "is this or its children hovered"
    is_scroll_area_hovered := scroll_area.signal & .HOVER || box_bar.signal & .HOVER;
    if is_scroll_area_hovered || (body.signal & .HOVER_ON_SCROLL_CHILD && axis == .Y)
    {
      scroll_by := G.mouse_scroll.y * 0.05;
      scroll.* = clamp(scroll.* + scroll_by, 0.0, 1.0);
    }

    if bar_size_pct < 1.0
    {
      if box_bar.signal & .HOVER
      {
        box_bar.bg_color = color_scroll_active;
      }
      if box_bar.signal & .DRAG
      {
        scrollable_size_px := Inner(scroll_area, axis) - Inner(box_bar, axis);
        if scrollable_size_px > 0.0
        {
          scrollable_position_px := (G.mouse - scroll_area.abs_p - layout_state.drag_box_abs_p_offset).component[axis];
          scrollable_position_01 := clamp(scrollable_position_px / scrollable_size_px, 0.0, 1.0);
          body.scroll.set_pct.component[axis] = scrollable_position_01;
        }
      }

      box_margin0.layout.size.pref.axes[axis] = Pct(body.scroll_pct.component[axis] * (1.0 - bar_size_pct));
    }
    else
    {
      scroll_area.bg_color = 0;
      box_bar.bg_color = 0;
    }
  }

  return body;
}
