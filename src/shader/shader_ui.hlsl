// #include "shader_util.hlsl"

struct UI_DX_Vertex
{
  U32 vertex_index : SV_VertexID;
};

struct UI_DX_Uniform
{
  V2 window_dim;
  V2 texture_dim;
};

struct UI_DX_Shape
{
  V2 p_min;
  V2 p_max;
  V2 tex_min; // in pixel space
  V2 tex_max; // in pixel space
  V2 clip_min;
  V2 clip_max;
  V4 border_widths; // left, right, top, bottom
  float tex_layer;
  float corner_radius;
  float edge_softness;
  U32 color; // @todo array of 4 colors for gradients
};

struct UI_DX_Fragment
{
  V4 color               : TEXCOORD0;
  V4 border_widths       : TEXCOORD1;
  V3 tex_uv              : TEXCOORD2;
  V2 pos                 : TEXCOORD3;
  V2 center              : TEXCOORD4;
  V2 half_dim            : TEXCOORD5;
  float corner_radius    : TEXCOORD6;
  float edge_softness    : TEXCOORD7;
  V4 vertex_p            : SV_Position;
};

// Dx resources
cbuffer VertexUniformBuf : register(b0, space1) { UI_DX_Uniform UniV; };

StructuredBuffer<UI_DX_Shape> ShapeBuf : register(t0);

Texture2DArray<V4> AtlasTexture : register(t0, space2);
SamplerState AtlasSampler : register(s0, space2);

// Shaders
UI_DX_Fragment UI_DxShaderVS(UI_DX_Vertex input)
{
  U32 corner_index = input.vertex_index & 3u; // 2 bits; [0:1]
  U32 shape_index = (input.vertex_index >> 2u) & 0x3FFFFFFF; // 30 bits; [2:31]
  UI_DX_Shape shape = ShapeBuf[shape_index];

  // position
  V2 pos = shape.p_min;
  if (corner_index & 1) pos.x = shape.p_max.x;
  if (corner_index & 2) pos.y = shape.p_max.y;

  // texture uv
  V2 tex_min = shape.tex_min;
  V2 tex_max = shape.tex_max;

  // clipping
  if (shape.clip_min.x > pos.x)
  {
    float delta = shape.clip_min.x - pos.x;
    tex_min.x += delta;
    pos.x = shape.clip_min.x;
  }
  if (shape.clip_min.y > pos.y)
  {
    float delta = shape.clip_min.y - pos.y;
    tex_min.y += delta;
    pos.y = shape.clip_min.y;
  }
  if (shape.clip_max.x < pos.x)
  {
    float delta = shape.clip_max.x - pos.x;
    tex_max.x += delta;
    pos.x = shape.clip_max.x;
  }
  if (shape.clip_max.y < pos.y)
  {
    float delta = shape.clip_max.y - pos.y;
    tex_max.y += delta;
    pos.y = shape.clip_max.y;
  }

  V2 tex_uv = V2(tex_min.x, tex_min.y);
  if (corner_index & 1) tex_uv.x = tex_max.x;
  if (corner_index & 2) tex_uv.y = tex_max.y;
  tex_uv /= UniV.texture_dim;

  //
  UI_DX_Fragment frag;
  frag.color = UnpackColor32(shape.color);
  frag.border_widths = shape.border_widths;
  frag.tex_uv = V3(tex_uv, shape.tex_layer);
  frag.pos = pos;
  frag.center   = (shape.p_min + shape.p_max) * 0.5f;
  frag.half_dim = (shape.p_max - shape.p_min) * 0.5f;
  frag.corner_radius    = shape.corner_radius;
  frag.edge_softness    = shape.edge_softness;
  frag.vertex_p = V4(2.f*pos / UniV.window_dim - 1.f, 1, 1);
  frag.vertex_p.y = -frag.vertex_p.y; // Flip Y so 0 means top of the window
  return frag;
}

V4 UI_DxShaderPS(UI_DX_Fragment frag) : SV_Target0
{
  V4 color = frag.color;
  if (frag.tex_uv.z >= 0.f)
  {
    V4 tex_color = AtlasTexture.Sample(AtlasSampler, frag.tex_uv);
    color *= tex_color;
  }

  V2 soft_pad = V2(frag.edge_softness, frag.edge_softness);

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

    V2 inner_half_dim = frag.half_dim - V2(border_h, border_v);

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
