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
cbuffer FragmentUniform : register(b0, space3)
{
  float2 Resolution;
};

float4 FragmentShader(Fragment frag) : SV_Target0
{
  float2 uv = frag.vertex_p.xy / Resolution;
  // float2 outline_uv = Texture.Load(int3(frag.vertex_p.xy, 0));
  float2 outline_uv = Texture.Sample(Sampler, float3(uv, 0.0));
  return float4(max(float2(0.0, 0.0), outline_uv), uv.x, 1.0);
}
