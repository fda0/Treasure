OBJ_Collider :: struct
{
  vertices: [OBJ_MAX_COLLIDER_VERTS] V2;
  normals: [OBJ_MAX_COLLIDER_VERTS] V2;
};

OBJ_ColliderProjection :: struct
{
  ranges: [OBJ_MAX_COLLIDER_VERTS] Range(float);
};

OBJ_ColliderFromRect :: (dim: V2) -> OBJ_Collider
{
  p0 := dim * -0.5;
  p1 := dim * 0.5;

  res: OBJ_Collider;
  res.vertices[0] = .{p1.x, p0.y}; // SE
  res.vertices[1] = .{p1.x, p1.y}; // NE
  res.vertices[2] = .{p0.x, p1.y}; // NW
  res.vertices[3] = .{p0.x, p0.y}; // SW
  OBJ_ColliderCalculateNormals(*res);
  return res;
}

OBJ_RotateCollider :: (collider: *OBJ_Collider, turns: float)
{
  for *collider.vertices
    it.* = Rotate(it.*, turns);
  OBJ_ColliderCalculateNormals(collider);
}

OBJ_OffsetCollider :: (collider: *OBJ_Collider, offset: V2)
{
  for *collider.vertices
    it.* += offset;
}

OBJ_ColliderCalculateNormals :: (using collider: *OBJ_Collider)
{
  for MakeRange(OBJ_MAX_COLLIDER_VERTS)
  {
    next_it := (it + 1) % OBJ_MAX_COLLIDER_VERTS;
    normals[it] = NormalFromSegment(vertices[it], vertices[next_it]);
  }
}

OBJ_CalculateColliderProjection :: (normals_source: OBJ_Collider, vertices_source: OBJ_Collider) -> OBJ_ColliderProjection
{
  res: OBJ_ColliderProjection;
  for normal: normals_source.normals
  {
    projection := *res.ranges[it_index];
    projection.min = FLOAT32_MAX;
    projection.max = -FLOAT32_MAX;

    for vert: vertices_source.vertices
    {
      inner := dot(normal, vert);
      projection.min = min(inner, projection.min);
      projection.max = max(inner, projection.max);
    }
  }
  return res;
}
