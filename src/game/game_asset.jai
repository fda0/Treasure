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
  using,only(models) links: *PIE_Links;

  // Materials
  materials: [] Material; // reserve 0 for nil

  // Texture loading thread
  tex_load_needed: bool;
  tex_semaphore: Semaphore;
  tex_thread: Thread;

  // Models
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

  Flags :: enum_flags u8
  {
    ERROR;
    LOADED;
  }
}

Material :: struct
{
  using pie: PIE_Material;
  stream: AssetStream;
  texture_handle: *SDL_GPUTexture;
}

IsNil :: (a: *Material) -> bool { return a == *AST.materials[0]; }

aterialFromAlias :: (alias: MaterialAlias) -> *Material { return MaterialFromSlot(MaterialSlotFromAlias(alias)); }
ModelFromAlias :: (alias: ModelAlias) -> *Model { return ModelFromSlot(ModelSlotFromAlias(alias)); }

MaterialFromSlot :: (slot: MaterialSlot) -> *Material
{
  material := *AST.materials[slot];
  if slot > 0
  {
    material.stream.last_touched_frame = G.frame_number;
    if !(material.stream.flags & .LOADED) AST.tex_load_needed = true;
  }
  return material;
}

ModelFromSlot :: (slot: ModelSlot) -> *Model { return *AST.models[slot]; }
SkeletonFromSlot :: (slot: SkeletonSlot) -> *Skeleton { return *AST.skeletons[slot]; }

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

AliasFromName :: ($T: Type, name: string) -> T
{
  #insert -> string {
    b: String_Builder;
    append(*b, "if name == {\n");

    kind: AssetKind;
    #if T == {
      case MaterialAlias; kind = .Material;
      case ModelAlias; kind = .Model;
      case; assert(false, "Unexpected Type % in AssetAliasFromName", T);
    }

    info := type_info(T);
    for info.names {
      print_to_builder(*b, "case \"%\"; return .%;", it, it);
    }

    append(*b, "}\n");
    append(*b, "return 0;\n");
    return builder_to_string(*b);
  }
}
