#scope_file;
using,only(AST,G,GPU) COMPS;
#scope_export;

ASSET_InitPreGPU :: ()
{
  ASSET_LoadPieFile("assets.pie");
}

ASSET_InitPostGPU :: ()
{
  // Texture thread init
  init(*AST.tex_semaphore);
  AST.tex_thread.starting_context = context;
  thread_init(*AST.tex_thread, ASSET_TextureThreadEntry);
  thread_start(*AST.tex_thread);
}

ASSET_PostFrame :: ()
{
  PerfFunc();

  // Wake up texture asset loading thread
  if AST.tex_load_needed
  {
    signal(*AST.tex_semaphore);
    AST.tex_load_needed = false;
  }

  // Increment loaded_t
  for *AST.materials
  {
    LOAD_T_SPEED :: 10.0;
    using it.stream;
    if flags & .LOADED
      loaded_t = min(1.0, loaded_t + G.dt * LOAD_T_SPEED);
  }
}

// ASSET_Error :: log;
ASSET_Error :: #bake_arguments assert(arg = false);

ASSET_InitSounds :: ()
{
  AST.sounds = NewArray(AST.pie.sounds.count, AUDIO_Sound);
  for AST.pie.sounds
  {
    // @todo reduce boilerplate on the whole [.pie -> in game memory] transformations
    AST.sounds[it_index].data = it.buffer;
    AST.sounds[it_index].format = it.format;
  }
}

// TEXTURE THREAD
ASSET_TextureThreadEntry :: (thread: *Thread) -> s64
{
  PerfThreadName("TR texture loading");

  // This thread just touched the same global data as the main thread.
  // Any false-sharing etc wasn't a concern when making this and it could be improved.
  while true
  {
    wait_for(*AST.tex_semaphore);

    // Just load any texture that was used in the last 2 frames.
    // Do something smarter when texture eviction is added.
    min_load_frame := max(1, G.frame_number - 2);
    log("Attempting to load an asset with min_load_frame: %", min_load_frame);

    for *AST.materials
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
  pie_material := *AST.pie.materials[material_index - 1];
  material_buffer := pie_material.tex.buffer;

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
      size = xx (material_buffer.count * 4) // @todo why *4?
    };
    transfer := SDL_CreateGPUTransferBuffer(GPU.device, *transfer_create_info);

    // CPU -> GPU
    {
      gpu_mapped := SDL_MapGPUTransferBuffer(GPU.device, transfer, false);
      memcpy(gpu_mapped, material_buffer.data, material_buffer.count);
      SDL_UnmapGPUTransferBuffer(GPU.device, transfer);
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

      texture = SDL_CreateGPUTexture(GPU.device, *texture_info);
      debug_texture_name := tprint("tex.pie: %", pie_material.name);
      SDL_SetGPUTextureName(GPU.device, texture, temp_c_string(debug_texture_name));
    }

    // GPU memory -> GPU texture
    {
      cmd := SDL_AcquireGPUCommandBuffer(GPU.device);
      copy_pass := SDL_BeginGPUCopyPass(cmd);

      for pie_material.tex.sections
      {
        source := SDL_GPUTextureTransferInfo.{
          transfer_buffer = transfer,
          offset = xx it.data_offset,
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

    SDL_ReleaseGPUTransferBuffer(GPU.device, transfer);
  }

  material.tex = texture;
  material.stream.flags |= .LOADED;
}

file_:string;
address_patch_: s64;

// LOAD .PIE
ASSET_LoadPieFile :: (file_path: string)
{
  desc := tprint("[Processing asset file %]", file_path);

  file, read_success := read_entire_file(file_path);
  file_ = file;

  if !read_success {
    ASSET_Error("% Failed to open file", desc);
    return;
  }

  if file.count < size_of(PIE_Header) {
    ASSET_Error("% Asset file can't fit header", desc);
    return;
  }

  header := file.data.(*PIE_Header);

  hashable := Skip(file, size_of(type_of(header.file_hash)));
  calculated_hash := Hash64Any(PIE_MAGIC_HASH_SEED, hashable);
  if calculated_hash != header.file_hash {
    ASSET_Error("% Calculated (%) doesn't match file hash (%).", desc, calculated_hash, header.file_hash);
    return;
  }

  if header.links.count != 1 {
    ASSET_Error("% Expected a header with exactly one link, got: %", desc, header.links.count);
    return;
  }

  address_patch := file.data.(s64);
  address_patch_ = address_patch;
  Patch :: (list: *$T)
  {
    desc := "@todo";

    data: *s64 = xx *list.data;
    size_bytes := list.count;
    align := 1;
    #if type_info(T).type == .ARRAY {
      size_bytes = array_size_bytes(list.*);
      align = array_align_of(list.*);
    }

    // Check list underflow / overflow
    list_end := data.* + size_bytes;
    if data.* < 0 {
      ASSET_Error("% Found a list that underflows", desc);
      return;
    }
    if list_end > file_.count {
      ASSET_Error("% Found a list that overflows", desc);
      return;
    }

    data.* += address_patch_;
    if (data.* % align != 0) {
      ASSET_Error("% Asset file contains unaligned data", desc);
      return;
    }
  }

  // Patch all lists
  Patch(*header.links);
  links := *header.links[0];

  Patch(*links.vertices);
  Patch(*links.indices);
  Patch(*links.models);
  Patch(*links.skeletons);
  Patch(*links.materials);
  Patch(*links.shaders);
  Patch(*links.fonts);
  Patch(*links.sounds);

  for * links.models {
    Patch(*it.name);
    Patch(*it.meshes);
  }

  for * links.skeletons {
    skel := it;

    Patch(*it.inverse_matrices);
    Patch(*it.child_index_buffer);
    Patch(*it.child_index_ranges);
    Patch(*it.translations);
    Patch(*it.rotations);
    Patch(*it.scales);
    Patch(*it.names);
    Patch(*it.anims);

    for * it.names {
      Patch(it);
    }

    for * it.anims {
      Patch(*it.name);
      Patch(*it.channels);

      for * it.channels {
        Patch(*it.inputs);
        Patch(*it.outputs);
      }
    }
  }

  for * links.materials {
    Patch(*it.name);
    Patch(*it.tex.buffer);
    Patch(*it.tex.sections);
  }

  for * links.shaders {
    Patch(*it.buffer);
    Patch(*it.info);
  }

  for * links.fonts {
    Patch(*it.buffer);
    Patch(*it.info);
  }

  for * links.sounds {
    Patch(*it.buffer);
  }

  // set AST.pie members
  AST.pie.file = file;
  AST.pie.header = header;
  AST.pie.links = links;

  AST.pie.vertices = links.vertices;
  AST.pie.indices = links.indices;
  AST.pie.models = links.models;
  AST.pie.materials = links.materials;
  AST.pie.shaders = links.shaders;
  AST.pie.fonts = links.fonts;
  AST.pie.sounds = links.sounds;

  ASSET_InitSkeletons();
  ASSET_InitMaterials();
  ASSET_InitModels();
  ASSET_InitSounds();
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
    texture := SDL_CreateGPUTexture(GPU.device, *tex_info);
    SDL_SetGPUTextureName(GPU.device, texture, "Fallback texture");

    // Fill texture
    {
      trans_desc := SDL_GPUTransferBufferCreateInfo.{
        usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        size = tex_size,
      };
      trans_buf := SDL_CreateGPUTransferBuffer(GPU.device, *trans_desc);
      assert(!!trans_buf, "@todo handle this error? or remove assert");

      // Fill GPU memory
      {
        map: *u32 = SDL_MapGPUTransferBuffer(GPU.device, trans_buf, false);
        pixel := map;
        for y: MakeRange(dim)
        {
          for x: MakeRange(dim)
          {
            pixel[0] = xx ifx x & y & and_mask then 0xff000000 else 0xffFF00FF;
            pixel += 1;
          }
        }
        SDL_UnmapGPUTransferBuffer(GPU.device, trans_buf);
      }

      // GPU memory -> GPU buffers
      {
        cmd := SDL_AcquireGPUCommandBuffer(GPU.device);
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
      SDL_ReleaseGPUTransferBuffer(GPU.device, trans_buf);
    }

    // Generate texture mipmap
    {
      cmd := SDL_AcquireGPUCommandBuffer(GPU.device);
      SDL_GenerateMipmapsForGPUTexture(cmd, texture);
      SDL_SubmitGPUCommandBuffer(cmd);
    }

    // Fill nil_material data
    nil_material := array_add(*AST.materials);
    nil_material.stream.flags |= .LOADED;
    nil_material.stream.loaded_t = 1;
    nil_material.has_texture = true;
    nil_material.texture_layers = 1;
    nil_material.tex = texture;
  }

  // Init material array
  for AST.pie.materials
  {
    ast_mat := array_add(*AST.materials);
    ast_mat.name = it.name;
    ast_mat.hash = AssetHashFromName(.Material, ast_mat.name);
    ast_mat.params = it.params;
    ast_mat.has_texture = it.tex.format != .Empty;
    ast_mat.texture_layers = it.tex.layers;
    if !ast_mat.has_texture
    {
      // no texture = it is already fully loaded
      ast_mat.stream.flags |= .LOADED;
      ast_mat.stream.loaded_t = 1;
    }
    ast_mat.tex = AST.materials[0].tex; // fallback texture as default in case anybody tries to use it
  }

  // fill material_id_to_idx
  for material, material_slot: AST.materials
  {
    material_id := AssetIDFromAssetHash(MaterialID, material.hash);
    if material_id > 0 {
      AST.material_id_to_slot[material_id] = xx material_slot;
    }
  }
}

// MODELS
ASSET_InitModels :: () #expand
{
  // Load meshes
  {
    AST.model_vertices = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_VERTEX, xx array_size_bytes(AST.pie.vertices), "WORLD vertices");
    AST.model_indices = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_INDEX, xx array_size_bytes(AST.pie.indices), "Model indices");

    cmd := SDL_AcquireGPUCommandBuffer(GPU.device);
    GPU_TransferBuffer(cmd, AST.model_vertices, AST.pie.vertices.data, xx array_size_bytes(AST.pie.vertices));
    GPU_TransferBuffer(cmd, AST.model_indices, AST.pie.indices.data, xx array_size_bytes(AST.pie.indices));
    SDL_SubmitGPUCommandBuffer(cmd);
  }

  // Alloc nil_model... not really used right now...
  {
    nil_nodel := array_add(*AST.models);
  }

  for pie_model: AST.pie.models
  {
    model := array_add(*AST.models);
    model.name = pie_model.name;
    model.hash = AssetHashFromName(.Model, model.name);
    model.is_skinned = !!pie_model.is_skinned;

    if pie_model.is_skinned
    {
      if pie_model.skeleton_index >= AST.skeletons.count {
        ASSET_Error("% Wkeleton index overflow", `desc);
        `return;
      }

      model.skeleton = *AST.skeletons[pie_model.skeleton_index];
    }

    model.meshes = NewArray(pie_model.meshes.count, Mesh);
    for *mesh: model.meshes
    {
      pie_mesh := *pie_model.meshes[it_index];

      if !is_index_in_bounds(AST.materials, pie_mesh.material_index)
      {
        ASSET_Error("Pie mesh material index (%) is out of bounds (count=%).", pie_mesh.material_index, AST.materials.count);
        `return;
      }

      mesh.material_slot = pie_mesh.material_index + 1;
      mesh.vertices_start_index = pie_mesh.vertices_start_index;
      mesh.indices_start_index = pie_mesh.indices_start_index;
      mesh.indices_count = pie_mesh.indices_count;
    }
  }

  // set default model_id_to_idx to Bed model
  {
    bed_slot: ModelSlot = 1;
    for AST.models {
      if it.name == "Bed" {
        bed_slot = xx it_index;
      }
    }

    for * AST.model_id_to_slot {
      it.* = bed_slot;
    }
  }

  // fill model_id_to_idx
  for model, model_slot: AST.models
  {
    model_id := AssetIDFromAssetHash(ModelID, model.hash);
    if model_id > 0 {
      AST.model_id_to_slot[model_id] = xx model_slot;
    }
  }
}

// SKELETONS
ASSET_InitSkeletons :: ()
{
  desc := "@todo";

  AST.skeletons = NewArray(AST.pie.links.skeletons.count, Skeleton);
  for * skel: AST.skeletons
  {
    pie_skel := *AST.pie.links.skeletons[it_index];
    skel.root_transform = pie_skel.root_transform;

    skel.inverse_matrices   = pie_skel.inverse_matrices;
    skel.child_index_buffer = pie_skel.child_index_buffer;
    skel.child_index_ranges = pie_skel.child_index_ranges;
    skel.bind_translations  = pie_skel.translations;
    skel.bind_rotations     = pie_skel.rotations;
    skel.bind_scales        = pie_skel.scales;
    skel.joint_names        = pie_skel.names;
    skel.joints_count       = xx skel.inverse_matrices.count;

    if (skel.joints_count != skel.inverse_matrices.count ||
        skel.joints_count != skel.child_index_buffer.count ||
        skel.joints_count != skel.child_index_ranges.count ||
        skel.joints_count != skel.bind_translations.count ||
        skel.joints_count != skel.bind_rotations.count ||
        skel.joints_count != skel.bind_scales.count ||
        skel.joints_count != skel.joint_names.count)
    {
      ASSET_Error("% joints count mismatch detected", desc);
      return;
    }

    // Animations
    skel.animations = NewArray(pie_skel.anims.count, Animation);
    for * anim: skel.animations
    {
      pie_anim := *pie_skel.anims[it_index];

      anim.name = pie_anim.name;
      anim.t_min = pie_anim.t_min;
      anim.t_max = pie_anim.t_max;

      anim.channels = NewArray(pie_anim.channels.count, AnimationChannel);
      for *chan: anim.channels
      {
        pie_chan := *pie_anim.channels[it_index];

        pie_joint_index := ((pie_chan.joint_index30_type2 << 2) >> 2).(u32);
        pie_transform_type := cast(PIE_AnimationChannelType) (pie_chan.joint_index30_type2 >> 30);
        chan.joint_index = pie_joint_index;
        chan.type = pie_transform_type;
        chan.inputs = pie_chan.inputs;

        comp_count := ifx chan.type == .Rotation then 4 else 3;
        if !(comp_count * chan.inputs.count * size_of(float) == array_size_bytes(pie_chan.outputs)) {
          ASSET_Error("Animation channel %*%*% != %", comp_count, chan.inputs.count, size_of(float), array_size_bytes(pie_chan.outputs));
          return;
        }

        chan.outputs = pie_chan.outputs;
      }
    }
  }
}
