//#include "shader_flags.h"
//#include "shader_util.hlsl"

struct WORLD_DX_Uniform
{
  Mat4 camera_transform;
  Mat4 shadow_transform;
  V3 camera_position;
  V3 sun_dir;
  U32 flags;

  U32 fog_color; // RGBA
  U32 sky_ambient; // RGBA
  U32 sun_diffuse; // RGBA
  U32 sun_specular; // RGBA

  U32 material_diffuse; // RGBA
  U32 material_specular; // RGBA
  float material_roughness;
  float material_loaded_t;
};

cbuffer VertexUniformBuf : register(b0, space1) { WORLD_DX_Uniform UV; };
cbuffer PixelUniformBuf  : register(b0, space3) { WORLD_DX_Uniform UP; };

struct WORLD_DX_Vertex
{
  V3  p              : TEXCOORD0;
  V3  normal         : TEXCOORD1;
  V2  uv             : TEXCOORD2;
  U32 joints_packed4 : TEXCOORD3;
  V4  joint_weights  : TEXCOORD4;
  U32 instance_index : SV_InstanceID;
};

struct WORLD_DX_Fragment
{
  V4   shadow_p       : TEXCOORD0; // position in shadow space
  V3   world_p        : TEXCOORD1;
  U32  instance_color : TEXCOORD2;
  U32  picking_color  : TEXCOORD3;
  V2   uv             : TEXCOORD4;
  Mat3 normal_rot     : TEXCOORD5;
  V4   vertex_p       : SV_Position;
};

struct WORLD_DX_InstanceModel
{
  Mat4 transform;
  U32 color;
  U32 picking_color;
  U32 pose_offset; // in indices; unused for rigid
};
StructuredBuffer<WORLD_DX_InstanceModel> InstanceBuf : register(t0);
StructuredBuffer<Mat4> SkinningPoseBuf : register(t1);

WORLD_DX_Fragment WORLD_DxShaderVS(WORLD_DX_Vertex vert)
{
  // Position
  WORLD_DX_InstanceModel instance;
  instance.transform = Mat4_Identity();
  instance.color = ~0;
  instance.picking_color = 0;
  instance.pose_offset = 0;

  if (UV.flags & WORLD_FLAG_UseInstanceBuffer)
    instance = InstanceBuf[vert.instance_index];

  Mat4 position_transform = instance.transform;

  if (UV.flags & WORLD_FLAG_DoMeshSkinning)
  {
    U32 joint0 = (vert.joints_packed4      ) & 0xff;
    U32 joint1 = (vert.joints_packed4 >>  8) & 0xff;
    U32 joint2 = (vert.joints_packed4 >> 16) & 0xff;
    U32 joint3 = (vert.joints_packed4 >> 24) & 0xff;
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

  V4 world_p = mul(position_transform, float4(vert.p, 1.0f));
  V4 vertex_p = mul(UV.camera_transform, world_p);

  Quat normal_rot = Quat_FromZupCrossV3(vert.normal);
  //Quat normal_rot = Quat(0,0,0,1);
  Mat3 input_normal_mat = Mat3_Rotation_Quat(normal_rot);
  Mat3 position_rotation = Mat3_FromMat4(Mat4_RotationPart(position_transform));
  Mat3 normal_rotation = mul(position_rotation, input_normal_mat);

  // Return
  WORLD_DX_Fragment frag;
  frag.shadow_p = mul(UV.shadow_transform, world_p);
  frag.world_p = world_p.xyz;
  frag.instance_color = instance.color;
  frag.picking_color = instance.picking_color;
  frag.uv = vert.uv;
  frag.normal_rot = normal_rotation;
  frag.vertex_p = vertex_p;
  return frag;
}

Texture2DArray<half> ShadowTexture : register(t0, space2);
SamplerState ShadowSampler : register(s0, space2);
Texture2DArray<float4> MaterialTexture : register(t1, space2);
SamplerState MaterialSampler : register(s1, space2);

V4 WORLD_DxShaderPS(WORLD_DX_Fragment frag) : SV_Target0
{
  V3 fog_color = UnpackColor32(UP.fog_color).xyz;
  V3 material_diffuse = UnpackColor32(UP.material_diffuse).xyz;
  V3 instance_color = UnpackColor32(frag.instance_color).xyz;

  // Load diffuse texture
  if (UP.flags & WORLD_FLAG_SampleTexDiffuse)
  {
    V4 tex_diffuse_raw = MaterialTexture.Sample(MaterialSampler, V3(frag.uv, 0.f));
    if (tex_diffuse_raw.a <= 0.1419588476419449f) // @todo this should be a material parameter
      discard;

    V3 tex_diffuse = tex_diffuse_raw.xyz;
    tex_diffuse = lerp(fog_color, tex_diffuse, UP.material_loaded_t);
    material_diffuse = tex_diffuse;
  }

  material_diffuse *= instance_color;

  if (UP.flags & WORLD_FLAG_PixelEarlyExit)
  {
    return UnpackColor32(frag.picking_color);
  }

  V3 sky_ambient = UnpackColor32(UP.sky_ambient).xyz;
  V3 sun_diffuse = UnpackColor32(UP.sun_diffuse).xyz;
  V3 sun_specular = UnpackColor32(UP.sun_specular).xyz;
  V3 material_specular = UnpackColor32(UP.material_specular).xyz;
  float material_roughness = UP.material_roughness;

  V3 face_normal = mul(frag.normal_rot, V3(0,0,1));
  V3 pixel_normal = face_normal;

  // Load normal texture
  if (UP.flags & WORLD_FLAG_SampleTexNormal)
  {
    V3 tex_normal = MaterialTexture.Sample(MaterialSampler, V3(frag.uv, 1.f)).xyz;
    // swizzle normal components into engine format - @todo do this in asset baker
    tex_normal.y = 1.f - tex_normal.y;
    tex_normal = tex_normal*2.f - 1.f; // transform from [0, 1] to [-1; 1]

    tex_normal = lerp(pixel_normal, tex_normal, UP.material_loaded_t);
    pixel_normal = normalize(mul(frag.normal_rot, tex_normal));
  }

   // Load roughness texture
  if (UP.flags & WORLD_FLAG_SampleTexRoughness)
  {
    float tex_roughness = MaterialTexture.Sample(MaterialSampler, V3(frag.uv, 2.f)).x;
    tex_roughness = lerp(0.5f, tex_roughness, UP.material_loaded_t);
    material_roughness = tex_roughness;
  }

  // Shadow mapping
  float shadow = 0.f;
  if (UP.flags & WORLD_FLAG_ApplyShadows)
  {
    V3 shadow_proj = frag.shadow_p.xyz / frag.shadow_p.w; // this isn't needed for orthographic projection
    // [-1, 1] -> [0, 1]
    shadow_proj.x = shadow_proj.x * 0.5f + 0.5f;
    shadow_proj.y = shadow_proj.y * -0.5f + 0.5f;

    V3 shadow_dim = 0.f;
    ShadowTexture.GetDimensions(shadow_dim.x, shadow_dim.y, shadow_dim.z);
    V2 texel_size = 1.f / shadow_dim.xy;

    int sample_radius = 1;
    for (int x = -sample_radius; x <= sample_radius; x++)
    {
      for (int y = -sample_radius; y <= sample_radius; y++)
      {
        V2 shadow_coord = shadow_proj.xy + V2(x,y) * texel_size;
        float closest_depth = ShadowTexture.Sample(ShadowSampler, V3(shadow_coord, 0.f));

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
    V3 view_dir = normalize(UP.camera_position - frag.world_p);
    V3 halfway_dir = normalize(view_dir - UP.sun_dir);
    float specular_angle = max(dot(pixel_normal, halfway_dir), 0.f);
    float max_shininess = 32.f;
    float shininess = max_shininess * material_roughness;
    specular_factor = pow(specular_angle, shininess);
  }

  V3 color_ambient = sky_ambient * material_diffuse;
  V3 color_diffuse = diffuse_factor * sun_diffuse * material_diffuse;
  V3 color_specular = specular_factor * sun_specular * material_specular;
  V3 color = color_ambient + (color_diffuse + color_specular) * (1.f - shadow);

  if (UP.flags & WORLD_FLAG_DrawBorderAtUVEdge)
  {
    float u = frac(frag.uv.x);
    float v = frac(frag.uv.y);

    float border = 1.0f;
    border = min(border, smoothstep(0.f, 0.01f, u)); // u min
    border = min(border, smoothstep(0.f, 0.01f, v)); // v min
    border = min(border, smoothstep(1.f, 0.99f, u)); // u max
    border = min(border, smoothstep(1.f, 0.99f, v)); // v max

    float mask = 1.f;
    mask *= smoothstep(0.0f, 0.02f, border);
    mask *= (border*0.5 + 0.5);
    // mask *= border;
    color *= mask;
  }

  // Apply fog
  {
    float pixel_distance = distance(frag.world_p, UP.camera_position);
    float fog_min = 1000.f;
    float fog_max = 2000.f;

    float fog_t = smoothstep(fog_min, fog_max, pixel_distance);
    color = lerp(color, fog_color, fog_t);
  }

  return V4(color, 1.f);
}
