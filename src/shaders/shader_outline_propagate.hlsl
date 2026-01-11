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

Texture2D<float2> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

float2 FragmentShader(Fragment frag) : SV_Target0
{
  float2 frag_xy = frag.vertex_p.xy;
  int2 frag_xy_int = int2(frag_xy);

  float2 best_xy = float2(-1.0, -1.0);
  float best_distsq = 1024.0 * 1024.0 * 1024.0;

  for (int y = -1; y <= 1; y++)
  {
    for (int x = -1; x <= 1; x++)
    {
      float2 candidate_xy = Texture.Load(int3(frag_xy_int + int2(x, y), 0));
      if (candidate_xy.x >= 0.0)
      {
        float2 delta = frag_xy - candidate_xy;
        float candidate_distsq = dot(delta, delta);
        if (candidate_distsq < best_distsq)
        {
          best_xy = candidate_xy;
          best_distsq = candidate_distsq;
        }
      }
    }
  }

  return best_xy;
}
