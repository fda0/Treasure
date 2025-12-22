// #include "shader_util.hlsl"

struct UI_DX_Vertex
{
  uint vertex_index : SV_VertexID;
};

struct UI_DX_Uniform
{
  float2 window_dim;
  float2 texture_dim;
};

struct UI_DX_Shape
{
  float2 p_min;
  float2 p_max;
  float2 tex_min; // in pixel space
  float2 tex_max; // in pixel space
  float2 clip_min;
  float2 clip_max;
  float4 border_widths; // left, right, top, bottom
  float tex_layer;
  float corner_radius;
  float edge_softness;
  uint color; // @todo array of 4 colors for gradients
};

struct UI_DX_Fragment
{
  float4 color               : TEXCOORD0;
  float4 border_widths       : TEXCOORD1;
  float3 tex_uv              : TEXCOORD2;
  float2 pos                 : TEXCOORD3;
  float2 center              : TEXCOORD4;
  float2 half_dim            : TEXCOORD5;
  float corner_radius    : TEXCOORD6;
  float edge_softness    : TEXCOORD7;
  float4 vertex_p            : SV_Position;
};

// Dx resources
cbuffer VertexUniformBuf : register(b0, space1) { UI_DX_Uniform UniV; };

StructuredBuffer<UI_DX_Shape> ShapeBuf : register(t0);

Texture2DArray<float4> AtlasTexture : register(t0, space2);
SamplerState AtlasSampler : register(s0, space2);

// Shaders
UI_DX_Fragment UI_DxShaderVS(UI_DX_Vertex input)
{
  uint corner_index = input.vertex_index & 3u; // 2 bits; [0:1]
  uint shape_index = (input.vertex_index >> 2u) & 0x3FFFFFFF; // 30 bits; [2:31]
  UI_DX_Shape shape = ShapeBuf[shape_index];

  // position
  float2 pos = shape.p_min;
  if (corner_index & 1) pos.x = shape.p_max.x;
  if (corner_index & 2) pos.y = shape.p_max.y;

  // texture uv
  float2 tex_min = shape.tex_min;
  float2 tex_max = shape.tex_max;

  // dimensions
  float2 pos_dim = shape.p_max - shape.p_min;
  float2 tex_dim = tex_max - tex_min;
  float2 pos_to_tex = float2(0, 0);
  if (tex_dim.x) pos_to_tex = tex_dim.x / pos_dim.x;
  if (tex_dim.y) pos_to_tex = tex_dim.y / pos_dim.y;

  // clipping
  if (shape.clip_min.x > pos.x)
  {
    float pos_delta = shape.clip_min.x - pos.x;
    tex_min.x += pos_delta * pos_to_tex.x;
    pos.x = shape.clip_min.x;
  }
  if (shape.clip_min.y > pos.y)
  {
    float pos_delta = shape.clip_min.y - pos.y;
    tex_min.y += pos_delta * pos_to_tex.y;
    pos.y = shape.clip_min.y;
  }
  if (shape.clip_max.x < pos.x)
  {
    float pos_delta = shape.clip_max.x - pos.x;
    tex_max.x += pos_delta * pos_to_tex.x;
    pos.x = shape.clip_max.x;
  }
  if (shape.clip_max.y < pos.y)
  {
    float pos_delta = shape.clip_max.y - pos.y;
    tex_max.y += pos_delta * pos_to_tex.y;
    pos.y = shape.clip_max.y;
  }

  float2 tex_uv = float2(tex_min.x, tex_min.y);
  if (corner_index & 1) tex_uv.x = tex_max.x;
  if (corner_index & 2) tex_uv.y = tex_max.y;
  tex_uv /= UniV.texture_dim;

  //
  UI_DX_Fragment frag;
  frag.color = UnpackColor(shape.color);
  frag.border_widths = shape.border_widths;
  frag.tex_uv = float3(tex_uv, shape.tex_layer);
  frag.pos = pos;
  frag.center   = (shape.p_min + shape.p_max) * 0.5f;
  frag.half_dim = (shape.p_max - shape.p_min) * 0.5f;
  frag.corner_radius    = shape.corner_radius;
  frag.edge_softness    = shape.edge_softness;
  frag.vertex_p = float4(2.f*pos / UniV.window_dim - 1.f, 1, 1);
  frag.vertex_p.y = -frag.vertex_p.y; // Flip Y so 0 means top of the window
  return frag;
}

float4 UI_DxShaderPS(UI_DX_Fragment frag) : SV_Target0
{
  float4 color = frag.color;
  if (frag.tex_uv.z >= 0.f)
  {
    float4 tex_color = AtlasTexture.Sample(AtlasSampler, frag.tex_uv);
    color *= tex_color;
  }

  float2 soft_pad = float2(frag.edge_softness, frag.edge_softness);

  // outter-rect
  {
    float dist = RoundedRectSDF(frag.pos, frag.center,
                                frag.half_dim - soft_pad,
                                frag.corner_radius);
    float rect_factor = 1.f - smoothstep(0, 2*frag.edge_softness, dist);
    color.a *= rect_factor;
  }

  // border rendering: removing inner-rect
  bool has_border = length(frag.border_widths) > 0.0;
  if (has_border)
  {
    bool is_left = frag.pos.x <= frag.center.x;
    bool is_up = frag.pos.y <= frag.center.y;

    float border_h = is_left ? frag.border_widths.x : frag.border_widths.y;
    float border_v = is_up ? frag.border_widths.z : frag.border_widths.w;

    float2 inner_half_dim = frag.half_dim - float2(border_h, border_v);

    float inner_r_coef = min(inner_half_dim.x / frag.half_dim.x,
                             inner_half_dim.y / frag.half_dim.y);
    float inner_r = frag.corner_radius * inner_r_coef * inner_r_coef;
    float inner_dist = RoundedRectSDF(frag.pos, frag.center,
                                      inner_half_dim - soft_pad,
                                      inner_r);
    float inner_factor = smoothstep(0, frag.edge_softness, inner_dist);
    color.a *= inner_factor;
  }

  return color;
}
