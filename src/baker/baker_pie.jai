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

B_OffsetAddress :: (target: *$T, offset: s64) #expand
{
  data: *s64 = xx *target.data;
  if (data.* == 0) return;

  align := 1;
  #if type_info(T).type == .ARRAY {
    align = array_align_of(target.*);
  }

  data.* += offset;
  assert(data.* % align == 0);
}

B_OffsetAddresses :: (builder_or_links: *$T, offset: s64)
{
  for * model: builder_or_links.models
  {
    B_OffsetAddress(*model.name, offset);
    B_OffsetAddress(*model.meshes, offset);
  }

  for * skeleton: builder_or_links.skeletons
  {
    for * skeleton.names {
      B_OffsetAddress(it, offset);
    }

    for * anim: skeleton.anims
    {
      for * channel: anim.channels
      {
        B_OffsetAddress(*channel.inputs, offset);
        B_OffsetAddress(*channel.outputs, offset);
      }
      B_OffsetAddress(*anim.name, offset);
      B_OffsetAddress(*anim.channels, offset);
    }

    B_OffsetAddress(*skeleton.inverse_matrices, offset);
    B_OffsetAddress(*skeleton.child_index_buffer, offset);
    B_OffsetAddress(*skeleton.child_index_ranges, offset);
    B_OffsetAddress(*skeleton.translations, offset);
    B_OffsetAddress(*skeleton.rotations, offset);
    B_OffsetAddress(*skeleton.scales, offset);
    B_OffsetAddress(*skeleton.names, offset);
    B_OffsetAddress(*skeleton.anims, offset);
  }

  for * material: builder_or_links.materials
  {
    B_OffsetAddress(*material.name, offset);
    B_OffsetAddress(*material.tex.buffer, offset);
    B_OffsetAddress(*material.tex.sections, offset);
  }

  for * shader: builder_or_links.shaders
  {
    B_OffsetAddress(*shader.buffer, offset);
    B_OffsetAddress(*shader.info, offset);
  }

  for * font: builder_or_links.fonts
  {
    B_OffsetAddress(*font.buffer, offset);
    B_OffsetAddress(*font.info, offset);
  }

  for * sound: builder_or_links.sounds
  {
    B_OffsetAddress(*sound.buffer, offset);
  }
}

B_MergePieBuilders :: (dst: *B_PieBuilder, src: *B_PieBuilder)
{
  // Rebase source indices
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

  // Rebase source address offsets
  src_to_dst_offset: s64 = dst.file.current_point - src.file.memory_base;
  B_OffsetAddresses(src, src_to_dst_offset);

  // Copy pie file content
  src_file_size: s64 = src.file.current_point - src.file.memory_base;
  dst_append_memory := get(*dst.file, src_file_size);
  memcpy(dst_append_memory, src.file.memory_base, src_file_size);

  // Copy arrays
  array_add_from_another_array(*dst.vertices, src.vertices);
  array_add_from_another_array(*dst.indices, src.indices);
  array_add_from_another_array(*dst.models, src.models);
  array_add_from_another_array(*dst.skeletons, src.skeletons);
  array_add_from_another_array(*dst.materials, src.materials);
  array_add_from_another_array(*dst.shaders, src.shaders);
  array_add_from_another_array(*dst.fonts, src.fonts);
  array_add_from_another_array(*dst.sounds, src.sounds);

  // Clear src to avoid use after merge
  array_reset(*src.vertices);
  array_reset(*src.indices);
  array_reset(*src.models);
  array_reset(*src.skeletons);
  array_reset(*src.materials);
  array_reset(*src.shaders);
  array_reset(*src.fonts);
  array_reset(*src.sounds);
  fini(*src.file);
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

  // Fill links
  header.links = B_NewArray(1, PIE_Links);
  header.links[0].vertices = B_CopyArray(context.pie.vertices);
  header.links[0].indices = B_CopyArray(context.pie.indices);
  header.links[0].models = B_CopyArray(context.pie.models);
  header.links[0].skeletons = B_CopyArray(context.pie.skeletons);
  header.links[0].materials = B_CopyArray(context.pie.materials);
  header.links[0].shaders = B_CopyArray(context.pie.shaders);
  header.links[0].fonts = B_CopyArray(context.pie.fonts);
  header.links[0].sounds = B_CopyArray(context.pie.sounds);

  // Rebase arrays/strings in pie builder to base address 0 before serialization.
  to_zero_offset := 0 - header.(s64);
  B_OffsetAddresses(*header.links[0], to_zero_offset);
  B_OffsetAddress(*header.links[0].vertices, to_zero_offset);
  B_OffsetAddress(*header.links[0].indices, to_zero_offset);
  B_OffsetAddress(*header.links[0].models, to_zero_offset);
  B_OffsetAddress(*header.links[0].skeletons, to_zero_offset);
  B_OffsetAddress(*header.links[0].materials, to_zero_offset);
  B_OffsetAddress(*header.links[0].shaders, to_zero_offset);
  B_OffsetAddress(*header.links[0].fonts, to_zero_offset);
  B_OffsetAddress(*header.links[0].sounds, to_zero_offset);
  B_OffsetAddress(*header.links, to_zero_offset);

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

B_CopyString :: (s: string) -> string
{
  memory := get(*context.pie.file, s.count);
  memcpy(memory, s.data, s.count);
  return string.{s.count, memory};
}

B_CopyArray :: (a: [] $T) -> [] T
{
  result := B_NewArray(a.count, T, initialized = false);
  memcpy(result.data, a.data, array_size_bytes(result));
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
