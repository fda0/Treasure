#scope_file;
using,only(AST,G) COMPS;
#scope_export;

AssetState :: struct
{
  error: bool;
  error_message: string;

  file_path: string;
  file: string;
  header: *PIE_Header;
  links: *PIE_Links;

  // Materials
  // nil_material: Material;
  materials: [..] Material; // reserve 0 for nil

  // Texture loading thread
  tex_load_needed: bool;
  tex_semaphore: Semaphore;
  tex_thread: Thread;

  // Models
  // nil_model: Model;
  models: [..] Model; // reserve 0 for nil
  model_vertices: *SDL_GPUBuffer;
  model_indices: *SDL_GPUBuffer;
  skeletons: [] Skeleton;

  // Blobs
  sounds: [] AUDIO_Sound;

  model_alias_to_slot: [ModelAlias_Count] ModelSlot;
  material_alias_to_slot: [MaterialAlias_Count] MaterialSlot;
};

ShaderType :: enum
{
  WORLD_VS;
  WORLD_PS;
  UI_VS;
  UI_PS;
};

AssetKind :: enum u8
{
  Material;
  Model;
}

AssetStream :: struct
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

AssetBase :: struct
{
  name: string;
  hash: AssetHash;
}

Material :: struct
{
  using base: AssetBase;
  stream: AssetStream;
  params: PIE_MaterialParams;
  has_texture: bool;
  texture_layers: s32;
  tex: *SDL_GPUTexture;
};

Mesh :: struct
{
  using base: AssetBase;
  material_slot: MaterialSlot;
  vertices_start_index: u32;
  indices_start_index: u32;
  indices_count: u32;
};

Model :: struct
{
  using base: AssetBase;
  is_skinned: bool;
  skeleton: *Skeleton; // can be null
  meshes: [] Mesh;
};

IsNil :: (a: *Material) -> bool { return a == *AST.materials[0]; }
IsNil :: (a: *Model) -> bool { return a == *AST.models[0]; }

MaterialFromSlot :: (idx: MaterialSlot) -> *Material
{
  material := *AST.materials[idx];
  if idx > 0
  {
    material.stream.last_touched_frame = G.frame_number;
    if !(material.stream.flags & .LOADED) AST.tex_load_needed = true;
  }
  return material;
}

MaterialFromAlias :: (id: MaterialAlias) -> *Material { return MaterialFromSlot(MaterialSlotFromAlias(id)); }
ModelFromSlot :: (idx: ModelSlot) -> *Model { return *AST.models[idx]; }
ModelFromAlias :: (id: ModelAlias) -> *Model { return ModelFromSlot(ModelSlotFromAlias(id)); }

GetShader :: (type: ShaderType) -> string
{
  if type.(s64) >= AST.links.shaders.count return "";
  return AST.links.shaders[type].buffer;
}

//
// User facing enum API
//
ModelAlias :: enum u16
{
  None;
  Bed; // used as "missing model" for now
  Dude;
  Flag;
  Tree;
  Zombie;
  Plank;
  Potion;
  Stool;
  Cross;
  Carrot;
}

MaterialAlias :: enum u16
{
  None;
  Leather011;
  Grass004;
  Ground075;
  Clay002;
}

ModelAlias_Count :: #run EnumCount(ModelAlias);
MaterialAlias_Count :: #run EnumCount(MaterialAlias);

ModelSlotFromAlias :: (alias: ModelAlias) -> ModelSlot { return AST.model_alias_to_slot[alias]; }
MaterialSlotFromAlias :: (alias: MaterialAlias) -> MaterialSlot { return AST.material_alias_to_slot[alias]; }

//
// Currently loaded memory asset offsets
//
ModelSlot :: u32;
MaterialSlot :: u32;

//
// Name based asset hash.
// Used to match assets between game and pie file.
//
AssetHash :: u64;

AssetHashFromName :: (kind: AssetKind, name: string) -> AssetHash
{
  hash := Hash64Any(kind, name);
  type4_hash60 := (kind).(u64) | (hash << 4);
  return type4_hash60;
}

AssetKindFromType :: (T: Type) -> AssetKind, bool
{
  if T == {
    case MaterialAlias; return .Material, true;
    case ModelAlias; return .Model, true;
  }
  return .Material, false;
}

AssetAliasFromAssetHash :: ($T: Type, hash: AssetHash) -> T
{
  #insert -> string {
    b: String_Builder;
    append(*b, "if hash == {\n");

    kind, known_type := AssetKindFromType(T);
    assert(known_type, "Unexpected T % in AssetIDFromAssetHash", T);

    info := type_info(T);
    for info.names {
      print_to_builder(*b, "case %; return .%;", AssetHashFromName(kind, it), it);
    }

    append(*b, "}\n");
    append(*b, "return 0;\n");
    return builder_to_string(*b);
  }
}
