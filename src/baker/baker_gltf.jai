BK_GLTF_LoadSpec :: struct
{
  file_path: string;

  height: float; // automatically adjust scale so model is equal height (meters) on Z axis
  disable_z0: bool; // automatically move model to start at z = 0

  scale := 1.0;
  rot: Quat;
  move: V3;

  name: string; // If empty name will be taken from file name.
};

BK_GLTF_Mesh :: struct
{
  // BK_GLTF_Mesh Groups all vertices and indicecs per common material in .gltf file.
  material_index: s64;
  verts_count: u32;
  indices:       [..] u16;
  positions:     [..] float;
  normals:       [..] float;
  texcoords:     [..] float;
  joint_indices: [..] u8;
  weights:       [..] float;
};

BK_GLTF_Model :: struct
{
  meshes: [..] BK_GLTF_Mesh;

  name: string;
  has_skeleton: bool;
  skeleton_index: u32;
  is_skinned: bool;
  joints_count: u32;
  spec: BK_GLTF_LoadSpec;
  spec_transform: Mat4;
};

BK_GLTF_Load :: (spec: BK_GLTF_LoadSpec)
{
  auto_release_temp();
  push_allocator(temp);

  BK_FakeMalloc :: (user_data: *void, size: u64) -> *void #c_call {
    push_context {
      return talloc(xx size);
    }
  }
  BK_FakeFree :: (user_data: *void, ptr: *void) #c_call {}
  options := cgltf_options.{
    memory = .{
      alloc = BK_FakeMalloc,
      free = BK_FakeFree,
    },
  };

  // Parse .gltf file & load buffers
  data: *cgltf_data;
  res := cgltf_parse_file(*options, to_c_string(spec.file_path), *data);
  if res != .cgltf_result_success
  {
    log_error("[GLTF LOADER] Failed to parse %", spec.file_path);
    return;
  }

  res = cgltf_load_buffers(*options, data, to_c_string(spec.file_path));
  if res != .cgltf_result_success
  {
    log_error("[GLTF LOADER] Failed to load buffers, %", spec.file_path);
    return;
  }

  res = cgltf_validate(data);
  if res != .cgltf_result_success
  {
    log_error("[GLTF LOADER] Failed to validate data, %", spec.file_path);
    return;
  }

  // Prepare strings based on file_path
  dir_path, file_name_no_ext, _, _ := path_decomp(spec.file_path);

  // Collect data from .gltf file
  // @todo Arena_Scope scratch = Arena_PushScope(BAKER.tmp);
  max_indices := 1024*256;
  max_verts := 1024*128;

  model: BK_GLTF_Model;
  model.name = ifx spec.name then spec.name else file_name_no_ext;
  model.spec = spec;
  model.is_skinned = data.animations_count > 0;
  array_resize(*model.meshes, xx data.materials_count);

  for * bk_mesh, mesh_index: model.meshes
  {
    // Fetch material data
    assert(mesh_index < xx data.materials_count);
    gltf_material := data.materials[mesh_index];

    // Create material
    bk_mesh.material_index = B.pie.materials.count;
    {
      pie_material := array_add(*B.pie.materials);
      BK_SetDefaultsPIEMaterial(pie_material);

      // Fill material name
      PIE_ListSetPrint(*pie_material.name, "%.m%.%", model.name, mesh_index, to_string(gltf_material.name));

      diffuse_tex: BK_TEX_Input;
      normal_tex: BK_TEX_Input;
      specular_tex: BK_TEX_Input;

      if gltf_material.normal_texture.texture
        normal_tex = BK_GLTF_ImageToTexInput(gltf_material.normal_texture.texture.image, dir_path);

      if gltf_material.has_pbr_metallic_roughness
      {
        metal := *gltf_material.pbr_metallic_roughness;
        pie_material.params.diffuse   = xx Color32_RGBAf(metal.base_color_factor);
        pie_material.params.roughness = metal.roughness_factor;

        if metal.base_color_texture.texture
          diffuse_tex = BK_GLTF_ImageToTexInput(metal.base_color_texture.texture.image, dir_path);
      }

      if gltf_material.has_pbr_specular_glossiness
      {
        gloss := *gltf_material.pbr_specular_glossiness;
        pie_material.params.diffuse   = xx Color32_RGBAf(gloss.diffuse_factor);
        pie_material.params.specular  = xx Color32_RGBf(gloss.specular_factor);
        pie_material.params.roughness = 1.0 - gloss.glossiness_factor;

        if gloss.diffuse_texture.texture
          diffuse_tex = BK_GLTF_ImageToTexInput(gloss.diffuse_texture.texture.image, dir_path);

        if gloss.specular_glossiness_texture.texture
          specular_tex = BK_GLTF_ImageToTexInput(gloss.specular_glossiness_texture.texture.image, dir_path);
      }

      if (gltf_material.alpha_mode != .cgltf_alpha_mode_opaque)
        pie_material.params.flags |= .HasAlpha;

      // Prepare tex_paths array
      // These are expected to be in a fixed order for now
      // So if any in the chain is missing we have to drop all subsequent textures.
      tex_inputs: [3] BK_TEX_Input;
      tex_inputs_count := 0;

      if diffuse_tex.str
      {
        tex_inputs[tex_inputs_count] = diffuse_tex;
        tex_inputs_count += 1;
      }

      if tex_inputs_count == 1 && normal_tex.str
      {
        tex_inputs[tex_inputs_count] = normal_tex;
        tex_inputs_count += 1;
      }

      if tex_inputs_count == 2 && specular_tex.str
      {
        tex_inputs[tex_inputs_count] = specular_tex;
        tex_inputs_count += 1;
      }

      if tex_inputs_count
        BK_TEX_LoadPaths(pie_material, Prefix(tex_inputs, tex_inputs_count));
    }
  }

  // The hierarchy of .gltf files might be a bit confusing.
  // Division into meshes and primitives wasn't strictly
  // necessary (it could have been merged into one) but it is what it is.
  for gltf_mesh_index: MakeRange(data.meshes_count)
  {
    gltf_mesh := *data.meshes[gltf_mesh_index];

    for gltf_primitive_index: MakeRange(gltf_mesh.primitives_count)
    {
      primitive := *gltf_mesh.primitives[gltf_primitive_index];

      // Our internal groups things into common meshes based on common material.
      mesh_index := BK_GLTF_FindMaterialIndex(data, primitive.material);
      bk_mesh := *model.meshes[mesh_index];

      if primitive.type != .cgltf_primitive_type_triangles
      {
        log("[GLTF LOADER] Primitive with non triangle type (%) skipped", primitive.type, flags=.WARNING);
        continue;
      }

      // Unpack indices from gltf primitive to bk_mesh.
      Check(primitive.indices != null);
      {
        index_start_offset: u64 = xx (bk_mesh.positions.count / 3);

        accessor := primitive.indices;
        Check(accessor.type == .cgltf_type_scalar);
        numbers := BK_GLTF_UnpackAccessor(accessor, *bk_mesh.indices);

        // Since we are possibly merging multiple primitives into one mesh
        // (we batch meshes based on common material) - we have to add
        // index offset to the indicies from gltf primitve.
        if index_start_offset
        {
          for MakeRange(accessor.count)
          {
            value := numbers[it] + index_start_offset;
            Check(value <= U16_MAX);
            numbers[it] = cast,no_check(u16) value;
          }
        }
      }

      for attribute_index: MakeRange(primitive.attributes_count)
      {
        attribute := *primitive.attributes[attribute_index];
        accessor := attribute.data;

        comp_count := cgltf_num_components(accessor.type);

        if attribute.type == {
          case .cgltf_attribute_type_position;
          Check(comp_count == 3);
          Check(accessor.component_type == .cgltf_component_type_r_32f);
          BK_GLTF_UnpackAccessor(accessor, *bk_mesh.positions);

          case .cgltf_attribute_type_normal;
          Check(comp_count == 3);
          Check(accessor.component_type == .cgltf_component_type_r_32f);
          BK_GLTF_UnpackAccessor(accessor, *bk_mesh.normals);

          case .cgltf_attribute_type_tangent;
          log("[GLTF LOADER] Attribute with type tangent skipped", flags=.VERBOSE_ONLY);
          continue;

          case .cgltf_attribute_type_texcoord;
          Check(comp_count == 2);
          Check(accessor.component_type == .cgltf_component_type_r_32f);
          BK_GLTF_UnpackAccessor(accessor, *bk_mesh.texcoords);

          case .cgltf_attribute_type_joints;
          Check(comp_count == 4);
          //Check(accessor.component_type == .cgltf_component_type_r_8u);
          BK_GLTF_UnpackAccessor(accessor, *bk_mesh.joint_indices);

          case .cgltf_attribute_type_weights;
          Check(comp_count == 4);
          Check(accessor.component_type == .cgltf_component_type_r_32f);
          BK_GLTF_UnpackAccessor(accessor, *bk_mesh.weights);

          case;
          log("[GLTF LOADER] Attribute with unknown type (%) skipped", attribute.type, flags=.WARNING);
          continue;
        }
      }
    }
  }

  // Validate buffer counts
  for * model.meshes
  {
    Check(it.positions.count % 3 == 0);
    it.verts_count = xx (it.positions.count / 3);

    Check(it.normals.count % 3 == 0);
    Check(it.verts_count == it.normals.count / 3);

    if model.is_skinned
    {
      Check(it.joint_indices.count % 4 == 0);
      Check(it.verts_count == it.joint_indices.count / 4);
      Check(it.weights.count % 4 == 0);
      Check(it.verts_count == it.weights.count / 4);
    }
  }

  // Calculate model spec transforms
  {
    // query highest and lowest Z position
    biggest_z := -FLOAT32_MAX;
    lowest_z := FLOAT32_MAX;
    for bk_mesh: model.meshes
    {
      for MakeRange(bk_mesh.verts_count)
      {
        p := V3.{
          bk_mesh.positions[it*3 + 0],
          bk_mesh.positions[it*3 + 1],
          bk_mesh.positions[it*3 + 2],
        };
        p = Rotate(p, spec.rot); // We want to query Z after rotation is applied.
        biggest_z = max(biggest_z, p.z);
        lowest_z = min(lowest_z, p.z);
      }
    }

    height_fix := 1.0;
    if spec.height
    {
      current_height := biggest_z - lowest_z;
      height_fix = spec.height / current_height;
    }

    ground_fix: V3;
    if !spec.disable_z0
    {
      ground_fix = V3.{0,0,-lowest_z};
    }

    // Apply scales to ground fix
    total_scale := spec.scale * height_fix;
    ground_fix = ground_fix * total_scale;
    total_move := spec.move + ground_fix;

    // Get spec transforms
    mat_scale := ScaleMatrix(total_scale);
    mat_rotate := RotationMatrix(spec.rot);
    mat_move := TranslationMatrix(total_move);

    // Calculate final transform
    model.spec_transform = (mat_move * (mat_rotate * mat_scale));
  }

  if model.is_skinned
  {
    // Joints
    Check(data.skins_count == 1);
    Check(data.skins[0].joints_count <= U32_MAX);
    model.joints_count = data.skins[0].joints_count.(u32);
  }

  // Sekeleton export
  if model.is_skinned
  {
    BK_GLTF_ExportSkeletonToPie(*model, data);
  }

  if !model.is_skinned // apply transformations directly to rigid mesh
  {
    if model.spec_transform != DiagonalMatrix()
    {
      for bk_mesh: model.meshes
      {
        for MakeRange(bk_mesh.verts_count)
        {
          position := (*bk_mesh.positions[it*3]).(*V3);
          p :=  model.spec_transform * V4.{xyz = position, w = 1.0};
          position.* = p.xyz;

          normal := (*bk_mesh.normals[it*3]).(*V3);
          n := Rotate(normal.*, spec.rot);
          normal.* = n;
        }
      }
    }
  }

  // Vertices export
  BK_GLTF_ExportModelToPie(model);
}

BK_GLTF_ExportSkeletonToPie :: (model: *BK_GLTF_Model, data: *cgltf_data)
{
  model.has_skeleton = true;
  model.skeleton_index = xx B.pie.skeletons.count;
  pie_skel := array_add(*B.pie.skeletons);

  // Root transform
  pie_skel.root_transform = model.spec_transform;

  Check(data.skins_count == 1);
  skin := data.skins;
  joints_count := skin.joints_count;

  // Joints data
  {
    // Unpack inverse bind matrices.
    {
      inv_bind := skin.inverse_bind_matrices;
      Check(inv_bind != null);
      Check(inv_bind.count == joints_count);
      Check(inv_bind.component_type == .cgltf_component_type_r_32f);
      Check(inv_bind.type == .cgltf_type_mat4);

      comp_count := cgltf_num_components(inv_bind.type);
      Check(comp_count == 16);

      PIE_ListStart(*pie_skel.inverse_matrices);
      matrices := PIE_FileAllocArray(xx inv_bind.count, Mat4);
      float_count := comp_count * inv_bind.count;
      unpacked_count := cgltf_accessor_unpack_floats(inv_bind, matrices.data.(*float), float_count);
      Check(unpacked_count == float_count);
      PIE_ListEnd();
    }

    // Child hierarchy indices.
    {
      temp_ranges := NewArray(xx joints_count, Range(u32));

      PIE_ListStart(*pie_skel.child_index_buffer);
      indices := PIE_FileAllocArray(xx joints_count, u32);

      indices_counter: u32;
      for joint_index: MakeRange(joints_count)
      {
        joint := skin.joints[joint_index];

        for child_index: MakeRange(joint.children_count)
        {
          child := joint.children[child_index];
          child_joint_index := BK_GLTF_FindJointIndex(skin, child);

          if child_index == 0
            temp_ranges[joint_index].min = indices_counter;

          Check(indices_counter < xx joints_count);
          indices[indices_counter] = child_joint_index;
          indices_counter += 1;

          temp_ranges[joint_index].max = indices_counter;
        }
      }
      PIE_ListEnd();
      PIE_ListSetArray(*pie_skel.child_index_ranges, temp_ranges);
    }

    // rest pose transformations
    {
      // Translations
      PIE_ListStart(*pie_skel.translations);
      for joint_index: MakeRange(joints_count)
      {
        joint := skin.joints[joint_index];
        PIE_FileAppendValue(V3.{component = joint.translation});
      }
      PIE_ListEnd();

      // Rotations
      PIE_ListStart(*pie_skel.rotations);
      for joint_index: MakeRange(joints_count)
      {
        joint := skin.joints[joint_index];
        PIE_FileAppendValue(Quat.{component = joint.rotation});
      }
      PIE_ListEnd();

      // Scales
      PIE_ListStart(*pie_skel.scales);
      for joint_index: MakeRange(joints_count)
      {
        joint := skin.joints[joint_index];
        PIE_FileAppendValue(V3.{component = joint.scale});
      }
      PIE_ListEnd();
    }

    // First allocate all strings in file in one continuous chunk.
    // Track min&max paris of each string and put them in file at the end.
    temp_name_ranges := NewArray(xx joints_count, Range(s64));
    for joint_index: MakeRange(joints_count)
    {
      temp_name_ranges[joint_index].min = PIE_CurrentFileOffset();
      joint := skin.joints[joint_index];
      PIE_FileAppendString(to_string(joint.name));
      temp_name_ranges[joint_index].max = PIE_CurrentFileOffset();
    }
    PIE_ListSetArray(*pie_skel.name_ranges, temp_name_ranges);
  }

  // Animations
  if data.animations_count
  {
    pie_animations := PIE_ListAllocArray(*pie_skel.anims, xx data.animations_count, PIE_Animation);
    for * pie_anim: pie_animations
    {
      gltf_anim := *data.animations[it_index];
      t_min := FLOAT32_MAX;
      t_max := -FLOAT32_MAX;

      // Name string
      PIE_ListSetString(*pie_anim.name, to_string(gltf_anim.name));

      // Channels
      pie_channels := PIE_ListAllocArray(*pie_anim.channels, xx gltf_anim.channels_count, PIE_AnimationChannel);
      for * pie_chan: pie_channels
      {
        gltf_chan := *gltf_anim.channels[it_index];
        gltf_sampler := gltf_chan.sampler;
        Check(gltf_sampler.interpolation == .cgltf_interpolation_type_linear);
        Check(gltf_sampler.input.count == gltf_sampler.output.count);

        sample_count := gltf_sampler.input.count;
        joint_index := BK_GLTF_FindJointIndex(skin, gltf_chan.target_node);

        channel_type: PIE_AnimationChannelType;
        if gltf_chan.target_path == {
          case; Check(false, "Unsupported channel target");
          case .cgltf_animation_path_type_translation; channel_type = .Translation;
          case .cgltf_animation_path_type_rotation;    channel_type = .Rotation;
          case .cgltf_animation_path_type_scale;       channel_type = .Scale;
        }

        pie_chan.joint_index30_type2 = joint_index | (channel_type << 30).(u32);


        // inputs
        in_nums := PIE_ListAllocArray(*pie_chan.inputs, xx sample_count, float);
        in_unpacked_count := cgltf_accessor_unpack_floats(gltf_sampler.input, in_nums.data, sample_count);
        Check(in_unpacked_count == sample_count);

        for MakeRange(sample_count)
        {
          n := in_nums[it];
          if n > t_max then t_max = n;
          if n < t_min then t_min = n;
        }

        // outputs
        out_comp_count := cgltf_num_components(gltf_sampler.output.type);
        out_count := out_comp_count * sample_count;
        out_nums := PIE_ListAllocArray(*pie_chan.outputs, xx out_count, float);
        out_unpacked_count := cgltf_accessor_unpack_floats(gltf_sampler.output, out_nums.data, out_count);
        Check(out_unpacked_count == out_count);
      }

      pie_anim.t_min = t_min;
      pie_anim.t_max = t_max;
    }
  }
}

BK_GLTF_ExportModelToPie :: (bk_model: BK_GLTF_Model)
{
  pie_model := array_add(*B.pie.models);

  // Name string
  PIE_ListSetString(*pie_model.name, bk_model.name);

  pie_model.is_skinned = bk_model.is_skinned;
  pie_model.skeleton_index = bk_model.skeleton_index;

  pie_meshes := PIE_ListAllocArray(*pie_model.meshes, bk_model.meshes.count, PIE_Mesh);

  for bk_mesh, mesh_index: bk_model.meshes
  {
    pie_mesh := *pie_meshes[mesh_index];
    pie_mesh.material_index = xx bk_mesh.material_index;
    pie_mesh.vertices_start_index = xx B.pie.vertices.count;

    // vertices
    for vert_i: MakeRange(bk_mesh.verts_count)
    {
      vert: RD_WorldVertex;

      // POS
      vert.p = V3.{
        bk_mesh.positions[vert_i*3 + 0],
        bk_mesh.positions[vert_i*3 + 1],
        bk_mesh.positions[vert_i*3 + 2],
      };

      // NORMAL
      vert.normal = V3.{
        bk_mesh.normals[vert_i*3 + 0],
        bk_mesh.normals[vert_i*3 + 1],
        bk_mesh.normals[vert_i*3 + 2],
      };

      // NORMAL validation
      {
        normal_lensq := length_squared(vert.normal);
        if normal_lensq < 0.001
        {
          log("[GLTF LOADER] Found normal equal to zero", flags=.WARNING);
          vert.normal = V3.{0,0,1};
        }
        else if normal_lensq < 0.9 || normal_lensq > 1.1
        {
          log("[GLTF LOADER] Normal wasn't normalized", flags=.WARNING);
          vert.normal = vert.normal * invsqrt(normal_lensq);
        }
      }

      // UV
      vert.uv = V2.{
        bk_mesh.texcoords[vert_i*2 + 0],
        bk_mesh.texcoords[vert_i*2 + 1],
      };

      // SKINNED specific
      if pie_model.is_skinned
      {
        joint_indices: [4] u32 = .[
          bk_mesh.joint_indices[vert_i*4 + 0],
          bk_mesh.joint_indices[vert_i*4 + 1],
          bk_mesh.joint_indices[vert_i*4 + 2],
          bk_mesh.joint_indices[vert_i*4 + 3],
        ];

        // Validate joint indices
        for joint_indices
        {
          if it >= bk_model.joints_count
            log("[GLTF LOADER] Joint index overflow. %u >= %u", it, bk_model.joints_count, flags=.WARNING);
        }

        vert.joints_packed4 = (joint_indices[0] |
                               (joint_indices[1] << 8) |
                               (joint_indices[2] << 16) |
                               (joint_indices[3] << 24));

        weights := V4.{
          bk_mesh.weights[vert_i*4 + 0],
          bk_mesh.weights[vert_i*4 + 1],
          bk_mesh.weights[vert_i*4 + 2],
          bk_mesh.weights[vert_i*4 + 3],
        };

        // Validate weights
        weight_sum := weights.x + weights.y + weights.z + weights.w;
        if weight_sum < 0.9 || weight_sum > 1.1
          log("[GLTF LOADER] Weight sum == %f (should be 1)", weight_sum, flags=.WARNING);

        vert.joint_weights = weights;
      }

      array_add(*B.pie.vertices, vert);
    }

    // Indices
    {
      pie_mesh.indices_start_index = xx B.pie.indices.count;
      pie_mesh.indices_count += xx bk_mesh.indices.count;
      array_add_from_another_array(*B.pie.indices, bk_mesh.indices);
    }
  }
}

BK_GLTF_FindJointIndex :: (skin: *cgltf_skin, find_node: *cgltf_node) -> u32
{
  for joint_index: MakeRange(skin.joints_count)
    if find_node == skin.joints[joint_index]
      return xx joint_index;

  Check(false, "Joint index not found");
  return xx skin.joints_count;
}

BK_GLTF_FindMaterialIndex :: (data: *cgltf_data, find_material: *cgltf_material) -> u32
{
  for material_index: MakeRange(data.materials_count.(u32))
    if find_material == data.materials + material_index
      return material_index;

  Check(false, "Material index not found");
  return data.materials_count.(u32);
}

BK_GLTF_UnpackAccessor :: (accessor: *cgltf_accessor, buffer: *[..] $T) -> slice: [] T
{
  comp_count := cgltf_num_components(accessor.type);
  total_count := accessor.count * comp_count;
  comp_size := cgltf_component_size(accessor.component_type);

  #if T == float
  {
    {
      Check(accessor.component_type == .cgltf_component_type_r_32f,
            "Expected component_type to be r_32f when buffer type is float. Instead got %.",
            accessor.component_type);

      numbers_slice := array_add_alloc(buffer, xx total_count);
      unpacked_count := cgltf_accessor_unpack_floats(accessor, numbers_slice.data, total_count);
      Check(unpacked_count == total_count);
      return numbers_slice;
    }
  }

  numbers_slice := array_add_alloc(buffer, xx total_count);

  if size_of(T) >= comp_size
  {
    unpacked_count := cgltf_accessor_unpack_indices(accessor, numbers_slice.data, size_of(T), total_count);
    Check(unpacked_count == total_count);
  }
  else
  {
    // Alloc tmp buffer
    auto_release_temp();
    bytes_to_allocate := comp_size * total_count;
    tmp_nums := talloc(xx bytes_to_allocate);

    // Unpack big integers into tmp_nums
    unpacked_count := cgltf_accessor_unpack_indices(accessor, tmp_nums, comp_size, total_count);
    Check(unpacked_count == total_count);

    // Copy into numbers_slice and check against truncation
    for MakeRange(total_count)
    {
      // Load value from tmp_nums into u64
      value: u64;
      if comp_size == {
        case 8; value = tmp_nums.(*u64)[it];
        case 4; value = tmp_nums.(*u32)[it];
        case 2; value = tmp_nums.(*u16)[it];
        case 1; value = tmp_nums.(*u8)[it];
        case; Check(false, "Unsupported comp_size downconversion");
      }

      // Store into buffer backed array with truncation
      #if T == {
        case u8;
        Check(value <= U8_MAX);
        numbers_slice[it] = cast,no_check(u8) value;
        case u16;
        Check(value <= U16_MAX);
        numbers_slice[it] = cast,no_check(u16) value;
        case u32;
        Check(value <= U32_MAX);
        numbers_slice[it] = cast,no_check(u32) value;
        case;
        Check(false, "Downconversion for % is not supported.", T);
      }
    }
  }

  return numbers_slice;
}

BK_GLTF_ImageToTexInput :: (image: *cgltf_image, dir_path: string) -> BK_TEX_Input
{
  result: BK_TEX_Input;
  if !image then return result;

  if image.uri
  {
    result.type = .PATH;
    uri := to_string(image.uri);
    result.str = sprint("%/%", dir_path, uri);
  }
  else if image.buffer_view
  {
    result.type = .DATA;
    result.str.count = xx image.buffer_view.size;
    result.str.data = cgltf_buffer_view_data(image.buffer_view);
  }
  return result;
}
