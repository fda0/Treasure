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

CreateContextWithRole :: (role: Role) -> (result: #Context)
{
  ctx := context;
  ctx.role = role;

  if      role == .SERVER  ctx.R = *G.client.role_state;
  else if role == .CLIENT  ctx.R = *G.server.role_state;
  else                             assert(false);
  return ctx;
}

// raddebugger inspired
LaneCtx :: struct
{
  lane_id: s64;
  lane_count: s64;
  barrier: *Barrier;
  broadcast_memory: *u64;
}

