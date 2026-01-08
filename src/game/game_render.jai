#scope_file;
using,only(AST,DEV,G,GPU,RD) COMPS;
#scope_export;

RenderState :: struct
{
  ui_indices: Fixed(u32, 1024 * 64);
  ui_shapes: Fixed(RD_UIShape, 1024 * 16);
  ui_shapes3d: Fixed(RD_UIShapeIn3D, 1024 * 2);

  world_batches: [] RD_WorldBatch; // count = LaneCount(); indexed by LaneIdx()

  all_stagings: [] RD_Staging;
  transforms_staging: *RD_Staging;
  models_stagings: [] RD_Staging; // count = AST.models.count
  meshes_stagings: [] RD_Staging; // count = AST.materials.count
}

RD_Staging :: struct
{
  transfer_handle: *SDL_GPUTransferBuffer;
  element_count: s64;
  bytes: s64;

  buffer_handle: *SDL_GPUBuffer;
  buffer_capacity: s64;
}

RD_WorldUniform :: struct
{
  camera_transform: Mat4;
  shadow_transform: Mat4;
  camera_position: V3 #align 16;
  sun_dir: V3 #align 16;
  flags: RD_WorldFlags;

  fog_color: Color32; // RGBA
  sky_ambient: Color32; // RGBA
  sun_diffuse: Color32; // RGBA
  sun_specular: Color32; // RGBA

  material_diffuse: Color32; // RGBA
  material_specular: Color32; // RGBA
  material_roughness: float;
  material_loaded_t: float;
}

RD_WorldInstance :: struct
{
  transform: Mat4;
  color_mask: Color32;
  hue_shift: float;
  picking_color: Color32;
  pose_offset: u32; // in indices; unused for rigid
};

RD_WorldBatch :: struct
{
  models: [] ModelBatch #align CACHELINE_SIZE; // indexed with ModelSlot
  meshes: [] MeshBatch; // indexed with MeshSlot
  transforms: [..] Mat4;

  ModelBatch :: struct { buf: [..] RD_WorldInstance; }
  MeshBatch :: struct { buf: [..] RD_WorldVertex; }
}

RD_Init :: ()
{
  RD.world_batches = NewArray(GLOBAL.core_count, RD_WorldBatch);
  RD.all_stagings = NewArray(1 + AST.models.count + AST.materials.count, RD_Staging);
  RD.transforms_staging = *RD.all_stagings[0];
  RD.models_stagings = Subarray(RD.all_stagings, 1, AST.models.count);
  RD.meshes_stagings = Subarray(RD.all_stagings, 1 + AST.models.count, AST.materials.count);

  for * RD.all_stagings {
    it.buffer_handle = GPU.dummy_instance_buffer;
  }
}

RD_InitializeWorldBatch :: (batch: *RD_WorldBatch)
{
  batch.models = NewArray(AST.models.count, RD_WorldBatch.ModelBatch);
  batch.meshes = NewArray(AST.materials.count, RD_WorldBatch.MeshBatch);
}

RD_UploadWorldBatchesToGPUTransferBuffers :: ()
{
  AssertThatOnlyOneLaneEverReachedThisCodepath();
  if RD.world_batches.count == 0 return;

  // @todo counting could be done directly on staging
  auto_release_temp();
  transforms_sum := 0;
  models_sums := NewArray(AST.models.count, s64,, temp);
  meshes_sums := NewArray(AST.materials.count, s64,, temp);

  // Count all transforms, models, meshes + patch model's pose_offset
  for batch: RD.world_batches
  {
    for batch.models {
      models_sums[it_index] += it.buf.count;
      for * it.buf { // patch pose_offsets with cumulative lane offset
        it.pose_offset += xx transforms_sum;
      }
    }

    for batch.meshes {
      meshes_sums[it_index] += it.buf.count;
    }

    transforms_sum += batch.transforms.count;
  }

  // @todo 1. Following 3 code blocks are a bit fragile copypasta.
  //          Could be compressed with some effort.

  // @todo 2. Calling SDL_CreateGPUTransferBuffer all the time shows up in the profiler actually.
  //          Reuse transfer buffer unless it's too small. Use SDL's built-in cycling.

  // Upload transforms to GPU
  {
    sum := transforms_sum;

    staging := RD.transforms_staging;
    staging.element_count = sum;
    staging.bytes = staging.element_count * size_of(Mat4);
    if staging.bytes > 0
    {
      transfer_desc := SDL_GPUTransferBufferCreateInfo.{
        usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, size = xx staging.bytes,
      };
      staging.transfer_handle = SDL_CreateGPUTransferBuffer(GPU.device, *transfer_desc);

      // CPU -> GPU transfer buffer
      mapped_memory := SDL_MapGPUTransferBuffer(GPU.device, staging.transfer_handle, false).(*u8);
      mapped_dst := mapped_memory;
      for batch: RD.world_batches
      {
        src := *batch.transforms;
        size := array_size_bytes(src.*);
        memcpy(mapped_dst, src.data, size);
        mapped_dst += size;
      }
      assert(mapped_dst - mapped_memory == staging.bytes);
      SDL_UnmapGPUTransferBuffer(GPU.device, staging.transfer_handle);
    }
  }

  // Upload models to GPU
  for sum, slot: models_sums
  {
    staging := *RD.models_stagings[slot];
    staging.element_count = sum;
    staging.bytes = staging.element_count * size_of(RD_WorldInstance);
    if staging.bytes == 0 continue;

    transfer_desc := SDL_GPUTransferBufferCreateInfo.{
      usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, size = xx staging.bytes,
    };
    staging.transfer_handle = SDL_CreateGPUTransferBuffer(GPU.device, *transfer_desc);

    // CPU -> GPU transfer buffer
    mapped_memory := SDL_MapGPUTransferBuffer(GPU.device, staging.transfer_handle, false).(*u8);
    mapped_dst := mapped_memory;
    for batch: RD.world_batches
    {
      src := *batch.models[slot].buf;
      size := array_size_bytes(src.*);
      memcpy(mapped_dst, src.data, size);
      mapped_dst += size;
    }
    assert(mapped_dst - mapped_memory == staging.bytes);
    SDL_UnmapGPUTransferBuffer(GPU.device, staging.transfer_handle);
  }

  // Upload meshes to GPU
  for sum, slot: meshes_sums
  {
    staging := *RD.meshes_stagings[slot];
    staging.element_count = sum;
    staging.bytes = staging.element_count * size_of(RD_WorldVertex);
    if staging.bytes == 0 continue;

    transfer_desc := SDL_GPUTransferBufferCreateInfo.{
      usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, size = xx staging.bytes,
    };
    staging.transfer_handle = SDL_CreateGPUTransferBuffer(GPU.device, *transfer_desc);

    // CPU -> GPU transfer buffer
    mapped_memory := SDL_MapGPUTransferBuffer(GPU.device, staging.transfer_handle, false).(*u8);
    mapped_dst := mapped_memory;
    for batch: RD.world_batches
    {
      src := *batch.meshes[slot].buf;
      size := array_size_bytes(src.*);
      memcpy(mapped_dst, src.data, size);
      mapped_dst += size;
    }
    assert(mapped_dst - mapped_memory == staging.bytes);
    SDL_UnmapGPUTransferBuffer(GPU.device, staging.transfer_handle);
  }

  // Clear world batch CPU arrays
  for * batch: RD.world_batches
  {
    RD_ResetWorldBatch(batch);
  }
}

RD_CopyFromTransferBuffersToBuffers :: (copy_pass: *SDL_GPUCopyPass)
{
  for * RD.all_stagings
  {
    if it.bytes == 0 continue;

    if it.buffer_capacity < it.bytes
    {
      if it.buffer_handle && it.buffer_handle != GPU.dummy_instance_buffer // @todo collapse it into "nil buffer" concept
      {
        SDL_ReleaseGPUBuffer(GPU.device, it.buffer_handle);
        it.buffer_handle = null;
      }
      it.buffer_capacity = 0;
    }

    if !it.buffer_handle || it.buffer_handle == GPU.dummy_instance_buffer
    {
      it.buffer_capacity = xx CeilPow2(xx (it.bytes * 2));

      info := SDL_GPUBufferCreateInfo.{size = xx it.buffer_capacity};
      if is_pointer_in_bounds(RD.meshes_stagings, it) info.usage |= SDL_GPU_BUFFERUSAGE_VERTEX;
      else info.usage |= SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;

      it.buffer_handle = SDL_CreateGPUBuffer(GPU.device, *info);
    }

    src := SDL_GPUTransferBufferLocation.{transfer_buffer = it.transfer_handle};
    dst := SDL_GPUBufferRegion.{buffer = it.buffer_handle, size = xx it.bytes};
    SDL_UploadToGPUBuffer(copy_pass, *src, *dst, true); // @todo can this be false instead? does copy_pass part take care of cycling?

    // Release transfer buffer
    SDL_ReleaseGPUTransferBuffer(GPU.device, it.transfer_handle);
    it.transfer_handle = null;
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

RD_WorldMaterialToUniform :: (uniform: *RD_WorldUniform, material: Material, mode: GPU_RenderWorldMode)
{
  uniform.material_loaded_t = material.stream.loaded_t;
  uniform.material_diffuse = xx material.diffuse;
  uniform.material_specular = xx material.specular;
  uniform.material_roughness = xx material.roughness;

  uniform.flags = .ApplyShadows;

  if mode != .RENDER
  {
    uniform.flags |= .PixelEarlyExit;
  }

  if mode == .MOUSE_PICKING
  {
    uniform.flags |= .DiscardColorPickZero;
  }

  if material.tex.format
  {
    if material.tex.layers >= 1  uniform.flags |= .SampleTexDiffuse;
    if material.tex.layers >= 2  uniform.flags |= .SampleTexNormal;
    if material.tex.layers >= 3  uniform.flags |= .SampleTexRoughness;
  }
}

RD_DrawGhost :: (ghost: Ghost, batch: *RD_WorldBatch)
{
  draw_model := OBJ_HasAnyFlag(ghost, .DRAW_MODEL);
  draw_colliders := OBJ_HasAnyFlag(ghost, .DRAW_COLLIDERS);
  debug_colliders := DEV.show_colliders;
  draw_bars := OBJ_HasAnyFlag(ghost, .DRAW_BARS);

  if draw_model
  {
    transform := TranslationMatrix(ghost.anim.position);
    transform = transform * RotationMatrix(ghost.anim.rotation); // rotate first, translate second

    hover_color := ColorWhite();
    if OBJ_HasAnyFlag(ghost, .CANT_DAMAGE) hover_color.y *= 0.2 + 0.6*Sin01(G.at*1.9);
    if (ghost.key == G.hover_object) hover_color.x *= 0.25*Cos01(G.at*1.5);
    if (ghost.key == DEV.inspected_object) hover_color.xyz *= 0.2 + 0.8*Sin01(G.at*2.8);

    instance := RD_WorldInstance.{
      transform = transform,
      hue_shift = ghost.hue_shift,
      color_mask = ColorPack(hover_color),
      picking_color = ifx ghost.flags & .DISABLE_MOUSE then (0).(Color32) else OBJ_KeyToColor(ghost.key),
    };

    model := ModelFromAlias(ghost.model);
    if model.is_skinned
    {
      skeleton := SkeletonFromSlot(model.skeleton_slot);
      instance.pose_offset = xx batch.transforms.count;
      tracks := AN_GetTracks(ghost);
      transforms := AN_GetPoseTransforms(skeleton, tracks);
      array_add_from_another_array(*batch.transforms, transforms);
    }

    model_slot := ModelSlotFromAlias(ghost.model);
    array_add(*batch.models[model_slot].buf, instance);
  }

  if draw_bars
  {
    bar_height := 10.0;
    start_x := -ghost.stats.max_health / 2;
    start_y := -bar_height*2;
    alpha := 1.0;

    {
      death_t := Elapsed(G.frame_timestamp, ghost.death_time);
      death_t = clamp(death_t * 2.0, 0.0, 1.0);
      alpha = 1.0 - death_t;
    }

    max_hp_bar := RD_UIShape.{
      rect = MakeRectMinDim(.{start_x, start_y}, .{ghost.stats.max_health, bar_height}),
      color = ColorPack(ColorRGBA(0, 0, 0, alpha))
    };
    active_hp_bar := RD_UIShape.{
      rect = MakeRectMinDim(.{start_x, start_y}, .{max(0.0, ghost.health), bar_height}),
      color = ColorPack(ColorRGBA(0.1, 1, 0, alpha))
    };

    RD_UIDraw3D(ghost.p + .{0,0,1.75}, max_hp_bar);
    RD_UIDraw3D(ghost.p + .{0,0,1.75}, active_hp_bar);

    if ghost.team
    {
      color: Color32;
      if ghost.team == .BLUE color = ColorPack(ColorRGBA(0.2, 0.2, 1.0, alpha));
      if ghost.team == .RED  color = ColorPack(ColorRGBA(1.0, 0.2, 0.2, alpha));

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
        mesh_verts[i].color = U32_MAX;
      }
    }

    // Transfer verts to GPU
    material_slot := MaterialSlotFromAlias(material);
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
