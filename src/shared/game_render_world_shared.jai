WORLD_Vertex :: struct
{
  p: V3;
  normal: V3;
  uv: V2;
  joints_packed4: u32;
  joint_weights: V4;
};

WORLD_ShaderFlags :: enum_flags u32 // @todo generate hlsl header for shaders out of this
{
  DoMeshSkinning;
  UseInstanceBuffer;
  SampleTexDiffuse;
  SampleTexNormal;
  SampleTexRoughness;
  ApplyShadows;
  DrawBorderAtUVEdge;
  PixelEarlyExit;
};
