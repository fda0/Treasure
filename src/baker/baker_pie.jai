PIE_Builder :: struct
{
  file: Flat_Pool;

  active_list: *PIE_List;
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

//
// Init, Finalize, Save to file
//

PIE_InitBuilder :: ()
{
  using B.pie;
  file.alignment = 1; // We are doing our own, tightly packed, precise alignment on per-type basis.
  init(*file, reserve = Gigabyte(2));
  remember_allocators(*vertices);
  remember_allocators(*indices);
  remember_allocators(*models);
  remember_allocators(*skeletons);
  remember_allocators(*materials);
  remember_allocators(*shaders);
  remember_allocators(*fonts);
  remember_allocators(*sounds);

  PIE_FileAllocType(PIE_Header);
}

PIE_FinalizeBuilder :: ()
{
  using B.pie;

  // Prepare PIE_Links and append it to memory
  links: PIE_Links;
  PIE_ListSetArray(*links.models.vertices, vertices);
  PIE_ListSetArray(*links.models.indices, indices);
  PIE_ListSetArray(*links.models.list, models);
  PIE_ListSetArray(*links.skeletons, skeletons);
  PIE_ListSetArray(*links.materials, materials);
  PIE_ListSetArray(*links.shaders, shaders);
  PIE_ListSetArray(*links.fonts, fonts);
  PIE_ListSetArray(*links.sounds, sounds);

  // Prepare PIE_Header
  header := file.memory_base.(*PIE_Header);
  PIE_ListSetValue(*header.links, links);

  // Calculate hash
  hashable_file := StrFirstLast(header.(*u8) + size_of(type_of(PIE_Header.file_hash)), file.current_point);
  header.file_hash = Hash64Any(PIE_MAGIC_HASH_SEED, hashable_file);
}

PIE_SaveToFile :: (file_path: string)
{
  using B.pie;
  content := StrFirstLast(file.memory_base, file.current_point);
  write_entire_file(file_path, content);
}

//
// File buffer / List helers
//
PIE_CurrentFileOffset :: () -> u32
{
  using B.pie;
  offset := file.current_point.(u64) - file.memory_base.(u64);
  return xx offset;
}

// Alignment
PIE_FileAlign :: (alignment: s64)
{
  using B.pie;

  current_offset := PIE_CurrentFileOffset();
  missaligned_bytes := current_offset % alignment;
  if missaligned_bytes
  {
    to_align := alignment - missaligned_bytes;
    align_bytes_memory := get(*file, to_align);
    memset(align_bytes_memory, 0, to_align);
  }
}

PIE_FileAlignToType :: ($T: Type)
{
  PIE_FileAlign(align_of(T));
}

PIE_FileIsAlignedToType :: ($T: Type) -> bool
{
  current_offset := PIE_CurrentFileOffset();
  alignment := align_of(T);
  missaligned_bytes := current_offset % alignment;
  return missaligned_bytes == 0;
}

// ListStart / ListEnd
PIE_ListStart :: (list: *PIE_ListT($LT))
{
  using B.pie;
  Check(!list.size);
  Check(!active_list && !active_list_type);
  active_list = list;
  active_list_type = LT;

  PIE_FileAlignToType(LT);
  list.offset = PIE_CurrentFileOffset();
}

PIE_ListEnd :: ()
{
  using B.pie;
  Check(active_list && active_list_type);
  Check(!active_list.size);

  current_offset := PIE_CurrentFileOffset();
  Check(current_offset >= active_list.offset);
  active_list.size = current_offset - active_list.offset;

  active_list_type_size := active_list_type.(*Type_Info).runtime_size;
  Check(active_list.size % active_list_type_size == 0);

  active_list = null;
  memset(*active_list_type, 0, size_of(Type));
}

// AllocInFile
PIE_FileAllocBytes :: (size: s64) -> *void
{
  bytes := get(*B.pie.file, size);
  memset(bytes, 0, size);
  return bytes;
}

PIE_FileAllocType :: ($T: Type) -> *T
{
  using B.pie;
  Check(PIE_FileIsAlignedToType(T));
  Check(!active_list_type || active_list_type == T);
  return PIE_FileAllocBytes(size_of(T));
}

PIE_FileAllocArray :: (count: s64, $T: Type) -> [] T
{
  using B.pie;
  Check(PIE_FileIsAlignedToType(T));
  Check(!active_list_type || active_list_type == T);

  result: [] T;
  result.count = count;
  result.data = PIE_FileAllocBytes(count * size_of(T));
  return result;
}

// FileAppend
PIE_FileAppendValue :: (value: $T)
{
  using B.pie;
  Check(!active_list_type || active_list_type == T);
  dst := PIE_FileAllocType(T);
  dst.* = value;
}

PIE_FileAppendArray :: (array: [] $T)
{
  using B.pie;
  dst := PIE_FileAllocArray(array.count, T);
  memcpy(dst.data, array.data, size_of(T)*array.count);
}

PIE_FileAppendString :: (str: string)
{
  using B.pie;
  PIE_FileAppendArray(cast([] u8) str);
}

PIE_FileAppendPrint :: (format_string: string, args: .. Any)
{
  auto_release_temp();
  printed := tprint(format_string, ..args);
  PIE_FileAppendString(printed);
}

// ListAlloc
PIE_ListAllocArray :: (list: *PIE_ListT($LT), count: s64, $T: Type) -> [] T
{
  #assert(LT == T);
  PIE_ListStart(list);
  result := PIE_FileAllocArray(count, T);
  PIE_ListEnd();
  return result;
}

// ListSet
PIE_ListSetValue :: (list: *PIE_ListT($LT), value: $T)
{
  #assert(LT == T);
  PIE_ListStart(list);
  PIE_FileAppendValue(value);
  PIE_ListEnd();
}

PIE_ListSetArray :: (list: *PIE_ListT($LT), array: [] $T)
{
  #assert(LT == T);
  PIE_ListStart(list);
  PIE_FileAppendArray(array);
  PIE_ListEnd();
}

PIE_ListSetString :: (list: *PIE_ListT($LT), str: string)
{
  #assert(LT == u8);
  PIE_ListStart(list);
  PIE_FileAppendString(str);
  PIE_ListEnd();
}

PIE_ListSetPrint :: (list: *PIE_ListT($LT), format_string: string, args: .. Any)
{
  #assert(LT == u8);
  PIE_ListStart(list);
  PIE_FileAppendPrint(format_string, ..args);
  PIE_ListEnd();
}
