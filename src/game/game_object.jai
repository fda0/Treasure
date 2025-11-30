OBJ_SHARED_COUNT : ObjIdx : 128;
OBJ_LOCAL_COUNT : ObjIdx : 4096 * 16;
OBJ_ALL_COUNT : ObjIdx : OBJ_SHARED_COUNT + OBJ_LOCAL_COUNT;
OBJ_MAX_ANIMATIONS :: 4;
OBJ_MAX_COLLIDER_VERTS :: 4;

OBJ_GHOST_NIL :: Ghost.{};

OBJ_Storage :: enum_flags u8
{
  // This enum is useful for filtering obj storage when doing queries.
  // A single object can have only one storage type.
  LOCAL;
  SHARED;
  ALL :: LOCAL | SHARED;
};

ObjIdx :: u32; // 24 bits only
OBJ_Key :: struct { index24_serial8: u32; }

OBJ_IndexOfKey :: (key: OBJ_Key) -> ObjIdx {
  return key.index24_serial8 & 0xff_ff_ff;
}
OBJ_SerialOfKey :: (key: OBJ_Key) -> u32 {
  return key.index24_serial8 >> 24;
}
OBJ_CreateKey :: (index: ObjIdx, serial: u32) -> OBJ_Key {
  return OBJ_Key.{(serial << 24) | (index & 0xff_ff_ff)};
}
OBJ_KeyIsZero :: (key: OBJ_Key) -> bool {
  return !key.index24_serial8;
}

OBJ_Flags :: enum_flags u32
{
  MOVE;
  COLLIDE;

  ANIMATE_ROTATION;
  ANIMATE_POSITION;
  ANIMATE_TRACKS;
  MANUAL_ROTATION;
  MANUAL_POSITION;

  DRAW_MODEL;
  DRAW_COLLIDERS;
  // MOUSE_PICKING;

  HAS_HP;
  TARGETABLE;
  PLAY_SOUNDS;
  IS_TURRET;
  TARGETED_PROJECTILE;
  HAS_ACTIVITY;
  DELETE_ON_DEATH;
  RESPAWN;
};

OBJ_Team :: enum u8
{
  NO_TEAM;
  BLUE;
  RED;
}
BOTH_TEAMS :: OBJ_Team.[.BLUE, .RED];

OBJ_Activity :: struct
{
  is_walking: bool;
  wants_to_attack: bool;
  is_attacking: bool;

  walking_to: V2; @lerp

  attack_t: float; @lerp
  visual_attack_t: float; @lerp

  target: OBJ_Key;
  last_projectile: OBJ_Key;
}

Object :: struct
{
  // Object data that's synced with the server
  key: OBJ_Key;
  flags: OBJ_Flags;
  team: OBJ_Team;
  init: bool;

  creation_tick: ServerTick;
  death_tick: ServerTick;
  p: V3; @lerp // XY center, Z at bottom
  desired_dp: V3; @lerp // move that Object wanted to make
  moved_dp: V3; @lerp // move that Object did after collision simulation

  // base stats
  max_hp: float; @lerp
  attack_speed: float = 1.2; @lerp
  base_move_speed: float = 1.0; @lerp

  // stats
  hp: float; @lerp
  move_speed: float = 1.0; @lerp
  move_speed_boost_t: float; @lerp

  // attack timers
  attack_landed_t := 0.25; @lerp
  attack_cooldown_t := 1.0; @lerp

  // game state
  activity: OBJ_Activity; @lerp_recurse
  animation_requests: Queue(3, AnimationRequest);
  sound_requests: Queue(3, AUDIO_Request);

  skill_cooldowns: [4] float; // @todo - support array lerp

  // visuals
  color: Color32 = 0xffff_ffff; @lerp // unused?
  rotation: Quat; @Slerp
  model: ModelID; // used by DrawModel
  material: MaterialID; // used by DrawCollision
  height: float; @lerp // used by DrawCollision
  texture_texels_per_m: float; @lerp // used by DrawCollision

  collider: OBJ_Collider;
};

OBJ_LerpObject :: (prev: Object, next: Object, t: float) -> Object
{
  result := ifx t < 0.5 then prev else next;

  #insert -> string {
    GenerateStructLerp :: (b: *String_Builder, struct_type: *Type_Info_Struct, prefix: string)
    {
      for struct_type.members
      {
        basic_lerp := "";
        if Contains(it.notes, "lerp") basic_lerp = "lerp";
        if Contains(it.notes, "Slerp") basic_lerp = "Slerp";
        if basic_lerp {
          print_to_builder(b, "result%1.%2 = %3(prev%1.%2, next%1.%2, t);\n", prefix, it.name, basic_lerp);
        }

        if Contains(it.notes, "lerp_recurse")
        {
          new_prefix := sprint("%.%", prefix, it.name);
          assert(it.type.type == .STRUCT);
          GenerateStructLerp(b, xx it.type, new_prefix);
        }
      }
    }

    b: String_Builder;
    GenerateStructLerp(*b, type_info(Object), "");
    code := builder_to_string(*b);
    // log("Code inserted by OBJ_LerpObject:\n%", code);
    return code;
  }

  return result;
}

OBJ_KeyToColor :: (key: OBJ_Key) -> Color32
{
  byte_array := (*key).([4] u8);
  #assert(size_of(OBJ_Key) == size_of(type_of(byte_array)));
  #assert(size_of(OBJ_Key) == size_of(Color32));
  return byte_array.data.(*Color32).*;
}

OBJ_EntropyFromObj :: (obj: Object) -> Entropy
{
  rng: Entropy;
  rng.inc = obj.creation_tick.(u64) | 1;
  rng.state = obj.creation_tick.(u64) ^ 0xdeadbeeffda01234;
  return rng;
}

OBJ_ColorToKey :: (color: Color32, from_bgra := true) -> OBJ_Key
{
  r := ((color      ) & 0xff).(u8);
  g := ((color >>  8) & 0xff).(u8);
  b := ((color >> 16) & 0xff).(u8);
  a := ((color >> 24) & 0xff).(u8);
  byte_array: [4] u8;
  if from_bgra byte_array = .[b,g,r,a];
  else         byte_array = .[r,g,b,a];

  #assert(size_of(OBJ_Key) == size_of(type_of(byte_array)));
  return byte_array.data.(*OBJ_Key).*;
}

OBJ_Distance2DSquared :: (a: *Object, b: *Object) -> float { return distance_squared(a.p.xy, b.p.xy); }
OBJ_Distance2D :: (a: *Object, b: *Object) -> float { return distance(a.p.xy, b.p.xy); }

OBJ_NilObject :: () -> *Object { return xx *OBJ_GHOST_NIL; }
OBJ_NilGhost :: () -> *Ghost { return *OBJ_GHOST_NIL; }
OBJ_IsNil :: (obj: Object) -> bool { return *obj == xx *OBJ_GHOST_NIL; }
OBJ_IsNil :: (ov: Ghost) -> bool { return *ov == *OBJ_GHOST_NIL; }
operator == :: (a: OBJ_Key, b: OBJ_Key) -> bool { return (a.index24_serial8 == b.index24_serial8); }

OBJ_IsInit :: (obj: Object) -> bool { return obj.init; }
OBJ_HasData :: (obj: Object) -> bool { return !!obj.flags; }
OBJ_HasAnyFlag :: (obj: Object, flag: OBJ_Flags) -> bool { return !!(obj.flags & flag); }
OBJ_HasAllFlags :: (obj: Object, flags: OBJ_Flags) -> bool { return (obj.flags & flags) == flags; }

OBJ_TestParams :: struct
{
  filter := DefaultFilter;
  DefaultFilter :: (obj: Object) -> bool { return true; }

  require_flags: OBJ_Flags;
  reject_flags: OBJ_Flags;

  common: enum_flags u8 {
    IS_ALIVE; // (has HAS_HP flag) AND (hp > 0.0)
    IS_ALIVE_OR_NO_HP; // (doesn't have HAS_HP flag) OR (hp > 0.0)
  }
  common2: enum_flags u8 { // for 2 object tests
    ARE_ENEMIES;
  }
}

OBJ_Test :: (obj: Object, using params: OBJ_TestParams) -> bool
{
  if OBJ_IsNil(obj) return false;
  if OBJ_HasAnyFlag(obj, reject_flags) return false;
  if !OBJ_HasAllFlags(obj, require_flags) return false;

  if common & .IS_ALIVE
  {
    if !((obj.flags & .HAS_HP) && (obj.hp > 0.0)) return false;
  }
  if common & .IS_ALIVE_OR_NO_HP
  {
    if !(!(obj.flags & .HAS_HP) || (obj.hp > 0.0)) return false;
  }

  if !filter(obj) return false;
  return true;
}

OBJ_Test2 :: (tested: Object, reference: Object, using params: OBJ_TestParams) -> bool
{
  if !OBJ_Test(tested, params) return false;

  if common2 & .ARE_ENEMIES
  {
    if tested.team == reference.team return false;
  }
  return true;
}
