Occupation :: enum
{
  NOT_SET;
  SERVER;
  CLIENT;
}
#add_context occupation: Occupation;
#add_context C: *CtxState;

CtxState :: struct
{
  frame_timestamp: Timestamp;
  obj: OBJ_State;
}

PatchContext :: (occupation: Occupation) -> (result: #Context)
{
  c := context;
  c.occupation = occupation;

  if      occupation == .SERVER  c.ctx = *G.client.ctx;
  else if occupation == .CLIENT  c.ctx = *G.server.ctx;
  else                           assert(false);
  return c;
}
