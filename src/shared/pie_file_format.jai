//
// This file describes PIE file format - which is produced by "baker" asset preprocessor.
// .pie files pack all the data needed by the game like models' meshes & animations, materials, textures.
//

ModelSlot :: #type,distinct u32;
MaterialSlot :: #type,distinct u32;
SkeletonSlot :: #type,distinct u32;

RD_WorldVertex :: struct
{
  p: V3;
  normal: V3;
  uv: V2;
  // @todo color_packed: u32; (Carrot model uses vertex colors!)
  joints_packed4: u32;
  joint_weights: V4;
}

RD_WorldFlags :: enum_flags u32
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

AnimationChannel :: struct
{
  type: enum u8
  {
    Translation;
    Rotation;
    Scale;
  };
  joint_index: u32;
  inputs: [] float;  // float * count
  outputs: [] float; // float * (3 or 4 [V3 or Quat]) * count
}

Animation :: struct
{
  name: string;
  t_min, t_max: float;
  channels: [] AnimationChannel;
}

PIE_Skeleton :: struct
{
  root_transform: Mat4;
  animations: [] Animation;

  // each of these has the same count of elements (joints_count)
  names: [] string;
  inverse_matrices: [] Mat4;
  child_index_buffer: [] u32; // @todo use u16 here?
  child_index_ranges: [] Range(u32); // @todo use u16 here?

  // bind translations, rotations, scales
  bind_translations: [] V3;
  bind_rotations: [] Quat;
  bind_scales: [] V3;
}

Mesh :: struct
{
  material_slot: MaterialSlot;
  vertices_start_index: u32;
  indices_start_index: u32;
  indices_count: u32;
}

Model :: struct
{
  name: string;
  is_skinned: bool;
  skeleton_slot: SkeletonSlot; // for skinned only
  meshes: [] Mesh;
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

PIE_Material :: struct
{
  name: string;

  // params
  flags: enum_flags u8 { HasAlpha; };
  diffuse: u32;
  specular: u32;
  roughness: float; // [0:1]

  // texture
  tex: struct {
    format: TexFormat;
    width: s32;
    height: s32;
    lods: s32;
    layers: s32;
    buffer: string;
    sections: [] PIE_MaterialTexSection;
  }

  TexFormat :: enum u8
  {
    Empty;
    R8G8B8A8;
    BC7_RGBA;
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
  models: [] Model;

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
