GPU_USE_MSAA :: true;
GPU_SHADOW_MAP_DIM :: 2048*2;
GPU_ENABLE_BACKFACE_CULL :: 0;
GPU_CLEAR_DEPTH_FLOAT :: 1.0;
GPU_CLEAR_COLOR_R :: 0.78;
GPU_CLEAR_COLOR_G :: 0.78;
GPU_CLEAR_COLOR_B :: 0.96;
GPU_CLEAR_COLOR_A :: 1.0;

GPU_FrameReadback :: struct
{
  fence: *SDL_GPUFence;
  download_transfer_buffer: *SDL_GPUTransferBuffer;
  dim: Vec2(s32);
  out_of_screen: bool;
}

GPU_State :: struct
{
  device: *SDL_GPUDevice;
  mem: GPU_BATCH_State;

  readback_queue: Queue(8, GPU_FrameReadback);

  tex_msaa: *SDL_GPUTexture;
  tex_resolve: *SDL_GPUTexture;
  tex_world_depth: *SDL_GPUTexture;
  tex_mouse_picking_depth: *SDL_GPUTexture;
  tex_mouse_picking: *SDL_GPUTexture;

  shadow_tex: *SDL_GPUTexture;
  shadow_sampler: *SDL_GPUSampler;

  dummy_shadow_tex: *SDL_GPUTexture; // bound in shadowmap prepass; @todo delete?
  dummy_instance_buffer: *SDL_GPUBuffer;

  // pipeline, sample settings
  sample_count: SDL_GPUSampleCount;
  world_pipelines: [2] *SDL_GPUGraphicsPipeline; // 0: 4xMSAA; 1: no AA (for shadow mapping)
  ui_pipeline: *SDL_GPUGraphicsPipeline;

  bound_uniform_hash: u64;
  world_uniform: WORLD_Uniform;

  mesh_tex_sampler: *SDL_GPUSampler;

  UI_GPU :: struct
  {
    gpu_atlas_texture: *SDL_GPUTexture;
    gpu_atlas_sampler: *SDL_GPUSampler;
    gpu_indices: *SDL_GPUBuffer;
    gpu_shape_buffer: *SDL_GPUBuffer;
    gpu_clip_buffer: *SDL_GPUBuffer;

    // @todo move some of these things to game_render_ui.jai and use GPU_BATCH?
    indices: [1024 * 8] u32;
    indices_count: u32;

    shapes: [1024 * 2] UI_Shape;
    shapes_count: u32;

    shapes3d: [1024 * 2] UI_ShapeIn3D;
    shapes3d_count: u32;

    clips: [1024] UI_Clip; // buffer that's uploaded to GPU
    clips_count: u32;
    clip_stack: [256] u32; // contains indices into clips; tracks state when UI is constructed @todo remove in the future
    clip_stack_index: u32;
  };
  ui: UI_GPU;

  // sdl properties
  clear_depth_props: SDL_PropertiesID;
  clear_mouse_picking_props: SDL_PropertiesID;
  clear_color_props: SDL_PropertiesID;
}

GPU_Init :: ()
{
  // preapre props
  {
    G.gpu.clear_depth_props = SDL_CreateProperties();
    SDL_SetFloatProperty(G.gpu.clear_depth_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_DEPTH_FLOAT, GPU_CLEAR_DEPTH_FLOAT);

    G.gpu.clear_mouse_picking_props = SDL_CreateProperties();
    SDL_SetFloatProperty(G.gpu.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_R_FLOAT, 0.0);
    SDL_SetFloatProperty(G.gpu.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_G_FLOAT, 0.0);
    SDL_SetFloatProperty(G.gpu.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_B_FLOAT, 0.0);
    SDL_SetFloatProperty(G.gpu.clear_mouse_picking_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_A_FLOAT, 0.0);

    G.gpu.clear_color_props = SDL_CreateProperties();
    SDL_SetFloatProperty(G.gpu.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_R_FLOAT, GPU_CLEAR_COLOR_R);
    SDL_SetFloatProperty(G.gpu.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_G_FLOAT, GPU_CLEAR_COLOR_G);
    SDL_SetFloatProperty(G.gpu.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_B_FLOAT, GPU_CLEAR_COLOR_B);
    SDL_SetFloatProperty(G.gpu.clear_color_props, SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_A_FLOAT, GPU_CLEAR_COLOR_A);
  }

  // check for msaa 4 support
  G.gpu.sample_count = .SDL_GPU_SAMPLECOUNT_1;
  if (GPU_USE_MSAA)
  {
    tex_format := SDL_GetGPUSwapchainTextureFormat(G.gpu.device, G.window);
    supports_msaa := SDL_GPUTextureSupportsSampleCount(G.gpu.device, tex_format, .SDL_GPU_SAMPLECOUNT_4);
    if (supports_msaa)
    G.gpu.sample_count = .SDL_GPU_SAMPLECOUNT_4;
  }

  // Texture sampler
  {
    sampler_info := SDL_GPUSamplerCreateInfo.{
      min_filter = .SDL_GPU_FILTER_LINEAR,
      mag_filter = .SDL_GPU_FILTER_LINEAR,
      mipmap_mode = .SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
      address_mode_u = .SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
      address_mode_v = .SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
      address_mode_w = .SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
      min_lod = 0,
      max_lod = 100,
    };
    G.gpu.mesh_tex_sampler = SDL_CreateGPUSampler(G.gpu.device, *sampler_info);
  }

  G.gpu.dummy_instance_buffer = GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
    xx Kilobyte(1), "Dummy instance storage buffer");

  // Shadow map
  {
    G.gpu.shadow_tex = GPU_CreateDepthTexture(GPU_SHADOW_MAP_DIM, GPU_SHADOW_MAP_DIM, true, true);
    G.gpu.dummy_shadow_tex = GPU_CreateDepthTexture(16, 16, true, true);

    sampler_info := SDL_GPUSamplerCreateInfo.{
      min_filter = .SDL_GPU_FILTER_LINEAR,
      mag_filter = .SDL_GPU_FILTER_LINEAR,
      mipmap_mode = .SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
      address_mode_u = .SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
      address_mode_v = .SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
      address_mode_w = .SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
      min_lod = 0,
      max_lod = 100,
    };
    G.gpu.shadow_sampler = SDL_CreateGPUSampler(G.gpu.device, *sampler_info);
  }

  // UI sampler
  {
    sampler_info := SDL_GPUSamplerCreateInfo.{
      min_filter = .SDL_GPU_FILTER_LINEAR,
      mag_filter = .SDL_GPU_FILTER_LINEAR,
    };
    G.gpu.ui.gpu_atlas_sampler = SDL_CreateGPUSampler(G.gpu.device, *sampler_info);
  }

  // UI buffers
  {
    G.gpu.ui.gpu_indices =
    GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_INDEX, size_of(type_of(G.gpu.ui.indices)), "UI Index Buffer");
    G.gpu.ui.gpu_shape_buffer =
    GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ, size_of(type_of(G.gpu.ui.shapes)), "UI Shapes Storage Buffer");
    G.gpu.ui.gpu_clip_buffer =
    GPU_CreateBuffer(SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ, size_of(type_of(G.gpu.ui.clips)), "UI Clips Storage Buffer");
  }

  GPU_InitPipelines();
  GPU_ResizeFramebuffer();
}

GPU_InitPipelines :: ()
{
  // Release pipelines if they exist
  {
    for G.gpu.world_pipelines
      SDL_ReleaseGPUGraphicsPipeline(G.gpu.device, it);
    SDL_ReleaseGPUGraphicsPipeline(G.gpu.device, G.gpu.ui_pipeline);
  }

  color_desc := SDL_GPUColorTargetDescription.{
    format = SDL_GetGPUSwapchainTextureFormat(G.gpu.device, G.window),
  };

  // WORLD pipeline
  {
    binary_vs := GetShader(.WORLD_VS);
    binary_ps := GetShader(.WORLD_PS);

    vertex_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .SDL_GPU_SHADERSTAGE_VERTEX,
        num_samplers = 0,
        num_storage_buffers = 2,
        num_storage_textures = 0,
        num_uniform_buffers = 1,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_vs.data,
        code_size = xx binary_vs.count,
        entrypoint = "World_DxShaderSkinnedVS",
      };
      vertex_shader = SDL_CreateGPUShader(G.gpu.device, *create_info);
    }

    fragment_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .SDL_GPU_SHADERSTAGE_FRAGMENT,
        num_samplers = 2,
        num_storage_buffers = 0,
        num_storage_textures = 0,
        num_uniform_buffers = 1,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_ps.data,
        code_size = xx binary_ps.count,
        entrypoint = "World_DxShaderSkinnedPS",
      };
      fragment_shader = SDL_CreateGPUShader(G.gpu.device, *create_info);
    }

    pipeline := SDL_GPUGraphicsPipelineCreateInfo.{
      vertex_shader = vertex_shader,
      fragment_shader = fragment_shader,
      multisample_state = SDL_GPUMultisampleState.{
        sample_count = G.gpu.sample_count,
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
        color_target_descriptions = *color_desc,
        depth_stencil_format = .SDL_GPU_TEXTUREFORMAT_D16_UNORM,
        has_depth_stencil_target = true,
      },
      props = 0
    };

    VERTEX_BUFFERS :: SDL_GPUVertexBufferDescription.[
      .{slot = 0,
        pitch = size_of(WORLD_Vertex),
        input_rate = .SDL_GPU_VERTEXINPUTRATE_VERTEX,
        instance_step_rate = 0,
      },
    ];
    pipeline.vertex_input_state.num_vertex_buffers = VERTEX_BUFFERS.count;
    pipeline.vertex_input_state.vertex_buffer_descriptions = VERTEX_BUFFERS.data;

    VERTEX_ATTRIBS :: SDL_GPUVertexAttribute.[
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
        location = 0,
        offset = #run offset_of(WORLD_Vertex, "p"), // 0
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
        location = 1,
        offset = #run offset_of(WORLD_Vertex, "normal"),
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
        location = 2,
        offset = #run offset_of(WORLD_Vertex, "uv"),
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_UINT,
        location = 3,
        offset = #run offset_of(WORLD_Vertex, "joints_packed4"),
      },
      .{format = .SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
        location = 4,
        offset = #run offset_of(WORLD_Vertex, "joint_weights"),
      },
    ];
    pipeline.vertex_input_state.num_vertex_attributes = VERTEX_ATTRIBS.count;
    pipeline.vertex_input_state.vertex_attributes = VERTEX_ATTRIBS.data;

    // Create main pipeline
    G.gpu.world_pipelines[0] = SDL_CreateGPUGraphicsPipeline(G.gpu.device, *pipeline);
    assert(!!G.gpu.world_pipelines[0]);

    // Modify pipeline settings for shadow mapping depth pass
    {
      pipeline.multisample_state.sample_count = .SDL_GPU_SAMPLECOUNT_1;
      pipeline.rasterizer_state.cull_mode = .SDL_GPU_CULLMODE_NONE;
    }

    // Create shadow pass pipeline
    G.gpu.world_pipelines[1] = SDL_CreateGPUGraphicsPipeline(G.gpu.device, *pipeline);
    assert(!!G.gpu.world_pipelines[1]);

    SDL_ReleaseGPUShader(G.gpu.device, vertex_shader);
    SDL_ReleaseGPUShader(G.gpu.device, fragment_shader);
  }

  // UI pipeline
  {
    binary_vs := GetShader(.UI_VS);
    binary_ps := GetShader(.UI_PS);

    vertex_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .SDL_GPU_SHADERSTAGE_VERTEX,
        num_samplers = 0,
        num_storage_buffers = 2,
        num_storage_textures = 0,
        num_uniform_buffers = 1,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_vs.data,
        code_size = xx binary_vs.count,
        entrypoint = "UI_DxShaderVS",
      };
      vertex_shader = SDL_CreateGPUShader(G.gpu.device, *create_info);
    }

    fragment_shader: *SDL_GPUShader;
    {
      create_info := SDL_GPUShaderCreateInfo.{
        stage = .SDL_GPU_SHADERSTAGE_FRAGMENT,
        num_samplers = 1,
        num_storage_buffers = 0,
        num_storage_textures = 0,
        num_uniform_buffers = 0,

        format = SDL_GPU_SHADERFORMAT_DXIL,
        code = binary_ps.data,
        code_size = xx binary_ps.count,
        entrypoint = "UI_DxShaderPS",
      };
      fragment_shader = SDL_CreateGPUShader(G.gpu.device, *create_info);
    }

    ui_color_desc := SDL_GPUColorTargetDescription.{
      format = color_desc.format,
      blend_state = .{
        src_color_blendfactor = .SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        dst_color_blendfactor = .SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        color_blend_op = .SDL_GPU_BLENDOP_ADD,
        // use ONE, ONE instead?
        src_alpha_blendfactor = .SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        dst_alpha_blendfactor = .SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        alpha_blend_op = .SDL_GPU_BLENDOP_ADD,
        enable_blend = true,
      },
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
    G.gpu.ui_pipeline = SDL_CreateGPUGraphicsPipeline(G.gpu.device, *pipeline);

    SDL_ReleaseGPUShader(G.gpu.device, vertex_shader);
    SDL_ReleaseGPUShader(G.gpu.device, fragment_shader);
  }
}

GPU_Iterate :: ()
{
  GPU_RenderWorld :: (cmd: *SDL_GPUCommandBuffer, pass: *SDL_GPURenderPass, mode: enum { RENDER; DEPTH; MOUSE_PICKING; })
  {
    simplified_pipeline := ifx mode == .RENDER then false else true;
    pipeline_index := ifx simplified_pipeline then 1 else 0;
    SDL_BindGPUGraphicsPipeline(pass, G.gpu.world_pipelines[pipeline_index]);

    // Bind shadow texture sampler to fragment shader
    {
      binding_sampl := SDL_GPUTextureSamplerBinding.{
        texture = ifx simplified_pipeline then G.gpu.dummy_shadow_tex else G.gpu.shadow_tex,
        sampler = G.gpu.shadow_sampler,
      };
      SDL_BindGPUFragmentSamplers(pass, 0, *binding_sampl, 1);
    }

    // Bind dummy buffers
    {
      storage_bufs := *SDL_GPUBuffer.[
        G.gpu.dummy_instance_buffer,
        GPU_BATCH_GetPosesBatch().buffer.handle,
      ];
      SDL_BindGPUVertexStorageBuffers(pass, 0, storage_bufs.data, storage_bufs.count);

    }
    //
    // Dynamic meshes
    //
    {
      for batch_index: MakeRange(G.gpu.mem.batches_count)
      {
        gpu_verts := *G.gpu.mem.batches[batch_index];
        if gpu_verts.target.type != .MeshVertices then continue;
        if !gpu_verts.element_count then continue;

        // Bind vertex buffer
        SDL_BindGPUVertexBuffers(pass, 0, *(SDL_GPUBufferBinding.{buffer = gpu_verts.buffer.handle}), 1);

        material := GetMaterial(gpu_verts.target.material_key);

        // Uniforms
        WORLD_ApplyMaterialToUniform(*G.gpu.world_uniform, material, simplified_pipeline);
        if MatchKey(material.key, MaterialKey("tex.Clay002")) ||
           MatchKey(material.key, MaterialKey("tex.Grass004"))
        {
          G.gpu.world_uniform.flags |= .DrawBorderAtUVEdge;
        }
        GPU_UpdateWorldUniform(cmd, G.gpu.world_uniform);

        // Bind texture
        binding_sampl := SDL_GPUTextureSamplerBinding.{
          texture = material.tex,
          sampler = G.gpu.mesh_tex_sampler,
        };
        SDL_BindGPUFragmentSamplers(pass, 1, *binding_sampl, 1);

        SDL_DrawGPUPrimitives(pass, gpu_verts.element_count, 1, 0, 0);
      }
    }

    //
    // Prepare GPU state to render models
    //

    // Bind model vertices & indices
    SDL_BindGPUVertexBuffers(pass, 0, *(SDL_GPUBufferBinding.{buffer = G.ast.model_vertices}), 1);
    SDL_BindGPUIndexBuffer(pass, *(SDL_GPUBufferBinding.{buffer = G.ast.model_indices}), .SDL_GPU_INDEXELEMENTSIZE_16BIT);

    //
    // Models
    //
    for batch_index: MakeRange(G.gpu.mem.batches_count)
    {
      gpu_instances := *G.gpu.mem.batches[batch_index];
      if gpu_instances.target.type != .ModelInstances  continue;
      if !gpu_instances.element_count  continue;

      model := GetModel(gpu_instances.target.model_key);

      // bind instance storage buffer
      storage_bufs := *SDL_GPUBuffer.[
        gpu_instances.buffer.handle,
        GPU_BATCH_GetPosesBatch().buffer.handle,
      ];
      SDL_BindGPUVertexStorageBuffers(pass, 0, storage_bufs.data, storage_bufs.count);

      for mesh: model.meshes
      {
        material := GetMaterial(mesh.material);

        // Uniforms
        WORLD_ApplyMaterialToUniform(*G.gpu.world_uniform, material, simplified_pipeline);
        G.gpu.world_uniform.flags |= .UseInstanceBuffer;
        if model.is_skinned then G.gpu.world_uniform.flags |= .DoMeshSkinning;
        if MatchKey(model.key, ModelKey("Tree"))
        {
          //G.gpu.world_uniform.flags |= .LessShadows;
        }
        GPU_UpdateWorldUniform(cmd, G.gpu.world_uniform);

        // Bind texture
        if material.has_texture
        {
          binding_sampl := SDL_GPUTextureSamplerBinding.{
            texture = material.tex,
            sampler = G.gpu.mesh_tex_sampler,
          };
          SDL_BindGPUFragmentSamplers(pass, 1, *binding_sampl, 1);
        }

        SDL_DrawGPUIndexedPrimitives(pass, mesh.indices_count, gpu_instances.element_count,
          mesh.indices_start_index, xx mesh.vertices_start_index, 0);
      }
    }
  }

  cmd := SDL_AcquireGPUCommandBuffer(G.gpu.device);
  swapchain_tex: *SDL_GPUTexture;
  draw_width, draw_height: u32;
  SDL_WaitAndAcquireGPUSwapchainTexture(cmd, G.window, *swapchain_tex, *draw_width, *draw_height);

  if !swapchain_tex
  {
    SDL_CancelGPUCommandBuffer(cmd);
    return;
  }

  GPU_BATCH_UploadAllBatches(cmd);

  depth_target := SDL_GPUDepthStencilTargetInfo.{
    clear_depth = GPU_CLEAR_DEPTH_FLOAT,
    load_op = .SDL_GPU_LOADOP_CLEAR,
    store_op = .SDL_GPU_STOREOP_DONT_CARE,
    stencil_load_op = .SDL_GPU_LOADOP_DONT_CARE,
    stencil_store_op = .SDL_GPU_STOREOP_DONT_CARE,
    cycle = true,
  };

  G.gpu.world_uniform = WORLD_Uniform.{
    camera_transform = G.sun_camera_transform,
    shadow_transform = G.sun_camera_transform,
    camera_position = G.camera_p,
    sun_dir = G.sun_dir,

    fog_color = Color32_RGBf(GPU_CLEAR_COLOR_R, GPU_CLEAR_COLOR_G, GPU_CLEAR_COLOR_B),
    sky_ambient  = Color32_RGBf(0.50, 0.45, 0.40),
    sun_diffuse  = Color32_RGBf(1.00, 0.95, 0.90),
    sun_specular = Color32_RGBf(1.00, 0.90, 0.85),
  };

  // Sun shadow map render pass
  {
    depth_target.texture = G.gpu.shadow_tex;
    pass := SDL_BeginGPURenderPass(cmd, null, 0, *depth_target);
    GPU_RenderWorld(cmd, pass, .DEPTH);
    SDL_EndGPURenderPass(pass);
  }

  // Set camera position
  G.gpu.world_uniform.camera_transform = G.camera_transform;
  if G.dev.sun_camera
  {
    G.gpu.world_uniform.camera_transform = G.sun_camera_transform;
    G.gpu.world_uniform.camera_position = G.sun_camera_p;
  }

  // Mouse picking pass
  if G.dev.mouse_picking & .ENABLED
  {
    depth_target.texture = G.gpu.tex_mouse_picking_depth;

    color_target := SDL_GPUColorTargetInfo.{
      load_op = .SDL_GPU_LOADOP_CLEAR,
      store_op = .SDL_GPU_STOREOP_STORE,
      texture = G.gpu.tex_mouse_picking,
      cycle = true,
    };

    pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, *depth_target);
    GPU_RenderWorld(cmd, pass, .MOUSE_PICKING);
    SDL_EndGPURenderPass(pass);
  }

  // World render pass
  {
    depth_target.texture = G.gpu.tex_world_depth;

    color_target := SDL_GPUColorTargetInfo.{
      clear_color = .{
        r = GPU_CLEAR_COLOR_R,
        g = GPU_CLEAR_COLOR_G,
        b = GPU_CLEAR_COLOR_B,
        a = GPU_CLEAR_COLOR_A,
      },
      load_op = .SDL_GPU_LOADOP_CLEAR,
      store_op = .SDL_GPU_STOREOP_STORE,
    };

    if G.gpu.tex_msaa
    {
      color_target.store_op = .SDL_GPU_STOREOP_RESOLVE;
      color_target.texture = G.gpu.tex_msaa;
      color_target.resolve_texture = G.gpu.tex_resolve;
      color_target.cycle = true;
      color_target.cycle_resolve_texture = true;
    }
    else
    {
      color_target.texture = swapchain_tex;
    }

    pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, *depth_target);
    GPU_RenderWorld(cmd, pass, .RENDER);
    SDL_EndGPURenderPass(pass);
  }

  if G.gpu.sample_count > .SDL_GPU_SAMPLECOUNT_1
  {
    blit := SDL_GPUBlitInfo.{
      source = .{
        texture = G.gpu.tex_resolve,
        w = xx G.window_dim.x,
        h = xx G.window_dim.y,
      },
      destination = .{
        texture = swapchain_tex,
        w = draw_width,
        h = draw_height,
      },
      load_op = .SDL_GPU_LOADOP_DONT_CARE,
      filter = .SDL_GPU_FILTER_LINEAR,
    };
    SDL_BlitGPUTexture(cmd, *blit);
  }

  // UI render pass
  if G.gpu.ui.indices_count
  {
    // Upload uniform
    uniform := UI_Uniform.{
      window_dim = G.window_dim,
      texture_dim = V2.{xx G.font.texture_dim, xx G.font.texture_dim},
    };
    GPU_UpdateUIUniform(cmd, uniform);

    // Upload buffers to GPU
    {
      transfer_size := size_of(type_of(G.gpu.ui.indices[0])) * G.gpu.ui.indices_count;
      GPU_TransferBuffer(cmd, G.gpu.ui.gpu_indices, G.gpu.ui.indices.data, xx transfer_size);
    }
    if (G.gpu.ui.shapes_count)
    {
      transfer_size := size_of(type_of(G.gpu.ui.shapes[0])) * G.gpu.ui.shapes_count;
      GPU_TransferBuffer(cmd, G.gpu.ui.gpu_shape_buffer, G.gpu.ui.shapes.data, xx transfer_size);
    }
    if (G.gpu.ui.clips_count)
    {
      transfer_size := size_of(type_of(G.gpu.ui.clips[0])) * G.gpu.ui.clips_count;
      GPU_TransferBuffer(cmd, G.gpu.ui.gpu_clip_buffer, G.gpu.ui.clips.data, xx transfer_size);
    }

    // Start pass
    color_target := SDL_GPUColorTargetInfo.{
      load_op = .SDL_GPU_LOADOP_LOAD,
      store_op = .SDL_GPU_STOREOP_STORE,
      texture = swapchain_tex,
    };
    pass := SDL_BeginGPURenderPass(cmd, *color_target, 1, null);

    // Bind pipeline
    SDL_BindGPUGraphicsPipeline(pass, G.gpu.ui_pipeline);

    // Bind texture & sampler
    sampler_binding := SDL_GPUTextureSamplerBinding.{
      texture = G.gpu.ui.gpu_atlas_texture,
      sampler = G.gpu.ui.gpu_atlas_sampler,
    };
    SDL_BindGPUFragmentSamplers(pass, 0, *sampler_binding, 1);

    // Bind storage buffers
    storage_bufs := *SDL_GPUBuffer.[
      G.gpu.ui.gpu_shape_buffer,
      G.gpu.ui.gpu_clip_buffer,
    ];
    SDL_BindGPUVertexStorageBuffers(pass, 0, storage_bufs.data, storage_bufs.count);

    // Bind index buffer
    binding_ind := SDL_GPUBufferBinding.{buffer = G.gpu.ui.gpu_indices};
    SDL_BindGPUIndexBuffer(pass, *binding_ind, .SDL_GPU_INDEXELEMENTSIZE_32BIT);

    // Draw
    SDL_DrawGPUIndexedPrimitives(pass, G.gpu.ui.indices_count, 1, 0, 0, 0);

    // End pass
    SDL_EndGPURenderPass(pass);
  }

  // Submit command buffer
  if G.dev.mouse_picking & .ENABLED
  {
    if !QueueIsFull(G.gpu.readback_queue)
    {
      readback := QueuePush(*G.gpu.readback_queue);
      readback.dim = Vec2(s32).{xx G.window_dim.x, xx G.window_dim.y};
      if G.dev.mouse_picking & .ONE_PIXEL
        readback.dim = .{1,1};

      download_info := SDL_GPUTransferBufferCreateInfo.{
        usage = .SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        size = xx (readback.dim.x * readback.dim.y * 4),
      };
      readback.download_transfer_buffer = SDL_CreateGPUTransferBuffer(G.gpu.device, *download_info);

      copy_pass := SDL_BeginGPUCopyPass(cmd);
      src := SDL_GPUTextureRegion.{
        texture = G.gpu.tex_mouse_picking,
        w = xx readback.dim.x,
        h = xx readback.dim.y,
        d = 1,
      };
      if G.dev.mouse_picking & .ONE_PIXEL
      {
        if OverlapsRange(MakeRange(G.window_dim), G.mouse)
        {
          src.x = xx G.mouse.x;
          src.y = xx G.mouse.y;
        }
        else
          readback.out_of_screen = true;
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
  using,only(readback_queue, device) G.gpu;
  if !QueueIsEmpty(readback_queue)
  {
    if readback_queue.count > 3
      log("GPU readback queue count = %. Interesting... Should we try to catch up?", readback_queue.count, flags=.VERBOSE_ONLY);

    peeked := QueuePeek(readback_queue);
    if SDL_QueryGPUFence(device, peeked.fence)
    {
      QueuePop(*readback_queue);
      SDL_ReleaseGPUFence(device, peeked.fence);
      downloaded_color: u32;

      if !peeked.out_of_screen
      {
        downloaded_data: *u32 = SDL_MapGPUTransferBuffer(device, peeked.download_transfer_buffer, false);

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

        SDL_UnmapGPUTransferBuffer(device, peeked.download_transfer_buffer);
      }

      G.hover_object = OBJ_ColorToKey(xx downloaded_color);
      SDL_ReleaseGPUTransferBuffer(device, peeked.download_transfer_buffer);
    }
  }
}

GPU_ResizeFramebuffer :: ()
{
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_world_depth);
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_mouse_picking_depth);
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_msaa);
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_resolve);
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_mouse_picking);

  window_width := cast(u32) G.window_dim.x;
  window_height := cast(u32) G.window_dim.y;
  G.gpu.tex_msaa = GPU_CreateMSAATexture(window_width, window_height);
  G.gpu.tex_resolve = GPU_CreateResolveTexture(window_width, window_height);
  G.gpu.tex_world_depth = GPU_CreateDepthTexture(window_width, window_height, false, false);
  G.gpu.tex_mouse_picking_depth = GPU_CreateDepthTexture(window_width, window_height, false, true);
  G.gpu.tex_mouse_picking = GPU_CreateMousePickingTexture(window_width, window_height);
}

GPU_CreateBuffer :: (usage: SDL_GPUBufferUsageFlags, size: u32, name: string) -> *SDL_GPUBuffer
{
  desc := SDL_GPUBufferCreateInfo.{usage = usage, size = size};
  result := SDL_CreateGPUBuffer(G.gpu.device, *desc);
  assert(!!result);
  if (name.count)
  SDL_SetGPUBufferName(G.gpu.device, result, temp_c_string(name));
  return result;
}

GPU_CreateDepthTexture :: (width: u32, height: u32, used_in_sampler: bool, sample_count_1: bool) -> *SDL_GPUTexture
{
  info := SDL_GPUTextureCreateInfo.{
    type = .SDL_GPU_TEXTURETYPE_2D,
    format = .D16_UNORM,
    width = width,
    height = height,
    layer_count_or_depth = 1,
    num_levels = 1,
    sample_count = G.gpu.sample_count,
    usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    props = G.gpu.clear_depth_props,
  };

  if used_in_sampler then info.usage |= SDL_GPU_TEXTUREUSAGE_SAMPLER;
  if sample_count_1 then info.sample_count = .SDL_GPU_SAMPLECOUNT_1;

  result := SDL_CreateGPUTexture(G.gpu.device, *info);
  assert(!!result); // @todo report err
  return result;
}

GPU_CreateMSAATexture :: (width: u32, height: u32) -> *SDL_GPUTexture
{
  if G.gpu.sample_count == .SDL_GPU_SAMPLECOUNT_1 return null;

  info := SDL_GPUTextureCreateInfo.{
    type = .SDL_GPU_TEXTURETYPE_2D,
    format = SDL_GetGPUSwapchainTextureFormat(G.gpu.device, G.window),
    width = width,
    height = height,
    layer_count_or_depth = 1,
    num_levels = 1,
    sample_count = G.gpu.sample_count,
    usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
    props = G.gpu.clear_color_props,
  };

  result := SDL_CreateGPUTexture(G.gpu.device, *info);
  assert(!!result); // @todo report err
  return result;
}

GPU_CreateResolveTexture :: (width: u32, height: u32) -> *SDL_GPUTexture
{
  if G.gpu.sample_count == .SDL_GPU_SAMPLECOUNT_1 return null;

  info := SDL_GPUTextureCreateInfo.{
    type = .SDL_GPU_TEXTURETYPE_2D,
    format = SDL_GetGPUSwapchainTextureFormat(G.gpu.device, G.window),
    width = width,
    height = height,
    layer_count_or_depth = 1,
    num_levels = 1,
    sample_count = .SDL_GPU_SAMPLECOUNT_1,
    usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER, // @todo remove SAMPLER?
    props = G.gpu.clear_color_props,
  };

  result := SDL_CreateGPUTexture(G.gpu.device, *info);
  assert(!!result); // @todo report err
  return result;
}

GPU_CreateMousePickingTexture :: (width: u32, height: u32) -> *SDL_GPUTexture
{
  info := SDL_GPUTextureCreateInfo.{
    type = .SDL_GPU_TEXTURETYPE_2D,
    format = .B8G8R8A8_UNORM, // @todo Pick this from swapchain texture format? But be careful when reading from it?
    width = width,
    height = height,
    layer_count_or_depth = 1,
    num_levels = 1,
    sample_count = .SDL_GPU_SAMPLECOUNT_1,
    usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
    props = G.gpu.clear_mouse_picking_props,
  };

  result := SDL_CreateGPUTexture(G.gpu.device, *info);
  assert(!!result); // @todo report err
  SDL_SetGPUTextureName(G.gpu.device, result, "MousePickingTexture");
  return result;
}

GPU_TransferBuffer :: (cmd: *SDL_GPUCommandBuffer, gpu_buffer: *SDL_GPUBuffer, data: *void, data_size: u32)
{
  // create transfer buffer
  trans_desc := SDL_GPUTransferBufferCreateInfo.{
    usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    size = data_size
  };
  buf_transfer := SDL_CreateGPUTransferBuffer(G.gpu.device, *trans_desc);
  assert(!!buf_transfer); // @todo report err

  // CPU memory -> GPU memory
  {
    map : *void = SDL_MapGPUTransferBuffer(G.gpu.device, buf_transfer, false);
    memcpy(map, data, data_size);
    SDL_UnmapGPUTransferBuffer(G.gpu.device, buf_transfer);
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
    SDL_UploadToGPUBuffer(copy_pass, *buf_location, *dst_region, false);

    SDL_EndGPUCopyPass(copy_pass);
  }

  SDL_ReleaseGPUTransferBuffer(G.gpu.device, buf_transfer);
}

GPU_UpdateWorldUniform :: (cmd: *SDL_GPUCommandBuffer, uniform: WORLD_Uniform)
{
  uniform_hash := Hash64Any(uniform);
  if (G.gpu.bound_uniform_hash != uniform_hash)
  {
    G.gpu.bound_uniform_hash = uniform_hash;
    SDL_PushGPUVertexUniformData(cmd, 0, *uniform, size_of(type_of(uniform)));
    SDL_PushGPUFragmentUniformData(cmd, 0, *uniform, size_of(type_of(uniform)));
  }
}

GPU_UpdateUIUniform :: (cmd: *SDL_GPUCommandBuffer, uniform: UI_Uniform)
{
  uniform_hash := Hash64Any(uniform);
  if (G.gpu.bound_uniform_hash != uniform_hash)
  {
    G.gpu.bound_uniform_hash = uniform_hash;
    SDL_PushGPUVertexUniformData(cmd, 0, *uniform, size_of(type_of(uniform)));
    // SDL_PushGPUFragmentUniformData(cmd, 0, *uniform, size_of(type_of(uniform)));
  }
}

GPU_Deinit :: ()
{
  for G.gpu.world_pipelines
  {
    SDL_ReleaseGPUGraphicsPipeline(G.gpu.device, it);
  }
  SDL_ReleaseGPUGraphicsPipeline(G.gpu.device, G.gpu.ui_pipeline);

  // SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_depth);
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_msaa);
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.tex_resolve);

  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.shadow_tex);
  SDL_ReleaseGPUSampler(G.gpu.device, G.gpu.shadow_sampler);

  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.dummy_shadow_tex);
  SDL_ReleaseGPUBuffer(G.gpu.device, G.gpu.dummy_instance_buffer);

  // Mesh
  SDL_ReleaseGPUSampler(G.gpu.device, G.gpu.mesh_tex_sampler);

  // UI
  SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.ui.gpu_atlas_texture);
  SDL_ReleaseGPUSampler(G.gpu.device, G.gpu.ui.gpu_atlas_sampler);
  SDL_ReleaseGPUBuffer(G.gpu.device, G.gpu.ui.gpu_indices);
  SDL_ReleaseGPUBuffer(G.gpu.device, G.gpu.ui.gpu_shape_buffer);
  SDL_ReleaseGPUBuffer(G.gpu.device, G.gpu.ui.gpu_clip_buffer);
}
