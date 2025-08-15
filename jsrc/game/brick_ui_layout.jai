/* @todo
- implementing floating,
- implement mouse-box interactions like dragging, detect direct hover,
- too much space is removed from GROW/FIT if there isn't enough space (example: UI_Button)
*/

#module_parameters(
  Color: Type = u32,
  V2: Type = Vector2,
  LayoutHash := DefaultHash,
  MAX_NESTING := 512)
{
  Hash :: #import "Hash";
  DefaultHash :: (byte_arrays: ..[] u8) -> u64
  {
    h := Hash.FNV_64_OFFSET_BIAS;
    for byte_arrays
    {
      h = Hash.fnv1a_hash(it.data, it.count, h);
    }
    return h;
  }
}

//
// BoxSpec's structs and enums
//
Bool3 :: enum u8 { DEFAULT; FALSE; TRUE; };
Axis2 :: enum u8 { X; Y; COUNT; };
LayoutDirection :: enum { DEFAULT; LEFT_TO_RIGHT; TOP_TO_BOTTOM; };
AxisMatchesLayoutDirection :: inline (axis: Axis2, lay_dir: LayoutDirection) -> bool
{
  matches := false;
  matches |= axis == .X && (lay_dir == .DEFAULT || lay_dir == .LEFT_TO_RIGHT);
  matches |= axis == .Y && lay_dir == .TOP_TO_BOTTOM;
  return matches;
}

BorderWidths :: struct
{
  left, right, top, bottom: Length;
  between_children: Length;
};
BorderAll     :: (w: Length) -> BorderWidths { return .{w,w,w,w, w}; }
BorderOutside :: (w: Length) -> BorderWidths { return .{w,w,w,w, .{}}; }

Padding :: struct
{
  left, right, top, bottom: Length;
  #place left; axes: [2] struct {
    lower, upper: Length;
  };
};
PaddingAll :: (l: Length)                   -> Padding { return .{l, l, l, l}; }
PaddingV   :: (top_bottom: Length)          -> Padding { return .{.{}, .{}, top_bottom, top_bottom}; }
PaddingV   :: (top: Length, bottom: Length) -> Padding { return .{.{}, .{}, top, bottom}; }
PaddingH   :: (left_right: Length)          -> Padding { return .{left_right, left_right, .{}, .{}}; }
PaddingH   :: (left: Length, right: Length) -> Padding { return .{left, right, .{}, .{}}; }

CornerRadius :: struct
{
  top_left, top_right, bottom_left, bottom_right: Length;
};
RadiusAll :: (r: Length) -> CornerRadius { return .{r, r, r, r}; }

AttachPoint :: enum u8
{
  LEFT_TOP; LEFT_CENTER; LEFT_BOTTOM;
  CENTER_TOP; CENTER_CENTER; CENTER_BOTTOM;
  RIGHT_TOP; RIGHT_CENTER; RIGHT_BOTTOM;
};

Align :: enum u8
{
  DEFAULT :: 0;
  LEFT    :: 1;
  TOP     :: 1;
  CENTER  :: 2;
  RIGHT   :: 3;
  BOTTOM  :: 3;
};

Unit :: enum u32
{
  // Simple units
  PX;
  REM;
  EM;
  /*PT;?*/
  // Dynamic units
  TEXT; // Measure text
  FIT; // Fit children
  PCT; // Percentage of parent
  GROW;
};

RemToPx :: (scale := 1.0) -> float
{
  using layout_state;
  return scale * rem_to_px;
}

Length :: struct
{
  unit: Unit;
  value: float = -1.0;
};

Px  :: (v: float) -> Length { return .{.PX, v}; }
Em :: (v: float) -> Length { return .{.EM, v}; }
Rem :: (v: float) -> Length { return .{.REM, v}; }
operator * :: (length: Length, scale: float) -> Length #symmetric {
  return .{length.unit, length.value * scale};
}

LengthToPx :: (length: Length, owner_box: *Box, clamp_at_zero: bool) -> float
{
  using layout_state;
  value := length.value;
  if clamp_at_zero then value = max(value, 0.0);

  if length.unit == {
  case .PX;
  return value;

  case .EM;
    box := owner_box;
    while !IsNil(box)
    {
      if box.text.font_size.value > 0.0
      {
        // Defining font_size as EM recursively is not allowed for now!
        // EM on font_size will be interpreted as REM instead.
        if box.text.font_size.unit == .EM
          return value * rem_to_px;
        return LengthToPx(value * box.text.font_size, box, clamp_at_zero);
      }
      box = box.parent;
    }
    return value * rem_to_px; // fallback to REM

    case .REM;
    return value * rem_to_px;

    case;
    st := get_stack_trace_string(context.stack_trace,, temp);
    // log("[BRICK] Length with dynamic unit is not supported here. %", st);
    return min(value, 0.0);
  }
  return value;
}

Length2 :: struct
{
  x, y: Length;
  #place x; axes: [2] Length;
}
Px  :: (v: V2) -> Length2 { return .{Px(v.x), Px(v.y)}; }
Rem :: (v: V2) -> Length2 { return .{Rem(v.x), Rem(v.y)}; }

LengthToPx :: (len2: Length2, owner_box: *Box, clamp_to_zero: bool) -> V2
{
  return .{LenghtToPx(len2.x, owner_box, clamp_to_zero),
           LengthToPx(len2.y, owner_box, clamp_to_zero)};
}

Fit :: () -> Length    { return .{.FIT, 1.0}; }
Fit2 :: () -> Length2  { return .{.{.FIT, 1.0}, .{.FIT, 1.0}}; }
Grow :: () -> Length   { return .{.GROW, 1.0}; }
Grow2 :: () -> Length2 { return .{.{.GROW, 1.0}, .{.GROW, 1.0}}; }
Pct :: (value01: float) -> Length { return .{.PCT, value01}; }
Pct2 :: (value01: float) -> Length2 { return .{.{.PCT, value01}, .{.PCT, value01}}; }

BoxKey :: struct
{
  hash: u64;
};
operator == :: (a: BoxKey, b: BoxKey) -> bool { return a.hash == b.hash; }
operator ! :: (a: BoxKey) -> bool { return !a.hash; }

CreateKey :: (loc: Source_Code_Location, seed: u64 = 0) -> BoxKey
{
  h := HashLocFunc(loc, seed);
  key := BoxKey.{hash};
  return key;
}

CreateKey :: (text: string, seed: u64 = 0) -> BoxKey
{
  h := HashStringFunc(text, seed);
  return BoxKey.{h};
}

BoxSpec :: struct
{
  key: BoxKey;
  autokey_seed: u64;

  layout: struct
  {
    dim: Length2;
    dim_min: Length2;
    dim_max: Length2;

    padding: Padding;
    child_gap: Length;
    child_align: struct { x, y: Align; #place x; axes: [2] Align; }
    direction: LayoutDirection;

    #place dim; dimensions: [3] Length2;
  }

  bg_color: Color;
  corner_radius: CornerRadius;

  scroll: struct
  {
    enable: enum_flags u8 { SCROLL_X; SCROLL_Y; }
    set_01: V2 = .{-1, -1};
  }

  floating: struct
  {
    attach_to: enum
    {
      NONE; // disables floating
      PARENT;
      ELEMENT_WITH_ID;
      ROOT;
    }

    offset: Length2;
    // expand: [Axis2.COUNT] Size; do we need this?
    parent: BoxKey;
    z_index: s16;
    attach_points: struct { element: AttachPoint; parent: AttachPoint; }
    cursor_passthrough: bool;
  }

  border: struct
  {
    color: Color;
    widths: BorderWidths;
  }

  text: struct
  {
    str: string;
    color: Color;
    font: s32 = -1;
    font_size: Length; // EM on font size will be interpreted as REM!
  }
}

//
// BoxSpec Layer helpers
//
PushLayer :: (spec: BoxSpec)
{
  using layout_state;
  if layers_count < layers.count
    layers[layers_count] = spec;
  layers_count += 1;
}
PopLayer :: ()
{
  using layout_state;
  layers_count -= 1;
}
Layer :: (spec: BoxSpec) #expand
{
  PushLayer(spec);
  `defer PopLayer();
}
Layers :: (specs: ..BoxSpec) #expand
{
  for specs PushLayer(it);
  `defer for specs PopLayer();
}
ActiveLayers :: () -> [] BoxSpec
{
  using layout_state;
  result: [] BoxSpec;
  result.data = layers.data;
  result.count = layers_count;
  return result;
}

//
// Helpers for merging multiple BoxSpecs together
//
Merge :: (c: *$T, p: T)
#modify { return T.(*Type_Info).type == .ENUM; }
{
  if c.* == .DEFAULT then c.* = p;
}
Merge :: (c: *Length, p: Length) {
  if c.value < 0.0 then c.* = p;
}
Merge :: (c: *Length2, p: Length2) {
  if c.x.value < 0.0 then c.x = p.x;
  if c.y.value < 0.0 then c.y = p.y;
}
Merge :: (c: *s32, p: s32) {
  if c.* < 0 then c.* = p;
}
Merge :: (c: *float, p: float) {
  if c.* < 0.0 then c.* = p;
}
Merge :: (c: *u64, p: u64) {
  if c.* == 0 then c.* = p;
}
Merge :: (c: *Color, p: Color) {
  if c.* == 0 then c.* = p;
}
Merge :: (c: *Padding, p: Padding) {
  Merge(*c.left, p.left);
  Merge(*c.right, p.right);
  Merge(*c.top, p.top);
  Merge(*c.bottom, p.bottom);
}
Merge :: (c: *CornerRadius, p: CornerRadius) {
  Merge(*c.top_left,     p.top_left);
  Merge(*c.top_right,    p.top_right);
  Merge(*c.bottom_left,  p.bottom_left);
  Merge(*c.bottom_right, p.bottom_right);
}
Merge :: (c: *BorderWidths, p: BorderWidths) {
  Merge(*c.left,             p.left);
  Merge(*c.right,            p.right);
  Merge(*c.top,              p.top);
  Merge(*c.bottom,           p.bottom);
  Merge(*c.between_children, p.between_children);
}
Merge :: (c: *BoxSpec, p: BoxSpec) {
  Merge(*c.autokey_seed,         p.autokey_seed); // @todo hash 2 seeds together

  Merge(*c.layout.dim,           p.layout.dim);
  Merge(*c.layout.dim_min,       p.layout.dim_min);
  Merge(*c.layout.dim_max,       p.layout.dim_max);
  Merge(*c.layout.padding,       p.layout.padding);
  Merge(*c.layout.child_gap,     p.layout.child_gap);
  Merge(*c.layout.child_align.x, p.layout.child_align.x);
  Merge(*c.layout.child_align.y, p.layout.child_align.y);
  Merge(*c.layout.direction,     p.layout.direction);

  Merge(*c.bg_color,      p.bg_color);
  Merge(*c.corner_radius, p.corner_radius);

  // floating isn't merged - at least for now

  Merge(*c.border.color,  p.border.color);
  Merge(*c.border.widths, p.border.widths);

  Merge(*c.text.color,     p.text.color);
  Merge(*c.text.font,      p.text.font);
  Merge(*c.text.font_size, p.text.font_size);
}
Merge :: (child_spec: BoxSpec, parent_specs: ..BoxSpec, reverse_order := false) -> BoxSpec
{
  merged := child_spec;
  if reverse_order then for < parent_specs Merge(*merged, it);
  else                  for   parent_specs Merge(*merged, it);
  return merged;
}
MergeButTakeFirstAsBase :: (specs: ..BoxSpec) -> BoxSpec
{
  // First spec in specs array is "primary".
  // It will be taken by value and won't be subjected
  // to the rules of merge.
  spec: BoxSpec;
  for specs
  {
    if it_index == 0
      spec = it;
    else
      spec = Merge(spec, it);
  }
  return spec;
}

//
// Box struct and helpers
//
Box :: struct
{
  using spec: BoxSpec;
  next, prev, first, last, parent: *Box;
  loc: Source_Code_Location; // creation loc
  old: *Box; // Pointer to this Box from previous frame. Otherwise should point to nil_box.

  // in pixels
  inner: V2;
  inner_min: V2 = .{-1, -1};
  inner_max: V2 = .{-1, -1};

  padding: struct
  {
    left, right, top, bottom: float;
    #place left; axes: [2] struct {
      lower, upper: float;
    };
  };
  child_gap: float;

  rel_p: V2; // offset from outer dimensions of parent
  scroll_offset: V2;
  abs_p: V2; // offset from 0,0 of root box

  #place inner; inners: [3] V2;
};

//
// Helpers for accessing layout dimensions quickly.
// @todo delete some of these?
//
PaddingLower :: (box: *Box, axis: Axis2) -> float #expand #no_debug {
  return box.padding.axes[axis].lower;
}
PaddingUpper :: (box: *Box, axis: Axis2) -> float #expand #no_debug {
  return box.padding.axes[axis].upper;
}
PaddingDim :: (box: *Box, axis: Axis2) -> float #expand #no_debug {
  return box.padding.axes[axis].lower + box.padding.axes[axis].upper;
}
OuterDim :: (box: *Box, axis: Axis2) -> float #expand #no_debug {
  return box.inner.component[axis] +
         box.padding.axes[axis].lower +
         box.padding.axes[axis].upper;
}
InnerDim :: (box: *Box, axis: Axis2) -> float #expand #no_debug {
  return box.inner.component[axis];
}
InnerDimMin :: (box: *Box, axis: Axis2) -> float #expand #no_debug {
  return box.inner_min.component[axis];
}
InnerDimMax :: (box: *Box, axis: Axis2) -> float #expand #no_debug {
  return box.inner_max.component[axis];
}
OuterDim2 :: (box: *Box) -> V2 #expand #no_debug {
  return V2.{OuterDim(box, .X), OuterDim(box, .Y)};
}
InnerDim2 :: (box: *Box) -> V2 #expand #no_debug {
  return box.inner;
}

//
// Box functions
//
LinkToNil :: (box: *Box)
{
  using layout_state;
  box.next   = *nil_box;
  box.prev   = *nil_box;
  box.first  = *nil_box;
  box.last   = *nil_box;
  box.parent = *nil_box;
}
IsNil :: (box: *Box) -> bool { return !box || box == *layout_state.nil_box; }

FindBox :: (key: BoxKey, target := BoxStorageArray.CURRENT) -> *Box
{
  // @speed accelerate using hash table or something
  result := *layout_state.nil_box;
  array := BoxesArray(target);
  for * array.*
  {
    if it.key == key
    {
      result = it;
      break;
    }
  }
  return result;
}

CreateBoxDirect :: (source_spec: BoxSpec, loc := #caller_location) -> *Box
{
  spec := source_spec;
  if !spec.key
  {
    // spec.key = CreateKey(loc, spec.autokey_seed);
    stack_trace_string := get_stack_trace_string(context.stack_trace,, temp);
    spec.key = CreateKey(stack_trace_string, spec.autokey_seed);
  }
  if spec.text.str then spec.text.str = copy_temporary_string(spec.text.str); // @todo This should live in some double-buffered array in layout_state

  // check for collision
  {
    check := FindBox(spec.key);
    if !IsNil(check)
    {
      log_error("brick_ui_layout - Found BoxKey collision when creating a new box. Collided on key: %. Tried to create a box from: %. Collided with box from: %.", spec.key, loc, check.loc);
    }
  }

  layout_state.boxes_count += 1;

  box := array_add(BoxesArray(.CURRENT));
  box.spec = spec;
  box.loc = loc;

  // links
  LinkToNil(box);
  box.parent = ActiveParent();
  if !IsNil(box.parent)
  {
    if IsNil(box.parent.first)
    {
      box.parent.first = box;
      box.parent.last = box;
    }
    else
    {
      box.prev = box.parent.last;
      box.parent.last.next = box;
      box.parent.last = box;
    }
  }

  // Find old (from previous frame) box
  box.old = FindBox(box.key, .OLD); // will be equal to nil_box if not found

  return box;
}

CreateBox :: (specs: ..BoxSpec, loc := #caller_location) -> *Box
{
  merged := MergeButTakeFirstAsBase(..specs);
  merged = Merge(merged, ..ActiveLayers(), reverse_order=true);
  return CreateBoxDirect(merged, loc);
}

CreateText :: (text: string, specs: ..BoxSpec, loc := #caller_location) -> *Box
{
  merged := MergeButTakeFirstAsBase(..specs);
  merged = Merge(merged, ..ActiveLayers(), reverse_order=true);

  merged.text.str = text;
  merged.autokey_seed = HashStringFunc(text, merged.autokey_seed);

  {
    if merged.text.font_size.value < 0.0 then merged.text.font_size = Rem(1);
    if merged.layout.dim_min.x.value < 0.0 then merged.layout.dim_min.x = .{.TEXT, 1.0};
    if merged.layout.dim_min.y.value < 0.0 then merged.layout.dim_min.y = .{.TEXT, 1.0};
  }

  return CreateBoxDirect(merged, loc);
}

//
// Box Parent helpers
//
PushParent :: (value: *Box)
{
  using layout_state;
  if parents_count < parents.count
    parents[parents_count] = value;
  parents_count += 1;
}
PopParent :: (value: *Box)
{
  using layout_state;
  parents_count -= 1;
}
Parent :: (box: *Box) -> *Box #expand
{
  PushParent(box);
  `defer PopParent(box);
  return box;
}
ActiveParent :: () -> *Box
{
  using layout_state;
  if parents_count > 0 && parents_count <= parents.count
    return parents[parents_count-1];
  return *nil_box;
}

//
// BoxSignal
//
BoxSignal :: struct
{
  using #as box: *Box;
  flags: Flags;

  Flags :: enum_flags u32
  {
    OVERLAPS; HOVER;
    CLICK; DOUBLE_CLICK; TRIPLE_CLICK;
    RIGHT_CLICK; RIGHT_DOUBLE_CLICK; RIGHT_TRIPLE_CLICK;
    DRAG;
  };
};

Signal :: (box: *Box) -> BoxSignal
{
  using layout_state;
  using ButtonType;
  // using ButtonFlags;
  // @todo See if things like 2 boxes catching the same click,
  //       floating boxes and their Z-order etc are a problem to be solved.

  signal := BoxSignal.{box = box};
  mouse_overlaps_box := false;

  // Test mouse overlap with box from previous frame + its parents.
  if !IsNil(box.old)
  {
    mouse_overlaps_box = true;
    tested := box.old;

    while true
    {
      tested_min := tested.abs_p;
      tested_max := tested_min + OuterDim2(tested);

      mouse_overlaps_box &&= (mouse.x >= tested_min.x && mouse.x < tested_max.x &&
                              mouse.y >= tested_min.y && mouse.y < tested_max.y);

      // Advance to parent if tested wasn't floating
      if tested.floating.attach_to then break;
      tested = tested.parent;
      if IsNil(tested) break;
    }
  }

  if mouse_overlaps_box
  {
    signal.flags |= .OVERLAPS;
    signal.flags |= .HOVER;
    if buttons[MOUSE_LEFT]  & .PRESSED then signal.flags |= .CLICK;
    if buttons[MOUSE_RIGHT] & .PRESSED then signal.flags |= .RIGHT_CLICK;
  }

  return signal;
}

//
// Measure text callback
//
MeasureTextParams :: struct
{
  text: string;
  font: s32;
  font_size_px: float;
};
MeasureTextStub :: (params: MeasureTextParams) -> Vector2 { return .{}; }

//
// Output RenderCommand struct
//
RenderCommand :: struct
{
  type: enum u8 {RECTANGLE; BORDER; TEXT;};
  p: V2;
  dim: V2; // skipped for TEXT
  color: Color;

  corner_radius: float; // @todo [4] float
  border_width: float;
  // edge_softness: float; add?

  // .TEXT only
  text: string;
  font: s32;
  font_size_px: float;

  box: *Box;
};


//
// LayoutBegin initializes internal layout state according to LayoutSpec
//
ButtonType :: enum u32 { MOUSE_LEFT; MOUSE_MIDDLE; MOUSE_RIGHT; };
ButtonTypeCount :: #run enum_highest_value(ButtonType) + 1;
ButtonFlags :: enum_flags u8
{
  HELD;
  PRESSED; DOUBLE_PRESSED; TRIPLE_PRESSED;
  RELEASED;
};

LayoutLogFlags :: enum_flags {
  DEPTH;
  DIMENSIONS;
  SIZES;
  MINMAX;
  POSITIONS;
  LOCATION;

  NONE :: 0;
  ALL :: ~0;
};

LayoutSpec :: struct
{
  log_flags: LayoutLogFlags;

  root_dim_px: V2;
  rem_to_px: float;
  measure_text_callback := MeasureTextStub;

  // @todo A second pass on input is needed - best done in the future when keyboard support is added.
  // Or should keyboard support be left outside of layout library? Not sure.
  mouse: V2;
  are_buttons_down: [ButtonTypeCount] bool;
};

LayoutBegin :: (new_spec: LayoutSpec)
{
  using layout_state;

  // Update button states
  for was_down: are_buttons_down
  {
    is_down := new_spec.are_buttons_down[it_index];

    using ButtonFlags;
    buttons[it_index] =
      (ifx is_down              then HELD     else 0) |
      (ifx is_down && !was_down then PRESSED  else 0) |
      (ifx !is_down && was_down then RELEASED else 0);
  }

  // Assing new spec
  layout_spec = new_spec;

  // Boxes init
  boxes_count = 0;

  nil_box = .{};
  LinkToNil(*nil_box);

  current_boxes_index = xx !current_boxes_index;
  array_reset_keeping_memory(BoxesArray(.CURRENT));

  old_boxes := BoxesArray(.OLD);
  for * old_boxes.*
  {
    it.old = *nil_box;
  }

  array_reset_keeping_memory(*render_commands);

  parents_count = 0;
  layers_count = 0;

  root_box = CreateBox(.{layout.dim = Px(root_dim_px)});
  PushParent(root_box);
}

//
// Computes layout and generates render commands (@todo put render command generation in a separate or optional step?)
//
LayoutEnd :: ()
{
  using layout_state;

  // Validate that nil_box wasn't modified.
  // This wouldn't be needed if one could use read_only memory in jai for nil_box.
  {
    err := false;
    err |= nil_box.next   != *nil_box;
    err |= nil_box.prev   != *nil_box;
    err |= nil_box.first  != *nil_box;
    err |= nil_box.last   != *nil_box;
    err |= nil_box.parent != *nil_box;
    if err
    {
      log_error("[BRICK_UI_LAYOUT] error detected - nil_box was modified. Make sure you check with IsNil before modifying a box.");
      nil_box = .{};
      LinkToNil(*nil_box);
    }
  }

  ClampInnerDim :: (box: *Box, axis: Axis2)
  {
    dim := *box.inner.component[axis];
    inner_min := box.inner_min.component[axis];
    inner_max := box.inner_max.component[axis];
    if inner_min >= 0 then dim.* = max(dim.*, inner_min);
    if inner_max >= 0 then dim.* = min(dim.*, inner_max);
  }


  // - SIZING PASS 1 -
  // Steps:
  //   1. Calculate standalone sizes (px, rem, text).
  //   2. Calculate values for TEXT (measure text), PCT (percent of parent).
  //   3. Calculate padding.
  //   4. Calculate child gap.
  for :TreeBreadthFirst root_box
  {
    parent_inner := it.parent.inner;
    text_was_measured := false;
    text_dim: V2;

    for axis: Axis2.X .. Axis2.Y
    {
      for *layout_dim, layout_dim_index: it.layout.dimensions
      {
        length := layout_dim.axes[axis];
        inner := *it.inners[layout_dim_index].component[axis];

        // 1. Calculate standalone sizes (px, rem, text)
        clamp_to_zero := layout_dim_index == 0;
        inner.* = LengthToPx(length, it, clamp_to_zero);

        // 2. Calculate values for TEXT (measure text), PCT (percent of parent).
        if length.unit == .TEXT
        {
          if !text_was_measured
          {
            params := MeasureTextParams.{
              text = it.text.str,
              font = it.text.font,
              font_size_px = LengthToPx(it.text.font_size, it, true),
            };
            text_dim = measure_text_callback(params);
            text_was_measured = true;
          }

          inner.* = text_dim.component[axis];
        }
        if length.unit == .PCT
        {
          inner.* = parent_inner.component[axis] * length.value;
        }
      }
    }

    ClampInnerDim(it, .X);
    ClampInnerDim(it, .Y);

    // 3. Calculate padding.
    for axis: Axis2.X .. Axis2.Y
    {
      it.padding.axes[axis].lower = LengthToPx(it.layout.padding.axes[axis].lower, it, true);
      it.padding.axes[axis].upper = LengthToPx(it.layout.padding.axes[axis].upper, it, true);
    }

    // 4. Calculate child gap.
    it.child_gap = LengthToPx(it.layout.child_gap, it, true);
  }

  for axis: Axis2.X .. Axis2.Y
  {
    // - SIZING PASS 2 -
    // Steps:
    //   1. Calculate sizes dependent on children (fit).
    for :TreeDepthFirst root_box
    {
      has_length_with_fit_unit := false;
      for it.layout.dimensions
        has_length_with_fit_unit |= it.axes[axis].unit == .FIT;

      // 1. Calculate size from children (fit).
      if has_length_with_fit_unit
      {
        children_outer_sum: float;
        if AxisMatchesLayoutDirection(axis, it.layout.direction)
        {
          for :Siblings child, child_index: it.first
          {
            if child_index > 0 then children_outer_sum += it.child_gap;
            children_outer_sum += OuterDim(child, axis);
          }
        }
        else
        {
          for :Siblings child: it.first
            children_outer_sum = max(children_outer_sum, OuterDim(child, axis));
        }

        for layout_dim, layout_dim_index: it.layout.dimensions
        {
          if layout_dim.axes[axis].unit == .FIT
            it.inners[layout_dim_index].component[axis] = children_outer_sum;
        }

        // Clamp inner using inner_min and inner_max.
        ClampInnerDim(it, axis);
      }
    }

    // - SIZING PASS 3 -
    // Steps:
    //   1. Solve overflow violations.
    //   2. Use free space from parent if grow == .TRUE.
    for :TreeBreadthFirst parent: root_box
    {
      is_scrolling_across_this_axis :=
        axis == .X && parent.scroll.enable & .SCROLL_X ||
        axis == .Y && parent.scroll.enable & .SCROLL_Y;
      if is_scrolling_across_this_axis continue;

      if AxisMatchesLayoutDirection(axis, parent.layout.direction)
      {
        mode: enum { NOT_SET; GROWING; SHRINKING; };
        prev_free_space := FLOAT32_MAX;

        while true // GROWING might need multiple iterations to be solved.
        {
          // Loop over children and sum things
          children_outer_sum := 0.0;
          children_grow_weight_sum := 0.0;
          children_shrinkable_sum := 0.0;
          for :Siblings child, child_index: parent.first
          {
            if child_index > 0 then children_outer_sum += parent.child_gap;
            children_outer_sum += OuterDim(child, axis);

            if child.layout.dim.axes[axis].unit == .GROW
            {
              can_grow := (InnerDimMax(child, axis) < 0.0 ||
                InnerDimMax(child, axis) > InnerDim(child, axis));

              if can_grow then children_grow_weight_sum += 1.0; // @todo use weight in the future.
            }

            shrinkable := InnerDim(child, axis) - max(0.0, InnerDimMin(child, axis));
            children_shrinkable_sum += shrinkable;
          }

          free_space := InnerDim(parent, axis) - children_outer_sum;

          // Assign mode on first iteration
          if !mode then mode = ifx free_space > 0.0 then .GROWING else .SHRINKING;

          // Prevent endless GROWING loops when no progress was made.
          if free_space >= prev_free_space break;
          prev_free_space = free_space;

          if mode == .GROWING
          {
            if free_space > 0.0 && children_grow_weight_sum > 0.0
            {
              grow_per_child := free_space / children_grow_weight_sum;

              for :Siblings child: parent.first
              {
                if child.layout.dim.axes[axis].unit == .GROW
                {
                  grow_amount := grow_per_child;
                  if InnerDimMax(child, axis) >= 0.0
                  {
                    space_left := InnerDimMax(child, axis) - InnerDim(child, axis);
                    grow_amount = min(grow_amount, space_left);
                  }
                  child.inner.component[axis] += grow_amount;
                }
              }

              continue; // continue while loop iteration
            }
          }
          else if mode == .SHRINKING
          {
            // Detect overflow. Shrink children.
            if free_space < 0.0 && children_shrinkable_sum > 0.0
            {
              shrink_ratio := children_shrinkable_sum / -free_space;
              shrink_ratio = min(shrink_ratio, 1.0); // If there isn't enough free space then allow boxes to overflow.

              for :Siblings child: parent.first
              {
                shrinkable := InnerDim(child, axis) - max(0.0, InnerDimMin(child, axis));
                to_shrink := shrinkable * shrink_ratio;
                child.inner.component[axis] -= to_shrink;
              }
            }
          }

          break; // break out of the whie loop
        }
      }
      else // Axis doesn't match layout
      {
        for :Siblings child: parent.first
        {
          free_space := InnerDim(parent, axis) - OuterDim(child, axis);

          // shrink child
          if free_space < 0.0
          {
            max_child_inner := InnerDim(parent, axis) - PaddingDim(child, axis);
            child.inner.component[axis] = PositiveMax(max_child_inner, InnerDimMin(child, axis));
          }

          // grow child
          if free_space > 0.0 && child.layout.dim.axes[axis].unit == .GROW
          {
            max_child_inner := InnerDim(parent, axis) - PaddingDim(child, axis);
            child.inner.component[axis] = PositiveMin(max_child_inner, InnerDimMax(child, axis));
          }
        }
      }
    }

    // - POSITION PASS 1 -
    // Compute relative positions.
    for :TreeBreadthFirst parent: root_box
    {
      align_shift_ratio := 0.0;
      if parent.layout.child_align.axes[axis] == {
        case .LEFT;  /*or TOP*/    align_shift_ratio = 0.0;
        case .CENTER;              align_shift_ratio = 0.5;
        case .RIGHT; /*or BOTTOM*/ align_shift_ratio = 1.0;
      };

      if AxisMatchesLayoutDirection(axis, parent.layout.direction)
      {
        // Set base relative positions
        {
          offset := PaddingLower(parent, axis);
          for :Siblings child, child_index: parent.first
          {
            if child_index > 0 then offset += parent.child_gap;
            child.rel_p.component[axis] = offset;
            offset += OuterDim(child, axis);
          }
        }

        // Add alignment if there is free space in parent
        if align_shift_ratio > 0.0
        {
          children_outer_sum := 0.0;
          for :Siblings child, child_index: parent.first
          {
            if child_index > 0 then children_outer_sum += parent.child_gap;
            children_outer_sum += OuterDim(child, axis);
          }
          free_space := InnerDim(parent, axis) - children_outer_sum;

          if free_space > 0.0
          {
            shift_by := free_space * align_shift_ratio;
            for :Siblings child: parent.first
              child.rel_p.component[axis] += shift_by;
          }
        }
      }
      else
      {
        // Clear relative positions
        for :Siblings child: parent.first
          child.rel_p.component[axis] = PaddingLower(parent, axis);

        // Add alignment if there is free space in parent
        if align_shift_ratio > 0.0
        {
          for :Siblings child: parent.first
          {
            free_space := InnerDim(parent, axis) - OuterDim(child, axis);
            if free_space > 0.0
            {
              shift_by := free_space * align_shift_ratio;
              child.rel_p.component[axis] += shift_by;
            }
          }
        }
      }

      // Compute scroll set_01
      if parent.scroll.set_01.component[axis] >= 0.0
      {
        children_outer_sum := 0.0;
        for :Siblings child: parent.first
          children_outer_sum += OuterDim(child, axis);

        parent_inner := InnerDim(parent, axis);
        px_offset := 0.0;

        if children_outer_sum > parent_inner
        {
          // Don't allow to scroll past the end of child; This could be modifed via spec in the future.
          children_outer_scrollable := children_outer_sum - parent_inner;
          px_offset = -children_outer_scrollable * parent.scroll.set_01.component[axis];
        }

        parent.scroll_offset.component[axis] = px_offset;
      }

      // Apply scroll offset to children
      for :Siblings child: parent.first
        child.rel_p.component[axis] += parent.scroll_offset.component[axis];
    }
  }

  // - POSITION PASS 2 -
  // Compute absolute positions.
  for :TreeBreadthFirst root_box
  {
    it.abs_p = it.parent.abs_p + it.rel_p;
  }

  // - DEBUG PRINT PASS -
  if log_flags
  {
    print("[TreeBreadthFirst] Debug dump of root_box\n");
    for :TreeBreadthFirst root_box
    {
      if log_flags & .DEPTH
      {
        for 0..it_depth-1 print("  ");
        print("[d %; i %]; ", it_depth, it_index);
      }
      if log_flags & .DIMENSIONS then print("dim%, dim_min%; dim_max%;\t", it.layout.dim, it.layout.dim_min, it.layout.dim_max);
      if log_flags & .SIZES      then print("inner% + padding% = outer%;\t", it.inner, it.padding, OuterDim2(it));
      if log_flags & .MINMAX     then print("inner_min%, inner_max%;\t", it.inner_min, it.inner_max);
      if log_flags & .POSITIONS  then print("rel_p %; abs_p %;\t", it.rel_p, it.abs_p);
      if log_flags & .LOCATION   then print("%", it.loc);
      print("\n");
    }
  }

  // - RENDER COMMANDS PASS -
  for :TreeBreadthFirst root_box.first
  {
    base_cmd: RenderCommand;
    base_cmd.p = it.abs_p;
    base_cmd.dim = OuterDim2(it);
    base_cmd.box = it;

    if it.bg_color
    {
      cmd := base_cmd;
      cmd.type = .RECTANGLE;
      cmd.color = it.bg_color;
      array_add(*render_commands, cmd);
    }

    if it.border.color
    {
      // cmd := base_cmd;
      // cmd.color = it.border.color;
      // cmd.type = .BORDER;
      // cmd.border_width = it.border.widths.left;
      // array_add(*render_commands, cmd);
    }

    if it.text.color
    {
      cmd := base_cmd;
      cmd.type = .TEXT;
      cmd.p += V2.{it.padding.left, it.padding.top + it.inner.y};
      cmd.color = it.text.color;
      cmd.text = it.text.str;
      cmd.font = it.text.font;
      cmd.font_size_px = LengthToPx(it.text.font_size, it, true);
      array_add(*render_commands, cmd);
    }
  }
}

//
// Box for_expansions
//
Siblings :: (first_box: *Box, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // Support for .REVERSE could be added.

  box := first_box;
  box_index := 0;

  while !IsNil(box)
  {
    `it := box;
    `it_index := box_index;
    box = box.next;
    box_index += 1;

    #insert body;
  }
}

TreeDepthFirst :: (root: *Box, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // Support for .REVERSE could be added but it shouldn't be needed.

  /* Example traversal order for a tree with 10 boxes.
        [10 (root)]
        /    |    \
       2     6     9
      /|    /|\    |\
     0 1   3 4 5   7 8
  */

  box := root;
  box_depth := 0;
  box_index := 0;

  coming_from_child_to_parent := false;
  while root_loop := true // Parent loop
  {
    siblings_and_children_not_found := false;
    while !siblings_and_children_not_found // Child/Sibling loop
    {
      if !coming_from_child_to_parent
      {
        // Descend depth-first to 'youngest' child
        while !IsNil(box.first)
        {
          box_depth += 1;
          box = box.first;
        }
      }

      `it := box;
      `it_depth := box_depth;
      `it_index := box_index;
      box_index += 1;

      defer {
        // Go to the next sibling or exit and go to parent
        coming_from_child_to_parent = false;
        if !IsNil(box.next) box = box.next;
        else siblings_and_children_not_found = true;
      };

      #insert(break=break root_loop) body;
    }

    // Ascend to parent or exit the tree traversal
    if !IsNil(box.parent) && box_depth > 0
    {
      coming_from_child_to_parent = true;
      box_depth -= 1;
      box = box.parent;
    }
    else break;
  }
}

TreeBreadthFirst :: (root: *Box, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // Support for .REVERSE could be added but it shouldn't be needed.

  /* Example traversal order for a tree with 10 boxes.
        [ 0 (root)]
        /    |    \
       1     4     8
      /|    /|\    |\
     2 3   5 6 7   9 10
  */

  box := root;
  box_depth := 0;
  box_index := 0;

  look_for_sibling := false;
  while root_loop := true // Parent loop
  {
    while true // Sibling/Child loop
    {
      if look_for_sibling
      {
        look_for_sibling = false; // Look for sibling only once until requested again
        // Go to the next sibling or exit loop
        if !IsNil(box.next) box = box.next;
        else break;
      }

      `it := box;
      `it_depth := box_depth;
      `it_index := box_index;
      box_index += 1;

      defer {
        // Go to the child or look_for_sibling
        if !IsNil(box.first)
        {
          box_depth += 1;
          box = box.first;
        }
        else look_for_sibling = true;
      };

      #insert(break=break root_loop) body;
    }

    // Ascend to parent or exit the tree traversal
    if !IsNil(box.parent) && box_depth > 0
    {
      look_for_sibling = true;
      box_depth -= 1;
      box = box.parent;
    }
    else break;
  }
}

//
// LayoutState - internal layout state
//
LayoutState :: struct
{
  using layout_spec: LayoutSpec;

  buttons: [ButtonTypeCount] ButtonFlags;

  boxes_count: s32;

  // Double-buffer system.
  // Each LayoutBegin call flips boxes_index between 0-1.
  // current_boxes_index points to boxes array used by current layout run.
  // Other boxes array points to boxes from the previous frame.
  current_boxes_index: u8;
  boxes: [2][..] Box; // @todo replace with HashTable

  nil_box: Box;
  root_box: *Box;

  render_commands: [..] RenderCommand;

  layers: [MAX_NESTING] BoxSpec;
  layers_count: s64;

  parents: [MAX_NESTING] *Box; // @todo make this dynamic? Or no?
  parents_count: s64;
};
layout_state: LayoutState; // @todo allow user to create a layout_state and to attach it to context instead of using a global variable

//
// Internal storage for Box. Uses double-buffer approach for keeping 1 "frame" old data around.
//
BoxStorageArray :: enum u8 {CURRENT; OLD;};
BoxesArray :: (which: BoxStorageArray) -> *[..] Box
{
  using layout_state;
  index := ifx which == .CURRENT then current_boxes_index else xx !current_boxes_index;
  res := *boxes[index];
  return res;
}

#scope_file;
#import "Basic"; // for array_add, clamp, log_error
#import "Math"; // Vector2, operator +

//
// Internal hash helpers
//
ObjectToByteArray :: (pointer: *$T) -> [] u8
{
  return []u8.{count = size_of(T), data = pointer.(*u8)};
}

HashStringFunc :: (s: string, init_seed: u64) -> u64
{
  seed := ObjectToByteArray(*init_seed);
  str := cast([] u8) s;
  return LayoutHash(seed, str);
}
HashLocFunc :: (loc: Source_Code_Location) -> u64
{
  filename := cast([] u8) loc.fully_pathed_filename;
  line_number := ObjectToByteArray(*loc.line_number);
  character_number := ObjectToByteArray(*loc.character_number);
  return LayoutHash(seed, filename, line_number, character_number);
}

//
// Internal math helpers
//
min :: (a: V2, b: V2) -> V2 { return V2.{min(a.x,b.x), min(a.y,b.y)}; }
max :: (a: V2, b: V2) -> V2 { return V2.{max(a.x,b.x), max(a.y,b.y)}; }

PositiveMin :: (a: float, b: float) -> float
{
  result := max(a,b);
  candidate := min(a,b);
  if candidate >= 0.0 then result = min(result, candidate);
  return result;
}
PositiveMax :: (a: float, b: float) -> float
{
  result := max(a,b);
  candidate := min(a,b);
  if candidate >= 0.0 then result = max(result, candidate);
  return result;
}
PositiveMin :: (a: V2, b: V2) -> V2 { return .{PositiveMin(a.x, b.x), PositiveMin(a.y, b.y)}; }
PositiveMax :: (a: V2, b: V2) -> V2 { return .{PositiveMax(a.x, b.x), PositiveMax(a.y, b.y)}; }
