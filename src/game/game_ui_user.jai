DEV_State :: struct // @todo serialize this struct to disk
{
  show := true;
  win_p: V2;

  category: enum {stats; switches; assets; network; sounds; objects; };

  selected_object: OBJ_Key;

  // switches
  show_stats: bool;
  noclip: bool;
  sun_camera: bool;
  show_colliders: bool;
  mouse_picking: enum_flags
  {
    ENABLED;
    ONE_PIXEL;
  } = .ENABLED;

  // objects
  show_joint_hierarchy := false;
}

UI_State :: struct
{
  payload: u64;
}

UI_RED1      :: #run Color32_RGBi(0xcc, 0x24, 0x1d);
UI_RED2      :: #run Color32_RGBi(0xfb, 0x49, 0x34);
UI_GREEN1    :: #run Color32_RGBi(0x98, 0x97, 0x1a);
UI_GREEN2    :: #run Color32_RGBi(0xb8, 0xbb, 0x26);
UI_YELLOW1   :: #run Color32_RGBi(0xd7, 0x99, 0x21);
UI_YELLOW2   :: #run Color32_RGBi(0xfa, 0xbd, 0x2f);
UI_BLUE1     :: #run Color32_RGBi(0x45, 0x85, 0x88);
UI_BLUE2     :: #run Color32_RGBi(0x83, 0xa5, 0x98);
UI_ORANGE1   :: #run Color32_RGBi(0xd6, 0x5d, 0x0e);
UI_ORANGE2   :: #run Color32_RGBi(0xfe, 0x80, 0x19);
UI_BG        :: #run Color32_RGBi(40, 40, 40);
UI_FG        :: #run Color32_RGBi(235, 219, 178);
UI_BORDER_BG :: #run Color32_RGBi(29, 32, 33);
UI_BUTTON_BG :: #run Color32_RGBi(80, 73, 69);
UI_BUTTON_HOVER_BG :: #run Color32_RGBi(102, 92, 84);
UI_SHADOW    :: #run Color32_RGBAi(29, 32, 33, 96);
UI_DARKER    :: #run Color32_RGBAi(0, 0, 0, 64);

UI_RADIUS :: #run RadiusAll(Px(3));
UI_BORDER_WIDTH :: #run BorderOutside(Px(1));
UI_WINDOW_GAP :: #run Rem(0.5);
UI_WINDOW_PAD :: #run PaddingAll(UI_WINDOW_GAP);
UI_BUTTON_PAD :: #run Padding.{UI_WINDOW_GAP, UI_WINDOW_GAP, UI_WINDOW_GAP*0.5, UI_WINDOW_GAP*0.5};

UI_HEADER_TEXT  :: #run BoxSpec.{text = .{font = xx FONT_Family.PlayfairDisplay, font_size = Rem(1.5)},
                                 layout.padding = PaddingV(Rem(0.2), Rem(0.6))};
UI_REGULAR_TEXT :: #run BoxSpec.{text = .{font = xx FONT_Family.PlayfairDisplay, font_size = Rem(1)}};
UI_MONO_TEXT    :: #run BoxSpec.{text = .{font = xx FONT_Family.Inconsolata, font_size = Rem(0.85)},
                                 layout.padding = PaddingV(Em(0.4))};

UI_DeveloperKeyShortcuts :: ()
{
  using G.dev;
  if (KEY_Pressed(.GRAVE)) then show = !show;
  if (KEY_Pressed(.RETURN)) then noclip = !noclip;
  if (KEY_Pressed(.BACKSPACE)) then sun_camera = !sun_camera;
}

UI_BuildDeveloperWindow :: ()
{
  using G.dev;
  if !show return;

  Layer(.{text.color = UI_FG});
  Layer(UI_REGULAR_TEXT);

  win_p = G.mouse;
  clamped_win_p := clamp(win_p, .{}, G.window_dim * 0.9);

  // Floating developer window
  Parent(CreateBox(.{layout = .{child_order = .TOP_TO_BOTTOM,
                                size.min = .{Rem(25), Rem(20)}},
                     bg_color = UI_BG,
                     floating = .{attach_to = .ROOT, offset = Px2(clamped_win_p)},
                     border = .{color = UI_SHADOW, widths = UI_BORDER_WIDTH},
                     corner_radius = UI_RADIUS}));

  // Window bar
  {
    window_bar := Signal(Parent(CreateBox(.{layout = .{size.pref.x = Grow(), size.min.y = Fit(),
                                                       padding = PaddingAll(Rem(0.4)),
                                                       child_align = .{x = .CENTER, y = .CENTER}},
                                            bg_color = UI_ORANGE2,
                                            corner_radius = UI_RADIUS})));
    if window_bar.flags & .DRAG  win_p += G.mouse_delta;
    else                         win_p = clamped_win_p;

    CreateText("Developer window", .{text.color = UI_BG});
  }

  // Content body
  {
    Parent(CreateBox(.{layout = .{size.min.x = Fit(), size.pref = Grow2()}}));
    category_names := enum_names(type_of(category));
    category_values := enum_values_as_enum(type_of(category));

    // Category vertical bar
    {
      Parent(CreateBox(.{layout = .{child_order = .TOP_TO_BOTTOM,
                                    size.min = Fit2(), size.pref.y = Grow(),
                                    padding = UI_WINDOW_PAD,
                                    child_gap = UI_WINDOW_GAP,
                                    child_align.x = .CENTER},
                         border = .{color = UI_BORDER_BG,
                                    widths = UI_BORDER_WIDTH}}));
      for category_names
      {
        UI_ButtonRadio(it, *category, category_values[it_index]);
      }
    }

    // Scrolling
    Parent(UI_ScrollableContainer(UniqueFloat(), UniqueFloat()));

    // Content box
    Parent(CreateBox(.{layout = .{child_order = .TOP_TO_BOTTOM,
                                  size.min = Fit2(), size.pref = Grow2(),
                                  padding = UI_WINDOW_PAD},
                       corner_radius = UI_RADIUS}));

    // Header
    CreateText(category_names[category], UI_HEADER_TEXT);

    // Per category body
    if #complete category == {
      case .stats;
      Layers(UI_MONO_TEXT);
      CreateText(tprint("dt: %ms; fps: %", Round(G.dt*1000), Round(1.0 / G.dt)));
      CreateText(tprint("Mouse: %", G.mouse));
      CreateText(tprint("World Camera: %", G.camera_p));
      CreateText(tprint("Camera - Player: %", G.camera_p - OBJ_Get(.NETWORK, G.client.player_key).s.p));
      CreateText(tprint("Camera angles: %", G.camera_angles));

      CreateText("more random data 1");
      CreateText("more random data 2");
      CreateText("more random data 3");
      CreateText("more random data 4");
      CreateText("more random data 5 that's very long; seriously long string");
      CreateText("more random data 6 and that's even longer, like this won't happen in nature!");


      {
        DisplayCounter :: (label: string, c: *STATS_Counter)
        {
          CreateText("");
          CreateText(label);
          stats := tprint("total: %; frame: %; peak: % (on %)",
            c.total, c.prev_frame, c.on_peak_frame, c.peak_frame_number);
          CreateText(stats);
        }

        using G.stats;

        #insert -> string {
          tis := type_info(STATS_State);
          sb: String_Builder;
          for tis.members
          {
            if it.type == type_info(STATS_Counter)
              print_to_builder(*sb, "DisplayCounter(\"%\", *%);\n", it.name, it.name);
          }
          result := builder_to_string(*sb);
          // log("Inserted code: ```%```", result);
          return result;
        }
      }

      case .switches;
      UI_Checkbox("Noclip camera", *noclip);
      UI_Checkbox("Sun camera", *sun_camera);
      UI_Checkbox("Show colliders", *show_colliders);
      UI_Checkbox("Enable mouse picking", *mouse_picking, .ENABLED);
      UI_Checkbox("Mouse picking - one pixel mode", *mouse_picking, .ONE_PIXEL);
      UI_Checkbox("Render normals", null);

      case .assets;
      Layers(UI_MONO_TEXT);
      CreateText("what got loaded from .pie file?");
      CreateText("hot-reload state");

      case .network;
      Layers(UI_MONO_TEXT);
      CreateText("network stuff here");

      case .sounds;
      Layers(UI_MONO_TEXT);
      // @todo Master volume slider
      CreateText("Active sounds:");
      for G.audio.actives
      {
        // @todo not related to dev_ui but add data driver way to tweak volume, pitch etc
        CreateText(tprint("%, %ms / %ms", it.type, ElapsedTimeMS(it.start_time), it.duration));
      }
      // @todo log recently finished sounds too

      case .objects;
      Layers(UI_MONO_TEXT);
      if KEY_Pressed(.T) selected_object = G.hover_object; // @todo improve
      CreateText(tprint("Seletected: %", selected_object));
      if UI_Button("reset selection") selected_object = .{};

      obj := OBJ_GetAny(selected_object);
      if OBJ_IsNil(obj) CreateText("obj is nil");

      CreateText(tprint("ModelKey: %", obj.s.model));

      model := GetModel(obj.s.model, silent = true);
      if !OBJ_IsNil(obj) && model.skeleton
      {
        anim: Animation;
        if IndexInBounds(model.skeleton.animations, obj.l.overwrite_animation_index)
        {
          anim = model.skeleton.animations[obj.l.overwrite_animation_index];
        }
        CreateText(tprint("overwrite animation: %/%", obj.l.overwrite_animation_index, model.skeleton.animations.count));
        CreateText(tprint("name: %, t range: {%, %}", anim.name, anim.t_min, anim.t_max));
        CreateText(tprint("obj_anim[0]: %", obj.l.animation_tracks[0]));

        horizontal_group := BoxSpec.{layout = .{size = .{min = Fit2(),
                                                         pref.x = Grow()},
                                                child_gap = Em(1)}};

        {
          Parent(CreateBox(horizontal_group));
          UI_ButtonRadio("Time", *obj.l.overwrite_animation_mode, .TIME);
          UI_ButtonRadio("Distance", *obj.l.overwrite_animation_mode, .DISTANCE);
          UI_ButtonRadio("Manual01", *obj.l.overwrite_animation_mode, .MANUAL01);
          UI_ButtonRadio("Manual", *obj.l.overwrite_animation_mode, .MANUAL);
        }

        if obj.l.overwrite_animation_mode == .MANUAL01 ||
           obj.l.overwrite_animation_mode == .MANUAL
        {
          Parent(CreateBox(horizontal_group));
          CreateText("Anim t");
          if UI_Button("reset")  obj.l.animation_tracks[0].t = 0.0;
          if UI_Button("-.5")    obj.l.animation_tracks[0].t -= 0.5;
          if UI_Button("-.05")   obj.l.animation_tracks[0].t -= 0.05;
          if UI_Button("-.01")   obj.l.animation_tracks[0].t -= 0.01;
          if UI_Button("+.01")   obj.l.animation_tracks[0].t += 0.01;
          if UI_Button("+.05")   obj.l.animation_tracks[0].t += 0.05;
          if UI_Button("+.5")    obj.l.animation_tracks[0].t += 0.5;
        }

        {
          Parent(CreateBox(horizontal_group));
          CreateText("Anim index");
          if UI_Button("reset")  obj.l.overwrite_animation_index = -1;
          if UI_Button("-10")    obj.l.overwrite_animation_index -= 10;
          if UI_Button("-1")     obj.l.overwrite_animation_index -= 1;
          if UI_Button("+1")     obj.l.overwrite_animation_index += 1;
          if UI_Button("+10")    obj.l.overwrite_animation_index += 10;
        }

        UI_Checkbox("Show joint hierarchy", *show_joint_hierarchy);
        if show_joint_hierarchy
        {
          CreateText("Joint hierarchy");
          Parent(UI_ScrollableContainer(null, UniqueFloat(), spec = .{layout.size.min.y = Rem(10)}));

          RecursivePrint :: (skeleton: Skeleton, index: u32, indent := 0.0, highlight := false)
          {
            sig := Signal(CreateText(skeleton.joint_names[index], .{layout.padding.left = Px(indent)}));
            if sig.flags & .HOVER then highlight = true;
            if highlight
            {
              sig.box.spec.text.color = Color32_RGBf(1,1,0);
            }

            for skeleton.child_index_ranges[index]
            {
              child_index := skeleton.child_index_buffer[it];
              RecursivePrint(skeleton, child_index, indent + 10.0, highlight);
            }
          }
          RecursivePrint(model.skeleton, 0);
        }
      }

    }
  }
}

// UI element library
UI_Checkbox :: (label: string, checkbox_value: *$T, set_flags: T)
#modify { return IsEnumFlags(T); }
{
  Layer(.{autokey_seed = Hash64Any(label, checkbox_value.(u64))});

  button := Signal(CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                          padding = UI_BUTTON_PAD,
                                          child_align.y = .CENTER,
                                          child_gap = UI_WINDOW_GAP}}));
  Parent(button);

  if button.flags & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  square_text := "";
  if checkbox_value
  {
    is_active := (checkbox_value.* & set_flags) == set_flags;
    if button.flags & .CLICK
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
                       corner_radius = UI_RADIUS},));
    CreateText(square_text, .{text.font_size = square_length});
  }
  CreateText(label);
}

UI_Checkbox :: (label: string, checkbox_value: *bool)
{
  Layer(.{autokey_seed = Hash64Any(label, checkbox_value.(u64))});

  button := Signal(CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                          padding = UI_BUTTON_PAD,
                                          child_align.y = .CENTER,
                                          child_gap = UI_WINDOW_GAP}}));
  Parent(button);

  if button.flags & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  square_text := "";
  if checkbox_value
  {
    if button.flags & .CLICK then checkbox_value.* = !checkbox_value.*;
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
  Layer(.{autokey_seed = Hash64Any(label, button_value.(u64), set_value)});

  button := Signal(CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                          padding = UI_BUTTON_PAD,
                                          child_align.x = .RIGHT,
                                          child_align.y = .CENTER,
                                          child_gap = UI_WINDOW_GAP}}));
  Parent(button);

  button.bg_color = UI_BUTTON_BG;
  if button.flags & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  label_box := CreateText(label);

  if button_value
  {
    if button.flags & .CLICK then button_value.* = set_value;
    if button_value.* == set_value
    {
      button.bg_color = UI_FG;
      label_box.text.color = UI_BG;
    }
  }
  else label_box.text.color = UI_RED2;
}

UI_Button :: (label: string) -> clicked: bool
{
  Layer(.{autokey_seed = Hash64Any(label)});

  button := Signal(CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                          padding = UI_BUTTON_PAD,
                                          child_align.x = .RIGHT,
                                          child_align.y = .CENTER,
                                          child_gap = UI_WINDOW_GAP}}));
  Parent(button);

  button.bg_color = UI_BUTTON_BG;
  if button.flags & .HOVER then button.bg_color = UI_BUTTON_HOVER_BG;

  label_box := CreateText(label);
  return !!(button.flags & .CLICK);
}

UI_ScrollableContainer :: (scroll_x: *float, scroll_y: *float, spec := BoxSpec.{}) -> *Box
{
  BAR_THICKNESS :: #run Rem(0.75);
  color_bar_bg := Color32_SetAlphai(UI_FG, 24);
  color_scroll := Color32_SetAlphai(UI_FG, 128);
  color_scroll_active := Color32_SetAlphai(UI_FG, 220);

  TempParentScope();
  Layer(.{layout.padding = PaddingAll(Px(0))}); // @todo Add something that allows the user to disable Layers for a while?

  default_spec := BoxSpec.{layout = .{size.pref = Grow2()}};
  container_x: *Box;
  container_y: *Box;
  scroll_area_x: *Box;
  scroll_area_y: *Box;
  body: *Box;

  if scroll_x
  {
    container_x = CreateBox(spec, default_spec);
    container_x.layout.child_order = .TOP_TO_BOTTOM;
    PushParent(container_x);
  }

  if scroll_y
  {
    container_y = CreateBox(spec, default_spec);
    container_y.layout.child_order = .LEFT_TO_RIGHT;
  }

  if !scroll_y body = CreateBox();
  if scroll_x scroll_area_x = CreateBox();

  if scroll_y
  {
    PushParent(container_y);
    body = CreateBox();
    scroll_area_y = CreateBox();
  }

  body.layout = .{size.pref = Grow2(), child_order = .TOP_TO_BOTTOM};
  if scroll_x then body.scroll.enable |= .SCROLL_X;
  if scroll_y then body.scroll.enable |= .SCROLL_Y;

  scroll_wheel_was_consumed := false;

  for axis: Axis2.X .. Axis2.Y
  {
    other_axis := (!axis).(Axis2);
    scroll      := ifx axis == .X then scroll_x else scroll_y;
    container   := ifx axis == .X then container_x else container_y;
    scroll_area := ifx axis == .X then scroll_area_x else scroll_area_y;
    if !scroll continue;

    scroll_area_sig := Signal(scroll_area, .CANT_ACTIVATE);
    container_sig := Signal(container, .CANT_ACTIVATE);

    if !scroll_wheel_was_consumed && container_sig.flags & .HOVER
    {
      if scroll_area_sig.flags & .HOVER || axis == .Y
      {
        scroll_by := -G.mouse_scroll.y * 0.05;
        scroll.* = clamp(scroll.* + scroll_by, 0.0, 1.0);
      }
    }

    scroll_area.bg_color = color_bar_bg;
    scroll_area.layout.child_order = ifx axis == .X then .LEFT_TO_RIGHT else .TOP_TO_BOTTOM;
    scroll_area.layout.size.pref.axes[axis] = Grow();
    scroll_area.layout.size.min.axes[other_axis] = BAR_THICKNESS;
    Parent(scroll_area);

    bar_size_pct := 0.0;
    children_outer_sum := SumOutersOfChildren(body.old, axis);
    if children_outer_sum > 0.0
    {
      bar_size_pct = Inner(body.old, axis) / children_outer_sum;
      if bar_size_pct < 1.0 then bar_size_pct = clamp(bar_size_pct, 0.2, 0.8);
    }

    box_margin0 := CreateBox(.{layout.size.pref = Grow2()});
    box_bar := Signal(CreateBox(.{bg_color = color_scroll}));
    box_margin1 := CreateBox(.{layout.size.pref = Grow2()});
    box_bar.layout.size.pref.axes[axis] = Pct(bar_size_pct);
    box_bar.layout.size.pref.axes[other_axis] = Grow();

    if bar_size_pct < 1.0
    {
      if box_bar.flags & .HOVER
      {
        box_bar.bg_color = color_scroll_active;
      }
      if box_bar.flags & .DRAG
      {
        scrollable_size_px := Inner(scroll_area.old, axis) - Inner(box_bar.old, axis);
        if scrollable_size_px > 0.0
        {
          scrollable_position_px := (G.mouse - scroll_area.old.abs_p - layout_state.drag_box_abs_p_offset).component[axis];
          scrollable_position_01 := clamp(scrollable_position_px / scrollable_size_px, 0.0, 1.0);
          scroll.* = scrollable_position_01;
        }
      }

      box_margin0.layout.size.pref.axes[axis] = Pct((scroll.*) * (1.0 - bar_size_pct));
    }
    else
    {
      scroll_area.bg_color = 0;
      box_bar.bg_color = 0;
    }

    body.scroll.set_01.component[axis] = scroll.*;
  }
  return body;
}


BOX :: #import "treasure_box_layout"(Color=Color32);
#scope_file;
using BOX;
