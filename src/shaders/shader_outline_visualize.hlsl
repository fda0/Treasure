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

float4 FragmentShader(Fragment frag) : SV_Target0
{
  float2 outline_xy = Texture.Load(int3(frag.vertex_p.xy, 0));
  if (outline_xy.x < 0.0) {
    discard;
  }

  float2 frag_xy = frag.vertex_p.xy;
  float dist = length(frag_xy - outline_xy);

  float4 color = float4(0.95, 0.02, 0.2, 1.0);
  color.a *= smoothstep(4.0, 0.0, dist);
  color.a *= smoothstep(0.0, 0.01, dist)*0.95 + 0.05;
  return color;
}
