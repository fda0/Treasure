ASSET_InitPreGPU :: ()
{
  using,only(err) G.ast.pie;

  init(*G.ast.arena, Gigabyte(32));
  {
    push_allocator(G.ast.arena);
    if !err ASSET_LoadPieFile("data.pie");
    if !err ASSET_InitSkeletons();
    if !err ASSET_InitMaterials();
    if !err ASSET_InitModels();
    if !err ASSET_InitShaders();
    if !err ASSET_InitFonts();
    if !err ASSET_InitSounds();
  }
}

ASSET_InitPostGPU :: ()
{
  using,only(err) G.ast.pie;

  // Texture thread init
  if !err
  {
    using G.ast;
    init(*tex_semaphore);
    thread_init(*tex_thread, ASSET_TextureThread);
    thread_start(*tex_thread);
  }
}

ASSET_PostFrame :: ()
{
  // Wake up texture asset loading thread
  if G.ast.tex_load_needed
  {
    signal(*G.ast.tex_semaphore);
    G.ast.tex_load_needed = false;
  }

  // Increment loaded_t
  for *G.ast.materials
  {
    LOAD_T_SPEED :: 10.0;
    using it.stream;
    if flags & .LOADED
      loaded_t = min(1.0, loaded_t + G.dt * LOAD_T_SPEED);
  }
}

ASSET_InitShaders :: ()
{
  G.ast.shaders = NewArray(G.ast.pie.shaders.count, string);
  for G.ast.pie.shaders
    G.ast.shaders[it_index] = PIE_LOAD_ListToString(it.data);
}

ASSET_InitFonts :: ()
{
  G.ast.fonts = NewArray(G.ast.pie.fonts.count, string);
  for G.ast.pie.fonts
    G.ast.fonts[it_index] = PIE_LOAD_ListToString(it.data);
}

ASSET_InitSounds :: ()
{
  G.ast.sounds = NewArray(G.ast.pie.sounds.count, AUDIO_Sound);
  for G.ast.pie.sounds
  {
    // @todo reduce boilerplate on the whole [.pie -> in game memory] transformations
    G.ast.sounds[it_index].data = PIE_LOAD_ListToString(it.data);
    G.ast.sounds[it_index].format = it.format;
  }
}

// TEXTURE THREAD
ASSET_TextureThread :: (thread: *Thread) -> s64
{
  // This thread just touched the same global data as the main thread.
  // Any false-sharing etc wasn't a concern when making this and it could be improved.
  while true
  {
    wait_for(*G.ast.tex_semaphore);

    // Just load any texture that was used in the last 2 frames.
    // Do something smarter when texture eviction is added.
    min_load_frame := max(1, G.frame_number - 2);

    for *G.ast.materials
    {
      if it.stream.last_touched_frame >= min_load_frame
        ASSET_LoadTextureFromPieToGPU(it, it_index);
    }

    reset_temporary_storage();
  }
  return 0;
}

ASSET_LoadTextureFromPieToGPU :: (material: *Material, material_index: s64)
{
  if material.stream.flags & (.LOADED | .ERROR)
    return;

  // Material from .pie - it contains a big buffer that needs to uploaded to GPU
  using,only(pie) G.ast;
  pie_material := *pie.materials[material_index];
  gpu_full_data := PIE_LOAD_ListToString(pie_material.tex.full_data);

  // MaterialTextures - it contains a mapping from big buffer to individual pieces of texture layers and lods
  pie_texture_sections := PIE_LOAD_ListToArray(pie_material.tex.sections);

  lods_count := pie_material.tex.lods;
  generate_lods := false;
  if (lods_count == 1 && pie_material.tex.format != .BC7_RGBA)
  {
    lods_count = CalculateMipMapCount(pie_material.tex.width, pie_material.tex.height);
    generate_lods = true;
  }


  // Create texture and transfer CPU memory -> GPU memory -> GPU texture
  texture: *SDL_GPUTexture;
  {
    transfer_create_info := SDL_GPUTransferBufferCreateInfo.{
      usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
      size = xx (gpu_full_data.count * 4) // @todo why *4?
    };
    transfer := SDL_CreateGPUTransferBuffer(G.gpu.device, *transfer_create_info);

    // CPU -> GPU
    {
      gpu_mapped := SDL_MapGPUTransferBuffer(G.gpu.device, transfer, false);
      memcpy(gpu_mapped, gpu_full_data.data, gpu_full_data.count);
      SDL_UnmapGPUTransferBuffer(G.gpu.device, transfer);
    }

    // Create texture
    {
      sdl_format: SDL_GPUTextureFormat = ifx pie_material.tex.format == .R8G8B8A8 then .R8G8B8A8_UNORM else .BC7_RGBA_UNORM;

      texture_info := SDL_GPUTextureCreateInfo.{
        type = .SDL_GPU_TEXTURETYPE_2D_ARRAY,
        format = sdl_format,
        width = xx pie_material.tex.width,
        height = xx pie_material.tex.height,
        layer_count_or_depth = xx pie_material.tex.layers,
        num_levels = xx lods_count,
        usage = SDL_GPU_TEXTUREUSAGE_SAMPLER
      };

      if (generate_lods)
        texture_info.usage |= SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;

      texture = SDL_CreateGPUTexture(G.gpu.device, *texture_info);
      debug_texture_name := tprint("PIE_TEX: %", PIE_LOAD_ListToString(pie_material.name));
      SDL_SetGPUTextureName(G.gpu.device, texture, temp_c_string(debug_texture_name));
    }

    // GPU memory -> GPU texture
    {
      cmd := SDL_AcquireGPUCommandBuffer(G.gpu.device);
      copy_pass := SDL_BeginGPUCopyPass(cmd);

      for pie_texture_sections
      {
        source := SDL_GPUTextureTransferInfo.{
          transfer_buffer = transfer,
          offset = it.data_offset,
          pixels_per_row = it.width,
        };
        destination := SDL_GPUTextureRegion.{
          texture = texture,
          mip_level = it.lod,
          layer = it.layer,
          w = it.width,
          h = it.height,
          d = 1,
        };
        SDL_UploadToGPUTexture(copy_pass, *source, *destination, false);
      }

      SDL_EndGPUCopyPass(copy_pass);
      if (generate_lods) SDL_GenerateMipmapsForGPUTexture(cmd, texture);
      SDL_SubmitGPUCommandBuffer(cmd);
    }

    SDL_ReleaseGPUTransferBuffer(G.gpu.device, transfer);
  }

  material.tex = texture;
  material.stream.flags |= .LOADED;
}

// LOAD .PIE
ASSET_LoadPieFile :: (file_path: string)
{
  using,only(pie) G.ast;
  using,only(err) pie;

  file, read_success := read_entire_file(file_path);
  err |= !read_success;
  if err return;
  pie.file = file;

  header := PIE_LOAD_OffsetSizeToArray(0, size_of(PIE_Header), PIE_Header);
  if err return;
  pie.header = header.data;

  hashable := STR_Skip(PIE_LOAD_File(), size_of(type_of(pie.header.file_hash)));
  calculated_hash := Hash64Any(PIE_MAGIC_HASH_SEED, hashable);
  PIE_LOAD_Check(calculated_hash == pie.header.file_hash,
    tprint("Calculated hash (%) doesn't match file hash (%).", calculated_hash, pie.header.file_hash));
  if err return;

  links := PIE_LOAD_ListToArray(pie.header.links);
  if err return;
  pie.links = links.data;

  models := PIE_LOAD_ListToArray(pie.links.models.list);
  materials := PIE_LOAD_ListToArray(pie.links.materials);
  shaders := PIE_LOAD_ListToArray(pie.links.shaders);
  fonts := PIE_LOAD_ListToArray(pie.links.fonts);
  sounds := PIE_LOAD_ListToArray(pie.links.sounds);
  if err return;
  pie.models = models;
  pie.materials = materials;
  pie.shaders = shaders;
  pie.fonts = fonts;
  pie.sounds = sounds;
}

// MATERIALS
ASSET_InitMaterials :: ()
{
  // Init nil material
  {
    dim: u32 = 512;
    tex_size: u32 = dim * dim * size_of(u32);
    and_mask: u32 = (1 << 6);

    tex_info := SDL_GPUTextureCreateInfo.{
      type = .SDL_GPU_TEXTURETYPE_2D_ARRAY,
      format = .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
      width = dim,
      height = dim,
      layer_count_or_depth = 1,
      num_levels = CalculateMipMapCount(dim, dim),
      usage = SDL_GPU_TEXTUREUSAGE_SAMPLER|SDL_GPU_TEXTUREUSAGE_COLOR_TARGET
    };
    texture := SDL_CreateGPUTexture(G.gpu.device, *tex_info);
    SDL_SetGPUTextureName(G.gpu.device, texture, "Fallback texture");

    // Fill texture
    {
      trans_desc := SDL_GPUTransferBufferCreateInfo.{
        usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        size = tex_size,
      };
      trans_buf := SDL_CreateGPUTransferBuffer(G.gpu.device, *trans_desc);
      assert(!!trans_buf, "@todo handle this error? or remove assert");

      // Fill GPU memory
      {
        map: *u32 = SDL_MapGPUTransferBuffer(G.gpu.device, trans_buf, false);
        pixel := map;
        for y: MakeRange(dim)
        {
          for x: MakeRange(dim)
          {
            pixel[0] = xx ifx x & y & and_mask then 0xff000000 else 0xffFF00FF;
            pixel += 1;
          }
        }
        SDL_UnmapGPUTransferBuffer(G.gpu.device, trans_buf);
      }

      // GPU memory -> GPU buffers
      {
        cmd := SDL_AcquireGPUCommandBuffer(G.gpu.device);
        copy_pass := SDL_BeginGPUCopyPass(cmd);

        trans_info := SDL_GPUTextureTransferInfo.{transfer_buffer = trans_buf};
        dst_region := SDL_GPUTextureRegion.{
          texture = texture,
          w = dim,
          h = dim,
          d = 1,
        };
        SDL_UploadToGPUTexture(copy_pass, *trans_info, *dst_region, false);

        SDL_EndGPUCopyPass(copy_pass);
        SDL_SubmitGPUCommandBuffer(cmd);
      }
      SDL_ReleaseGPUTransferBuffer(G.gpu.device, trans_buf);
    }

    // Generate texture mipmap
    {
      cmd := SDL_AcquireGPUCommandBuffer(G.gpu.device);
      SDL_GenerateMipmapsForGPUTexture(cmd, texture);
      SDL_SubmitGPUCommandBuffer(cmd);
    }

    // Fill nil_material data
    {
      G.ast.nil_material.stream.flags |= .LOADED;
      G.ast.nil_material.stream.loaded_t = 1;
      G.ast.nil_material.has_texture = true;
      G.ast.nil_material.texture_layers = 1;
      G.ast.nil_material.tex = texture;
    }
  }

  // Init material array
  {
    using,only(pie) G.ast;

    G.ast.materials = NewArray(pie.materials.count, Material);
    for *G.ast.materials
    {
      pie_material := *pie.materials[it_index];
      it.key = MaterialKey(PIE_LOAD_ListToString(pie_material.name));
      it.params = pie_material.params;
      it.has_texture = pie_material.tex.format != .Empty;
      it.texture_layers = pie_material.tex.layers;
      if (!it.has_texture)
      {
        // no texture = it is already fully loaded
        it.stream.flags |= .LOADED;
        it.stream.loaded_t = 1;
      }
      it.tex = G.ast.nil_material.tex; // fallback texture as default in case anybody tries to use it
    }
  }
}

// MODELS
ASSET_InitModels :: ()
{
  using,only(pie) G.ast;

  // Load meshes
  {
    G.ast.model_vertices = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_VERTEX,
      pie.links.models.vertices.size,
      "WORLD vertices");
    G.ast.model_indices = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_INDEX,
      pie.links.models.indices.size,
      "Model indices");

    vertices_string := PIE_LOAD_ListToString(pie.links.models.vertices);
    indices_string := PIE_LOAD_ListToString(pie.links.models.indices);

    cmd := SDL_AcquireGPUCommandBuffer(G.gpu.device);
    GPU_TransferBuffer(cmd, G.ast.model_vertices, vertices_string.data, xx vertices_string.count);
    GPU_TransferBuffer(cmd, G.ast.model_indices, indices_string.data, xx indices_string.count);
    SDL_SubmitGPUCommandBuffer(cmd);
  }

  G.ast.models = NewArray(pie.models.count, Model);

  for *model: G.ast.models
  {
    pie_model := *pie.models[it_index];

    model.key = ModelKey(PIE_LOAD_ListToString(pie_model.name));
    model.is_skinned = !!pie_model.is_skinned;

    if pie_model.is_skinned &&
      PIE_LOAD_Check(pie_model.skeleton_index < G.ast.skeletons.count,
        tprint("Pie model skeleton index (%) is out of bounds (count=%).", pie_model.skeleton_index, G.ast.skeletons.count),
        critical = false)
    {
      model.skeleton = *G.ast.skeletons[pie_model.skeleton_index];
    }

    pie_meshes := PIE_LOAD_ListToArray(pie_model.meshes);
    model.meshes = NewArray(pie_meshes.count, Mesh);

    for *mesh: model.meshes
    {
      pie_mesh := *pie_meshes[it_index];

      if PIE_LOAD_Check(pie_mesh.material_index < G.ast.materials.count,
        tprint("Pie mesh material index (%) is out of bounds (count=%).", pie_mesh.material_index, G.ast.materials.count),
        critical = false)
      {
        mesh.material = G.ast.materials[pie_mesh.material_index].key;
      }

      mesh.vertices_start_index = pie_mesh.vertices_start_index;
      mesh.indices_start_index = pie_mesh.indices_start_index;
      mesh.indices_count = pie_mesh.indices_count;
    }
  }
}

// SKELETONS
ASSET_InitSkeletons :: ()
{
  using,only(pie) G.ast;

  pie_skeletons := PIE_LOAD_ListToArray(pie.links.skeletons);
  G.ast.skeletons = NewArray(pie_skeletons.count, Skeleton);

  for *skel: G.ast.skeletons
  {
    pie_skel := *pie_skeletons[it_index];
    skel.root_transform = pie_skel.root_transform;

    skel.inverse_matrices   = PIE_LOAD_ListToArray(pie_skel.inverse_matrices);
    skel.child_index_buffer = PIE_LOAD_ListToArray(pie_skel.child_index_buffer);
    skel.child_index_ranges = PIE_LOAD_ListToArray(pie_skel.child_index_ranges);
    skel.bind_translations  = PIE_LOAD_ListToArray(pie_skel.translations);
    skel.bind_rotations     = PIE_LOAD_ListToArray(pie_skel.rotations);
    skel.bind_scales        = PIE_LOAD_ListToArray(pie_skel.scales);
    name_ranges            := PIE_LOAD_ListToArray(pie_skel.name_ranges);
    skel.joints_count       = xx skel.inverse_matrices.count;
    PIE_LOAD_Check(skel.joints_count == skel.inverse_matrices.count, "joints_count != inverse_matrices.count");
    PIE_LOAD_Check(skel.joints_count == skel.child_index_buffer.count, "joints_count != child_index_buffer.count");
    PIE_LOAD_Check(skel.joints_count == skel.child_index_ranges.count, "joints_count != child_index_ranges.count");
    PIE_LOAD_Check(skel.joints_count == skel.bind_translations.count, "joints_count != bind_translations.count");
    PIE_LOAD_Check(skel.joints_count == skel.bind_rotations.count, "joints_count != bind_rotations.count");
    PIE_LOAD_Check(skel.joints_count == skel.bind_scales.count, "joints_count != bind_scales.count");
    PIE_LOAD_Check(skel.joints_count == name_ranges.count, "joints_count != name_ranges.count");
    if pie.err  return;

    skel.joint_names = NewArray(name_ranges.count, string);
    for *skel.joint_names
      it.* = STR_Substring(PIE_LOAD_File(), name_ranges[it_index].min, name_ranges[it_index].max);

    // Animations
    pie_anims := PIE_LOAD_ListToArray(pie_skel.anims);
    skel.animations = NewArray(pie_anims.count, Animation);

    for *anim: skel.animations
    {
      pie_anim := *pie_anims[it_index];

      anim.name = PIE_LOAD_ListToString(pie_anim.name);
      anim.t_min = pie_anim.t_min;
      anim.t_max = pie_anim.t_max;

      pie_channels := PIE_LOAD_ListToArray(pie_anim.channels);
      anim.channels = NewArray(pie_channels.count, ANIMATION_Channel);

      for *chan: anim.channels
      {
        pie_chan := *pie_channels[it_index];

        pie_joint_index := ((pie_chan.joint_index30_type2 << 2) >> 2).(u32);
        pie_transform_type := cast(PIE_AnimationChannelType) (pie_chan.joint_index30_type2 >> 30);
        chan.joint_index = pie_joint_index;
        chan.type = pie_transform_type;
        chan.inputs = PIE_LOAD_ListToArray(pie_chan.inputs);

        comp_count := ifx chan.type == .Rotation then 4 else 3;
        PIE_LOAD_Check(comp_count * chan.inputs.count * size_of(float) == pie_chan.outputs.size,
          tprint("Animation channel %*%*% != %", comp_count, chan.inputs.count, size_of(float), pie_chan.outputs.size));
        chan.outputs = PIE_LOAD_ListToArray(pie_chan.outputs);
      }
    }
  }
}
