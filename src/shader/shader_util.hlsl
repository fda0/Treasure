typedef float4 Quat;
typedef float4 V4;
typedef float3 V3;
typedef float2 V2;
typedef float4x4 Mat4;
typedef float3x3 Mat3;
typedef uint U32;
typedef int I32;

static V4 UnpackColor32(U32 packed)
{
  float inv = 1.f / 255.f;
  V4 res;
  res.r = (packed & 255) * inv;
  res.g = ((packed >> 8) & 255) * inv;
  res.b = ((packed >> 16) & 255) * inv;
  res.a = ((packed >> 24) & 255) * inv;
  return res;
}

static Mat4 Mat4_Identity()
{
  return Mat4(1.0f, 0.0f, 0.0f, 0.0f,
              0.0f, 1.0f, 0.0f, 0.0f,
              0.0f, 0.0f, 1.0f, 0.0f,
              0.0f, 0.0f, 0.0f, 1.0f);
}

static Mat4 Mat4_RotationPart(Mat4 mat)
{
  // Extract the 3x3 submatrix columns
  // @todo is this extraction correct? - check with non-uniform scaling
  V3 axis_x = normalize(V3(mat._m00, mat._m10, mat._m20));
  V3 axis_y = normalize(V3(mat._m01, mat._m11, mat._m21));
  V3 axis_z = normalize(V3(mat._m02, mat._m12, mat._m22));

  // Rebuild the matrix with normalized vectors and zero translation
  mat._m00 = axis_x.x; mat._m01 = axis_y.x; mat._m02 = axis_z.x; mat._m03 = 0.f;
  mat._m10 = axis_x.y; mat._m11 = axis_y.y; mat._m12 = axis_z.y; mat._m13 = 0.f;
  mat._m20 = axis_x.z; mat._m21 = axis_y.z; mat._m22 = axis_z.z; mat._m23 = 0.f;
  mat._m30 = 0.f;      mat._m31 = 0.f;      mat._m32 = 0.f;      mat._m33 = 1.f;
  return mat;
}

static Mat3 Mat3_FromMat4(float4x4 mat)
{
  Mat3 res;
  res._m00 = mat._m00;
  res._m01 = mat._m01;
  res._m02 = mat._m02;
  res._m10 = mat._m10;
  res._m11 = mat._m11;
  res._m12 = mat._m12;
  res._m20 = mat._m20;
  res._m21 = mat._m21;
  res._m22 = mat._m22;
  return res;
}

static Quat Quat_FromNormalizedPair(V3 a, V3 b)
{
  V3 crs = cross(a, b);
  Quat res =
  {
    crs.x,
    crs.y,
    crs.z,
    1.f + dot(a, b),
  };
  return res;
}

static Quat Quat_FromZupCrossV3(V3 a)
{
  return Quat_FromNormalizedPair(V3(0,0,1), normalize(a));
}


static Mat3 Mat3_Rotation_Quat(Quat q)
{
  Quat norm = normalize(q);
  float xx = norm.x * norm.x;
  float yy = norm.y * norm.y;
  float zz = norm.z * norm.z;
  float xy = norm.x * norm.y;
  float xz = norm.x * norm.z;
  float yz = norm.y * norm.z;
  float wx = norm.w * norm.x;
  float wy = norm.w * norm.y;
  float wz = norm.w * norm.z;

  Mat3 res;
  res._m00 = 1.0f - 2.0f * (yy + zz);
  res._m10 = 2.0f * (xy + wz);
  res._m20 = 2.0f * (xz - wy);

  res._m01 = 2.0f * (xy - wz);
  res._m11 = 1.0f - 2.0f * (xx + zz);
  res._m21 = 2.0f * (yz + wx);

  res._m02 = 2.0f * (xz + wy);
  res._m12 = 2.0f * (yz - wx);
  res._m22 = 1.0f - 2.0f * (xx + yy);
  return res;
}

static float RoundedRectSDF(V2 pos, V2 center, V2 half_dim, float r)
{
  V2 d2 = (abs(center - pos) - half_dim + V2(r,r));
  float l = length(max(d2, V2(0.f,0.f)));
  return min(max(d2.x, d2.y), 0.f) + l - r;
}

static float HexagonSDF(V2 pos, float r)
{
  V3 k = V3(-0.866025404, 0.5, 0.577350269);
  V2 p = abs(pos);
  p -= 2 * min(dot(k.xy, p), 0.0) * k.xy;
  p -= V2(clamp(p.x, -k.z*r, k.z*r), r);
  return length(p) * sign(p.y);
}

static float HexagonBoardSDF(V2 position, float scale)
{
  position /= scale;

  position /= V2(2.0, sqrt(3.0));
  position.y -= 0.5;
  position.x -= frac(floor(position.y) * 0.5);
  position = abs(frac(position) - 0.5);
  float result = abs(1.0 - max(position.x + position.y * 1.5, position.x * 2.0));
  return result * scale;
}

static float FWrap(float min, float max, float a)
{
  float range = max - min;
  float offset = a - min;
  return (offset - (floor(offset / range) * range) + min);
}
