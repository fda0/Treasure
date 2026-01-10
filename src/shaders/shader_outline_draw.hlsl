struct Vertex
{
  uint index : SV_VertexID;
};

struct Fragment
{
  float4 vertex_p : SV_Position;
};

Fragment VertexShader(Vertex vert)
{
  float4 positions[3] = {
    float4(-1.0, -1.0, 0.0, 1.0),
    float4( 3.0, -1.0, 0.0, 1.0),
    float4(-1.0,  3.0, 0.0, 1.0),
  };
  Fragment frag;
  frag.vertex_p = positions[vert.index % 3];
  return frag;
}

float4 FragmentShader(Fragment frag) : SV_Target0
{
  return frag.vertex_p * 0.001;
}
