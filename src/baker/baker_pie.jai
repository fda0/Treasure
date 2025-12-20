B_PieBuilder :: struct
{
  file: Flat_Pool;

  vertices: [..] RD_WorldVertex;
  indices: [..] u16;

  models: [..] PIE_Model;
  skeletons: [..] PIE_Skeleton;
  materials: [..] PIE_Material;

  shaders: [..] PIE_Blob;
  fonts: [..] PIE_Blob;
  sounds: [..] PIE_Sound;
}

#add_context pie: *B_PieBuilder;

B_OffsetPieBuilderAddresses :: (builder: *B_PieBuilder, address_offset: s64)
{
  ApplyOffset :: (target: *$T) #expand
  {
    data: *s64;
    align := 1;

    #if T == string {
      data = xx  *target.data;
    } else #if type_info(T).type == .ARRAY {
      data = xx  *target.data;
      align = array_align_of(target.*);
    } else {
      data = *target.offset;
      align = align_of(T);
    }

    data.* += address_offset;
    assert(data.* % align == 0);
  }

  for * model: builder.models
  {
    ApplyOffset(*model.name);
    ApplyOffset(*model.meshes);
  }

  for * skeleton: builder.skeletons
  {
    for * skeleton.names {
      ApplyOffset(it);
    }

    for * anim: skeleton.anims
    {
      for * channel: anim.channels
      {
        ApplyOffset(*channel.inputs);
        ApplyOffset(*channel.outputs);
      }
      ApplyOffset(*anim.name);
      ApplyOffset(*anim.channels);
    }

    ApplyOffset(*skeleton.inverse_matrices);
    ApplyOffset(*skeleton.child_index_buffer);
    ApplyOffset(*skeleton.child_index_ranges);
    ApplyOffset(*skeleton.translations);
    ApplyOffset(*skeleton.rotations);
    ApplyOffset(*skeleton.scales);
    ApplyOffset(*skeleton.names);
    ApplyOffset(*skeleton.anims);
  }

  for * material: builder.materials
  {
    ApplyOffset(*material.name);
    ApplyOffset(*material.tex.buffer);
    ApplyOffset(*material.tex.sections);
  }

  for * shader: builder.shaders
  {
    ApplyOffset(*shader.buffer);
    ApplyOffset(*shader.info);
  }

  for * font: builder.fonts
  {
    ApplyOffset(*font.buffer);
    ApplyOffset(*font.info);
  }

  for * sound: builder.sounds
  {
    ApplyOffset(*sound.buffer);
  }
}

B_MergePieBuilders :: (dst: *B_PieBuilder, src: *B_PieBuilder)
{
  dst_off: s64 = dst.file.current_point - dst.file.memory_base;
  src_off: s64 = src.file.current_point - src.file.memory_base;

  for * model: src.models {
    if model.is_skinned {
      model.skeleton_index += xx dst.skeletons.count;
    }
  }

  for src.models
  {
    for * it.meshes
    {
      it.material_index += xx dst.materials.count;
      it.vertices_start_index += xx dst.vertices.count;
      it.indices_start_index += xx dst.indices.count;
    }
  }

  B_OffsetPieBuilderAddresses(src, dst_off);

  array_add_from_another_array(*dst.vertices, src.vertices);
  array_add_from_another_array(*dst.indices, src.indices);
  array_add_from_another_array(*dst.models, src.models);
  array_add_from_another_array(*dst.skeletons, src.skeletons);
  array_add_from_another_array(*dst.materials, src.materials);
  array_add_from_another_array(*dst.shaders, src.shaders);
  array_add_from_another_array(*dst.fonts, src.fonts);
  array_add_from_another_array(*dst.sounds, src.sounds);

  dst_file_mem := get(*dst.file, src_off);
  memcpy(dst_file_mem, src.file.memory_base, src_off);
}

B_InitPieBuilder :: ()
{
  context.pie.file.alignment = 1; // We are doing our own, tightly packed, precise alignment on per-type basis.
  init(*context.pie.file, reserve = Gigabyte(2));

  remember_allocators(*context.pie.vertices);
  remember_allocators(*context.pie.indices);
  remember_allocators(*context.pie.models);
  remember_allocators(*context.pie.skeletons);
  remember_allocators(*context.pie.materials);
  remember_allocators(*context.pie.shaders);
  remember_allocators(*context.pie.fonts);
  remember_allocators(*context.pie.sounds);

  B_NewArray(1, PIE_Header);
}

B_FinalizePieBuilder :: ()
{
  header := context.pie.file.memory_base.(*PIE_Header);

  header.links = B_NewArray(1, PIE_Links);
  header.links[0].vertices = B_CopyArray(context.pie.vertices);
  header.links[0].indices = B_CopyArray(context.pie.indices);
  header.links[0].models = B_CopyArray(context.pie.models);
  header.links[0].skeletons = B_CopyArray(context.pie.skeletons);
  header.links[0].materials = B_CopyArray(context.pie.materials);
  header.links[0].shaders = B_CopyArray(context.pie.shaders);
  header.links[0].fonts = B_CopyArray(context.pie.fonts);
  header.links[0].sounds = B_CopyArray(context.pie.sounds);

  // Calculate hash
  hashable_file := StrFirstLast(header.(*u8) + size_of(type_of(PIE_Header.file_hash)), context.pie.file.current_point);
  header.file_hash = Hash64Any(PIE_MAGIC_HASH_SEED, hashable_file);
}

B_SaveToFile :: (file_path: string)
{
  content := StrFirstLast(context.pie.file.memory_base, context.pie.file.current_point);
  write_entire_file(file_path, content);
}

//
// File buffer / List helers
//
B_CurrentFileOffset :: () -> s64
{
  offset := context.pie.file.current_point - context.pie.file.memory_base;
  return offset;
}


// Alignment
B_FileAlign :: (alignment: s64)
{
  current_offset := B_CurrentFileOffset();
  missaligned_bytes := current_offset % alignment;
  if missaligned_bytes
  {
    to_align := alignment - missaligned_bytes;
    align_bytes_memory := get(*context.pie.file, to_align);
    memset(align_bytes_memory, 0, to_align);
  }
}

B_FileAlignToType :: ($T: Type)
{
  B_FileAlign(align_of(T));
}

B_FileIsAlignedToType :: ($T: Type) -> bool
{
  current_offset := B_CurrentFileOffset();
  alignment := align_of(T);
  missaligned_bytes := current_offset % alignment;
  return missaligned_bytes == 0;
}


B_CopyString :: (s: string) -> string
{
  memory := get(*context.pie.file, s.count);
  memcpy(memory, s.data, s.count);
  return string.{s.count, memory};
}

B_CopyArray :: (a: [] $T) -> [] T
{
  result := B_NewArray(a.count, T, initialized = false);
  memcpy(result.data, a.data, result.count);
  return result;
}

B_NewArray :: (count: s64, $T: Type, initialized := true, aligned := true) -> [] T
{
  if (aligned) B_FileAlignToType(T);

  size_bytes := count * size_of(T);
  memory := get(*context.pie.file, size_bytes);
  if (initialized) memset(memory, 0, size_bytes);

  return [] T.{count, memory};
}


