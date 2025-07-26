Action :: struct
{
  type: enum
  {
    IDLE;
    PATHING;
    PATHING_DIRECTION;
    ATTACK;
  };

  world_p: V3; // used by PATHING*
  target_object: OBJ_Key; // used by ATTACK
}
