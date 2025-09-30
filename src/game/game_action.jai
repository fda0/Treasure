Action :: struct
{
  type: enum
  {
    IDLE;
    PATHING;
    ATTACK;
    SKILL_Q;
  }

  world_p: V3; // used by PATHING*
  target_object: OBJ_Key; // used by ATTACK

  skills: enum_flags u8 { Q; W; E; R; }
}
