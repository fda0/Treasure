#scope_file;
using,only(AST,DEV,FONT,G,GPU,RD) COMPS;
#scope_export;

GPU_USE_MSAA :: true;
GPU_SHADOW_MAP_DIM :: 2048*2;
GPU_ENABLE_BACKFACE_CULL :: 0;
GPU_CLEAR_DEPTH_FLOAT :: 1.0;
GPU_CLEAR_COLOR_R :: 0.78;
GPU_CLEAR_COLOR_G :: 0.78;
GPU_CLEAR_COLOR_B :: 0.96;
GPU_CLEAR_COLOR_A :: 1.0;
GPU_CLEAR_OUTLINES :: -1.0;

GPU_FrameReadback :: struct
{
  fence: *SDL_GPUFence;
  download_transfer_buffer: *SDL_GPUTransferBuffer;
  dim: Vec2(s32);
  out_of_screen: bool;
}

GPU_State :: struct
{
  // GPU device
  device: *SDL_GPUDevice;

  //
  // World pass
  //

  // Currently bound uniform
  world_uniform: RD_WorldUniform;
  bound_vertex_uniform_hash: u64;
  bound_fragment_uniform_hash: u64;

  // Pipeline, sample settings
  sample_count: SDL_GPUSampleCount;
  world_pipelines: [2] *SDL_GPUGraphicsPipeline; // 0: 4xMSAA; 1: no AA (for shadow mapping)

  // World target
  tex_msaa: *SDL_GPUTexture;
  tex_resolve: *SDL_GPUTexture;
  tex_world_depth: *SDL_GPUTexture;
  material_sampler: *SDL_GPUSampler;
  dummy_instance_buffer: *SDL_GPUBuffer;

  // World sun target
  shadow_tex: *SDL_GPUTexture;
  dummy_shadow_tex: *SDL_GPUTexture; // bound in shadowmap prepass; @todo delete?
  sampl_shadow: *SDL_GPUSampler;

  // Mouse picking target
  mouse_picking_readback_queue: Queue(8, GPU_FrameReadback);
  tex_mouse_picking: *SDL_GPUTexture;
  tex_mouse_picking_depth: *SDL_GPUTexture;

  //
  // Outline pass
  //
  outline_visualize_pipeline: *SDL_GPUGraphicsPipeline;
  outline_propagate_pipeline: *SDL_GPUGraphicsPipeline;
  outline_textures: [2] *SDL_GPUTexture;
  outline_texture_index: s64; // points to recently written texture from outline_textures
  outline_sampler: *SDL_GPUSampler;

  //
  // UI pass
  //
  ui_pipeline: *SDL_GPUGraphicsPipeline;
  ui_atlas_texture: *SDL_GPUTexture;
  ui_atlas_sampler: *SDL_GPUSampler;
  ui_indices: *SDL_GPUBuffer;
  ui_shape_buffer: *SDL_GPUBuffer;

  //
  // SDL properties
  //
  clear_color_props: SDL_PropertiesID;
  clear_mouse_picking_props: SDL_PropertiesID;
  clear_outline_props: SDL_PropertiesID;
  clear_depth_props: SDL_PropertiesID;
}

GPU_RenderWorldMode :: enum
{
  RENDER;
  DEPTH;
  MOUSE_PICKING;
}

GPU_Init :: ()
{
  // preapre props
  {
    GPU.clear_color_props = SDL_CreateProperties();
    SDL_SetFloatProperty(GPU.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_R_FLOAT, GPU_CLEAR_COLOR_R);
    SDL_SetFloatProperty(GPU.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_G_FLOAT, GPU_CLEAR_COLOR_G);
    SDL_SetFloatProperty(GPU.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_B_FLOAT, GPU_CLEAR_COLOR_B);
    SDL_SetFloatProperty(GPU.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_A_FLOAT, GPU_CLEAR_COLOR_A);

    GPU.clear_mouse_picking_props = SDL_CreateProperties();
    SDL_SetFloatProperty(GPU.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_R_FLOAT, 0.0);
    SDL_SetFloatProperty(GPU.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_G_FLOAT, 0.0);
    SDL_SetFloatProperty(GPU.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_B_FLOAT, 0.0);
    SDL_SetFloatProperty(GPU.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_A_FLOAT, 0.0);

    GPU.clear_outline_props = SDL_CreateProperties();
    SDL_SetFloatProperty(GPU.clear_outline_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_R_FLOAT, GPU_CLEAR_OUTLINES);
    SDL_SetFloatProperty(GPU.clear_outline_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_G_FLOAT, GPU_CLEAR_OUTLINES);

    GPU.clear_depth_props = SDL_CreateProperties();
    SDL_SetFloatProperty(GPU.clear_depth_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_DEPTH_FLOAT, GPU_CLEAR_DEPTH_FLOAT);
  }

  // check for msaa 4 support
  GPU.sample_count = .SDL_GPU_SAMPLECOUNT_1;
  if (GPU_USE_MSAA)
  {
    tex_format := SDL_GetGPUSwapchainTextureFormat(GPU.device, G.window);
    supports_msaa := SDL_GPUTextureSupportsSampleCount(GPU.device, tex_format, .SDL_GPU_SAMPLECOUNT_4);
    if (supports_msaa) {
      GPU.sample_count = .SDL_GPU_SAMPLECOUNT_4;
    }
  }

  // Material texture sampler
  {
    sampler_info := SDL_GPUSamplerCreateInfo.{
      min_filter = .LINEAR,
      mag_filter = .LINEAR,
      mipmap_mode = .LINEAR,
      address_mode_u = .REPEAT,
      address_mode_v = .REPEAT,
      address_mode_w = .REPEAT,
      min_lod = 0,
      max_lod = 100,
    };
    GPU.material_sampler = SDL_CreateGPUSampler(GPU.device, *sampler_info);
  }

  GPU.dummy_instance_buffer = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ, xx Kilobyte(1), "dummy_instance_buffer");

  // Shadow map
  {
    GPU.shadow_tex = GPU_CreateDepthTexture("shadow_tex", GPU_SHADOW_MAP_DIM, GPU_SHADOW_MAP_DIM, true, true);
    GPU.dummy_shadow_tex = GPU_CreateDepthTexture("dummy_shadow_tex", 16, 16, true, true);

    sampler_info := SDL_GPUSamplerCreateInfo.{
      min_filter = .LINEAR,
      mag_filter = .LINEAR,
      mipmap_mode = .LINEAR,
      address_mode_u = .CLAMP_TO_EDGE,
      address_mode_v = .CLAMP_TO_EDGE,
      address_mode_w = .CLAMP_TO_EDGE,
      min_lod = 0,
      max_lod = 100,
    };
    GPU.sampl_shadow = SDL_CreateGPUSampler(GPU.device, *sampler_info);
  }

  // Outline sampler + index buffer
  {
    sampler_info := SDL_GPUSamplerCreateInfo.{
      min_filter = .NEAREST,
      mag_filter = .NEAREST,
      mipmap_mode = .NEAREST,
      address_mode_u = .CLAMP_TO_EDGE,
      address_mode_v = .CLAMP_TO_EDGE,
      address_mode_w = .CLAMP_TO_EDGE,
      min_lod = 0,
      max_lod = 1,
    };
    GPU.outline_sampler = SDL_CreateGPUSampler(GPU.device, *sampler_info);
  }

  // UI sampler
  {
    sampler_info := SDL_GPUSamplerCreateInfo.{
      min_filter = .LINEAR,
      mag_filter = .LINEAR,
    };
    GPU.ui_atlas_sampler = SDL_CreateGPUSampler(GPU.device, *sampler_info);
  }

  // UI buffers
  {
    GPU.ui_indices = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_INDEX,
      RD.ui_indices.DATA_SIZE, "ui_indices");
    GPU.ui_shape_buffer = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
      RD.ui_shapes.DATA_SIZE, "ui_shape_buffer");
  }

  GPU_InitPipelines();
  GPU_ResizeFramebuffer();
}

GPU_InitPipelines :: ()
{
  // Release pipelines if they exist
  {
    for GPU.world_pipelines {
      SDL_ReleaseGPUGraphicsPipeline(GPU.device, it);
    }
    SDL_ReleaseGPUGraphicsPipeline(GPU.device, GPU.outline_visualize_pipeline);
    SDL_ReleaseGPUGraphicsPipeline(GPU.device, GPU.outline_propagate_pipeline);
    SDL_ReleaseGPUGraphicsPipeline(GPU.device, GPU.ui_pipeline);
  }

  default_color_desc := SDL_GPUColorTargetDescription.{
    format = SDL_GetGPUSwapchainTextureFormat(GPU.device, G.window),
  };

  default_blend_state := SDL_GPUColorTargetBlendState.{
    src_color_blendfactor = .SRC_ALPHA,
    dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
    color_blend_op = .ADD,
    // use ONE, ONE instead?
    src_alpha_blendfactor = .SRC_ALPHA,
    dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
    alpha_blend_op = .ADD,
    enable_blend = true,
  };

  // WORLD pipeline
  {
    binary_vs := AST.shaders[ShaderType.WORLD_VS].buffer;
    binary_ps := AST.shaders[ShaderType.WORLD_PS].buffer;

    vertex_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .VERTEX,
        num_samplers = 0,
        num_storage_buffers = 2,
        num_storage_textures = 0,
        num_uniform_buffers = 1,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_vs.data,
        code_size = xx binary_vs.count,
        entrypoint = "World_DxShaderSkinnedVS",
      };
      vertex_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    fragment_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .FRAGMENT,
        num_samplers = 2,
        num_storage_buffers = 0,
        num_storage_textures = 0,
        num_uniform_buffers = 1,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_ps.data,
        code_size = xx binary_ps.count,
        entrypoint = "World_DxShaderSkinnedPS",
      };
      fragment_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    pipeline := SDL_GPUGraphicsPipelineCreateInfo.{
      vertex_shader = vertex_shader,
      fragment_shader = fragment_shader,
      multisample_state = SDL_GPUMultisampleState.{
        sample_count = GPU.sample_count,
      },
      depth_stencil_state = .{
        enable_depth_test = true,
        enable_depth_write = true,
        compare_op = .SDL_GPU_COMPAREOP_LESS,
      },
      primitive_type = .SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
      rasterizer_state = .{
        front_face = .SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        cull_mode = ifx GPU_ENABLE_BACKFACE_CULL then .SDL_GPU_CULLMODE_BACK else .SDL_GPU_CULLMODE_NONE,
        enable_depth_clip = true,
      },
      target_info = .{
        num_color_targets = 1,
        color_target_descriptions = *default_color_desc,
        depth_stencil_format = .SDL_GPU_TEXTUREFORMAT_D16_UNORM,
        has_depth_stencil_target = true,
      },
      props = 0
    };

    VERTEX_BUFFERS :: SDL_GPUVertexBufferDescription.[
      .{slot = 0,
        pitch = size_of(RD_WorldVertex),
        input_rate = .SDL_GPU_VERTEXINPUTRATE_VERTEX,
        instance_step_rate = 0,
      },
    ];
    pipeline.vertex_input_state.num_vertex_buffers = VERTEX_BUFFERS.count;
    pipeline.vertex_input_state.vertex_buffer_descriptions = VERTEX_BUFFERS.data;

    VERTEX_ATTRIBS :: SDL_GPUVertexAttribute.[
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
        location = 0,
        offset = #run offset_of(RD_WorldVertex, "p"), // 0
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
        location = 1,
        offset = #run offset_of(RD_WorldVertex, "normal"),
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
        location = 2,
        offset = #run offset_of(RD_WorldVertex, "uv"),
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
        location = 3,
        offset = #run offset_of(RD_WorldVertex, "color"),
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_UINT,
        location = 4,
        offset = #run offset_of(RD_WorldVertex, "joints_packed4"),
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
        location = 5,
        offset = #run offset_of(RD_WorldVertex, "joint_weights"),
      },
    ];
    pipeline.vertex_input_state.num_vertex_attributes = VERTEX_ATTRIBS.count;
    pipeline.vertex_input_state.vertex_attributes = VERTEX_ATTRIBS.data;

    // Create main pipeline
    GPU.world_pipelines[0] = SDL_CreateGPUGraphicsPipeline(GPU.device, *pipeline);
    assert(!!GPU.world_pipelines[0]);

    // Modify pipeline settings for shadow mapping depth pass
    {
      pipeline.multisample_state.sample_count = .SDL_GPU_SAMPLECOUNT_1;
      pipeline.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_NONE;
    }

    // Create shadow pass pipeline
    GPU.world_pipelines[1] = SDL_CreateGPUGraphicsPipeline(GPU.device, *pipeline);
    assert(!!GPU.world_pipelines[1]);

    SDL_ReleaseGPUShader(GPU.device, vertex_shader);
    SDL_ReleaseGPUShader(GPU.device, fragment_shader);
  }

  // Outline visualize pipeline
  {
    binary_vs := AST.shaders[ShaderType.OUTLINE_VISUALIZE_VS].buffer;
    binary_ps := AST.shaders[ShaderType.OUTLINE_VISUALIZE_PS].buffer;

    vertex_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .VERTEX,
        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_vs.data,
        code_size = xx binary_vs.count,
        entrypoint = "VertexShader",
      };
      vertex_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    fragment_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .FRAGMENT,
        num_samplers = 1,
        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_ps.data,
        code_size = xx binary_ps.count,
        entrypoint = "FragmentShader",
      };
      fragment_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    color_desc := SDL_GPUColorTargetDescription.{
      format = default_color_desc.format,
      blend_state = default_blend_state,
    };

    pipeline := SDL_GPUGraphicsPipelineCreateInfo.{
      vertex_shader = vertex_shader,
      fragment_shader = fragment_shader,
      primitive_type = .SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
      target_info = .{
        num_color_targets = 1,
        color_target_descriptions = *color_desc,
      },
    };
    GPU.outline_visualize_pipeline = SDL_CreateGPUGraphicsPipeline(GPU.device, *pipeline);

    SDL_ReleaseGPUShader(GPU.device, vertex_shader);
    SDL_ReleaseGPUShader(GPU.device, fragment_shader);
  }

  // Outline propagate pipeline
  {
    binary_vs := AST.shaders[ShaderType.OUTLINE_PROPAGATE_VS].buffer;
    binary_ps := AST.shaders[ShaderType.OUTLINE_PROPAGATE_PS].buffer;

    vertex_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .VERTEX,
        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_vs.data,
        code_size = xx binary_vs.count,
        entrypoint = "VertexShader",
      };
      vertex_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    fragment_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .FRAGMENT,
        num_samplers = 1,
        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_ps.data,
        code_size = xx binary_ps.count,
        entrypoint = "FragmentShader",
      };
      fragment_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    pipeline := SDL_GPUGraphicsPipelineCreateInfo.{
      vertex_shader = vertex_shader,
      fragment_shader = fragment_shader,
      primitive_type = .SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
      target_info = .{
        num_color_targets = 1,
        color_target_descriptions = *default_color_desc,
      },
    };
    GPU.outline_propagate_pipeline = SDL_CreateGPUGraphicsPipeline(GPU.device, *pipeline);

    SDL_ReleaseGPUShader(GPU.device, vertex_shader);
    SDL_ReleaseGPUShader(GPU.device, fragment_shader);
  }

  // UI pipeline
  {
    binary_vs := AST.shaders[ShaderType.UI_VS].buffer;
    binary_ps := AST.shaders[ShaderType.UI_PS].buffer;

    vertex_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .VERTEX,
        num_samplers = 0,
        num_storage_buffers = 1,
        num_storage_textures = 0,
        num_uniform_buffers = 1,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_vs.data,
        code_size = xx binary_vs.count,
        entrypoint = "UI_DxShaderVS",
      };
      vertex_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    fragment_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .FRAGMENT,
        num_samplers = 1,
        num_storage_buffers = 0,
        num_storage_textures = 0,
        num_uniform_buffers = 0,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_ps.data,
        code_size = xx binary_ps.count,
        entrypoint = "UI_DxShaderPS",
      };
      fragment_shader = SDL_CreateGPUShader(GPU.device, *create_info);
    }

    ui_color_desc := SDL_GPUColorTargetDescription.{
      format = default_color_desc.format,
      blend_state = default_blend_state,
    };

    pipeline := SDL_GPUGraphicsPipelineCreateInfo.{
      vertex_shader = vertex_shader,
      fragment_shader = fragment_shader,
      primitive_type = .SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
      target_info = .{
        num_color_targets = 1,
        color_target_descriptions = *ui_color_desc,
      },
    };
    GPU.ui_pipeline = SDL_CreateGPUGraphicsPipeline(GPU.device, *pipeline);

    SDL_ReleaseGPUShader(GPU.device, vertex_shader);
    SDL_ReleaseGPUShader(GPU.device, fragment_shader);
  }
}



GPU_RenderWorld :: (cmd: *SDL_GPUCommandBuffer, pass: *SDL_GPURenderPass, mode: GPU_RenderWorldMode, group: RD_WorldGroup)
{
  simplified_pipeline := ifx mode == .RENDER then false else true;
  pipeline_index := ifx simplified_pipeline then 1 else 0;
  SDL_BindGPUGraphicsPipeline(pass, GPU.world_pipelines[pipeline_index]);

  // Bind shadow texture sampler to fragment shader
  {
    binding_sampl := SDL_GPUTextureSamplerBinding.[
      .{texture = ifx simplified_pipeline then GPU.dummy_shadow_tex else GPU.shadow_tex,
        sampler = GPU.sampl_shadow},
      .{texture = MaterialFromSlot(0).texture_handle,
        sampler = GPU.material_sampler},

    ];
    SDL_BindGPUFragmentSamplers(pass, 0, binding_sampl.data, binding_sampl.count);
  }

  // Bind dummy buffers
  {
    storage_bufs := *SDL_GPUBuffer.[
      GPU.dummy_instance_buffer,
      RD.stagings[group].transforms.buffer_handle,
    ];
    SDL_BindGPUVertexStorageBuffers(pass, 0, storage_bufs.data, storage_bufs.count);
  }
  //
  // Dynamic meshes
  //
  for staging, material_slot: RD.stagings[group].meshes
  {
    if staging.element_count == 0 continue;

    // Bind vertex buffer
    SDL_BindGPUVertexBuffers(pass, 0, *(SDL_GPUBufferBinding.{buffer = staging.buffer_handle}), 1);

    material := MaterialFromSlot(xx material_slot);

    // Uniforms
    RD_WorldMaterialToUniform(*GPU.world_uniform, material, mode, group);
    if material_slot == MaterialSlotFromAlias(.Clay002) || material_slot == MaterialSlotFromAlias(.Grass004) {
      GPU.world_uniform.flags |= .DrawBorderAtUVEdge;
    }
    GPU_UpdateUniform(cmd, GPU.world_uniform, vertex=true, fragment=true);

    // Bind texture
    binding_sampl := SDL_GPUTextureSamplerBinding.{
      texture = material.texture_handle,
      sampler = GPU.material_sampler,
    };
    SDL_BindGPUFragmentSamplers(pass, 1, *binding_sampl, 1);

    SDL_DrawGPUPrimitives(pass, xx staging.element_count, 1, 0, 0);
  }

  //
  // Prepare GPU state to render models
  //

  // Bind model vertices & indices
  SDL_BindGPUVertexBuffers(pass, 0, *(SDL_GPUBufferBinding.{buffer = AST.model_vertices}), 1);
  SDL_BindGPUIndexBuffer(pass, *(SDL_GPUBufferBinding.{buffer = AST.model_indices}), .SDL_GPU_INDEXELEMENTSIZE_16BIT);

  //
  // Models
  //
  for staging, model_slot: RD.stagings[group].models
  {
    if staging.element_count == 0 continue;

    model := ModelFromSlot(xx model_slot);

    // bind instance storage buffer
    storage_bufs := *SDL_GPUBuffer.[
      staging.buffer_handle,
      RD.stagings[group].transforms.buffer_handle,
    ];
    SDL_BindGPUVertexStorageBuffers(pass, 0, storage_bufs.data, storage_bufs.count);

    for mesh: model.meshes
    {
      material := MaterialFromSlot(mesh.material_slot);

      // Uniforms
      RD_WorldMaterialToUniform(*GPU.world_uniform, material, mode, group);
      GPU.world_uniform.flags |= .UseInstanceBuffer;
      GPU.world_uniform.flags |= .EnableHueShift;
      if (model.is_skinned) GPU.world_uniform.flags |= .DoMeshSkinning;
      if model_slot == ModelSlotFromAlias(.Tree) {
        //GPU.world_uniform.flags |= .LessShadows;
      }
      GPU_UpdateUniform(cmd, GPU.world_uniform, vertex=true, fragment=true);

      // Bind texture
      if material.tex.format
      {
        binding_sampl := SDL_GPUTextureSamplerBinding.{
          texture = material.texture_handle,
          sampler = GPU.material_sampler,
        };
        SDL_BindGPUFragmentSamplers(pass, 1, *binding_sampl, 1);
      }

      SDL_DrawGPUIndexedPrimitives(pass, mesh.indices_count, xx staging.element_count,
        mesh.indices_start_index, xx mesh.vertices_start_index, 0);
    }
  }
}

GPU_Iterate :: ()
{
  PerfFunc();

  cmd: *SDL_GPUCommandBuffer;
  swapchain_tex: *SDL_GPUTexture;
  draw_width, draw_height: u32;
  {
    PerfScope("GPU acquire frame");
    cmd = SDL_AcquireGPUCommandBuffer(GPU.device);
    SDL_WaitAndAcquireGPUSwapchainTexture(cmd, G.window, *swapchain_tex, *draw_width, *draw_height);
  }

  if !swapchain_tex
  {
    SDL_CancelGPUCommandBuffer(cmd);
    return;
  }

  {
    copy_pass := SDL_BeginGPUCopyPass(cmd);
    RD_CopyFromTransferBuffersToBuffers(copy_pass);
    SDL_EndGPUCopyPass(copy_pass);
  }

  CreateDepthTargetInfo :: (texture: *SDL_GPUTexture, store_results: bool) -> SDL_GPUDepthStencilTargetInfo
  {
    depth_target := SDL_GPUDepthStencilTargetInfo.{
      texture = texture,
      clear_depth = GPU_CLEAR_DEPTH_FLOAT,
      load_op = .CLEAR,
      store_op = ifx store_results then .STORE else .DONT_CARE,
      stencil_load_op = .DONT_CARE,
      stencil_store_op = .DONT_CARE,
      cycle = true,
    };
    return depth_target;
  }

  GPU.world_uniform = RD_WorldUniform.{
    camera_transform = G.sun_camera_transform,
    shadow_transform = G.sun_camera_transform,
    camera_position = G.camera_p,
    sun_dir = G.sun_dir,

    fog_color = ColorPack(ColorRGB(GPU_CLEAR_COLOR_R, GPU_CLEAR_COLOR_G, GPU_CLEAR_COLOR_B)),
    sky_ambient = ColorPack(ColorRGB(0.50, 0.45, 0.40)),
    sun_diffuse = ColorPack(ColorRGB(1.00, 0.95, 0.90)),
    sun_specular = ColorPack(ColorRGB(1.00, 0.90, 0.85)),
  };

  // Sun shadow map render pass
  {
    depth_target := CreateDepthTargetInfo(GPU.shadow_tex, true);
    pass := SDL_BeginGPURenderPass(cmd, null, 0, *depth_target);
    GPU_RenderWorld(cmd, pass, .DEPTH, .VISIBLE);
    SDL_EndGPURenderPass(pass);
  }

  // Set camera position
  GPU.world_uniform.camera_transform = G.camera_transform;
  if DEV.sun_camera
  {
    GPU.world_uniform.camera_transform = G.sun_camera_transform;
    GPU.world_uniform.camera_position = G.sun_camera_p;
  }

  // Mouse picking pass
  if DEV.mouse_picking & .ENABLED
  {
    depth_target := CreateDepthTargetInfo(GPU.tex_mouse_picking_depth, false);

    color_target := SDL_GPUColorTargetInfo.{
      load_op = .CLEAR,
      store_op = .STORE,
      texture = GPU.tex_mouse_picking,
      cycle = true,
    };

    pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, *depth_target);
    GPU_RenderWorld(cmd, pass, .MOUSE_PICKING, .VISIBLE);
    SDL_EndGPURenderPass(pass);
  }

  screen_color_target: SDL_GPUColorTargetInfo;
  {
    screen_color_target = .{
      clear_color = .{
        r = GPU_CLEAR_COLOR_R,
        g = GPU_CLEAR_COLOR_G,
        b = GPU_CLEAR_COLOR_B,
        a = GPU_CLEAR_COLOR_A,
      },
      load_op = .CLEAR,
      store_op = .STORE,
    };

    if GPU.tex_msaa
    {
      screen_color_target.store_op = .RESOLVE;
      screen_color_target.texture = GPU.tex_msaa;
      screen_color_target.resolve_texture = GPU.tex_resolve;
      screen_color_target.cycle = true;
      screen_color_target.cycle_resolve_texture = true;
    }
    else
    {
      screen_color_target.texture = swapchain_tex;
    }
  }

  // Main visible world render pass
  {
    depth_target := CreateDepthTargetInfo(GPU.tex_world_depth, false);
    pass := SDL_BeginGPURenderPass(cmd, *screen_color_target, 1, *depth_target);
    GPU_RenderWorld(cmd, pass, .RENDER, .VISIBLE);
    SDL_EndGPURenderPass(pass);
  }

  //
  // WORLD blit (with msaa) to native resolution
  //
  if GPU.sample_count > .SDL_GPU_SAMPLECOUNT_1
  {
    blit := SDL_GPUBlitInfo.{
      source = .{
        texture = GPU.tex_resolve,
        w = xx G.window_dim.x,
        h = xx G.window_dim.y,
      },
      destination = .{
        texture = swapchain_tex,
        w = draw_width,
        h = draw_height,
      },
      load_op = .DONT_CARE,
      filter = .LINEAR,
    };
    SDL_BlitGPUTexture(cmd, *blit);
  }

  //
  // Outlines
  //
  {
    // @todo doing this "post blit" is a bit problematic - we would like to render outlines at world resolution?

    // Initialize: WORLD -> sdf_outline_texture
    {
      GPU.outline_texture_index = 0;

      color_target := SDL_GPUColorTargetInfo.{
        clear_color = .{r = GPU_CLEAR_OUTLINES, g = GPU_CLEAR_OUTLINES},
        load_op = .CLEAR,
        store_op = .STORE,
        texture = GPU.outline_textures[0],
        cycle = true,
      };
      pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, null);
      GPU_RenderWorld(cmd, pass, .RENDER, .OUTLINE);
      SDL_EndGPURenderPass(pass);
    }

    // Propagete: sdf_outline_texture -> sdf_outline_texture
    for 0..16
    {
      prev_index := GPU.outline_texture_index;
      next_index := (GPU.outline_texture_index + 1) % 2;
      GPU.outline_texture_index = next_index;

      color_target := SDL_GPUColorTargetInfo.{
        load_op = .LOAD,
        store_op = .STORE,
        texture = GPU.outline_textures[next_index],
      };

      pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, null);
      SDL_BindGPUGraphicsPipeline(pass, GPU.outline_propagate_pipeline);

      samplers := SDL_GPUTextureSamplerBinding.[
        .{texture = GPU.outline_textures[prev_index],
          sampler = GPU.outline_sampler},
      ];
      SDL_BindGPUFragmentSamplers(pass, 0, samplers.data, samplers.count);

      SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
      SDL_EndGPURenderPass(pass);
    }

    // Display: sdf_outline_texture -> WORLD
    {
      color_target := SDL_GPUColorTargetInfo.{
        load_op = .LOAD,
        store_op = .STORE,
        texture = swapchain_tex,
      };

      pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, null);
      SDL_BindGPUGraphicsPipeline(pass, GPU.outline_visualize_pipeline);

      samplers := SDL_GPUTextureSamplerBinding.[
        .{texture = GPU.outline_textures[GPU.outline_texture_index],
          sampler = GPU.outline_sampler},
      ];
      SDL_BindGPUFragmentSamplers(pass, 0, samplers.data, samplers.count);

      SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
      SDL_EndGPURenderPass(pass);
    }
  }

  //
  // UI render pass
  //
  if RD.ui_indices.count > 0
  {
    // Upload uniform
    uniform := RD_UIUniform.{
      window_dim = G.window_dim,
      texture_dim = V2.{xx FONT.texture_dim, xx FONT.texture_dim},
    };
    GPU_UpdateUniform(cmd, uniform, vertex=true, fragment=false);
    GPU_TransferBuffer(cmd, GPU.ui_indices, RD.ui_indices.buf.data, xx array_size_bytes(RD.ui_indices));

    if RD.ui_shapes.count > 0 {
      GPU_TransferBuffer(cmd, GPU.ui_shape_buffer, RD.ui_shapes.buf.data, xx array_size_bytes(RD.ui_shapes));
    }

    // Start pass
    color_target := SDL_GPUColorTargetInfo.{
      load_op = .LOAD,
      store_op = .STORE,
      texture = swapchain_tex,
    };
    pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, null);

    // Bind pipeline
    SDL_BindGPUGraphicsPipeline(pass, GPU.ui_pipeline);

    // Bind texture & sampler
    sampler_binding := SDL_GPUTextureSamplerBinding.{
      texture = GPU.ui_atlas_texture,
      sampler = GPU.ui_atlas_sampler,
    };
    SDL_BindGPUFragmentSamplers(pass, 0, *sampler_binding, 1);

    // Bind storage buffers
    storage_bufs := *SDL_GPUBuffer.[GPU.ui_shape_buffer];
    SDL_BindGPUVertexStorageBuffers(pass, 0, storage_bufs.data, storage_bufs.count);

    // Bind index buffer
    binding_ind := SDL_GPUBufferBinding.{buffer = GPU.ui_indices};
    SDL_BindGPUIndexBuffer(pass, *binding_ind, .SDL_GPU_INDEXELEMENTSIZE_32BIT);

    // Draw
    SDL_DrawGPUIndexedPrimitives(pass, xx RD.ui_indices.count, 1, 0, 0, 0);

    // End pass
    SDL_EndGPURenderPass(pass);
  }

  // Submit command buffer
  PerfScope("GPU command buffer submit");

  if DEV.mouse_picking & .ENABLED
  {
    if !QueueIsFull(GPU.mouse_picking_readback_queue)
    {
      readback := QueuePush(*GPU.mouse_picking_readback_queue);
      readback.dim = Vec2(s32).{xx G.window_dim.x, xx G.window_dim.y};
      if DEV.mouse_picking & .ONE_PIXEL
        readback.dim = .{1,1};

      download_info := SDL_GPUTransferBufferCreateInfo.{
        usage = .SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        size = xx (readback.dim.x * readback.dim.y * 4),
      };
      readback.download_transfer_buffer = SDL_CreateGPUTransferBuffer(GPU.device, *download_info);

      copy_pass := SDL_BeginGPUCopyPass(cmd);
      src := SDL_GPUTextureRegion.{
        texture = GPU.tex_mouse_picking,
        w = xx readback.dim.x,
        h = xx readback.dim.y,
        d = 1,
      };
      if DEV.mouse_picking & .ONE_PIXEL
      {
        if OverlapsRange(MakeRange(G.window_dim), G.mouse)
        {
          src.x = xx G.mouse.x;
          src.y = xx G.mouse.y;
        }
        else
        {
          readback.out_of_screen = true;
        }
      }

      dst := SDL_GPUTextureTransferInfo.{
        transfer_buffer = readback.download_transfer_buffer,
      };
      SDL_DownloadFromGPUTexture(copy_pass, *src, *dst);
      SDL_EndGPUCopyPass(copy_pass);

      readback.fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
      assert(readback.fence != null);
    }
    else
    {
      log("GPU readback queue is full. Skipping frame readback.", flags=.VERBOSE_ONLY);
      SDL_SubmitGPUCommandBuffer(cmd);
    }
  }
  else
  {
    SDL_SubmitGPUCommandBuffer(cmd);
  }
}

GPU_ReadbackMousePickingTexture :: ()
{
  if !QueueIsEmpty(GPU.mouse_picking_readback_queue)
  {
    if QueueCount(GPU.mouse_picking_readback_queue) > 3 {
      log("GPU readback queue count = %. Interesting... Should we try to catch up?",
        QueueCount(GPU.mouse_picking_readback_queue), flags=.VERBOSE_ONLY);
    }

    peeked := QueuePeek(GPU.mouse_picking_readback_queue);
    if SDL_QueryGPUFence(GPU.device, peeked.fence)
    {
      QueuePop(*GPU.mouse_picking_readback_queue);
      SDL_ReleaseGPUFence(GPU.device, peeked.fence);
      downloaded_color: u32;

      if !peeked.out_of_screen
      {
        downloaded_data: *u32 = SDL_MapGPUTransferBuffer(GPU.device, peeked.download_transfer_buffer, false);

        if peeked.dim.x == 1 && peeked.dim.y == 1
        {
          downloaded_color = downloaded_data[0];
        }
        else
        {
          mouse := Vec2(s32).{xx G.mouse.x, xx G.mouse.y};
          if OverlapsRange(MakeRange(peeked.dim), mouse)
          {
            offset := mouse.x + mouse.y * peeked.dim.x;
            downloaded_color = downloaded_data[offset];
          }
        }

        SDL_UnmapGPUTransferBuffer(GPU.device, peeked.download_transfer_buffer);
      }

      G.hover_object = OBJ_ColorToKey(xx downloaded_color);
      SDL_ReleaseGPUTransferBuffer(GPU.device, peeked.download_transfer_buffer);
    }
  }
}

GPU_ResizeFramebuffer :: ()
{
  SDL_ReleaseGPUTexture(GPU.device, GPU.tex_msaa);
  SDL_ReleaseGPUTexture(GPU.device, GPU.tex_resolve);
  SDL_ReleaseGPUTexture(GPU.device, GPU.tex_mouse_picking);
  for GPU.outline_textures SDL_ReleaseGPUTexture(GPU.device, it);
  SDL_ReleaseGPUTexture(GPU.device, GPU.tex_world_depth);
  SDL_ReleaseGPUTexture(GPU.device, GPU.tex_mouse_picking_depth);

  window_width := cast(u32) G.window_dim.x;
  window_height := cast(u32) G.window_dim.y;

  CreateTextureAndName :: (info: SDL_GPUTextureCreateInfo, name: string) -> *SDL_GPUTexture
  {
    tex := SDL_CreateGPUTexture(GPU.device, *info);
    assert(tex != null);
    SDL_SetGPUTextureName(GPU.device, tex, temp_c_string(name));
    return tex;
  }

  //
  // Color textures
  //
  base_info := SDL_GPUTextureCreateInfo.{
    type = .SDL_GPU_TEXTURETYPE_2D,
    width = window_width,
    height = window_height,
    layer_count_or_depth = 1,
    num_levels = 1,
    sample_count = .SDL_GPU_SAMPLECOUNT_1,
    usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
  };

  GPU.tex_msaa = null;
  if GPU.sample_count > .SDL_GPU_SAMPLECOUNT_1
  {
    info := base_info;
    info.format = SDL_GetGPUSwapchainTextureFormat(GPU.device, G.window);
    info.sample_count = GPU.sample_count;
    info.props = GPU.clear_color_props;
    GPU.tex_msaa = CreateTextureAndName(info, "tex_msaa");
  }

  GPU.tex_resolve = null;
  if GPU.sample_count > .SDL_GPU_SAMPLECOUNT_1
  {
    info := base_info;
    info.format = SDL_GetGPUSwapchainTextureFormat(GPU.device, G.window);
    info.usage |= SDL_GPU_TEXTUREUSAGE_SAMPLER; // @todo remove SAMPLER?
    info.props = GPU.clear_color_props;
    GPU.tex_resolve = CreateTextureAndName(info, "tex_resolve");
  }

  // tex_mouse_picking
  {
    info := base_info;
    info.format = .B8G8R8A8_UNORM; // @todo Pick this from swapchain texture format? But be careful when reading from it?
    info.props = GPU.clear_mouse_picking_props;
    GPU.tex_mouse_picking = CreateTextureAndName(info, "tex_mouse_picking");
  }

  // tex_outline
  for * GPU.outline_textures
  {
    info := base_info;
    info.format = .R32G32_FLOAT;
    info.usage |= SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.props = GPU.clear_outline_props;
    it.* = CreateTextureAndName(info, tprint("tex_outline%", it_index));
  }

  //
  // Depth textures
  //
  GPU.tex_world_depth = GPU_CreateDepthTexture("tex_world_depth", window_width, window_height, false, false);
  GPU.tex_mouse_picking_depth = GPU_CreateDepthTexture("tex_mouse_picking_depth", window_width, window_height, false, true);
}

GPU_CreateBuffer :: (usage: SDL_GPUBufferUsageFlags, size: u32, name: string) -> *SDL_GPUBuffer
{
  desc := SDL_GPUBufferCreateInfo.{usage = usage, size = size};
  result := SDL_CreateGPUBuffer(GPU.device, *desc);
  assert(result != null);
  if (name) {
    SDL_SetGPUBufferName(GPU.device, result, temp_c_string(name));
  }
  return result;
}

GPU_CreateDepthTexture :: (name: string, width: u32, height: u32, used_in_sampler: bool, sample_count_1: bool) -> *SDL_GPUTexture
{
  info := SDL_GPUTextureCreateInfo.{
    type = .SDL_GPU_TEXTURETYPE_2D,
    format = .D16_UNORM,
    width = width,
    height = height,
    layer_count_or_depth = 1,
    num_levels = 1,
    sample_count = GPU.sample_count,
    usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    props = GPU.clear_depth_props,
  };

  if used_in_sampler then info.usage |= SDL_GPU_TEXTUREUSAGE_SAMPLER;
  if sample_count_1 then info.sample_count = .SDL_GPU_SAMPLECOUNT_1;

  tex := SDL_CreateGPUTexture(GPU.device, *info);
  assert(tex != null);
  SDL_SetGPUTextureName(GPU.device, tex, temp_c_string(name));
  return tex;
}

GPU_TransferBuffer :: (cmd: *SDL_GPUCommandBuffer, gpu_buffer: *SDL_GPUBuffer, data: *void, data_size: u32)
{
  // create transfer buffer
  trans_desc := SDL_GPUTransferBufferCreateInfo.{
    usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    size = data_size
  };
  buf_transfer := SDL_CreateGPUTransferBuffer(GPU.device, *trans_desc);
  assert(!!buf_transfer); // @todo report err

  // CPU memory -> GPU memory
  {
    map : *void = SDL_MapGPUTransferBuffer(GPU.device, buf_transfer, false);
    memcpy(map, data, data_size);
    SDL_UnmapGPUTransferBuffer(GPU.device, buf_transfer);
  }

  // GPU memory -> GPU buffers
  {
    copy_pass := SDL_BeginGPUCopyPass(cmd);

    buf_location := SDL_GPUTransferBufferLocation.{
      transfer_buffer = buf_transfer,
      offset = 0,
    };
    dst_region := SDL_GPUBufferRegion.{
      buffer = gpu_buffer,
      offset = 0,
      size = data_size,
    };
    SDL_UploadToGPUBuffer(copy_pass, *buf_location, *dst_region, false); // @todo should this be true?

    SDL_EndGPUCopyPass(copy_pass);
  }

  SDL_ReleaseGPUTransferBuffer(GPU.device, buf_transfer);
}

GPU_UpdateUniform :: (cmd: *SDL_GPUCommandBuffer, uniform: $T, vertex: bool, fragment: bool)
{
  uniform_hash := Hash64Any(uniform);
  if vertex && GPU.bound_vertex_uniform_hash != uniform_hash
  {
    GPU.bound_vertex_uniform_hash = uniform_hash;
    SDL_PushGPUVertexUniformData(cmd, 0, *uniform, size_of(T));
  }
  if fragment && GPU.bound_fragment_uniform_hash != uniform_hash
  {
    GPU.bound_fragment_uniform_hash = uniform_hash;
    SDL_PushGPUFragmentUniformData(cmd, 0, *uniform, size_of(T));
  }
}
