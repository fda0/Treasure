Occupation :: enum
{
  NOT_SET;
  SERVER;
  CLIENT;
}
#add_context occupation: Occupation;
#add_context O: *OccupationState;

OccupationState :: struct
{
  frame_timestamp: Timestamp;
  obj: OBJ_State;
}

PatchContext :: (occupation: Occupation) -> (result: #Context)
{
  c := context;
  c.occupation = occupation;

  if      occupation == .SERVER  c.O = *G.client.occ;
  else if occupation == .CLIENT  c.O = *G.server.occ;
  else                           assert(false);
  return c;
}
