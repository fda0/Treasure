//#include "shader_flags.h"
//#include "shader_util.hlsl"

struct WORLD_DX_Uniform
{
  Mat4 camera_transform;
  Mat4 shadow_transform;
  float3 camera_position;
  float3 sun_dir;
  uint flags;

  uint fog_color; // RGBA
  uint sky_ambient; // RGBA
  uint sun_diffuse; // RGBA
  uint sun_specular; // RGBA

  uint material_diffuse; // RGBA
  uint material_specular; // RGBA
  float material_roughness;
  float material_loaded_t;
};

cbuffer VertexUniformBuf : register(b0, space1) { WORLD_DX_Uniform UV; };
cbuffer PixelUniformBuf  : register(b0, space3) { WORLD_DX_Uniform UP; };

struct WORLD_DX_Vertex
{
  float3 p             : TEXCOORD0;
  float3 normal        : TEXCOORD1;
  float2 uv            : TEXCOORD2;
  uint color           : TEXCOORD3;
  uint joints_packed4  : TEXCOORD4;
  float4 joint_weights : TEXCOORD5;
  uint instance_index  : SV_InstanceID;
};

struct WORLD_DX_Fragment
{
  float4 shadow_p    : TEXCOORD0; // position in shadow space
  float3 world_p     : TEXCOORD1;
  uint color_mask    : TEXCOORD2;
  float hue_shift    : TEXCOORD3;
  uint picking_color : TEXCOORD4;
  float2 uv          : TEXCOORD5;
  Mat3 normal_rot    : TEXCOORD6;
  float4 vertex_p    : SV_Position;
};

struct WORLD_DX_InstanceModel
{
  Mat4 transform;
  uint color_mask;
  float hue_shift;
  uint picking_color;
  uint pose_offset; // in indices; unused for rigid
};
StructuredBuffer<WORLD_DX_InstanceModel> InstanceBuf : register(t0);
StructuredBuffer<Mat4> SkinningPoseBuf : register(t1);

WORLD_DX_Fragment WORLD_DxShaderVS(WORLD_DX_Vertex vert)
{
  // Position
  WORLD_DX_InstanceModel instance;
  instance.transform = Mat4_Identity();
  instance.color_mask = ~0;
  instance.picking_color = 0;
  instance.pose_offset = 0;

  if (UV.flags & WORLD_FLAG_UseInstanceBuffer)
  {
    instance = InstanceBuf[vert.instance_index];
  }

  if (UV.flags & WORLD_FLAG_DiscardColorPickZero)
  {
    if (instance.picking_color == 0)
    {
      WORLD_DX_Fragment frag;
      frag.vertex_p = 100.f;
      return frag;
    }
  }

  Mat4 position_transform = instance.transform;

  if (UV.flags & WORLD_FLAG_DoMeshSkinning)
  {
    uint joint0 = (vert.joints_packed4      ) & 0xff;
    uint joint1 = (vert.joints_packed4 >>  8) & 0xff;
    uint joint2 = (vert.joints_packed4 >> 16) & 0xff;
    uint joint3 = (vert.joints_packed4 >> 24) & 0xff;
    joint0 += instance.pose_offset;
    joint1 += instance.pose_offset;
    joint2 += instance.pose_offset;
    joint3 += instance.pose_offset;

    Mat4 pose_transform0 = SkinningPoseBuf[joint0];
    Mat4 pose_transform1 = SkinningPoseBuf[joint1];
    Mat4 pose_transform2 = SkinningPoseBuf[joint2];
    Mat4 pose_transform3 = SkinningPoseBuf[joint3];

    Mat4 pose_transform =
      pose_transform0 * vert.joint_weights.x +
      pose_transform1 * vert.joint_weights.y +
      pose_transform2 * vert.joint_weights.z +
      pose_transform3 * vert.joint_weights.w;

    position_transform = mul(position_transform, pose_transform);
  }

  float4 world_p = mul(position_transform, float4(vert.p, 1.0f));
  float4 vertex_p = mul(UV.camera_transform, world_p);

  Quat normal_rot = Quat_FromZupCrossV3(vert.normal);
  //Quat normal_rot = Quat(0,0,0,1);
  Mat3 input_normal_mat = Mat3_Rotation_Quat(normal_rot);
  Mat3 position_rotation = Mat3_FromMat4(Mat4_RotationPart(position_transform));
  Mat3 normal_rotation = mul(position_rotation, input_normal_mat);

  // Merge color masks
  float4 instance_color = UnpackColor(instance.color_mask);
  float4 vertex_color = UnpackColor(vert.color);
  float4 color_mask = instance_color * vertex_color;
  uint color_mask_packed = PackColor(color_mask);

  // Return
  WORLD_DX_Fragment frag;
  frag.shadow_p = mul(UV.shadow_transform, world_p);
  frag.world_p = world_p.xyz;
  frag.color_mask = color_mask_packed;
  frag.hue_shift = instance.hue_shift;
  frag.picking_color = instance.picking_color;
  frag.uv = vert.uv;
  frag.normal_rot = normal_rotation;
  frag.vertex_p = vertex_p;
  return frag;
}

Texture2D<half> ShadowTexture : register(t0, space2);
SamplerState ShadowSampler : register(s0, space2);
Texture2DArray<float4> MaterialTexture : register(t1, space2);
SamplerState MaterialSampler : register(s1, space2);

float4 WORLD_DxShaderPS(WORLD_DX_Fragment frag) : SV_Target0
{
  if (UP.flags & WORLD_FLAG_OutlineEarlyExit)
  {
    return frag.vertex_p;
  }

  float3 fog_color = UnpackColor(UP.fog_color).xyz;
  float3 material_diffuse = UnpackColor(UP.material_diffuse).xyz;
  float3 color_mask = UnpackColor(frag.color_mask).xyz;

  // Load diffuse texture
  if (UP.flags & WORLD_FLAG_SampleTexDiffuse)
  {
    float4 tex_diffuse_raw = MaterialTexture.Sample(MaterialSampler, float3(frag.uv, 0.f));
    if (tex_diffuse_raw.a <= 0.1419588476419449f) // @todo this should be a material parameter
      discard;

    float3 tex_diffuse = tex_diffuse_raw.xyz;
    tex_diffuse = lerp(fog_color, tex_diffuse, UP.material_loaded_t);
    material_diffuse = tex_diffuse;
  }

  if (UP.flags & WORLD_FLAG_PixelEarlyExit)
  {
    return UnpackColor(frag.picking_color);
  }

  // Apply color_mask
  material_diffuse *= color_mask;

  // Apply hue_shift
  if ((UP.flags & WORLD_FLAG_EnableHueShift) && frag.hue_shift)
  {
    float3 diffuse_hsv = RGBtoHSV(material_diffuse);
    diffuse_hsv.x = FWrap(0.f, 1.f, diffuse_hsv.x + frag.hue_shift);
    material_diffuse = HSVtoRGB(diffuse_hsv);
  }

  float3 sky_ambient = UnpackColor(UP.sky_ambient).xyz;
  float3 sun_diffuse = UnpackColor(UP.sun_diffuse).xyz;
  float3 sun_specular = UnpackColor(UP.sun_specular).xyz;
  float3 material_specular = UnpackColor(UP.material_specular).xyz;
  float material_roughness = UP.material_roughness;

  float3 face_normal = mul(frag.normal_rot, float3(0,0,1));
  float3 pixel_normal = face_normal;

  // Load normal texture
  if (UP.flags & WORLD_FLAG_SampleTexNormal)
  {
    float3 tex_normal = MaterialTexture.Sample(MaterialSampler, float3(frag.uv, 1.f)).xyz;
    // swizzle normal components into engine format - @todo do this in asset baker
    tex_normal.y = 1.f - tex_normal.y;
    tex_normal = tex_normal*2.f - 1.f; // transform from [0, 1] to [-1; 1]

    tex_normal = lerp(pixel_normal, tex_normal, UP.material_loaded_t);
    pixel_normal = normalize(mul(frag.normal_rot, tex_normal));
  }

   // Load roughness texture
  if (UP.flags & WORLD_FLAG_SampleTexRoughness)
  {
    float tex_roughness = MaterialTexture.Sample(MaterialSampler, float3(frag.uv, 2.f)).x;
    tex_roughness = lerp(0.5f, tex_roughness, UP.material_loaded_t);
    material_roughness = tex_roughness;
  }

  // Shadow mapping
  float shadow = 0.f;
  if (UP.flags & WORLD_FLAG_ApplyShadows)
  {
    float3 shadow_proj = frag.shadow_p.xyz / frag.shadow_p.w; // this isn't needed for orthographic projection
    // [-1, 1] -> [0, 1]
    shadow_proj.x = shadow_proj.x * 0.5f + 0.5f;
    shadow_proj.y = shadow_proj.y * -0.5f + 0.5f;

    float2 shadow_dim = 0.f;
    ShadowTexture.GetDimensions(shadow_dim.x, shadow_dim.y);
    float2 texel_size = 1.f / shadow_dim;

    int sample_radius = 1;
    for (int x = -sample_radius; x <= sample_radius; x++)
    {
      for (int y = -sample_radius; y <= sample_radius; y++)
      {
        float2 shadow_coord = shadow_proj.xy + float2(x,y) * texel_size;
        float closest_depth = ShadowTexture.Sample(ShadowSampler, float3(shadow_coord, 0.f));

        // This hack is done because SDL_GPU doesn't support BORDER_COLOR for SDL_GPUSamplerAddressMode
        if (shadow_proj.x < 0.f || shadow_proj.x > 1.f || shadow_proj.y < 0.f || shadow_proj.y > 1.f)
          closest_depth = 1.f;

        float current_depth = shadow_proj.z;
        if (current_depth <= 1.f)
        {
          float bias = max(0.005f * (1.f - dot(-UP.sun_dir, face_normal)), 0.005f);
          shadow += current_depth - bias > closest_depth ? 1.f : 0.f;
        }
      }
    }

    float sample_count = (sample_radius*2 + 1) * (sample_radius*2 + 1);
    shadow /= sample_count;
  }

  // Light
  float specular_factor = 0.0f;
  float diffuse_factor = max(dot(-UP.sun_dir, pixel_normal), 0.f);

  if (diffuse_factor > 0.f)
  {
    float3 view_dir = normalize(UP.camera_position - frag.world_p);
    float3 halfway_dir = normalize(view_dir - UP.sun_dir);
    float specular_angle = max(dot(pixel_normal, halfway_dir), 0.f);
    float max_shininess = 32.f;
    float shininess = max_shininess * material_roughness;
    specular_factor = pow(specular_angle, shininess);
  }

  float3 color_ambient = sky_ambient * material_diffuse;
  float3 color_diffuse = diffuse_factor * sun_diffuse * material_diffuse;
  float3 color_specular = specular_factor * sun_specular * material_specular;
  float3 color = color_ambient + (color_diffuse + color_specular) * (1.f - shadow);

  float pixel_distance = distance(frag.world_p, UP.camera_position);

  if (UP.flags & WORLD_FLAG_DrawBorderAtUVEdge)
  {
    float u = frac(frag.uv.x);
    float v = frac(frag.uv.y);

    float margin = pixel_distance * 0.001f;
    float edge0 = margin;
    float edge1 = 1.f - margin;

    float border = 1.0f;
    border *= smoothstep(0.f, edge0, u); // u min
    border *= smoothstep(0.f, edge0, v); // v min
    border *= smoothstep(1.f, edge1, u); // u max
    border *= smoothstep(1.f, edge1, v); // v max

    float visibility_falloff_start = 19.f;
    float visibility_falloff_end   = 28.f;
    float visibility_t = smoothstep(visibility_falloff_start, visibility_falloff_end, pixel_distance);

    float mask = lerp(border, 1.f, visibility_t);
    mask = mask*0.25 + 0.75;
    color *= mask;
  }

  // Apply fog
  {
    float fog_min = 100.f;
    float fog_max = 200.f;

    float fog_t = smoothstep(fog_min, fog_max, pixel_distance);
    color = lerp(color, fog_color, fog_t);
  }

  return float4(color, 1.f);
}
