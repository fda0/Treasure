#scope_file;
using,only(AST,G) COMPS;
#scope_export;

ShaderType :: enum
{
  WORLD_VS;
  WORLD_PS;
  UI_VS;
  UI_PS;
}

AssetStream :: struct
{
  last_touched: Timestamp;
  loaded_t: float;
  flags: enum_flags u8 { ERROR; LOADED; };
}

Material :: struct
{
  using base: BaseMaterial;
  stream: AssetStream;
  texture_handle: *SDL_GPUTexture;
}

ModelAlias :: enum u16
{
  None;
  Bed; // used as "missing model" for now
  Dude;
  Flag;
  Tree;
  Zombie;
  Plank;
  Dummy;
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

AssetState :: struct
{
  // Errors
  error: bool;
  error_message: string;

  // Asset file
  file_path: string;
  file: string;
  using links: *PieLinks;

  // Materials
  materials: [] Material; // reserve 0 for nil
  tex_load_needed: bool;
  tex_semaphore: Semaphore;
  tex_thread: Thread;

  // Models
  model_vertices: *SDL_GPUBuffer;
  model_indices: *SDL_GPUBuffer;
  skeletons: [] Skeleton;

  // Aliases
  model_alias_to_slot: [ModelAlias_Count] ModelSlot;
  material_alias_to_slot: [MaterialAlias_Count] MaterialSlot;
}

//
// User friendly alias enum for getting common models/materials
//
IsNil :: (a: *Material) -> bool { return a == *AST.materials[0]; }
MaterialFromAlias :: (alias: MaterialAlias) -> *Material { return MaterialFromSlot(MaterialSlotFromAlias(alias)); }
ModelFromAlias :: (alias: ModelAlias) -> *Model { return ModelFromSlot(ModelSlotFromAlias(alias)); }

MaterialFromSlot :: (slot: MaterialSlot) -> *Material
{
  material := *AST.materials[slot];
  if slot > 0
  {
    material.stream.last_touched = G.frame_timestamp;
    if !(material.stream.flags & .LOADED) AST.tex_load_needed = true;
  }
  return material;
}

ModelFromSlot :: (slot: ModelSlot) -> *Model { return *AST.models[slot]; }
SkeletonFromSlot :: (slot: SkeletonSlot) -> *Skeleton { return *AST.skeletons[slot]; }

ModelSlotFromAlias :: (alias: ModelAlias) -> ModelSlot { return AST.model_alias_to_slot[alias]; }
MaterialSlotFromAlias :: (alias: MaterialAlias) -> MaterialSlot { return AST.material_alias_to_slot[alias]; }

AliasFromName :: ($T: Type, name: string) -> T
{
  #insert -> string {
    b: String_Builder;
    append(*b, "if name == {\n");

    info := type_info(T);
    for info.names {
      print_to_builder(*b, "case \"%\"; return .%;", it, it);
    }

    append(*b, "}\n");
    append(*b, "return 0;\n");
    return builder_to_string(*b);
  }
}
