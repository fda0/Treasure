// TYPES
V2 :: Vector2;
V3 :: Vector3;
V4 :: Vector4;
Quat :: Quaternion;

Mat4 :: struct // @todo change to row-major matrices in the future?
{
  // column-major Matrix 4x4
  // 0 4 8 c
  // 1 5 9 d
  // 2 6 a e
  // 3 7 b f

  // _yx
  _11, _21, _31, _41 : float;
  _12, _22, _32, _42 : float;
  _13, _23, _33, _43 : float;
  _14, _24, _34, _44 : float;

  #place _11; flat: [16]   float = ---;
  #place _11; elem: [4][4] float = ---;
  #place _11; cols: [4]    V4    = ---;
};

IsInteger :: (T: Type) -> bool
{
  ti := T.(*Type_Info);
  return ti.type == .INTEGER;
}
IsEnumFlags :: (T: Type) -> bool
{
  ti := T.(*Type_Info);
  if ti.type != .ENUM return false;
  te := T.(*Type_Info_Enum);
  return !!(te.enum_type_flags & .FLAGS);
}
VectorTypes :: Type.[V2, V3, V4, Vec2(s32)];
IsVector :: (T: Type) -> bool
{
  for VectorTypes
    if it == T return true;
  return false;
}


// AXIS MATH
Axis3 :: enum { X; Y; Z; };
AxisV3 :: (axis: Axis3) -> V3
{
  if axis == {
    case; #through;
    case .X; return V3.{1,0,0};
    case .Y; return V3.{0,1,0};
    case .Z; return V3.{0,0,1};
  }
}

// RANGE MATH
Range :: struct ($T: Type)
{
  min: T;
  max: T; // exclusive (open) range.
  // Values are valid for `min <= x < max`.
};

MakeRange :: (max: $T) -> Range(T) { return Range(T).{max = max}; }
MakeRange :: (min: $T, max: T) -> Range(T) { return Range(T).{min, max}; }
MakeRangeMinDim :: (min: $T, dim: T) -> Range(T) { return Range(T).{min, min + dim}; }
MakeRangeCenterHalfDim :: (center: $T, half_dim: T) -> Range(T) { return Range(T).{center - half_dim, center + half_dim}; }
MakeRangeCenterDim :: (center: $T, dim: T) -> Range(T) { return Range(T).{center - dim/2, center + dim/2}; }

Rect :: Range(V2);
MakeRect :: #procedure_of_call MakeRange(V2.{});
MakeRect :: #procedure_of_call MakeRange(V2.{}, V2.{});
MakeRectMinDim :: #procedure_of_call MakeRangeMinDim(V2.{}, V2.{});
MakeRectCenterHalfDim :: #procedure_of_call MakeRangeCenterHalfDim(V2.{}, V2.{});
MakeRectCenterDim :: #procedure_of_call MakeRangeCenterDim(V2.{}, V2.{});
MakeRect :: (max_x: float, max_y: float) -> Rect { return .{max = .{max_x, max_y}}; }
MakeRect :: (x: float, y: float, max_x: float, max_y: float) -> Rect { return .{.{x, y}, .{max_x, max_y}}; }
MakeRectMinDim :: (x: float, y: float, dim_x: float, dim_y: float) -> Rect { return .{.{x, y}, .{x, y} + .{dim_x, dim_y}}; }

operator == :: (a: Range($T), b: Range(T)) -> bool
{
  return a.min == b.min && a.max == b.max;
}

RangeLength :: (r: Range) -> r.T
{
  if r.max < r.min return 0;
  return r.max - r.min;
}

DistanceBetweenRanges :: (a: Range($T), b: Range(T)) -> T
{
  d0 := b.min - a.max;
  d1 := a.min - b.max;
  return max(d0, d1);
}

OverlapsRange :: (r: Range($T), value: T) -> bool
#modify { return !IsVector(T); }
{
  return value >= r.min && value < r.max;
}
OverlapsRange :: (r: Range($T), value: T) -> bool
#modify { return IsVector(T); }
{
  result := true;
  for value.component
    result &&= it >= r.min.component[it_index] && it < r.max.component[it_index];
  return result;
}

RangeIntersection :: (a: Range($T), b: Range(T)) -> Range(T)
#modify { return !IsVector(T); }
{
  result: Range(T);
  result.min = max(a.min, b.min);
  result.max = min(a.max, b.max);
  return result;
}
RangeIntersection :: (a: Range($T), b: Range(T)) -> Range(T)
#modify { return IsVector(T); }
{
  result: Range(T);
  for * result.min.component it.* = max(a.min.component[it_index], b.min.component[it_index]);
  for * result.max.component it.* = min(a.max.component[it_index], b.max.component[it_index]);
  return result;
}

for_expansion :: (range: Range($T), body: Code, flags: For_Flags) #expand
{
  #assert(flags == 0); // @todo extend support
  `it_index := 0;
  `it := range.min;
  while true
  {
    if it >= range.max break;
    defer {
      it += 1;
      it_index += 1;
    }
    #insert body;
  }
}

// SCALAR MATH
DirectionXYToRotationZ :: (not_normalized_dir3: V3) -> Quat
{
  dir := normalize(not_normalized_dir3.xy);
  turns := -Atan2(dir) + 0.25;
  turns = WrapFloat(-0.5, 0.5, turns);
  rotation := RotationAroundAxis(AxisV3(.Z), turns);
  return rotation;
}

CastSaturate :: ($Tdst: Type, value: $Tstr) -> Tdst
#modify { return IsInteger(Tdst) && IsInteger(Tstr), "Both arguments have to be of an integer type."; }
{
  #assert type_info(Tdst).runtime_size < type_info(Tstr).runtime_size;

  #if Tdst == u32
    return cast,trunc(Tdst) min(value, U32_MAX);
  else
    #assert "CastSaturate doesn't support this destination type yet";
  return 0;
}

AddClamp01 :: (dst: *float, delta: float)
{
  dst.* = clamp(dst.* + delta, 0.0, 1.0);
}

Round :: (x: float) -> float {
    return cast(float)cast(int)(x + 0.5 * ifx x < 0 then -1 else 1);
}

Smoothstep :: (t: float, min: float = 0, max: float = 1) -> float
{
  t = clamp((t - min) / (max - min), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

EasingType :: enum u32
{
  IN_SINE;
  OUT_SINE;
  OUT_BOUNCE;
}
Easing :: (x: float, type: EasingType) -> float
{
  // easings.net
  if #complete type == {
    case .IN_SINE;  return 1 - Cos(x * 0.25);
    case .OUT_SINE; return 1 - Sin(x * 0.25);

    case .OUT_BOUNCE;
    n1 := 7.5625;
    d1 := 2.75;
    if x < 1.0 / d1 {
        return n1 * x * x;
    } else if x < 2.0 / d1 {
        x -= 1.5 / d1;
        return n1 * x * x + 0.75;
    } else if x < 2.5 / d1 {
        x -= 2.25 / d1;
        return n1 * x * x + 0.9375;
    } else {
        x -= 2.625 / d1;
        return n1 * x * x + 0.984375;
    }
  }

  return x;
}

EasingInOut :: (x: float, out_threshold: float, in: EasingType, out: EasingType,
                in_scale := 1.0, out_scale := 1.0) -> float
{
  if x < out_threshold
  {
    // in
    in_range := out_threshold;
    x = x / in_range;
    return Easing(x, in) * in_scale;
  }
  else
  {
    // out
    out_range := 1.0 - out_threshold;
    x = (x - out_threshold) / out_range;
    return in_scale - Easing(x, out)*out_scale;
  }
}

Sign :: (x: float) -> float { return ifx x < 0.0 then -1.0 else 1.0; }

CeilPow2 :: (v: u32) -> u32
{
  if (!v) return 0;
  v -= 1;
  v |= v >> 1;
  v |= v >> 2;
  v |= v >> 4;
  v |= v >> 8;
  v |= v >> 16;
  v += 1;
  return v;
}

WrapFloat :: (min: float, max: float, value: float) -> float
{
  range := max - min;
  offset := value - min;
  return (offset - (floor(offset / range) * range) + min);
}

invsqrt :: inline (x: float) -> float { return 1.0 / sqrt(x); }

// VECTOR2 MATH
Rotate :: (v: V2, turns: float) -> V2
{
  sin, cos := SinCos(turns);
  res := Vector2.{
    v.x * cos + v.y * -sin,
    v.x * sin + v.y * cos,
  };
  return res;
}

HasLength :: (vec: $T/VectorTypes) -> bool
{
  for vec.component if it != 0.0 return true;
  return false;
}

clamp :: (x: $T/VectorTypes, a: T, b: T) -> T
{
  res: T = ---;
  for v, i: x.component
    res.component[i] = clamp(v, a.component[i], b.component[i]);
  return res;
}

Tan :: (turns: float) -> float
{
  r64 := Math.tan(turns * TURNS_TO_RAD);
  r32 := cast(float32)r64;
  return r32;
}

Atan2 :: (x: float, y: float) -> float { return Math.atan2(x, y)*RAD_TO_TURNS; }
Atan2 :: (vec: V2) -> float { return Atan2(vec.x, vec.y); }
Acos :: (x: float) -> float { return Math.acos(x)*RAD_TO_TURNS; }

NormalFromSegment :: (a: V2, b: V2) -> V2
{
  direction := normalize(b - a);
  res := Rotate(direction, -0.25);
  return res;
}

// QUATERNION MATH
RotationAroundAxis :: (axis_: V3, turns: float) -> Quat // Assumes Right Handed coordinate system
{
  sin, cos := SinCos(turns * 0.5);
  axis := normalize(axis_);
  axis *= sin;
  res := Quat.{
    axis.x,
    axis.y,
    axis.z,
    cos
  };
  return res;
}

RotationFromNormalizedPair :: (a: V3, b: V3) -> Quat
{
  cr := cross(a, b);
  res := Quat.{cr.x, cr.y, cr.z, 1.0 + dot(a, b)};
  return res;
}

RotationFromPair :: (a: V3, b: V3) -> Quat
{
  return RotationFromNormalizedPair(normalize(a), normalize(b));
}

Mix :: (a: Quat, b: Quat, weight_a: float, weight_b: float) -> Quat
{
  res := Quat.{
    a.x*weight_a + b.x*weight_b,
    a.y*weight_a + b.y*weight_b,
    a.z*weight_a + b.z*weight_b,
    a.w*weight_a + b.w*weight_b,
  };
  return res;
}

Nlerp :: (a: Quat, b: Quat, t: float) -> Quat
{
  return Mix(a, b, 1.0 - t, t);
}

Slerp :: (a: Quat, b_: Quat, t: float) -> Quat
{
  b := b_;

  cos_theta := dot(a, b);
  if cos_theta < 0.0
  {
    cos_theta = -cos_theta;
    b = -b;
  }

  if cos_theta > 0.9995
  {
    // NOTE(lcf): Use Normalized Linear interpolation when vectors are roughly not L.I.
    return Nlerp(a, b, t);
  }

  angle := Acos(cos_theta);
  ta := Sin((1.0 - t) * angle);
  tb := Sin(t * angle);

  res := Mix(a, b, ta, tb);
  return normalize(res);
}

SlowMultiply :: (a: Quat, b: Quat) -> Quat
{
  // @todo SIMD
  res: Quat = ---;
  res.x = b.w * +a.x;
  res.y = b.z * -a.x;
  res.z = b.y * +a.x;
  res.w = b.x * -a.x;

  res.x += b.z * +a.y;
  res.y += b.w * +a.y;
  res.z += b.x * -a.y;
  res.w += b.y * -a.y;

  res.x += b.y * -a.z;
  res.y += b.x * +a.z;
  res.z += b.w * +a.z;
  res.w += b.z * -a.z;

  res.x += b.x * +a.w;
  res.y += b.y * +a.w;
  res.z += b.z * +a.w;
  res.w += b.w * +a.w;
  return res;
}


// MATRIX MATH
operator == :: (a: Mat4, b: Mat4) -> bool
{
  return memcmp(*a, *b, size_of(Mat4)) == 0;
}

ScaleMatrix :: (scale: V3) -> Mat4
{
  res: Mat4;
  res.elem[0][0] = scale.x;
  res.elem[1][1] = scale.y;
  res.elem[2][2] = scale.z;
  res.elem[3][3] = 1.0;
  return res;
}

ScaleMatrix :: (scale: float) -> Mat4
{
  res: Mat4;
  res.elem[0][0] = scale;
  res.elem[1][1] = scale;
  res.elem[2][2] = scale;
  res.elem[3][3] = 1.0;
  return res;
}

RotationMatrix :: (q: Quat) -> Mat4
{
  norm := normalize(q);
  xx_ := norm.x * norm.x;
  yy := norm.y * norm.y;
  zz := norm.z * norm.z;
  xy := norm.x * norm.y;
  xz := norm.x * norm.z;
  yz := norm.y * norm.z;
  wx := norm.w * norm.x;
  wy := norm.w * norm.y;
  wz := norm.w * norm.z;

  res: Mat4 = ---;
  res.elem[0][0] = 1.0 - 2.0 * (yy + zz);
  res.elem[0][1] = 2.0 * (xy + wz);
  res.elem[0][2] = 2.0 * (xz - wy);
  res.elem[0][3] = 0.0;

  res.elem[1][0] = 2.0 * (xy - wz);
  res.elem[1][1] = 1.0 - 2.0 * (xx_ + zz);
  res.elem[1][2] = 2.0 * (yz + wx);
  res.elem[1][3] = 0.0;

  res.elem[2][0] = 2.0 * (xz + wy);
  res.elem[2][1] = 2.0 * (yz - wx);
  res.elem[2][2] = 1.0 - 2.0 * (xx_ + yy);
  res.elem[2][3] = 0.0;

  res.elem[3][0] = 0.0;
  res.elem[3][1] = 0.0;
  res.elem[3][2] = 0.0;
  res.elem[3][3] = 1.0;
  return res;
}

DiagonalMatrix :: (value: float = 1) -> Mat4
{
  res: Mat4;
  res.elem[0][0] = value;
  res.elem[1][1] = value;
  res.elem[2][2] = value;
  res.elem[3][3] = value;
  return res;
}

TranslationMatrix :: (move: V3) -> Mat4
{
  res := DiagonalMatrix();
  res.elem[3][0] = move.x;
  res.elem[3][1] = move.y;
  res.elem[3][2] = move.z;
  return res;
}

RotationMatrixAroundAxis :: (axis_: V3, turns: float) -> Mat4
{
  axis := normalize(axis_);
  ts, tc := SinCos(turns);
  c1 := 1.0 - tc;

  res := DiagonalMatrix();
  res.elem[0][0] = (axis.x * axis.x * c1) + tc;
  res.elem[0][1] = (axis.x * axis.y * c1) + (axis.z * ts);
  res.elem[0][2] = (axis.x * axis.z * c1) - (axis.y * ts);

  res.elem[1][0] = (axis.y * axis.x * c1) - (axis.z * ts);
  res.elem[1][1] = (axis.y * axis.y * c1) + tc;
  res.elem[1][2] = (axis.y * axis.z * c1) + (axis.x * ts);

  res.elem[2][0] = (axis.z * axis.x * c1) + (axis.y * ts);
  res.elem[2][1] = (axis.z * axis.y * c1) - (axis.x * ts);
  res.elem[2][2] = (axis.z * axis.z * c1) + tc;
  return res;
}

PerspectiveMatrix :: (fov_y: float, aspect_ratio: float, near: float, far: float) -> Mat4
{
  // Modified to work with +x fordward, -y right, +z up coordinate system (same as Source engine).
  cotangent := 1.0 / Tan(fov_y * 0.5);
  res: Mat4;
  res.elem[0][2] = -far / (near - far); // X -> -Z
  res.elem[0][3] = 1.0; // X -> W
  res.elem[1][0] = -cotangent / aspect_ratio; // -Y -> X
  res.elem[2][1] = cotangent; // Z -> Y
  res.elem[3][2] = (near * far) / (near - far); // W -> Z
  return res;
}

OrthographicMatrix :: (left: float, right: float, bottom: float, top: float, near: float, far: float) -> Mat4
{
  res: Mat4;
  res.elem[0][2] = -1.0 / (near - far); // X -> -Z
  res.elem[1][0] = -2.0 / (right - left); // -Y -> X
  res.elem[2][1] = 2.0 / (top - bottom); // Z -> Y
  res.elem[3][3] = 1.0; // W -> W

  res.elem[3][0] = (left + right) / (left - right); // W -> X
  res.elem[3][1] = (bottom + top) / (bottom - top); // W -> Y
  res.elem[3][2] = near / (near - far); // W -> Z
  return res;
}

multiply :: (m: Mat4, n: Mat4) -> Mat4
{
  result: Mat4 = ---;

  result._11 = m._11*n._11 + m._12*n._21 + m._13*n._31 + m._14*n._41;
  result._21 = m._21*n._11 + m._22*n._21 + m._23*n._31 + m._24*n._41;
  result._31 = m._31*n._11 + m._32*n._21 + m._33*n._31 + m._34*n._41;
  result._41 = m._41*n._11 + m._42*n._21 + m._43*n._31 + m._44*n._41;

  result._12 = m._11*n._12 + m._12*n._22 + m._13*n._32 + m._14*n._42;
  result._22 = m._21*n._12 + m._22*n._22 + m._23*n._32 + m._24*n._42;
  result._32 = m._31*n._12 + m._32*n._22 + m._33*n._32 + m._34*n._42;
  result._42 = m._41*n._12 + m._42*n._22 + m._43*n._32 + m._44*n._42;

  result._13 = m._11*n._13 + m._12*n._23 + m._13*n._33 + m._14*n._43;
  result._23 = m._21*n._13 + m._22*n._23 + m._23*n._33 + m._24*n._43;
  result._33 = m._31*n._13 + m._32*n._23 + m._33*n._33 + m._34*n._43;
  result._43 = m._41*n._13 + m._42*n._23 + m._43*n._33 + m._44*n._43;

  result._14 = m._11*n._14 + m._12*n._24 + m._13*n._34 + m._14*n._44;
  result._24 = m._21*n._14 + m._22*n._24 + m._23*n._34 + m._24*n._44;
  result._34 = m._31*n._14 + m._32*n._24 + m._33*n._34 + m._34*n._44;
  result._44 = m._41*n._14 + m._42*n._24 + m._43*n._34 + m._44*n._44;

  return result;
}
operator * :: (a: Mat4, b: Mat4) -> Mat4 { return inline multiply(a, b); }


multiply :: (m: Mat4, vec: V4) -> V4
{
  // @todo SIMD
  res: V4 = ---;
  res.x = vec.component[0] * m.cols[0].x;
  res.y = vec.component[0] * m.cols[0].y;
  res.z = vec.component[0] * m.cols[0].z;
  res.w = vec.component[0] * m.cols[0].w;

  res.x += vec.component[1] * m.cols[1].x;
  res.y += vec.component[1] * m.cols[1].y;
  res.z += vec.component[1] * m.cols[1].z;
  res.w += vec.component[1] * m.cols[1].w;

  res.x += vec.component[2] * m.cols[2].x;
  res.y += vec.component[2] * m.cols[2].y;
  res.z += vec.component[2] * m.cols[2].z;
  res.w += vec.component[2] * m.cols[2].w;

  res.x += vec.component[3] * m.cols[3].x;
  res.y += vec.component[3] * m.cols[3].y;
  res.z += vec.component[3] * m.cols[3].z;
  res.w += vec.component[3] * m.cols[3].w;
  return res;
}
operator * :: (m: Mat4, vec: V4) -> V4 { return inline multiply(m, vec); }

transpose :: (m: Mat4) -> Mat4
{
    r: Mat4 = ---;
    for i: 0..3 for j: 0..3 {
        r.elem[i][j] = m.elem[j][i];
    }
    return r;
}



// VEC2 - generic impl (allows for T != float)
Vec2 :: struct($T: Type)
{
  x, y: T;
  #place x; component: [2] T;
};

// vec x vec
operator + :: (a: Vec2($T), b: Vec2(T)) -> Vec2(T) {
  return .{a.x+b.x, a.y+b.y};
}
operator - :: (a: Vec2($T), b: Vec2(T)) -> Vec2(T) {
  return .{a.x-b.x, a.y-b.y};
}
operator * :: (a: Vec2($T), b: Vec2(T)) -> Vec2(T) {
  return .{a.x*b.x, a.y*b.y};
}
operator / :: (a: Vec2($T), b: Vec2(T)) -> Vec2(T) {
  return .{a.x/b.x, a.y/b.y};
}
min :: (a: Vec2($T), b: Vec2(T)) -> Vec2(T) {
  return .{min(a.x,b.x), min(a.y,b.y)};
}
max :: (a: Vec2($T), b: Vec2(T)) -> Vec2(T) {
  return .{max(a.x,b.x), max(a.y,b.y)};
}

// vec x scalar
operator * :: (v: Vec2($T), scalar: T) -> Vec2(T) {
  return .{v.x*scalar, v.y*scalar};
}
operator / :: (v: Vec2($T), scalar: T) -> Vec2(T) {
  return .{v.x/scalar, v.y/scalar};
}
min :: (v: Vec2($T), scalar: T) -> Vec2(T) {
  return .{min(v.x,scalar), min(v.y,scalar)};
}
max :: (v: Vec2($T), scalar: T) -> Vec2(T) {
  return .{max(v.x,scalar), max(v.y,scalar)};
}


// We wrap some math operations here to change its units from radians to turns.
// For now there is a bunch of needless unit conversions which will be eliminated
// once I create my own math implementations (by forking modules/Math).
using,except(sin,cos,tan,atan,atan2,rotate,translate,rotation_matrix) Math :: #import "Math";

TURNS_TO_RAD :: TAU;
RAD_TO_TURNS :: 1.0 / TAU;

SinCos :: (turns: float) -> sin:float, cos:float
{
  rad := TURNS_TO_RAD * turns;
  // @speed add optimized function that calculates both sin & cos at once at reduced total cost
  s := Math.sin(rad);
  c := Math.cos(rad);
  return s, c;
}

Sin :: (turns: float) -> float
{
  rad := TURNS_TO_RAD * turns;
  return Math.sin(rad);
}
Cos :: (turns: float) -> float
{
  rad := TURNS_TO_RAD * turns;
  return Math.cos(rad);
}

Sin01 :: (turns: float) -> float { return Sin(turns)*0.5 + 0.5; }
Cos01 :: (turns: float) -> float { return Cos(turns)*0.5 + 0.5; }

//
Rotate :: (v: V3, q: Quat) -> V3 { return Math.rotate(v, q); }
