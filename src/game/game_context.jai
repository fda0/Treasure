#add_context role: Role;
#add_context R: *RoleState;

Role :: enum
{
  NOT_SET;
  SERVER;
  CLIENT;
}

RoleState :: struct
{
  frame_timestamp: Timestamp;
  obj: OBJ_State;
}

PatchContext :: (role: Role) -> (result: #Context)
{
  ctx := context;
  ctx.role = role;

  if      role == .SERVER  ctx.R = *G.client.occ;
  else if role == .CLIENT  ctx.R = *G.server.occ;
  else                             assert(false);
  return ctx;
}
