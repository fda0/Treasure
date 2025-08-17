UI_Uniform :: struct
{
  window_dim: V2;
  texture_dim: V2;
}

UI_Shape :: struct
{
  rect: Rect;
  tex_rect: Rect;
  tex_layer: float = -1.0;
  corner_radius: float;
  edge_softness: float;
  border_thickness: float;
  color: Color32; // @todo array of 4 colors for gradients
}

UI_ShapeIn3D :: struct
{
  world_p: V3;
  shape: UI_Shape;
}


UI_Draw2D :: (shape: UI_Shape)
{
  using G.gpu.ui;
  if indices_count + 6 > indices.count return; // @todo log errors?
  if shapes_count + 6 > shapes.count return;

  clip_i := UI_ActiveClipIndex();

  shape_i := shapes_count;
  shapes_count += 1;
  shapes[shape_i] = shape;

  index_i := indices_count;
  indices_count += 6;
  encoded := ((shape_i << 2) | (clip_i << 18));
  indices[index_i + 0] = 0 | encoded;
  indices[index_i + 1] = 1 | encoded;
  indices[index_i + 2] = 2 | encoded;
  indices[index_i + 3] = 2 | encoded;
  indices[index_i + 4] = 1 | encoded;
  indices[index_i + 5] = 3 | encoded;
}

UI_Draw3D :: (world_p: V3, shape: UI_Shape)
{
  using G.gpu.ui;
  if shapes3d_count + 1 > shapes3d.count return;

  shapes3d[shapes3d_count] = .{world_p, shape};
  shapes3d_count += 1;
}

UI_ActiveClipIndex :: () -> u32
{
  cursor := G.gpu.ui.active_clips_cursor;
  if cursor >= G.gpu.ui.active_clips.count
  {
    cursor = 0;
  }
  return G.gpu.ui.active_clips[cursor];
}

UI_ActiveClipRect :: () -> Rect
{
  return G.gpu.ui.clip_rects[UI_ActiveClipIndex()];
}

UI_PushClipRect :: (new_clip: Rect)
{
  prev_clip := UI_ActiveClipRect();
  G.gpu.ui.active_clips_cursor += 1;

  if G.gpu.ui.active_clips_cursor < G.gpu.ui.active_clips.count
  {
    rect_index := G.gpu.ui.clip_rects_count;
    if rect_index < G.gpu.ui.clip_rects.count
    {
      intersection := RangeIntersection(new_clip, prev_clip);
      // There could be a search and add only if unique step here.
      G.gpu.ui.clip_rects[rect_index] = intersection;
      G.gpu.ui.clip_rects_count += 1;
    }
    else rect_index = 0;

    G.gpu.ui.active_clips[G.gpu.ui.active_clips_cursor] = rect_index;
  }
}

UI_PopClipRect :: ()
{
  G.gpu.ui.active_clips_cursor -= 1;
}

UI_Translate3DShapes :: ()
{
  using G.gpu.ui;
  for MakeRange(shapes3d_count)
  {
    world_p := shapes3d[it].world_p;
    shape := shapes3d[it].shape;

    transformed_p := G.camera_transform * V4.{xyz = world_p, w = 1.0};
    divided_p := transformed_p.xyz / transformed_p.w;
    flipped_p := V2.{divided_p.x, -divided_p.y};
    screen_p := (flipped_p + .{1,1}) * (G.window_dim * 0.5);

    shape.rect.min += screen_p;
    shape.rect.max += screen_p;
    UI_Draw2D(shape);
  }
}

UI_ClearRenderCounters :: ()
{
  using G.gpu.ui;
  indices_count = 0;
  shapes_count = 0;
  shapes3d_count = 0;
  G.gpu.ui.clip_rects[0] = Rect.{.{0, 0}, .{FLOAT32_MAX, FLOAT32_MAX}};
  G.gpu.ui.clip_rects_count = 1;
  G.gpu.ui.active_clips[0] = 0;
  G.gpu.ui.active_clips_cursor = 0;
}
