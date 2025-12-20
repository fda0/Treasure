//
// This file describes PIE file format - which is produced by "baker" asset preprocessor.
// .pie files pack all the data needed by the game like models' meshes & animations, materials, textures.
//

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
  joint_index30_type2: u32; // [u32 | (PIE_AnimationChannelType << 30)] // @todo this is silly, simplify
  inputs: [] float;  // float * count
  outputs: [] float; // float * (3 or 4 [V3 or Quat]) * count
}

PIE_Animation :: struct
{
  name: string;
  t_min, t_max: float;
  channels: [] PIE_AnimationChannel;
}

PIE_Skeleton :: struct
{
  // each of these has the same count of elements (joints_count)
  inverse_matrices: [] Mat4;
  child_index_buffer: [] u32; // @todo use u16 here?
  child_index_ranges: [] Range(u32); // @todo use u16 here?
  translations: [] V3;
  rotations: [] Quat;
  scales: [] V3;
  names: [] string; // offset of min & max char* - can be transformed to S8

  anims: [] PIE_Animation;
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
  name: string;
  is_skinned: bool;
  skeleton_index: u32; // for skinned only
  meshes: [] PIE_Mesh;
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
  name: string;
  params: PIE_MaterialParams;

  tex: struct { // @todo inline tex struct
    format: PIE_TexFormat;
    width: s32;
    height: s32;
    lods: s32;
    layers: s32;
    buffer: string;
    sections: [] PIE_MaterialTexSection;
  }
}

PIE_Sound :: struct
{
  buffer: string;
  format: SDL_AudioSpec;
}

PIE_Blob :: struct
{
  buffer: string;
  info: string;
}

PIE_Links :: struct
{
  vertices: [] RD_WorldVertex;
  indices: [] u16;
  models: [] PIE_Model;

  skeletons: [] PIE_Skeleton;
  materials: [] PIE_Material;

  shaders: [] PIE_Blob;
  fonts: [] PIE_Blob;
  sounds: [] PIE_Sound;
}

PIE_MAGIC_HASH_SEED :: (0xB5EADC0D + 0); // @todo use 64 bits
PIE_Header :: struct
{
  file_hash: u64; // of everything after itself (the first 8 bytes) - seeded with PIE_MAGIC_HASH_SEED
  links: [] PIE_Links;
}
