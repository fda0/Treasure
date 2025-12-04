#scope_file;
using,only(AST,G) COMPS;
#scope_export;

ASSET_State :: struct
{
  pie: ASSET_PieFile;

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
  shaders: [] string;
  fonts: [] string;
  sounds: [] AUDIO_Sound;

  model_id_to_slot: [ModelID_Count] ModelSlot;
  material_id_to_slot: [MaterialID_Count] MaterialSlot;
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

MaterialFromID :: (id: MaterialID) -> *Material { return MaterialFromSlot(MaterialSlotFromID(id)); }
ModelFromSlot :: (idx: ModelSlot) -> *Model { return *AST.models[idx]; }
ModelFromID :: (id: ModelID) -> *Model { return ModelFromSlot(ModelSlotFromID(id)); }

GetShader :: (type: ShaderType) -> string
{
  if xx type >= AST.shaders.count then return "";
  return AST.shaders[type];
}

//
// User facing enum API
//
ModelID :: enum u16
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
}

MaterialID :: enum u16
{
  None;
  Leather011;
  Grass004;
  Ground075;
  Clay002;
}

ModelID_Count :: #run EnumCount(ModelID);
MaterialID_Count :: #run EnumCount(MaterialID);

ModelSlotFromID :: (id: ModelID) -> ModelSlot { return AST.model_id_to_slot[id]; }
MaterialSlotFromID :: (id: MaterialID) -> MaterialSlot { return AST.material_id_to_slot[id]; }

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
    case MaterialID; return .Material, true;
    case ModelID; return .Model, true;
  }
  return .Material, false;
}

AssetIDFromAssetHash :: ($T: Type, hash: AssetHash) -> T
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
