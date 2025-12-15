//
// This file describes PIE file format - which is produced by "baker" asset preprocessor.
// .pie files pack all the data needed by the game like models' meshes & animations, materials, textures.
//
PIE_ListUntyped :: struct
{
  count: s64;
  offset: s64;
}
PIE_List :: struct($TYPE: Type)
{
  #as using untyped: PIE_ListUntyped;
  #place untyped; array: [] TYPE;

  #if size_of(TYPE) == 1 {
    #place untyped; str: string;
  }
}

RD_WorldVertex :: struct
{
  p: V3;
  normal: V3;
  uv: V2;
  // @todo color_packed: u32; (Carrot model uses vertex colors!)
  joints_packed4: u32;
  joint_weights: V4;
}

RD_WorldShaderFlags :: enum_flags u32
{
  DoMeshSkinning;
  UseInstanceBuffer;
  SampleTexDiffuse;
  SampleTexNormal;
  SampleTexRoughness;
  ApplyShadows;
  DrawBorderAtUVEdge;
  EnableHueShift;
  DiscardColorPickZero;
  PixelEarlyExit;
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
  inputs: PIE_List(float);  // float * count
  outputs: PIE_List(float); // float * (3 or 4 [V3 or Quat]) * count
}

PIE_Animation :: struct
{
  name: PIE_List(u8);
  t_min, t_max: float;
  channels: PIE_List(PIE_AnimationChannel);
}

PIE_Skeleton :: struct
{
  // each of these has the same count of elements (joints_count)
  inverse_matrices: PIE_List(Mat4);
  child_index_buffer: PIE_List(u32); // @todo use u16 here?
  child_index_ranges: PIE_List(Range(u32)); // @todo use u16 here?
  translations: PIE_List(V3);
  rotations: PIE_List(Quat);
  scales: PIE_List(V3);
  name_ranges: PIE_List(Range(s64)); // offset of min & max char* - can be transformed to S8

  anims: PIE_List(PIE_Animation);
  root_transform: Mat4;
}

PIE_Mesh :: struct
{
  material_index: u32; // @todo replace with material_hash?

  vertices_start_index: u32;
  indices_start_index: u32;
  indices_count: u32;
}

PIE_Model :: struct
{
  name: PIE_List(u8);
  is_skinned: bool;
  skeleton_index: u32 ; // for skinned only
  meshes: PIE_List(PIE_Mesh);
}

PIE_MaterialTexSection :: struct
{
  width: u32;
  height: u32;
  lod: u32;
  layer: u32;
  // relative to full_data of Material
  data_offset: s64;
  data_size: s64;
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
  name: PIE_List(u8);
  params: PIE_MaterialParams;

  tex: struct {
    format: PIE_TexFormat;
    width: s32;
    height: s32;
    lods: s32;
    layers: s32;
    full_data: PIE_List(u8);
    sections: PIE_List(PIE_MaterialTexSection);
  }
}

PIE_Sound :: struct
{
  data: PIE_List(u8);
  format: SDL_AudioSpec;
}

PIE_Blob :: struct
{
  data: PIE_List(u8);
  info: PIE_List(u8);
}

PIE_Links :: struct
{
  vertices: PIE_List(RD_WorldVertex);
  indices: PIE_List(u16);
  models: PIE_List(PIE_Model);

  skeletons: PIE_List(PIE_Skeleton);
  materials: PIE_List(PIE_Material);

  shaders: PIE_List(PIE_Blob);
  fonts: PIE_List(PIE_Blob);
  sounds: PIE_List(PIE_Sound);
}

PIE_MAGIC_HASH_SEED :: (0xB5EADC0D + 0); // @todo use 64 bits
PIE_Header :: struct
{
  file_hash: u64; // of everything after itself (the first 8 bytes) - seeded with PIE_MAGIC_HASH_SEED
  links: PIE_List(PIE_Links);
}
