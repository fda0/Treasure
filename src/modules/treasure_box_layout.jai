/* @todo
- replace box storage with something that has stable pointers
- cache text measurement
- implementing floating,
- implement mouse-box interactions like dragging, detect direct hover,
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
Axis2Flags :: enum_flags u8 { X; Y; };
Order :: enum { DEFAULT; LEFT_TO_RIGHT; TOP_TO_BOTTOM; };
AxisMatchesOrder :: inline (axis: Axis2, order: Order) -> bool
{
  matches := false;
  matches |= axis == .X && (order == .DEFAULT || order == .LEFT_TO_RIGHT);
  matches |= axis == .Y && order == .TOP_TO_BOTTOM;
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

Anchor :: struct
{
  horizontal: enum u8 { LEFT; CENTER; RIGHT; }
  vertical: enum u8 { TOP; CENTER; BOTTOM; }
  add_padding: enum_flags u8 { PAD_HORIZONTAL; PAD_VERTICAL; }
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

LengthToPx :: (length: Length, relative_to: *Box, axis: Axis2, clamp_at_zero: bool) -> float
{
  result := length.value;
  if clamp_at_zero then result = max(result, 0.0);

  if length.unit == {
    case .PX; return result;

    case .EM;
    if relative_to.text.font_size.value > 0.0 {
      return result * LengthToPx(relative_to.text.font_size, relative_to.parent, axis, clamp_at_zero);
    } else {
      return result * layout_state.rem_to_px;
    }

    case .REM; return result * layout_state.rem_to_px;

    case .PCT; return relative_to.inner.component[axis] * result; // @todo PCT can't really work in places like padding if parent is .FIT; remove PCT from here?

    case; return min(result, 0.0);
  }
}

Length2 :: struct
{
  x, y: Length;
  #place x; axes: [2] Length;
}

LengthToPx2 :: (len2: Length2, owner_box: *Box, clamp_to_zero: bool) -> V2
{
  return .{LengthToPx(len2.x, owner_box, .X, clamp_to_zero),
           LengthToPx(len2.y, owner_box, .Y, clamp_to_zero)};
}

Len2 :: (l: Length) -> Length2 { return .{l, l}; }
Px2  :: (a: float) -> Length2 { return .{Px(a), Px(a)}; }
Rem2 :: (a: float) -> Length2 { return .{Rem(a), Rem(a)}; }
Px2  :: (v: V2) -> Length2 { return .{Px(v.x), Px(v.y)}; }
Rem2 :: (v: V2) -> Length2 { return .{Rem(v.x), Rem(v.y)}; }

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
  return BoxKey.{h};
}

CreateKey :: (text: string, seed: u64 = 0) -> BoxKey
{
  h := HashStringFunc(text, seed);
  return BoxKey.{h};
}

BoxSpec :: struct
{
  key: BoxKey;
  seed: u64;

  layout: struct
  {
    size: struct
    {
      pref: Length2;
      min: Length2;
      max: Length2;
      #place pref; all: [3] Length2;
    }

    padding: Padding;
    child_gap: Length;
    child_align: struct { x, y: Align; #place x; axes: [2] Align; }
    child_order: Order;
  }

  bg_color: Color;
  corner_radius: CornerRadius;
  edge_softness: Length;
  capture_hover: bool;

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
      REFERENCE_BOX;
      ROOT;
    }
    reference: BoxKey;

    offset: Length2;
    anchors: struct { itself: Anchor; parent: Anchor; }
    z_index: s16;
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
  c.seed = HashTwoU64(c.seed, p.seed);

  Merge(*c.layout.size.pref,     p.layout.size.pref);
  Merge(*c.layout.size.min,      p.layout.size.min);
  Merge(*c.layout.size.max,      p.layout.size.max);
  Merge(*c.layout.padding,       p.layout.padding);
  Merge(*c.layout.child_gap,     p.layout.child_gap);
  Merge(*c.layout.child_align.x, p.layout.child_align.x);
  Merge(*c.layout.child_align.y, p.layout.child_align.y);
  Merge(*c.layout.child_order,     p.layout.child_order);

  Merge(*c.bg_color,      p.bg_color);
  Merge(*c.corner_radius, p.corner_radius);
  Merge(*c.edge_softness, p.edge_softness);

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

  key_would_collide: bool;

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

  clipped_min: V2;
  clipped_max: V2;

  #place inner; inners: [3] V2;
};

DimType :: enum u8
{
  FINAL :: 0;
  PREF :: 0;
  MIN;
  MAX;
}

//
// Helpers for accessing layout dimensions quickly.
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
Inner :: (box: *Box, axis: Axis2, dim_type := DimType.FINAL) -> float #expand #no_debug {
  return box.inners[dim_type].component[axis];
}
Outer :: (box: *Box, axis: Axis2, dim_type := DimType.FINAL) -> float #expand #no_debug {

  return Inner(box, axis, dim_type) +
         box.padding.axes[axis].lower +
         box.padding.axes[axis].upper;
}

PaddingLower2 :: (box: *Box) -> V2 #expand #no_debug {
  return .{box.padding.left, box.padding.top};
}
PaddingUpper2 :: (box: *Box) -> V2 #expand #no_debug {
  return .{box.padding.right, box.padding.bottom};
}
Outer2 :: (box: *Box, dim_type := DimType.FINAL) -> V2 #expand #no_debug {
  return V2.{Outer(box, .X, dim_type), Outer(box, .Y, dim_type)};
}
Inner2 :: (box: *Box, dim_type := DimType.FINAL) -> V2 #expand #no_debug {
  return box.inners[dim_type];
}

SumOutersOfChildren :: (parent: *Box, axis: Axis2) -> float
{
  result := 0.0;
  if AxisMatchesOrder(axis, parent.layout.child_order)
  {
    for :SiblingsNonFloating parent.first result += Outer(it, axis);
  }
  else
  {
    for :SiblingsNonFloating parent.first result = max(result, Outer(it, axis));
  }
  return result;
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
GetNilBox :: () -> *Box { return *layout_state.nil_box; }

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
  key_would_collide := false;
  if !spec.key
  {
    spec.key = CreateKey(loc, spec.seed);
    // stack_trace_string := get_stack_trace_string(context.stack_trace,, temp);
    // spec.key = CreateKey(stack_trace_string, spec.seed);

    entry, newly_added := Hash_Table.find_or_add(*layout_state.added_seeds, spec.key.hash);
    if newly_added
    {
      entry.* = 0;
    }
    else
    {
      entry.* += 1;
      spec.key.hash += entry.*;
      layout_state.hash_collisions += 1;
      key_would_collide = true;
    }
  }
  if spec.text.str then spec.text.str = copy_temporary_string(spec.text.str); // @todo This should live in some double-buffered array in layout_state

  // check for collision
  {
    check := FindBox(spec.key);
    if !IsNil(check)
    {
      log_error("[KINTSUGI] - Found BoxKey collision when creating a new box. Collided on key: %. Tried to create a box from: %. Collided with box from: %.", spec.key, loc, check.loc);
    }
  }

  layout_state.boxes_count += 1;

  box := array_add(BoxesArray(.CURRENT));
  box.spec = spec;
  box.loc = loc;
  box.key_would_collide = key_would_collide;

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
      box.prev.next = box;
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
  // merged.seed = HashStringFunc(text, merged.seed);

  // Text specific
  if merged.text.font_size.value < 0.0 then merged.text.font_size = Rem(1);
  merged.layout.size.min.x = .{.TEXT, 1.0};
  merged.layout.size.min.y = .{.TEXT, 1.0};

  return CreateBoxDirect(merged, loc);
}

//
// Box Parent helpers
//
PushParent :: (value: *Box)
{
  using layout_state;
  if parents_count < parents.count
  {
    parents[parents_count] = value;
  }
  parents_count += 1;
}
PopParent :: ()
{
  using layout_state;
  parents_count -= 1;
}
Parent :: (box: *Box) -> *Box #expand
{
  PushParent(box);
  `defer PopParent();
  return box;
}
ActiveParent :: () -> *Box
{
  using layout_state;
  if parents_count > 0 && parents_count <= parents.count
  {
    return parents[parents_count-1];
  }
  return *nil_box;
}
TempParentScope :: () #expand
{
  starting_parents_count := layout_state.parents_count;
  `defer {
    layout_state.parents_count = starting_parents_count;
  }
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

BoxSignalMask :: enum_flags u32
{
  CANT_ACTIVATE;
  NONE :: 0;
}

Signal :: (box: *Box, mask := BoxSignalMask.NONE) -> BoxSignal
{
  using layout_state;
  using ButtonType;
  // using ButtonFlags;
  // @todo See if things like 2 boxes catching the same click,
  //       floating boxes and their Z-order etc are a problem to be solved.

  signal := BoxSignal.{box = box};
  box.capture_hover = true;

  mouse_overlaps_box := (mouse.x >= box.old.clipped_min.x && mouse.x < box.old.clipped_max.x &&
                         mouse.y >= box.old.clipped_min.y && mouse.y < box.old.clipped_max.y);

  assign_active := false;

  if mouse_overlaps_box
  {
    signal.flags |= .OVERLAPS;
  }

  if !active_key && hover_key == box.key
  {
    signal.flags |= .HOVER;

    for buttons
    {
      if it & .PRESSED
      {
        if !(mask & .CANT_ACTIVATE) then active_key = box.key;
        drag_start_p = mouse;
        drag_box_abs_p_offset = mouse - box.old.abs_p;
        signal.flags |= xx (BoxSignal.Flags.CLICK.(u32) + it_index);
      }
    }
  }

  if active_key == box.key
  {
    signal.flags |= .HOVER;
    signal.flags |= .DRAG;
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
  type: enum u8 {RECTANGLE; BORDER; TEXT; CLIP; };
  p: V2;
  dim: V2; // skipped for TEXT
  clip_min: V2;
  clip_max: V2;
  color: Color;

  corner_radius: struct { top_left, top_right, bottom_left, bottom_right: float; }
  border_widths: struct { left, right, top, bottom: float; }
  edge_softness: float;

  // .TEXT only
  text: string;
  font: s32;
  font_size_px: float;

  creation_index: s32; // this was added because our sort isn't stable, could be fixed with a stable sort.
  z_index: s16;
  box: *Box;
};


//
// LayoutBegin initializes internal layout state according to LayoutSpec
//
ButtonType :: enum u8 { MOUSE_LEFT; MOUSE_MIDDLE; MOUSE_RIGHT; };
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
  KEY;
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

  if !!active_key
  {
    not_held := true;
    for buttons      not_held &&= !(it & .HELD);
    if not_held then active_key = .{};
  }

  Hash_Table.init(*added_seeds, boxes_count*2 + 1024); // @todo this just leaks memory atm? api of the table could be better here?
  hash_collisions = 0;

  // Assing new spec
  layout_spec = new_spec;

  // Boxes init
  boxes_count = 0;

  nil_box = .{};
  LinkToNil(*nil_box);

  current_boxes_index = xx !current_boxes_index;
  array_reset_keeping_memory(BoxesArray(.CURRENT));

  for *boxes
  {
    // This allocates a lot of memory because we don't handle realloc right now.
    // @todo replace these [..] arrays with stable pointer allocations.
    array_reserve(it, 1024 * 1024 * 1);
  }

  old_boxes := BoxesArray(.OLD);
  for * old_boxes.*
  {
    it.old = *nil_box;
  }

  array_reset_keeping_memory(*render_commands);

  parents_count = 0;
  layers_count = 0;

  root_box = CreateBox(.{layout.size = .{pref = Px2(root_dim_px),
                                         min  = Px2(root_dim_px),
                                         max  = Px2(root_dim_px)}});
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
      log_error("[KINTSUGI] error detected - nil_box was modified. Make sure you check with IsNil before modifying a box.");
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

  SolveNodeSizePass1 :: (node: *Box, axis: Axis2)
  {
    using layout_state;

    // - SIZING PASS 1 -
    //   1. Calculate standalone sizes (px, rem, text).
    //   2. Calculate values for TEXT (measure text), PCT (percent of parent).
    //   3. Calculate padding.
    parent_inner := node.parent.inner;
    text_was_measured := false;
    text_dim: V2;

    for *size, dim_type: node.layout.size.all
    {
      length := size.axes[axis];
      inner := *node.inners[dim_type].component[axis];

      // 1. Calculate standalone sizes (px, rem, text)
      clamp_to_zero := dim_type == xx DimType.PREF;
      inner.* = LengthToPx(length, node.parent, axis, clamp_to_zero);

      // 2. Calculate values for TEXT (measure text), PCT (percent of parent).
      if length.unit == .TEXT
      {
        if !text_was_measured
        {
          params := MeasureTextParams.{
            text = node.text.str,
            font = node.text.font,
            font_size_px = LengthToPx(node.text.font_size, node.parent, .Y, true),
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

    // 3. Calculate padding.
    node.padding.axes[axis].lower = LengthToPx(node.layout.padding.axes[axis].lower, node, axis, true);
    node.padding.axes[axis].upper = LengthToPx(node.layout.padding.axes[axis].upper, node, axis, true);
  }

  SolveNodeSizePass2 :: (node: *Box, axis: Axis2)
  {
    // - SIZING PASS 2 -
    // 1. Calculate sizes dependent on children (fit).

    for size, dim_type: node.layout.size.all
    {
      length := size.axes[axis];
      inner := *node.inners[dim_type].component[axis];

      if length.unit == .FIT
      {
        if AxisMatchesOrder(axis, node.layout.child_order)
        {
          children_outer_sum: float;
          for :SiblingsNonFloating child, child_index: node.first
          {
            if child_index > 0 then children_outer_sum += node.child_gap;
            outer := Outer(child, axis, xx dim_type);
            children_outer_sum += max(0.0, outer);
          }
          inner.* = children_outer_sum;
        }
        else
        {
          largest_child_outer := 0.0;
          for :SiblingsNonFloating child: node.first
          {
            largest_child_outer = max(largest_child_outer, Outer(child, axis, xx dim_type));
          }
          inner.* = largest_child_outer;
        }
      }
    }
  }

  FixChildrenSizes :: (parent: *Box, axis: Axis2)
  {
    // - SIZING PASS 3 -
    //   1. Fix percentages.
    //   2. Clamp inner dim.
    //   3. Solve overflow violations.
    //   4. Use free space from parent if grow == .TRUE.

    FREE_SPACE_EPSILON :: 0.1;

    for :Siblings child: parent.first
    {
      // 1. Fix percentages.
      if child.layout.size.pref.axes[axis].unit == .PCT
      {
        child.inner.component[axis] = parent.inner.component[axis] * child.layout.size.pref.axes[axis].value;
      }
      // 2. Clamp inner dim.
      ClampInnerDim(child, axis);
    }

    // Big pass: Grow into free space or shrink if overflowing
    is_scrolling_across_this_axis := (
      axis == .X && parent.scroll.enable & .SCROLL_X ||
      axis == .Y && parent.scroll.enable & .SCROLL_Y);
    if is_scrolling_across_this_axis return;

    if AxisMatchesOrder(axis, parent.layout.child_order)
    {
      mode: enum { NOT_SET; GROWING; SHRINKING; };
      prev_free_space := FLOAT32_MAX;

      while true // GROWING might need multiple iterations to be solved.
      {
        // Loop over children and sum things
        children_outer_sum := 0.0;
        children_grow_weight_sum := 0.0;
        children_shrinkable_sum := 0.0;
        for :SiblingsNonFloating child, child_index: parent.first
        {
          if child_index > 0 then children_outer_sum += parent.child_gap;
          children_outer_sum += Outer(child, axis, .FINAL);

          if child.layout.size.pref.axes[axis].unit == .GROW
          {
            can_grow := (Inner(child, axis, .MAX) < 0.0 ||
              Inner(child, axis, .MAX) > Inner(child, axis, .FINAL));

            if can_grow then children_grow_weight_sum += 1.0; // @todo use weight in the future.
          }

          shrinkable := Inner(child, axis, .FINAL) - max(0.0, Inner(child, axis, .MIN));
          children_shrinkable_sum += shrinkable;
        }

        free_space := Inner(parent, axis, .FINAL) - children_outer_sum;

        // Assign mode on first iteration
        if !mode then mode = ifx free_space > FREE_SPACE_EPSILON then .GROWING else .SHRINKING;

        // Prevent endless GROWING loops when no progress was made.
        if free_space >= prev_free_space break;
        prev_free_space = free_space;

        if mode == .GROWING
        {
          if free_space > FREE_SPACE_EPSILON && children_grow_weight_sum > FREE_SPACE_EPSILON
          {
            grow_per_child := free_space / children_grow_weight_sum;

            for :SiblingsNonFloating child: parent.first
            {
              if child.layout.size.pref.axes[axis].unit == .GROW
              {
                grow_amount := grow_per_child;
                if Inner(child, axis, .MAX) >= 0.0
                {
                  space_left := Inner(child, axis, .MAX) - Inner(child, axis, .FINAL);
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
          if free_space < -FREE_SPACE_EPSILON && children_shrinkable_sum > FREE_SPACE_EPSILON
          {
            shrink_ratio := children_shrinkable_sum / -free_space;
            shrink_ratio = min(shrink_ratio, 1.0); // If there isn't enough free space then allow boxes to overflow.

            for :SiblingsNonFloating child: parent.first
            {
              shrinkable := Inner(child, axis, .FINAL) - max(0.0, Inner(child, axis, .MIN));
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
      for :SiblingsNonFloating child: parent.first
      {
        free_space := Inner(parent, axis, .FINAL) - Outer(child, axis, .FINAL);

        // shrink child
        if free_space < -FREE_SPACE_EPSILON
        {
          max_child_inner := Inner(parent, axis, .FINAL) - PaddingDim(child, axis);
          child.inner.component[axis] = PositiveMax(max_child_inner, Inner(child, axis, .MIN));
        }

        // grow child
        if free_space > FREE_SPACE_EPSILON && child.layout.size.pref.axes[axis].unit == .GROW
        {
          max_child_inner := Inner(parent, axis, .FINAL) - PaddingDim(child, axis);
          child.inner.component[axis] = PositiveMin(max_child_inner, Inner(child, axis, .MAX));
        }
      }
    }
  }

  // Solve child_gaps
  for :TreeBreadthFirst root_box
  {
    axis: Axis2 = ifx it.layout.child_order == .TOP_TO_BOTTOM then .Y else .X;
    it.child_gap = LengthToPx(it.layout.child_gap, it, axis, true);
  }

  // Solve sizes
  for axis: Axis2.X .. Axis2.Y
  {
    for :TreeBreadthFirst        root_box SolveNodeSizePass1(it, axis);
    for :TreeDepthFirst root_box SolveNodeSizePass2(it, axis);

    ClampInnerDim(root_box, axis);
    for :TreeBreadthFirst        root_box FixChildrenSizes(it, axis);
  }

  // Solve non floating relative positions
  for axis: Axis2.X .. Axis2.Y
  {
    for :TreeBreadthFirst parent: root_box
    {
      align_shift_ratio := 0.0;
      if parent.layout.child_align.axes[axis] == {
        case .LEFT;  /*or TOP*/    align_shift_ratio = 0.0;
        case .CENTER;              align_shift_ratio = 0.5;
        case .RIGHT; /*or BOTTOM*/ align_shift_ratio = 1.0;
      };

      if AxisMatchesOrder(axis, parent.layout.child_order)
      {
        // Set base relative positions
        {
          offset := PaddingLower(parent, axis);
          for :SiblingsNonFloating child, child_index: parent.first
          {
            if child_index > 0 then offset += parent.child_gap;
            child.rel_p.component[axis] = offset;
            offset += Outer(child, axis, .FINAL);
          }
        }

        // Add alignment if there is free space in parent
        if align_shift_ratio > 0.0
        {
          children_outer_sum := 0.0;
          for :SiblingsNonFloating child, child_index: parent.first
          {
            if child_index > 0 then children_outer_sum += parent.child_gap;
            children_outer_sum += Outer(child, axis, .FINAL);
          }
          free_space := Inner(parent, axis, .FINAL) - children_outer_sum;

          if free_space > 0.0
          {
            shift_by := free_space * align_shift_ratio;
            for :SiblingsNonFloating child: parent.first
            {
              child.rel_p.component[axis] += shift_by;
            }
          }
        }
      }
      else
      {
        // Clear relative positions
        for :SiblingsNonFloating child: parent.first
        {
          child.rel_p.component[axis] = PaddingLower(parent, axis);
        }

        // Add alignment if there is free space in parent
        if align_shift_ratio > 0.0
        {
          for :SiblingsNonFloating child: parent.first
          {
            free_space := Inner(parent, axis, .FINAL) - Outer(child, axis, .FINAL);
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
        children_outer_sum := SumOutersOfChildren(parent, axis);
        parent_inner := Inner(parent, axis, .FINAL);
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
      for :SiblingsNonFloating child: parent.first
      {
        child.rel_p.component[axis] += parent.scroll_offset.component[axis];
      }
    }
  }

  // Solve absolute positions.
  for :TreeBreadthFirst root_box
  {
    if it.floating.attach_to
    {
      it.rel_p = .{};
      attach_box := GetNilBox();
      if it.floating.attach_to == {
        case .PARENT; attach_box = it.parent;
        case .REFERENCE_BOX; log("This floating type isn't supported property: %", it.floating.attach_to);
        case .ROOT; attach_box = root_box;
      }

      calculate_attach_offset :: (box: *Box, ap: Anchor) -> V2
      {
        full_h := ifx ap.add_padding & .PAD_HORIZONTAL then Inner(box, .X) else Outer(box, .X);
        full_v := ifx ap.add_padding & .PAD_VERTICAL   then Inner(box, .Y) else Outer(box, .Y);
        ratio_h := ap.horizontal.(float) * 0.5;
        ratio_v := ap.vertical.(float) * 0.5;
        result := V2.{full_h * ratio_h, full_v * ratio_v};
        if ap.add_padding & .PAD_HORIZONTAL then result.x += PaddingLower(box, .X);
        if ap.add_padding & .PAD_VERTICAL   then result.y += PaddingLower(box, .Y);
        return result;
      }

      it_offset := calculate_attach_offset(it, it.floating.anchors.itself);
      attach_box_offset := calculate_attach_offset(attach_box, it.floating.anchors.parent);
      user_offset := LengthToPx2(it.floating.offset, it, true);

      it.abs_p = attach_box.abs_p - it_offset + attach_box_offset + user_offset;
    }
    else // non floating
    {
      it.abs_p = it.parent.abs_p + it.rel_p;
    }
  }

  // Solve clip rectangles (userful for rendering and mouse intersection testing)
  for :TreeBreadthFirst root_box
  {
    it.clipped_min = it.abs_p;
    it.clipped_max = it.abs_p + Outer2(it);
    if !IsNil(it.parent) && !it.floating.attach_to
    {
      it.clipped_min = max(it.clipped_min, it.parent.clipped_min);
      it.clipped_max = min(it.clipped_max, it.parent.clipped_max);
    }
    // it.clipped_max = max(it.clipped_min, it.clipped_max);
  }

  // Reserve hover key on first hit
  hover_key = .{};
  for :TreeDepthFirst root_box
  {
    if it.capture_hover
    {
      if mouse.x >= it.clipped_min.x && mouse.x < it.clipped_max.x &&
         mouse.y >= it.clipped_min.y && mouse.y < it.clipped_max.y
      {
        hover_key = it.key;
        break;
      }
    }
  }

  // Debug logging.
  if log_flags
  {
    print("Breadth first traversal of box layout tree.\n");
    for :TreeBreadthFirst root_box
    {
      if log_flags & .DEPTH
      {
        for 0..it_depth-1 print("  ");
        print("[d %]; ", it_depth);
      }
      if log_flags & .DIMENSIONS then print("size%;\t", it.layout.size);
      if log_flags & .SIZES      then print("inner% + padding% = outer%;\t", it.inner, it.padding, Outer2(it));
      if log_flags & .MINMAX     then print("inner_min%, inner_max%;\t", it.inner_min, it.inner_max);
      if log_flags & .POSITIONS  then print("rel_p %; abs_p %;\t", it.rel_p, it.abs_p);
      if log_flags & .KEY
      {
        print("key%", it.key);
        if it.key_would_collide then print("(would_collide)");
      }
      if log_flags & .LOCATION   then print("%", it.loc);
      print("\n");
    }
  }


  // Generate render commands.
  {
    nil_box.clipped_min = .{};
    nil_box.clipped_max = .{FLOAT32_MAX, FLOAT32_MAX};

    for :TreeBreadthFirst root_box.first
    {
      base_cmd: RenderCommand;
      base_cmd.p = it.abs_p;
      base_cmd.dim = Outer2(it);
      base_cmd.clip_max = .{FLOAT32_MAX, FLOAT32_MAX};
      base_cmd.corner_radius.top_left     = LengthToPx(it.corner_radius.top_left,     it, .Y, true);
      base_cmd.corner_radius.top_right    = LengthToPx(it.corner_radius.top_right,    it, .Y, true);
      base_cmd.corner_radius.bottom_left  = LengthToPx(it.corner_radius.bottom_left,  it, .Y, true);
      base_cmd.corner_radius.bottom_right = LengthToPx(it.corner_radius.bottom_right, it, .Y, true);
      base_cmd.edge_softness = LengthToPx(it.edge_softness, it, .Y, true);
      base_cmd.z_index = it.floating.z_index;
      base_cmd.box = it;

      // apply clipping for scrolling
      if !it.floating.attach_to
      {
        parent := it.parent;
        while true
        {
          if IsNil(parent) break;
          if parent.scroll.enable & .SCROLL_X
          {
            base_cmd.clip_min.x = parent.clipped_min.x;
            base_cmd.clip_max.x = parent.clipped_max.x;
          }
          if parent.scroll.enable & .SCROLL_Y
          {
            base_cmd.clip_min.y = parent.clipped_min.y;
            base_cmd.clip_max.y = parent.clipped_max.y;
          }
          base_cmd.z_index += parent.floating.z_index;

          if parent.floating.attach_to break;
          parent = parent.parent;
        }
      }

      if it.bg_color
      {
        cmd := base_cmd;
        cmd.type = .RECTANGLE;
        cmd.color = it.bg_color;
        cmd.creation_index = xx render_commands.count;
        array_add(*render_commands, cmd);
      }

      if it.border.color
      {
        cmd := base_cmd;
        cmd.color = it.border.color;
        cmd.type = .BORDER;
        cmd.border_widths.left   = LengthToPx(it.border.widths.left,   it, .X, true);
        cmd.border_widths.right  = LengthToPx(it.border.widths.right,  it, .X, true);
        cmd.border_widths.top    = LengthToPx(it.border.widths.top,    it, .Y, true);
        cmd.border_widths.bottom = LengthToPx(it.border.widths.bottom, it, .Y, true);
        cmd.creation_index = xx render_commands.count;
        array_add(*render_commands, cmd);
      }

      if it.text.color
      {
        cmd := base_cmd;
        cmd.type = .TEXT;
        cmd.p += V2.{it.padding.left, it.padding.top + it.inner.y};
        cmd.clip_min = it.parent.clipped_min;
        cmd.clip_max = it.parent.clipped_max;
        cmd.color = it.text.color;
        cmd.text = it.text.str;
        cmd.font = it.text.font;
        cmd.font_size_px = LengthToPx(it.text.font_size, it.parent, .Y, true);
        cmd.creation_index = xx render_commands.count;
        array_add(*render_commands, cmd);
      }
    }

    // do sorting
    quick_sort(render_commands, (x: RenderCommand, y: RenderCommand) -> s32 {
      cmp: s32 = xx (x.z_index - y.z_index);
      if cmp == 0 then cmp = x.creation_index - y.creation_index;
      return cmp;
    });
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

SiblingsNonFloating :: (first_box: *Box, body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // Support for .REVERSE could be added.

  box := first_box;
  box_index := 0;

  while !IsNil(box)
  {
    `it := box;
    `it_index := box_index;
    box = box.next;
    if it.floating.attach_to then continue;
    box_index += 1;
    #insert body;
  }
}

TreeDepthFirst :: (root: *Box, body: Code, flags: For_Flags) #expand
{
  // This is post order (in reverse breadth order? idk what is the computer sciency name for this)
  #assert(flags == 0); // Support for .REVERSE could be added but it shouldn't be needed.

  /* Example traversal order for a tree with 10 boxes.
        [10 (root)]
        /    |    \
       9     6     2
      /|    /|\    |\
     8 7   5 4 3   1 0
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
        while !IsNil(box.last)
        {
          box_depth += 1;
          box = box.last;
        }
      }

      `it := box;
      `it_depth := box_depth;
      `it_index := box_index;
      box_index += 1;

      defer {
        // Go to the next (prev?) sibling or exit and go to parent
        coming_from_child_to_parent = false;
        if !IsNil(box.prev) box = box.prev;
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

TreeIteratorBFS :: (root: *Box, body: Code, after_ascend: Code, after_descend: Code) #expand
{
  /* Example traversal order for a tree with 10 boxes.
        [ 0 (root)]
        /    |    \
       1     4     8
      /|    /|\    |\
     2 3   5 6 7   9 10
  */

  `it: *Box;
  `it_depth: s64;
  `it_index: s64;

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

      `it = box;
      `it_depth = box_depth;
      `it_index = box_index;
      box_index += 1;

      defer {
        // Go to the child or look_for_sibling
        if !IsNil(box.first)
        {
          box_depth += 1;
          box = box.first;

          // after_descend injection
          `it = box;
          `it_depth = box_depth;
          `it_index = box_index;
          // #insert(break=break root_loop) after_descend;
          #insert after_descend;
        }
        else look_for_sibling = true;
      };

      // #insert(break=break root_loop) body;
      #insert body;
    }

    // Ascend to parent or exit the tree traversal
    if !IsNil(box.parent) && box_depth > 0
    {
      look_for_sibling = true;
      box_depth -= 1;
      box = box.parent;

      // after_ascend injection
      `it = box;
      `it_depth = box_depth;
      `it_index = box_index;
      #insert after_ascend;
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

  active_key: BoxKey;
  hover_key: BoxKey;
  drag_start_p: V2;
  drag_box_abs_p_offset: V2;

  added_seeds: Hash_Table.Table(Value_Type = u64);
  hash_collisions := 0;

  // Double-buffer system.
  // Each LayoutBegin call flips boxes_index between 0-1.
  // current_boxes_index points to boxes array used by current layout run.
  // Other boxes array points to boxes from the previous frame.
  current_boxes_index: u8;
  boxes: [2][..] Box; // @todo replace with HashTable // @todo The rest of the code assumes STABLE pointers here!

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
Hash_Table :: #import "treasure_hash_table";
#import "Sort"; // quick_sort

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
HashLocFunc :: (loc: Source_Code_Location, init_seed: u64) -> u64
{
  seed := ObjectToByteArray(*init_seed);
  filename := cast([] u8) loc.fully_pathed_filename;
  line_number := ObjectToByteArray(*loc.line_number);
  character_number := ObjectToByteArray(*loc.character_number);
  return LayoutHash(seed, filename, line_number, character_number);
}
HashTwoU64 :: (a: u64, b: u64) -> u64
{
  a2 := ObjectToByteArray(*a);
  b2 := ObjectToByteArray(*b);
  return LayoutHash(a2, b2);
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
