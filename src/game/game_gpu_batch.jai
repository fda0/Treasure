// @todo Drawing colliders results in 21906 transfer buffers created vs 1501...
//       And that's on the first frame alone! Even the regular 1501 is insane. Needs debugging!
// @todo Collect per frame gpu stats and display them in dev UI so these things are more obvious.

/* @todo
- Do not free and allocate transfers and buffers all the time. Reuse them.
- Think about overlapping GPU work. Now everything happens at the end of the frame in the final command buffer.
*/

GPU_BATCH_Type :: enum // @todo this will be replaced by simpler U64 key/hash in the future
{
  Unknown;
  MeshVertices;
  ModelInstances;
  Poses;
};

GPU_BATCH_Target :: struct // @todo this will be replaced by simpler U64 key/hash in the future
{
  type: GPU_BATCH_Type;
  material_key: MATERIAL_Key;
  model_key: MODEL_Key;
};

GPU_BATCH_Transfer :: struct
{
  handle: *SDL_GPUTransferBuffer;
  cap: u32; // in bytes

  used: u32; // in bytes
  mapped_memory: *void;
  next: *GPU_BATCH_Transfer;
};

GPU_BATCH_Buffer :: struct
{
  handle: *SDL_GPUBuffer;
  cap: u32;

  next: *GPU_BATCH_Buffer; // used by free list only
};

GPU_Batch :: struct
{
  // can live between frames
  target: GPU_BATCH_Target;
  buffer: *GPU_BATCH_Buffer;

  // cleared after every frame
  transfer_first: *GPU_BATCH_Transfer;
  transfer_last: *GPU_BATCH_Transfer;
  total_used: u32;
  element_count: u32;
};

GPU_BATCH_State :: struct
{
  arena: Arena; // for allocating GPU_TransferStorage, GPU_BufferStorage

  // these free list don't hold any GPU resources, just a way to reuse CPU memory
  free_transfers: *GPU_BATCH_Transfer;
  free_buffers: *GPU_BATCH_Buffer;

  batches: [2048] GPU_Batch;
  batches_count: u32;
};

GPU_BATCH_TargetMatch :: (a: GPU_BATCH_Target, b: GPU_BATCH_Target) -> bool
{
  if (a.type == b.type)
  {
    if (a.type == .MeshVertices)
      return MatchKey(a.material_key, b.material_key);

    if (a.type == .ModelInstances)
      return MatchKey(a.model_key, b.model_key);
  }
  return false;
}

GPU_BATCH_FindBundle :: (target: GPU_BATCH_Target) -> *GPU_Batch
{
  batch: *GPU_Batch;
  for MakeRange(G.gpu.mem.batches_count)
  {
    search := *G.gpu.mem.batches[it];
    if (GPU_BATCH_TargetMatch(search.target, target))
    {
      batch = search;
      break;
    }
  }
  return batch;
}

GPU_BATCH_FindOrCreateBundle :: (target: GPU_BATCH_Target) -> *GPU_Batch
{
  batch := GPU_BATCH_FindBundle(target);
  if (!batch)
  {
    assert(G.gpu.mem.batches_count < G.gpu.mem.batches.count);
    batch = *G.gpu.mem.batches[G.gpu.mem.batches_count];
    G.gpu.mem.batches_count += 1;
    // We don't need to clear batch since
    // batches array is zero initialized on game launch.
    // + G.gpu.mem.batches_count isn't reset between frames.
    batch.target = target;
  }
  return batch;
}

GPU_BATCH_TransferUnmap :: (transfer: *GPU_BATCH_Transfer)
{
  assert(!!transfer.mapped_memory);
  SDL_UnmapGPUTransferBuffer(G.gpu.device, transfer.handle);
  transfer.mapped_memory = null;
}

GPU_BATCH_TransferCreate :: (batch: *GPU_Batch, size: u32) -> *GPU_BATCH_Transfer
{
  // Calculate rounded-up alloc_size
  alloc_size := CeilPow2(size*2);
  if (batch.buffer)
    alloc_size = Max(alloc_size, batch.buffer.cap);

  // Reclaim GPU_BATCH_TransferStorage from free list or allocate a new one
  // Zero initialize it
  result := G.gpu.mem.free_transfers;
  {
    if result  G.gpu.mem.free_transfers = G.gpu.mem.free_transfers.next;
    else       result = New(GPU_BATCH_Transfer, initialized=false,, G.gpu.mem.arena);
    Initialize(result);
  }

  // stats
  Increment(.GPU_BATCH_TRANSFER_BUFFERS_CREATED, 1);
  Increment(.GPU_BATCH_TRANSFER_BUFFERS_SIZE, alloc_size);

  // GPU alloc new transfer buffer and map it
  transfer_info := SDL_GPUTransferBufferCreateInfo.{
    usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    size = alloc_size
  };
  result.handle = SDL_CreateGPUTransferBuffer(G.gpu.device, *transfer_info);
  result.cap = alloc_size;
  result.mapped_memory = SDL_MapGPUTransferBuffer(G.gpu.device, result.handle, false);

  // Chain result into its GPU_BATCH_Entry
  {
    if (batch.transfer_last)
      batch.transfer_last.next = result;

    batch.transfer_last = result;

    if (!batch.transfer_first)
      batch.transfer_first = result;
  }

  return result;
}

GPU_BATCH_TransferGetMappedMemory :: (batch: *GPU_Batch, size: u32, elem_count: u32) -> *void
{
  batch.element_count += elem_count;

  transfer := batch.transfer_last;
  if (transfer)
  {
    assert(transfer.cap >= transfer.used);
    if (transfer.cap - transfer.used < size)
    {
      GPU_BATCH_TransferUnmap(transfer);
      transfer = null;
    }
  }

  if (!transfer)
    transfer = GPU_BATCH_TransferCreate(batch, size);

  result := cast(*u8) transfer.mapped_memory + transfer.used;
  batch.total_used += size;
  transfer.used += size;
  return result;
}

GPU_BATCH_TransferUploadBytes :: (batch: *GPU_Batch, data: *void, size: u32, elem_count: u32)
{
  dst := GPU_BATCH_TransferGetMappedMemory(batch, size, elem_count);
  memcpy(dst, data, size);
}

//
GPU_BATCH_AllocBuffer :: (alloc_size: u32, usage: SDL_GPUBufferUsageFlags) -> *GPU_BATCH_Buffer
{
  buffer := G.gpu.mem.free_buffers;
  {
    if buffer  G.gpu.mem.free_buffers = G.gpu.mem.free_buffers.next;
    else       buffer = New(GPU_BATCH_Buffer, initialized=false,, G.gpu.mem.arena);
    Initialize(buffer);
  }

  buffer_info := SDL_GPUBufferCreateInfo.{usage = usage, size = alloc_size};
  buffer.handle = SDL_CreateGPUBuffer(G.gpu.device, *buffer_info);
  buffer.cap = alloc_size;
  return buffer;
}

GPU_BATCH_UploadBatch :: (copy_pass: *SDL_GPUCopyPass, batch: *GPU_Batch)
{
  if (batch.total_used)
  {
    // Check if current buffer is big enough.
    // Free it if it's too small.
    if (batch.buffer)
    {
      if (batch.buffer.cap < batch.total_used)
      {
        SDL_ReleaseGPUBuffer(G.gpu.device, batch.buffer.handle);

        // Move BufferStorage to free list
        batch.buffer.next = G.gpu.mem.free_buffers;
        G.gpu.mem.free_buffers = batch.buffer;
        batch.buffer = null;
      }
    }

    // Allocate buffer
    if (!batch.buffer)
    {
      usage: SDL_GPUBufferUsageFlags;
      if (batch.target.type == .MeshVertices)
        usage |= SDL_GPU_BUFFERUSAGE_VERTEX;
      else
        usage |= SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;

      batch.buffer = GPU_BATCH_AllocBuffer(CeilPow2(batch.total_used*2), usage);
    }

    // Transfers -> Buffer
    {
      offset: u32;
      transfer := batch.transfer_first;
      while (transfer)
      {
        source := SDL_GPUTransferBufferLocation.{ transfer_buffer = transfer.handle };
        destination := SDL_GPUBufferRegion.{
          buffer = batch.buffer.handle,
          offset = offset,
          size = transfer.used
        };
        SDL_UploadToGPUBuffer(copy_pass, *source, *destination, false);

        offset += transfer.used;
        transfer = transfer.next;
      }
    }

    // Free transfers
    transfer := batch.transfer_first;
    while (transfer)
    {
      next := transfer.next;

      SDL_ReleaseGPUTransferBuffer(G.gpu.device, transfer.handle);
      transfer.next = G.gpu.mem.free_transfers;
      G.gpu.mem.free_transfers = transfer;

      transfer = next;
    }

    // clear batch transfer links
    batch.transfer_first = null;
    batch.transfer_last = null;
  }
}

GPU_BATCH_UploadAllBatches :: (cmd: *SDL_GPUCommandBuffer)
{
  copy_pass := SDL_BeginGPUCopyPass(cmd);

  for batch_index: MakeRange(G.gpu.mem.batches_count)
  {
    batch := *G.gpu.mem.batches[batch_index];
    GPU_BATCH_UploadBatch(copy_pass, batch);
  }

  SDL_EndGPUCopyPass(copy_pass);
}

GPU_BATCH_PostFrame :: ()
{
  for batch_index: MakeRange(G.gpu.mem.batches_count)
  {
    batch := *G.gpu.mem.batches[batch_index];
    assert(!batch.transfer_first);
    assert(!batch.transfer_last);
    batch.total_used = 0;
    batch.element_count = 0;
  }
}

GPU_BATCH_GetPosesBatch :: () -> *GPU_Batch
{
  return G.gpu.mem.batches.data;
}

GPU_BATCH_Init :: ()
{
  init(*G.gpu.mem.arena);
  // reserve poses batch
  G.gpu.mem.batches_count += 1;
  G.gpu.mem.batches[0].target.type = .Poses;
  G.gpu.mem.batches[0].buffer = GPU_BATCH_AllocBuffer(16, SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ);
}

GPU_BATCH_Deinit :: ()
{
  for batch_index: MakeRange(G.gpu.mem.batches_count)
  {
    batch := *G.gpu.mem.batches[batch_index];
    if (batch.buffer)
      SDL_ReleaseGPUBuffer(G.gpu.device, batch.buffer.handle);
  }
}
