ASSET_State :: struct
{
  pie: ASSET_PieFile;
  arena: Arena;

  // Materials
  nil_material: Material;
  materials: [] Material;

  // Texture loading thread
  tex_load_needed: bool;
  tex_semaphore: Semaphore;
  tex_thread: Thread;

  // Models
  nil_model: Model;
  models: [] Model;
  model_vertices: *SDL_GPUBuffer;
  model_indices: *SDL_GPUBuffer;
  skeletons: [] Skeleton;

  // Blobs
  shaders: [] string;
  fonts: [] string;
  sounds: [] AUDIO_Sound;
};

ShaderType :: enum
{
  WORLD_VS;
  WORLD_PS;
  UI_VS;
  UI_PS;
};

ASSET_Type :: enum
{
  Material;
  Model;
};

ASSET_Key :: struct
{
  type4_hash60: u64;
  name: string;
  // @info name is used for debugging/logging only -
  // - and might be excluded from shipping builds.
  // The constraint is this string's buffer has to be stored externally and
  // it has to be valid through the whole lifetime of the program.
  // This is fine for now. In the future if we add .pie file reloading we might
  // decide to store these names in some lookup table outside of MATERIAL_Key itself.

  // material name format:
  //   tex.Bricks071
  //   Tree.Bark_diffuse
};

MATERIAL_Key :: #type,isa ASSET_Key;
MODEL_Key ::  #type,isa ASSET_Key;

AssetCreateKey :: (type: ASSET_Type, name: string /* EXTERNALLY OWNED STRING */) -> ASSET_Key
{
  hash := Hash64Any(type, name);

  res: ASSET_Key;
  res.type4_hash60 = (cast(u64) type) | (hash << 4);
  res.name = name;
  return res;
}
MaterialKey :: (name: string) -> MATERIAL_Key { return cast(MATERIAL_Key) AssetCreateKey(.Material, name); }
ModelKey    :: (name: string) -> MODEL_Key    { return cast(MODEL_Key)    AssetCreateKey(.Model, name); }

MatchKey :: (a: ASSET_Key, b: ASSET_Key) -> bool
{
  return a.type4_hash60 == b.type4_hash60;
}

KeyType :: (key: ASSET_Key) -> ASSET_Type
{
  return cast(ASSET_Type) (key.type4_hash60 & 0b1111);
}

IsZeroKey :: (key: ASSET_Key) -> bool
{
  return !key.type4_hash60;
}

ASSET_Streamable :: struct
{
  last_touched_frame: s64;
  loaded_t: float;
  flags: Flags;

  Flags :: enum_flags
  {
    ERROR;
    LOADED;
  };
}

Material :: struct
{
  stream: ASSET_Streamable;
  key: MATERIAL_Key;

  params: PIE_MaterialParams;
  has_texture: bool;
  texture_layers: s32;
  tex: *SDL_GPUTexture;
};

Mesh :: struct
{
  material: MATERIAL_Key;
  vertices_start_index: u32;
  indices_start_index: u32;
  indices_count: u32;
};

Model :: struct
{
  key: MODEL_Key;
  is_skinned: bool;
  skeleton: *Skeleton; // can be null
  meshes: [] Mesh;
};

ASSET_PieFile :: struct
{
  file: string;
  err: bool;

  header: *PIE_Header;
  links: *PIE_Links;
  models: [] PIE_Model;
  materials: [] PIE_Material;
  shaders: [] PIE_Blob;
  fonts: [] PIE_Blob;
  sounds: [] PIE_Sound;
};

MaterialIsNil :: (a: *Material) -> bool
{
  return a == *G.ast.nil_material;
}

GetMaterial :: (key: MATERIAL_Key) -> *Material
{
  // @speed hash table lookup in the future
  asset := *G.ast.nil_material;
  for *G.ast.materials
  {
    if (MatchKey(it.key, key))
    {
      asset = it;
      break;
    }
  }

  if !MaterialIsNil(asset)
  {
    asset.stream.last_touched_frame = G.frame_number;
    if !(asset.stream.flags & .LOADED)  G.ast.tex_load_needed = true;
  }

  return asset;
}

PrefetchMaterial :: (key: MATERIAL_Key)
{
  GetMaterial(key);
}

// Model
ModelIsNil :: (a: *Model) -> bool
{
  return a == *G.ast.nil_model;
}

GetModel :: (key: MODEL_Key) -> *Model
{
  // @speed hash table lookup in the future
  asset := *G.ast.nil_model;
  for *G.ast.models
  {
    if (MatchKey(it.key, key))
    {
      asset = it;
      break;
    }
  }

  if asset == *G.ast.nil_model
    log("Model % not found", key, flags = .WARNING|.CONTENT);

  return asset;
}

// Shader
GetShader :: (type: ShaderType) -> string
{
  if xx type >= G.ast.shaders.count then return "";
  return G.ast.shaders[type];
}