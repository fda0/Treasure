//
// This file describes PIE file format - which is produced by "baker" asset preprocessor.
// .pie files pack all the data needed by the game like models' meshes & animations, materials, textures.
//

PIE_List :: struct
{
  type: u32; // @todo simplify: remove this
  count: u32; // @todo simplify: remove this
  offset: u32;
  size: u32;
}

PIE_ListT :: struct($T: Type)
{
  using #as l: PIE_List;
}

PIE_AnimationChannelType :: enum u32
{
  Translation;
  Rotation;
  Scale;
}

PIE_AnimationChannel :: struct
{
  joint_index30_type2: u32;  // [u32 | (PIE_AnimationChannelType << 30)] // @todo this is silly, simplify
  inputs: PIE_ListT(float);  // float * count
  outputs: PIE_ListT(float); // float * (3 or 4 [V3 or Quat]) * count
}

PIE_Animation :: struct
{
  name: PIE_ListT(u8);
  t_min, t_max: float;
  channels: PIE_ListT(PIE_AnimationChannel);
}

PIE_Skeleton :: struct
{
  // each of these has the same count of elements (joints_count)
  inverse_matrices: PIE_ListT(Mat4);
  child_index_buffer: PIE_ListT(u32); // @todo use u16 here?
  child_index_ranges: PIE_ListT(Range(u32)); // @todo use u16 here?
  translations: PIE_ListT(V3);
  rotations: PIE_ListT(Quat);
  scales: PIE_ListT(V3);
  name_ranges: PIE_ListT(Range(u32)); // offset of min & max char* - can be transformed to S8

  anims: PIE_ListT(PIE_Animation);
  root_transform: Mat4;
}

PIE_Mesh :: struct
{
  material_index: u32;

  vertices_start_index: u32;
  indices_start_index: u32;
  indices_count: u32;
}

PIE_Model :: struct
{
  name: PIE_ListT(u8);
  is_skinned: bool;
  skeleton_index: u32 ; // for skinned only
  meshes: PIE_ListT(PIE_Mesh);
}

PIE_MaterialTexSection :: struct
{
  width: u32;
  height: u32;
  lod: u32;
  layer: u32;
  // relative to full_data of Material
  data_offset: u32;
  data_size: u32;
}

PIE_TexFormat :: enum u32
{
  Empty;
  R8G8B8A8;
  BC7_RGBA;
}

PIE_MaterialFlags :: enum_flags u32
{
  HasAlpha;
}

PIE_MaterialParams :: struct
{
  flags: PIE_MaterialFlags;
  diffuse: u32;
  specular: u32;
  roughness: float; // [0:1]
}

PIE_Material :: struct
{
  name: PIE_ListT(u8);
  params: PIE_MaterialParams;

  tex: struct {
    format: PIE_TexFormat;
    width: s32;
    height: s32;
    lods: s32;
    layers: s32;
    full_data: PIE_ListT(u8);
    sections: PIE_ListT(PIE_MaterialTexSection);
  };
}

PIE_Sound :: struct
{
  data: PIE_ListT(u8);
  format: SDL_AudioSpec;
}

PIE_Blob :: struct
{
  data: PIE_ListT(u8);
  info: PIE_ListT(u8);
}

PIE_Links :: struct
{
  models: struct
  {
    vertices: PIE_ListT(WORLD_Vertex);
    indices: PIE_ListT(u16);
    list: PIE_ListT(PIE_Model);
  };

  skeletons: PIE_ListT(PIE_Skeleton);
  materials: PIE_ListT(PIE_Material);

  shaders: PIE_ListT(PIE_Blob);
  fonts: PIE_ListT(PIE_Blob);
  sounds: PIE_ListT(PIE_Sound);
}

PIE_MAGIC_HASH_SEED :: (0xB5EADC0D + 0); // @todo use 64 bits
PIE_Header :: struct
{
  file_hash: u64; // of everything after itself (the first 8 bytes) - seeded with PIE_MAGIC_HASH_SEED
  links: PIE_ListT(PIE_Links);
}
