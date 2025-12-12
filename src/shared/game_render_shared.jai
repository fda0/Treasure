RD_WorldVertex :: struct
{
  p: V3;
  normal: V3;
  uv: V2;
  // @todo color_packed: u32; (Carrot model uses vertex colors!)
  joints_packed4: u32;
  joint_weights: V4;
};

RD_WorldShaderFlags :: enum_flags u32
{
  DoMeshSkinning;
  UseInstanceBuffer;
  SampleTexDiffuse;
  SampleTexNormal;
  SampleTexRoughness;
  ApplyShadows;
  DrawBorderAtUVEdge;
  EnableHueShift;
  DiscardColorPickZero;
  PixelEarlyExit;
};
