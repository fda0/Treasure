#scope_file;
using,only(AST,G,GPU) COMPS;
#scope_export;

AST_LoadAssetFile :: ()
{
  AST_LoadPieFile("assets.pie");
  if !AST.error {
    expected := EnumCount(ShaderType);
    if AST.shaders.count != expected {
      AST_Error("Expected % shaders, found %.", AST.shaders.count, expected);
    }
  }
  if !AST.error AST_LoadSkeletons();
  if !AST.error AST_LoadMaterials();
  if !AST.error AST_LoadModelsAndUploadToGPU();

  AST_ShowErrorsToUser();
}

AST_ContinueLoadAssetFileWithGPU :: ()
{
  if !AST.error AST_UploadVerticesAndIndices();

  if !AST.error
  {
    // Texture thread init
    init(*AST.tex_semaphore);
    AST.tex_thread.starting_context = context;
    thread_init(*AST.tex_thread, AST_TextureUploadThread);
    thread_start(*AST.tex_thread);
  }

  AST_ShowErrorsToUser();
}

AST_ShowErrorsToUser :: ()
{
  if AST.error
  {
    if AST.error_message
    {
      push_allocator(temp);
      header := tprint("Treasure error - couldn't load %", AST.file_path);

      MessageBoxW(null,
        utf8_to_wide(AST.error_message),
        utf8_to_wide(header),
        MB_OK | MB_ICONERROR | MB_TOPMOST);
      AST.error_message = "";
    }
    exit(100);
  }
}

AST_Error :: (message := "", args: .. Any, loc := #caller_location)
{
  push_allocator(temp);

  b: String_Builder;
  init_string_builder(*b);

  print_to_builder(*b, "While loading % the game encountered following error:\n", AST.file_path);
  print_to_builder(*b, message, ..args);
  print_to_builder(*b, "\n\nCode location: %:%", String.path_filename(loc.fully_pathed_filename), loc.line_number);
  msg := builder_to_string(*b);

  log_error(msg);

  AST.error = true;
  if !AST.error_message {
    AST.error_message = msg;
  }
}

AST_PostFrame :: ()
{
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
    if it.stream.flags & .LOADED {
      it.stream.loaded_t = min(1.0, it.stream.loaded_t + G.dt * LOAD_T_SPEED);
    }
  }
}

//
// Load file
//
AST_LoadPieFile :: (file_path: string)
{
  AST.file_path = file_path;
  file, read_success := read_entire_file(file_path);
  AST.file = file;

  if !read_success {
    AST_Error("Failed to open file.");
    return;
  }

  if file.count < size_of(PIE_Header) {
    AST_Error("Asset file is too small to fit the header.");
    return;
  }

  header := file.data.(*PIE_Header);
  hashable := Skip(file, size_of(type_of(header.file_hash)));
  calculated_hash := Hash64Any(PIE_MAGIC_HASH_SEED, hashable);
  if calculated_hash != header.file_hash {
    AST_Error("Computed hash (%) doesn't match file hash (%).", calculated_hash, header.file_hash);
    return;
  }

  if header.links.count != 1 {
    AST_Error("Expected a header with exactly one link, got: %", header.links.count);
    return;
  }

  address_offset := file.data.(s64);
  PatchOffset :: (target: *$T) #expand
  {
    data: *s64 = xx *target.data;
    if (data.* == 0) return;

    // Collect target parameters
    size_bytes := target.count;
    align := 1;
    #if type_info(T).type == .ARRAY
    {
      size_bytes = array_size_bytes(target.*);
      align = array_align_of(target.*);
    }

    // Validate offset underflow / overflow.
    if data.* < 0
    {
      AST_Error("Offset underflow found.");
      `return;
    }

    if (data.* + size_bytes) > file.count
    {
      AST_Error("Offset overflow found.");
      `return;
    }

    // Patch offset
    data.* += address_offset;

    // Validate that patched address is aligned.
    if (data.* % align != 0)
    {
      AST_Error("Asset file contains unaligned data.");
      `return;
    }
  }

  // Patch addresses
  PatchOffset(*header.links);
  links := *header.links[0];

  PatchOffset(*links.vertices);
  PatchOffset(*links.indices);
  PatchOffset(*links.models);
  PatchOffset(*links.skeletons);
  PatchOffset(*links.materials);
  PatchOffset(*links.shaders);
  PatchOffset(*links.fonts);
  PatchOffset(*links.sounds);

  for * links.models {
    PatchOffset(*it.name);
    PatchOffset(*it.meshes);
  }

  for * links.skeletons {
    PatchOffset(*it.inverse_matrices);
    PatchOffset(*it.child_index_buffer);
    PatchOffset(*it.child_index_ranges);
    PatchOffset(*it.bind_translations);
    PatchOffset(*it.bind_rotations);
    PatchOffset(*it.bind_scales);
    PatchOffset(*it.names);
    PatchOffset(*it.animations);

    for * it.names {
      PatchOffset(it);
    }

    for * it.animations {
      PatchOffset(*it.name);
      PatchOffset(*it.channels);

      for * it.channels {
        PatchOffset(*it.inputs);
        PatchOffset(*it.outputs);
      }
    }
  }

  for * links.materials {
    PatchOffset(*it.name);
    PatchOffset(*it.tex.buffer);
    PatchOffset(*it.tex.sections);
  }

  for * links.shaders {
    PatchOffset(*it.buffer);
    PatchOffset(*it.info);
  }

  for * links.fonts {
    PatchOffset(*it.buffer);
    PatchOffset(*it.info);
  }

  for * links.sounds {
    PatchOffset(*it.buffer);
  }

  // set AST.pie members
  AST.file = file;
  AST.links = links;
}

//
// Materials thread
//
AST_TextureUploadThread :: (thread: *Thread) -> s64
{
  PerfThreadName("Texture upload thread");

  // This thread just touched the same global data as the main thread.
  // Any false-sharing etc wasn't a concern when making this and it could be improved.
  while true
  {
    wait_for(*AST.tex_semaphore);
    now := TimeNow();

    for *AST.materials {
      if Elapsed(now, it.stream.last_touched) < 0.5 {
        AST_LoadTextureFromPieToGPU(it, it_index);
      }
    }

    reset_temporary_storage();
  }
  return 0;
}

AST_LoadTextureFromPieToGPU :: (material: *Material, material_index: s64)
{
  if material.stream.flags & (.LOADED | .ERROR) {
    return;
  }

  lods_count := material.tex.lods;
  generate_lods := false;
  if (lods_count == 1 && material.tex.format != .BC7_RGBA)
  {
    lods_count = CalculateMipMapCount(material.tex.width, material.tex.height);
    generate_lods = true;
  }

  // Create texture and transfer CPU memory -> GPU memory -> GPU texture
  texture: *SDL_GPUTexture;
  {
    transfer_create_info := SDL_GPUTransferBufferCreateInfo.{
      usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
      size = xx (material.tex.buffer.count * 4) // @todo why *4?
    };
    transfer := SDL_CreateGPUTransferBuffer(GPU.device, *transfer_create_info);

    // CPU -> GPU
    {
      gpu_mapped := SDL_MapGPUTransferBuffer(GPU.device, transfer, false);
      memcpy(gpu_mapped, material.tex.buffer.data, material.tex.buffer.count);
      SDL_UnmapGPUTransferBuffer(GPU.device, transfer);
    }

    // Create texture
    {
      sdl_format: SDL_GPUTextureFormat = ifx material.tex.format == .R8G8B8A8 then .R8G8B8A8_UNORM else .BC7_RGBA_UNORM;

      texture_info := SDL_GPUTextureCreateInfo.{
        type = .SDL_GPU_TEXTURETYPE_2D_ARRAY,
        format = sdl_format,
        width = xx material.tex.width,
        height = xx material.tex.height,
        layer_count_or_depth = xx material.tex.layers,
        num_levels = xx lods_count,
        usage = SDL_GPU_TEXTUREUSAGE_SAMPLER
      };

      if (generate_lods)
        texture_info.usage |= SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;

      texture = SDL_CreateGPUTexture(GPU.device, *texture_info);
      debug_texture_name := tprint("tex.pie: %", material.name);
      SDL_SetGPUTextureName(GPU.device, texture, temp_c_string(debug_texture_name));
    }

    // GPU memory -> GPU texture
    {
      cmd := SDL_AcquireGPUCommandBuffer(GPU.device);
      copy_pass := SDL_BeginGPUCopyPass(cmd);

      for material.tex.sections
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

  material.texture_handle = texture;
  material.stream.flags |= .LOADED;
}

AST_LoadMaterials :: ()
{
  AST.materials = NewArray(AST.links.materials.count + 1, Material); // +1 for nil

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
    nil_material := *AST.materials[0];
    nil_material.stream.flags |= .LOADED;
    nil_material.stream.loaded_t = 1;
    nil_material.tex.format = .R8G8B8A8;
    nil_material.tex.layers = 1;
    nil_material.texture_handle = texture;
  }

  // Init material array
  for AST.links.materials
  {
    material := *AST.materials[it_index + 1];
    material.pie = it;

    if !material.tex.format
    {
      // no texture = it is already fully loaded
      material.stream.flags |= .LOADED;
      material.stream.loaded_t = 1;
    }

    // Set fallback texture as default in case anybody tries to use it.
    material.texture_handle = AST.materials[0].texture_handle;
  }

  // Fill alias -> slot mapping
  for material, material_slot: AST.materials
  {
    material_alias := AliasFromName(MaterialAlias, material.name);
    if material_alias > 0 {
      AST.material_alias_to_slot[material_alias] = xx material_slot;
    }
  }
}

//
// Models
//
AST_LoadModelsAndUploadToGPU :: ()
{
  for * model: AST.models
  {
    if model.is_skinned
    {
      if xx model.skeleton_slot >= AST.skeletons.count
      {
        AST_Error("Skeleton index overflow");
        return;
      }
    }

    for * mesh: model.meshes
    {
      if !is_index_in_bounds(AST.links.materials, xx mesh.material_slot)
      {
        AST_Error("Pie mesh material index (%) is out of bounds (count=%).", mesh.material_slot, AST.materials.count);
        return;
      }

      mesh.material_slot += 1; // correct for additional nil material
    }
  }

  // Set default alias -> slot mapping to Bed model
  {
    bed_slot: ModelSlot;
    for AST.models {
      if it.name == "Bed" {
        bed_slot = xx it_index;
      }
    }

    for * AST.model_alias_to_slot {
      it.* = bed_slot;
    }
  }

  // Create alias -> slot mapping for models
  for model, model_slot: AST.models
  {
    model_alias := AliasFromName(ModelAlias, model.name);
    if model_alias > 0 {
      AST.model_alias_to_slot[model_alias] = xx model_slot;
    }
  }
}

AST_UploadVerticesAndIndices :: ()
{
  AST.model_vertices = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_VERTEX, xx array_size_bytes(AST.vertices), "WORLD vertices");
  AST.model_indices = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_INDEX, xx array_size_bytes(AST.indices), "Model indices");

  cmd := SDL_AcquireGPUCommandBuffer(GPU.device);
  GPU_TransferBuffer(cmd, AST.model_vertices, AST.vertices.data, xx array_size_bytes(AST.vertices));
  GPU_TransferBuffer(cmd, AST.model_indices, AST.indices.data, xx array_size_bytes(AST.indices));
  SDL_SubmitGPUCommandBuffer(cmd);
}

AST_LoadSkeletons :: ()
{
  AST.skeletons = NewArray(AST.links.skeletons.count, Skeleton);
  for * skeleton: AST.skeletons
  {
    skeleton.pie = AST.links.skeletons[it_index];
    skeleton.joints_count = skeleton.inverse_matrices.count;

    if (skeleton.joints_count != skeleton.names.count ||
        skeleton.joints_count != skeleton.inverse_matrices.count ||
        skeleton.joints_count != skeleton.child_index_buffer.count ||
        skeleton.joints_count != skeleton.child_index_ranges.count ||
        skeleton.joints_count != skeleton.bind_translations.count ||
        skeleton.joints_count != skeleton.bind_rotations.count ||
        skeleton.joints_count != skeleton.bind_scales.count)
    {
      AST_Error("Joints count mismatch detected");
      return;
    }

    for skeleton.animations
    {
      for it.channels
      {
        comp_count := ifx it.type == .Rotation then 4 else 3;
        if !(comp_count * it.inputs.count * size_of(float) == array_size_bytes(it.outputs)) {
          AST_Error("Animation channel %*%*% != %", comp_count, it.inputs.count, size_of(float), array_size_bytes(it.outputs));
          return;
        }
      }
    }
  }
}
