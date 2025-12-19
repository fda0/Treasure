B_PieBuilder :: struct
{
  file: Flat_Pool;

  active_list: *PIE_ListUntyped;
  active_list_type: Type;

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

//
// @todo B_MergePieBuilders appears to work.
//       Explore ways of making this code less insane.
//
B_MergePieBuilders :: (dst: *B_PieBuilder, src: *B_PieBuilder)
{
  dst_off: s64 = dst.file.current_point - dst.file.memory_base;
  src_off: s64 = src.file.current_point - src.file.memory_base;

  FixOffset :: (target: *$T) #expand
  {
    data: *s64;
    align := 1;

    #if T == PIE_List {
      data = *target.offset;
      align = align_of(T);
    } else #if T == string {
      data = xx  *target.data;
    } else #if type_info(T).type == .ARRAY {
      data = xx  *target.data;
      align = array_align_of(T);
    }

    data.* += dst_off;
    assert(data.* % align == 0);
  }

  for *model: src.models
  {
    if model.is_skinned {
      model.skeleton_index += xx dst.skeletons.count;
    }

    for i: MakeRange(model.meshes.count)
    {
      mesh := (src.file.memory_base + model.meshes.offset + i * size_of(PIE_Mesh)).(*PIE_Mesh);
      mesh.material_index += xx dst.materials.count;
      mesh.vertices_start_index += xx dst.vertices.count;
      mesh.indices_start_index += xx dst.indices.count;
    }

    FixOffset(*model.name);
    model.meshes.offset += dst_off;
  }

  for *skeleton: src.skeletons
  {
    for i: MakeRange(skeleton.name_ranges.count)
    {
      name_range := (src.file.memory_base + skeleton.name_ranges.offset + i * size_of(Range(s64))).(*Range(s64));
      name_range.min += dst_off;
      name_range.max += dst_off;
    }

    for i: MakeRange(skeleton.anims.count)
    {
      anim := (src.file.memory_base + skeleton.anims.offset + i * size_of(PIE_Animation)).(*PIE_Animation);
      for j: MakeRange(anim.channels.count)
      {
        channel := (src.file.memory_base + anim.channels.offset + j * size_of(PIE_AnimationChannel)).(*PIE_AnimationChannel);
        channel.inputs.offset += dst_off;
        channel.outputs.offset += dst_off;
      }

      anim.name.offset += dst_off;
      anim.channels.offset += dst_off;
    }

    skeleton.inverse_matrices.offset += dst_off;
    skeleton.child_index_buffer.offset += dst_off;
    skeleton.child_index_ranges.offset += dst_off;
    skeleton.translations.offset += dst_off;
    skeleton.rotations.offset += dst_off;
    skeleton.scales.offset += dst_off;
    skeleton.name_ranges.offset += dst_off;
    skeleton.anims.offset += dst_off;
  }

  for *material: src.materials
  {
    material.name.offset += dst_off;
    material.tex.full_data.offset += dst_off;
    material.tex.sections.offset += dst_off;
  }

  for *shader: src.shaders
  {
    shader.data.offset += dst_off;
    shader.info.offset += dst_off;
  }

  for *font: src.fonts
  {
    font.data.offset += dst_off;
    font.info.offset += dst_off;
  }

  for *sound: src.sounds
  {
    sound.data.offset += dst_off;
  }

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

  B_FileAllocType(PIE_Header);
}

B_FinalizePieBuilder :: ()
{
  // Prepare PIE_Links and append it to memory
  links: PIE_Links;
  B_ListSetArray(*links.vertices, context.pie.vertices);
  B_ListSetArray(*links.indices, context.pie.indices);
  B_ListSetArray(*links.models, context.pie.models);
  B_ListSetArray(*links.skeletons, context.pie.skeletons);
  B_ListSetArray(*links.materials, context.pie.materials);
  B_ListSetArray(*links.shaders, context.pie.shaders);
  B_ListSetArray(*links.fonts, context.pie.fonts);
  B_ListSetArray(*links.sounds, context.pie.sounds);

  // Prepare PIE_Header
  header := context.pie.file.memory_base.(*PIE_Header);
  B_ListSetValue(*header.links, links);

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

B_NewArray :: (count: s64, $T: Type, aligned := true) -> [] T
{
  if (aligned) B_FileAlignToType(T);

  size_bytes := count * size_of(T);
  memory := get(*context.pie.file, size_bytes);
  memset(memory, 0, size_bytes);
  return [] T.{count, memory};
}



// ListStart / ListEnd
B_ListStart :: (list: *PIE_List($LT))
{
  Check(!list.count);
  Check(!context.pie.active_list && !context.pie.active_list_type);
  context.pie.active_list = list;
  context.pie.active_list_type = LT;

  B_FileAlignToType(LT);
  list.offset = B_CurrentFileOffset();
}

B_ListEnd :: ()
{
  // Check that ListStart was called first
  Check(context.pie.active_list && context.pie.active_list_type);
  Check(!context.pie.active_list.count);

  // Calculate offet / count
  current_offset := B_CurrentFileOffset();
  Check(current_offset >= context.pie.active_list.offset);
  size_bytes := current_offset - context.pie.active_list.offset;

  type_size := context.pie.active_list_type.(*Type_Info).runtime_size;
  Check(size_bytes % type_size == 0);

  context.pie.active_list.count = size_bytes / type_size;

  // Clean up active_list references
  context.pie.active_list = null;
  memset(*context.pie.active_list_type, 0, size_of(Type));
}

// AllocInFile
B_FileAllocBytes :: (size: s64) -> *void
{
  bytes := get(*context.pie.file, size);
  memset(bytes, 0, size);
  return bytes;
}

B_FileAllocType :: ($T: Type) -> *T
{
  Check(B_FileIsAlignedToType(T));
  Check(!context.pie.active_list_type || context.pie.active_list_type == T);
  return B_FileAllocBytes(size_of(T));
}

B_FileAllocArray :: (count: s64, $T: Type) -> [] T
{
  Check(B_FileIsAlignedToType(T));
  Check(!context.pie.active_list_type || context.pie.active_list_type == T);

  result: [] T;
  result.count = count;
  result.data = B_FileAllocBytes(count * size_of(T));
  return result;
}

// FileAppend
B_FileAppendValue :: (value: $T)
{
  Check(!context.pie.active_list_type || context.pie.active_list_type == T);
  dst := B_FileAllocType(T);
  dst.* = value;
}

B_FileAppendArray :: (array: [] $T)
{
  dst := B_FileAllocArray(array.count, T);
  memcpy(dst.data, array.data, size_of(T)*array.count);
}

B_FileAppendString :: (str: string)
{
  B_FileAppendArray(cast([] u8) str);
}

B_FileAppendPrint :: (format_string: string, args: .. Any)
{
  auto_release_temp();
  printed := tprint(format_string, ..args);
  B_FileAppendString(printed);
}

// ListAlloc
B_ListAllocArray :: (list: *PIE_List($LT), count: s64, $T: Type) -> [] T
{
  #assert(LT == T);
  B_ListStart(list);
  result := B_FileAllocArray(count, T);
  B_ListEnd();
  return result;
}

// ListSet
B_ListSetValue :: (list: *PIE_List($LT), value: $T)
{
  #assert(LT == T);
  B_ListStart(list);
  B_FileAppendValue(value);
  B_ListEnd();
}

B_ListSetArray :: (list: *PIE_List($LT), array: [] $T)
{
  #assert(LT == T);
  B_ListStart(list);
  B_FileAppendArray(array);
  B_ListEnd();
}

B_ListSetString :: (list: *PIE_List($LT), str: string)
{
  #assert(LT == u8);
  B_ListStart(list);
  B_FileAppendString(str);
  B_ListEnd();
}

B_ListSetPrint :: (list: *PIE_List($LT), format_string: string, args: .. Any)
{
  #assert(LT == u8);
  B_ListStart(list);
  B_FileAppendPrint(format_string, ..args);
  B_ListEnd();
}

