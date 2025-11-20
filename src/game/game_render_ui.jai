#scope_file;
using,only(GPU) COMPS;
#scope_export;

UI_Uniform :: struct
{
  window_dim: V2;
  texture_dim: V2;
}

UI_Shape :: struct
{
  rect: Rect;
  tex_rect: Rect;
  clip_rect: Rect = INIT_CLIP;
  border_widths: [4] float;
  tex_layer: float = -1.0;
  corner_radius: float;
  edge_softness: float;
  color: Color32; // @todo array of 4 colors for gradients

  INIT_CLIP :: Rect.{.{0, 0}, .{FLOAT32_MAX, FLOAT32_MAX}};
}

UI_ShapeIn3D :: struct
{
  world_p: V3;
  shape: UI_Shape;
}


UI_Draw2D :: (shape: UI_Shape)
{
  if (GPU.ui.indices_count + 6 > GPU.ui.indices.count) ||
     (GPU.ui.shapes_count + 6 > GPU.ui.shapes.count)
  {
    log_error("Out of space in UI_Draw2D");
    return;
  }

  shape_i := GPU.ui.shapes_count;
  GPU.ui.shapes_count += 1;
  GPU.ui.shapes[shape_i] = shape;

  index_i := GPU.ui.indices_count;
  GPU.ui.indices_count += 6;

  encoded := shape_i << 2;
  GPU.ui.indices[index_i + 0] = 0 | encoded;
  GPU.ui.indices[index_i + 1] = 1 | encoded;
  GPU.ui.indices[index_i + 2] = 2 | encoded;
  GPU.ui.indices[index_i + 3] = 2 | encoded;
  GPU.ui.indices[index_i + 4] = 1 | encoded;
  GPU.ui.indices[index_i + 5] = 3 | encoded;
}

UI_Draw3D :: (world_p: V3, shape: UI_Shape)
{
  if GPU.ui.shapes3d_count + 1 > GPU.ui.shapes3d.count
  {
    log_error("Out of space in UI_Draw3D");
    return;
  }

  GPU.ui.shapes3d[GPU.ui.shapes3d_count] = .{world_p, shape};
  GPU.ui.shapes3d_count += 1;
}

UI_Translate3DShapes :: ()
{
  PerfFunc();

  for MakeRange(GPU.ui.shapes3d_count)
  {
    world_p := GPU.ui.shapes3d[it].world_p;
    shape := GPU.ui.shapes3d[it].shape;

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
  GPU.ui.indices_count = 0;
  GPU.ui.shapes_count = 0;
  GPU.ui.shapes3d_count = 0;
}
