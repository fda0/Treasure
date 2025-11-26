#scope_file;
using,only(AST,DEV,G,GPU,RD) COMPS;
#scope_export;

RenderState :: struct
{
  ui_indices: Fixed(1024 * 64, u32);
  ui_shapes: Fixed(1024 * 16, RD_UIShape);
  ui_shapes3d: Fixed(1024 * 2, RD_UIShapeIn3D);

  world_batches: [] RD_WorldBatch; // indexed by LaneIdx()
}

RD_WorldUniform :: struct
{
  camera_transform: Mat4;
  shadow_transform: Mat4;
  camera_position: V3 #align 16;
  sun_dir: V3 #align 16;
  flags: RD_WorldShaderFlags;

  fog_color: Color32; // RGBA
  sky_ambient: Color32; // RGBA
  sun_diffuse: Color32; // RGBA
  sun_specular: Color32; // RGBA

  material_diffuse: Color32; // RGBA
  material_specular: Color32; // RGBA
  material_roughness: float;
  material_loaded_t: float;
};

RD_WorldModel :: struct
{
  transform: Mat4;
  color: Color32;
  picking_color: Color32;
  pose_offset: u32; // in indices; unused for rigid
};

RD_WorldBatch :: struct
{
  models: [] ModelBatch #align CACHELINE_SIZE; // indexed with ModelSlot
  meshes: [] MeshBatch; // indexed with MeshSlot
  transforms: [..] Mat4;

  ModelBatch :: struct {
    buf: [..] RD_WorldModel;
  }
  MeshBatch :: struct {
    buf: [..] RD_WorldVertex;
  }
}

RD_InitializeWorldBatch :: ()
{
  batch := *RD.world_batches[LaneIdx()];
  batch.models = NewArray(AST.models.count, RD_WorldBatch.ModelBatch);
  batch.meshes = NewArray(AST.materials.count, RD_WorldBatch.MeshBatch);
}

RD_UploadAllBatchesToGPU :: ()
{
  AssertThatOnlyOneLaneEverReachedThisCodepath();
  for * batch: RD.world_batches
  {
    if batch.transforms.count > 0 {
    GPU_BATCH_TransferUploadBytes(GPU_BATCH_GetPosesBatch(),
      batch.transforms.data, xx array_size_bytes(batch.transforms), xx batch.transforms.count);
    }

    for batch.models {
      if it.buf.count > 0 {
        gpu_batch := GPU_BATCH_FindOrCreateBundle(.{type = .ModelInstances, model_slot = xx it_index});
        GPU_BATCH_TransferUploadBytes(gpu_batch, it.buf.data, xx array_size_bytes(it.buf), xx it.buf.count);
      }
    }

    for batch.meshes {
      if it.buf.count > 0 {
        gpu_batch := GPU_BATCH_FindOrCreateBundle(.{type = .MeshVertices, material_slot = xx it_index});
        GPU_BATCH_TransferUploadBytes(gpu_batch, it.buf.data, xx array_size_bytes(it.buf), xx it.buf.count);
      }
    }

    RD_ResetWorldBatch(batch);
  }
}

RD_ResetWorldBatch :: (batch: *RD_WorldBatch)
{
  for * batch.models {
    array_reset_keeping_memory(*it.buf);
  }
  for * batch.meshes {
    array_reset_keeping_memory(*it.buf);
  }
  array_reset_keeping_memory(*batch.transforms);
}

RD_WorldMaterialToUniform :: (uniform: *RD_WorldUniform, material: Material, simplified_pipeline: bool)
{
  uniform.material_loaded_t = material.stream.loaded_t;
  uniform.material_diffuse = xx material.params.diffuse;
  uniform.material_specular = xx material.params.specular;
  uniform.material_roughness = xx material.params.roughness;

  uniform.flags = .ApplyShadows;

  if simplified_pipeline
  {
    uniform.flags |= .PixelEarlyExit;
  }

  if material.has_texture
  {
    if material.texture_layers >= 1  uniform.flags |= .SampleTexDiffuse;
    if material.texture_layers >= 2  uniform.flags |= .SampleTexNormal;
    if material.texture_layers >= 3  uniform.flags |= .SampleTexRoughness;
  }
}

RD_WorldDrawObject :: (ghost: Ghost)
{
  batch := *RD.world_batches[LaneIdx()];

  draw_model := OBJ_HasAnyFlag(ghost, .DRAW_MODEL);
  draw_colliders := OBJ_HasAnyFlag(ghost, .DRAW_COLLIDERS);
  debug_colliders := DEV.show_colliders;
  draw_hp := OBJ_HasAnyFlag(ghost, .HAS_HP);

  if draw_model
  {
    transform := TranslationMatrix(ghost.animated_p);
    transform = transform * RotationMatrix(ghost.animated_rot); // rotate first, translate second

    hover_color := C4.{1,1,1,1};
    if (ghost.key == G.hover_object)      hover_color.x   *= 0.25*Cos01(G.at*1.5);
    if (ghost.key == DEV.selected_object) hover_color.xyz *= 0.5 + 0.5*Sin01(G.at*3.0);

    instance := RD_WorldModel.{
      transform = transform,
      color = C32_from_C4(hover_color),
      picking_color = OBJ_KeyToColor(ghost.key)
    };

    model := GetModel(ghost.model);
    if model.is_skinned {
      instance.pose_offset = xx batch.transforms.count;
      transforms := ANIMATION_GetPoseTransforms(model.skeleton, ghost.anim.tracks);
      array_add_from_array(*batch.transforms, transforms);
    }

    model_slot := GetModelSlot(ghost.model);
    array_add(*batch.models[model_slot].buf, instance);
  }

  if draw_hp
  {
    bar_height := 10.0;
    start_x := -ghost.max_hp / 2;
    start_y := -bar_height*2;
    alpha := 1.0;

    if ghost.death_tick
    {
      death_t := Elapsed(G.frame_timestamp, ghost.death_time);
      death_t = clamp(death_t * 2.0, 0.0, 1.0);
      alpha = 1.0 - death_t;
    }

    max_hp_bar := RD_UIShape.{
      rect = MakeRectMinDim(.{start_x, start_y}, .{ghost.max_hp, bar_height}),
      color = Color32_RGBAf(0, 0, 0, alpha)
    };
    active_hp_bar := RD_UIShape.{
      rect = MakeRectMinDim(.{start_x, start_y}, .{max(0.0, ghost.hp), bar_height}),
      color = Color32_RGBAf(0.1, 1, 0, alpha)
    };

    RD_UIDraw3D(ghost.p + .{0,0,1.75}, max_hp_bar);
    RD_UIDraw3D(ghost.p + .{0,0,1.75}, active_hp_bar);

    if ghost.team
    {
      color: Color32;
      if ghost.team == .BLUE color = Color32_RGBAf(0.2, 0.2, 1.0, alpha);
      if ghost.team == .RED  color = Color32_RGBAf(1.0, 0.2, 0.2, alpha);

      bar_dim := bar_height;

      team_square := RD_UIShape.{
        rect = MakeRectMinDim(.{start_x - bar_dim, start_y}, .{bar_dim, bar_dim}),
        color = color
      };
      RD_UIDraw3D(ghost.p + .{0,0,1.75}, team_square);
    }
  }

  if draw_colliders || debug_colliders
  {
    height := ghost.height;
    material := ghost.material;

    if debug_colliders && draw_model
    {
      if !height  height = 0.2;
      if (!material) material = .Leather011;
    }

    face_count := cast(u32) ifx height then 6 else 1;
    vertices_per_face: u32 = 3 * 2;
    mesh_verts_count: u32 = face_count * vertices_per_face;
    mesh_verts: [6 * 3 * 2] RD_WorldVertex; // CPU side temporary buffer

    bot_z := ghost.p.z;
    top_z := bot_z + height;

    collider := ghost.collider;
    {
      cube_verts := V3.[
        V3.{xy=collider.vertices[0], z=bot_z}, // 0
        V3.{xy=collider.vertices[1], z=bot_z}, // 1
        V3.{xy=collider.vertices[2], z=bot_z}, // 2
        V3.{xy=collider.vertices[3], z=bot_z}, // 3
        V3.{xy=collider.vertices[0], z=top_z}, // 4
        V3.{xy=collider.vertices[1], z=top_z}, // 5
        V3.{xy=collider.vertices[2], z=top_z}, // 6
        V3.{xy=collider.vertices[3], z=top_z}, // 7
      ];

      // mapping to expand verts to walls (each wall is made out of 2 triangles)
      cube_verts_map_array := u32.[
        0,5,4,0,1,5, // E
        2,7,6,2,3,7, // W
        1,6,5,1,2,6, // N
        3,4,7,3,0,4, // S
        6,4,5,6,7,4, // Top
        1,3,2,1,0,3, // Bottom
      ];

      cube_verts_map := cube_verts_map_array.data;
      if (face_count == 1) // generate top mesh only
      cube_verts_map += 6*Direction3D.T.(u32);

      for mesh_index: MakeRange(mesh_verts_count)
      {
        cube_index := cube_verts_map[mesh_index];
        mesh_verts[mesh_index].p = cube_verts[cube_index];
        mesh_verts[mesh_index].p.x += ghost.p.x;
        mesh_verts[mesh_index].p.y += ghost.p.y;
      }
    }

    w0 := length(collider.vertices[0] - collider.vertices[1]);
    w1 := length(collider.vertices[1] - collider.vertices[2]);
    w2 := length(collider.vertices[2] - collider.vertices[3]);
    w3 := length(collider.vertices[3] - collider.vertices[0]);

    for face_i: MakeRange(face_count)
    {
      face_dir := face_i.(Direction3D);
      if (face_count == 1) face_dir = .T;

      face_uvs := V2.[
        .{0, 1},
        .{1, 0},
        .{0, 0},
        .{0, 1},
        .{1, 1},
        .{1, 0},
      ];

      // If texture_texels_per_m is set - scale texture uvs
      if (ghost.texture_texels_per_m)
      {
        // face texture UVs
        face_dim: V2;
        if face_dir ==
        {
          case .E; face_dim = V2.{w0, height};
          case .W; face_dim = V2.{w2, height};
          case .N; face_dim = V2.{w3, height};
          case .S; face_dim = V2.{w1, height};
          case .T; face_dim = V2.{w0, w1}; // works for rects only
          case .B; face_dim = V2.{w0, w1}; // works for rects only
        }

        face_scale := face_dim * ghost.texture_texels_per_m;
        for *face_uvs
        it.* *= face_scale;
      }

      obj_norm_E := V3.{xy=collider.normals[0]};
      obj_norm_W := V3.{xy=collider.normals[2]};
      obj_norm_N := V3.{xy=collider.normals[1]};
      obj_norm_S := V3.{xy=collider.normals[3]};
      normal: V3;
      if face_dir ==
      {
        case .E; normal = obj_norm_E;
        case .W; normal = obj_norm_W;
        case .N; normal = obj_norm_N;
        case .S; normal = obj_norm_S;
        case .T; normal = V3.{0,0,1};
        case .B; normal = V3.{0,0,-1};
      }

      for vert_i: MakeRange(vertices_per_face)
      {
        i := (face_i * vertices_per_face) + vert_i;
        mesh_verts[i].uv = face_uvs[vert_i];
        mesh_verts[i].normal = normal;
      }
    }

    // Transfer verts to GPU
    material_slot := GetMaterialSlot(material);
    array_add_many(*batch.meshes[material_slot].buf, mesh_verts.data, mesh_verts_count);
  }
}

//
// UI
//

RD_UIUniform :: struct
{
  window_dim: V2;
  texture_dim: V2;
}

RD_UIShape :: struct
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

RD_UIShapeIn3D :: struct
{
  world_p: V3;
  shape: RD_UIShape;
}

RD_UIDraw2D :: (shape: RD_UIShape)
{
  if array_space_left(RD.ui_indices) < 6 || array_space_left(RD.ui_shapes) < 6 {
    log_error("Out of space in RD_UIDraw2D");
    return;
  }

  shape_index := RD.ui_shapes.count;
  array_add(*RD.ui_shapes, shape);

  encoded := shape_index << 2;
  array_add(*RD.ui_indices, xx 0 | encoded);
  array_add(*RD.ui_indices, xx 1 | encoded);
  array_add(*RD.ui_indices, xx 2 | encoded);
  array_add(*RD.ui_indices, xx 2 | encoded);
  array_add(*RD.ui_indices, xx 1 | encoded);
  array_add(*RD.ui_indices, xx 3 | encoded);
}

RD_UIDraw3D :: (world_p: V3, shape: RD_UIShape)
{
  if array_space_left(RD.ui_shapes3d) <= 0 {
    log_error("Out of space in RD_UIDraw3D");
    return;
  }
  array_add(*RD.ui_shapes3d, .{world_p, shape});
}

RD_UITranslate3DShapes :: ()
{
  PerfFunc();

  for RD.ui_shapes3d
  {
    world_p := it.world_p;
    shape := it.shape;

    transformed_p := G.camera_transform * V4.{xyz = world_p, w = 1.0};
    divided_p := transformed_p.xyz / transformed_p.w;
    flipped_p := V2.{divided_p.x, -divided_p.y};
    screen_p := (flipped_p + .{1,1}) * (G.window_dim * 0.5);

    shape.rect.min += screen_p;
    shape.rect.max += screen_p;
    RD_UIDraw2D(shape);
  }
}

RD_UIClearRenderCounters :: ()
{
  array_reset(*RD.ui_indices);
  array_reset(*RD.ui_shapes);
  array_reset(*RD.ui_shapes3d);
}
