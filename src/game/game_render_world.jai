#scope_file;
using,only(CL,DEV) COMPS;
#scope_export;

WORLD_Dir :: enum u32
{
  E; // +X
  W; // -X
  N; // +Y
  S; // -Y
  T; // +Z
  B; // -Z
  COUNT;
};

WORLD_Uniform :: struct
{
  camera_transform: Mat4;
  shadow_transform: Mat4;
  camera_position: V3 #align 16;
  sun_dir: V3 #align 16;
  flags: WORLD_ShaderFlags;

  fog_color: Color32; // RGBA
  sky_ambient: Color32; // RGBA
  sun_diffuse: Color32; // RGBA
  sun_specular: Color32; // RGBA

  material_diffuse: Color32; // RGBA
  material_specular: Color32; // RGBA
  material_roughness: float;
  material_loaded_t: float;
};

WORLD_InstanceModel :: struct
{
  transform: Mat4;
  color: Color32;
  picking_color: Color32;
  pose_offset: u32; // in indices; unused for rigid
};

WORLD_ApplyMaterialToUniform :: (uniform: *WORLD_Uniform, material: *Material, simplified_pipeline: bool)
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

WORLD_DrawModel :: (model_key: MODEL_Key, transform: Mat4, animation_tracks: [] ANIMATION_Track,
                    color: Color32, picking_color: Color32 = 0)
{
  instance := WORLD_InstanceModel.{
    transform = transform,
    color = color,
    picking_color = picking_color
  };

  model := GetModel(model_key);
  if model.is_skinned
  {
    instance.pose_offset = GPU_BATCH_GetPosesBatch().element_count;

    transforms := ANIMATION_GetPoseTransforms(model.skeleton, animation_tracks);
    transfer_size := transforms.count * size_of(type_of(transforms[0]));
    GPU_BATCH_TransferUploadBytes(GPU_BATCH_GetPosesBatch(), transforms.data, xx transfer_size, xx transforms.count);
  }

  instance_batch := GPU_BATCH_FindOrCreateBundle(.{type = .ModelInstances, model_key = model_key});
  GPU_BATCH_TransferUploadBytes(instance_batch, *instance, size_of(type_of(instance)), 1);
}

WORLD_DrawVertices :: (material: MATERIAL_Key, vertices: *WORLD_Vertex, vertices_count: u32)
{
  mesh_batch := GPU_BATCH_FindOrCreateBundle(.{type=.MeshVertices, material_key=material});
  transfer_size: u32 = vertices_count * size_of(type_of(vertices[0]));
  GPU_BATCH_TransferUploadBytes(mesh_batch, vertices, transfer_size, vertices_count);
}

WORLD_DrawObjects :: ()
{
  PerfFunc();

  for *ghost: CL.all_ghosts
  {
    draw_model := OBJ_HasAnyFlag(ghost, .DRAW_MODEL);
    draw_colliders := OBJ_HasAnyFlag(ghost, .DRAW_COLLIDERS);
    debug_colliders := DEV.show_colliders;
    draw_hp := OBJ_HasAnyFlag(ghost, .HAS_HP);

    if draw_model
    {
      transform := TranslationMatrix(ghost.animated_p);
      transform = transform * RotationMatrix(ghost.animated_rot); // rotate first, translate second

      hover_color := C4.{1,1,1,1};
      if ghost.key == G.hover_object         then hover_color.x   *= 0.25*Cos01(G.at*1.5);
      if ghost.key == DEV.selected_object  then hover_color.xyz *= 0.5 + 0.5*Sin01(G.at*3.0);

      WORLD_DrawModel(ghost.model, transform, ghost.anim.tracks,
                      C32_from_C4(hover_color), OBJ_KeyToColor(ghost.key));
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

      max_hp_bar := UI_Shape.{
        rect = MakeRectMinDim(.{start_x, start_y}, .{ghost.max_hp, bar_height}),
        color = Color32_RGBAf(0, 0, 0, alpha)
      };
      active_hp_bar := UI_Shape.{
        rect = MakeRectMinDim(.{start_x, start_y}, .{max(0.0, ghost.hp), bar_height}),
        color = Color32_RGBAf(0.1, 1, 0, alpha)
      };

      UI_Draw3D(ghost.p + .{0,0,1.75}, max_hp_bar);
      UI_Draw3D(ghost.p + .{0,0,1.75}, active_hp_bar);

      if ghost.team
      {
        color: Color32;
        if ghost.team == .BLUE color = Color32_RGBAf(0.2, 0.2, 1.0, alpha);
        if ghost.team == .RED  color = Color32_RGBAf(1.0, 0.2, 0.2, alpha);

        bar_dim := bar_height;

        team_square := UI_Shape.{
          rect = MakeRectMinDim(.{start_x - bar_dim, start_y}, .{bar_dim, bar_dim}),
          color = color
        };
        UI_Draw3D(ghost.p + .{0,0,1.75}, team_square);
      }
    }

    if draw_colliders || debug_colliders
    {
      height := ghost.height;
      material := ghost.material;

      if debug_colliders && draw_model
      {
        if !height  height = 0.2;
        if IsZeroKey(material)  material = MaterialKey("tex.Leather011");
      }

      face_count := cast(u32) ifx height then 6 else 1;
      vertices_per_face: u32 = 3 * 2;
      mesh_verts_count: u32 = face_count * vertices_per_face;
      mesh_verts: [6 * 3 * 2] WORLD_Vertex; // CPU side temporary buffer

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
          cube_verts_map += 6*WORLD_Dir.T.(u32);

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
        face_dir := face_i.(WORLD_Dir);
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
      WORLD_DrawVertices(material, mesh_verts.data, mesh_verts_count);
    }
  }
}
