Color32 :: #type,distinct u32;
C4 :: V4;
C32 :: Color32;

Color32_RGBAi :: (r: u32, g: u32, b: u32, a: u32) -> Color32
{
  res := (a << 24) | (b << 16) | (g << 8) | r;
  return res.(Color32);
}
Color32_SetAlphai :: (color: Color32, a: u32) -> Color32
{
  no_alpha := color.(u32) & ~(0xff << 24);
  return xx (no_alpha | (a << 24));
}
Color32_RGBAf :: (r: float, g: float, b: float, a: float) -> Color32
{
  ri := (r * 255).(u32) & 255;
  gi := (g * 255).(u32) & 255;
  bi := (b * 255).(u32) & 255;
  ai := (a * 255).(u32) & 255;
  return Color32_RGBAi(ri, gi, bi, ai);
}
Color32_RGBf :: (r: float, g: float, b: float) -> Color32
{
  ri := (r * 255).(u32) & 255;
  gi := (g * 255).(u32) & 255;
  bi := (b * 255).(u32) & 255;
  return Color32_RGBAi(ri, gi, bi, 255);
}
Color32_RGBi  :: (r: u32, g: u32, b: u32) -> Color32 { return Color32_RGBAi(r, g, b, 255); }
Color32_Grayi :: (rgb: u32) -> Color32 { return Color32_RGBi(rgb, rgb, rgb); }
Color32_Grayf :: (rgb: float)       -> Color32 { return Color32_RGBf(rgb, rgb, rgb); }
Color32_RGBf  :: (color: V3)        -> Color32 { return Color32_RGBf(color.x, color.y, color.z); }
Color32_RGBf  :: (color: [3] float) -> Color32 { return Color32_RGBf(color[0], color[1], color[2]); }
Color32_RGBAf :: (color: [4] float) -> Color32 { return Color32_RGBAf(color[0], color[1], color[2], color[3]); }

C32_RGBAi :: Color32_RGBAi;
C32_SetAlpha :: Color32_SetAlphai;
C32_RGBAf :: Color32_RGBAf;
C32_RGBf :: Color32_RGBf;
C32_RGBi :: Color32_RGBi;
C32_Grayi :: Color32_Grayi;
C32_Grayf :: Color32_Grayf;
C32_RGBf :: Color32_RGBf;
C32_RGBf :: Color32_RGBf;
C32_RGBAf :: Color32_RGBAf;
C32_RGBAf :: Color32_RGBAf;

C32_0xRGB :: (rgb: u32) -> C32
{
  r := (rgb >> 16) & 0xff;
  g := (rgb >> 8) & 0xff;
  b := rgb & 0xff;
  return C32_RGBi(r, g, b);
}

lerp :: (c0: Color32, c1: Color32, t: float) -> Color32
{
  // @todo Do a lerp in a different color space - like Oklab or something
  // https://raphlinus.github.io/color/2021/01/18/oklab-critique.html
  vec0 := C4_from_C32(c0);
  vec1 := C4_from_C32(c1);
  lerped := lerp(vec0, vec1, t);
  res := C32_from_C4(lerped);
  return res;
}

C32_to_C4 :: C4_from_C32;
Unpack :: C4_from_C32;
C4_from_C32 :: (packed: Color32) -> C4
{
  inv: float = 1.0 / 255.0;
  res: C4 = ---;
  res.x = (packed & 255) * inv;
  res.y = ((packed >> 8) & 255) * inv;
  res.z = ((packed >> 16) & 255) * inv;
  res.w = ((packed >> 24) & 255) * inv;
  return res;
}

C4_to_C32 :: C32_from_C4;
Pack :: C32_from_C4;
C32_from_C4 :: (color: V4) -> Color32
{
  return Color32_RGBAf(color.x, color.y, color.z, color.w);
}

C4_RGB :: (r: float, g: float, b: float) -> C4
{
  return .{r, g, b, 1.0};
}

InvertRGB :: (c: C32) -> C32
{
  rgb := ~c & 0xff_ff_ff;
  c &= 0xff_00_00_00;
  c |= rgb;
  return c;
}
