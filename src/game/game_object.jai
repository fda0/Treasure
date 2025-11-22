OBJ_MAX_SHARED_OBJECTS :: 128;
OBJ_MAX_LOCAL_OBJECTS :: 4096 * 16;
OBJ_MAX_ALL_OBJECTS :: OBJ_MAX_SHARED_OBJECTS + OBJ_MAX_LOCAL_OBJECTS;
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

OBJ_Key :: struct
{
  index24_serial8: u32;
};

OBJ_IndexOfKey :: (key: OBJ_Key) -> u32
{
  return key.index24_serial8 & 0xff_ff_ff;
}
OBJ_SerialOfKey :: (key: OBJ_Key) -> u32
{
  return key.index24_serial8 >> 24;
}
OBJ_CreateKey :: (index: u32, serial: u32) -> OBJ_Key
{
  return OBJ_Key.{(serial << 24) | (index & 0xff_ff_ff)};
}
OBJ_KeyIsZero :: (key: OBJ_Key) -> bool
{
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

OBJ_ActivityState :: struct
{
  is_walking: bool;
  wants_to_attack: bool;
  is_attacking: bool;

  walking_to: V2;

  attack_t: float;
  visual_attack_t: float;

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
  p: V3; // XY center, Z at bottom
  desired_dp: V3; // move that Object wanted to make
  moved_dp: V3; // move that Object did after collision simulation

  // game stats
  max_hp: float;
  hp: float;
  attack_speed: float = 1.2;
  move_speed: float = 1.0;

  attack_landed_t := 0.25;
  attack_cooldown_t := 1.0;

  // game state
  activity: OBJ_ActivityState;
  animation_requests: Queue(3, ANIMATION_Request);
  sound_requests: Queue(3, AUDIO_Request);

  skill_cooldowns: [4] float;

  // visuals
  color: Color32 = 0xffff_ffff; // unused?
  rotation: Quat;
  model: MODEL_Key; // used by DrawModel
  material: MATERIAL_Key; // used by DrawCollision
  height: float; // used by DrawCollision
  texture_texels_per_m: float; // used by DrawCollision

  collider: OBJ_Collider;
};

lerp :: (prev: Object, next: Object, t: float) -> Object
{
  res := prev;
  res.p = lerp(prev.p, next.p, t);
  res.desired_dp = lerp(prev.desired_dp, next.desired_dp, t);
  res.moved_dp = lerp(prev.moved_dp, next.moved_dp, t);
  res.color = lerp(prev.color, next.color, t);
  res.rotation = Slerp(prev.rotation, next.rotation, t);
  return res;
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
