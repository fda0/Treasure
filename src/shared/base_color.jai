Color32 :: u32; // Packed color
Color :: V4; // Unpacked color

ColorUnpack :: (packed: u32) -> Color
{
  inv :: 1.0 / 255.0;
  res: V4 = ---;
  res.x = (packed & 0xff) * inv;
  res.y = ((packed >> 8) & 0xff) * inv;
  res.z = ((packed >> 16) & 0xff) * inv;
  res.w = ((packed >> 24) & 0xff) * inv;
  return res;
}

ColorPack :: (color: V4) -> Color32
{
  r := (color.x * 0xff).(u32) & 0xff;
  g := (color.y * 0xff).(u32) & 0xff;
  b := (color.z * 0xff).(u32) & 0xff;
  a := (color.w * 0xff).(u32) & 0xff;
  res := (a << 24) | (b << 16) | (g << 8) | r;
  return res;
}

ColorRGB :: (r: float, g: float, b: float) -> Color {
  return .{r, g, b, 1};
}
ColorRGB :: (rgb: [3] float) -> Color {
  return .{rgb[0], rgb[1], rgb[2], 1};
}
ColorRGBA :: (r: float, g: float, b: float, a: float) -> Color {
  return .{r, g, b, a};
}
ColorRGBA :: (rgba: [4] float) -> Color {
  return .{rgba[0], rgba[1], rgba[2], rgba[3]};
}

ColorBlack :: (shade := 0.0, alpha := 1.0) -> V4 {
  return .{shade, shade, shade, alpha};
}
ColorGray :: (shade := 0.5, alpha := 1.0) -> V4 {
  return .{shade, shade, shade, alpha};
}
ColorWhite :: (shade := 1.0, alpha := 1.0) -> V4 {
  return .{shade, shade, shade, alpha};
}

//
// Packed
//
PackedRGB :: (r: Color32, g: Color32, b: Color32) -> Color32 {
  return r | ((g & 0xff) << 8) | ((b & 0xff) << 16) | (0xff << 24);
}
PackedRGB :: (rgb: Color32) -> Color32 {
  return (rgb & 0xffffff) | (0xff << 24);
}
PackedRGBA :: (r: Color32, g: Color32, b: Color32, a: Color32) -> Color32 {
  return r | ((g & 0xff) << 8) | ((b & 0xff) << 16) | ((a & 0xff) << 24);
}

PackedBGR :: (bgr: Color32) -> Color32 {
  b := bgr & 0xff;
  g := (bgr >> 8) & 0xff;
  r := (bgr >> 16) & 0xff;
  return r | ((g & 0xff) << 8) | ((b & 0xff) << 16) | (0xff << 24);
}
PackedBGRA :: (bgra: Color32) -> Color32 {
  b := bgra & 0xff;
  g := (bgra >> 8) & 0xff;
  r := (bgra >> 16) & 0xff;
  a := (bgra >> 25) & 0xff;
  return r | ((g & 0xff) << 8) | ((b & 0xff) << 16) | (a << 24);
}

PackedBlack :: (shade: Color32 = 0, alpha: Color32 = 255) -> Color32 {
  return PackedRGBA(shade, shade, shade, alpha);
}
PackedGray :: (shade: Color32 = 128, alpha: Color32 = 255) -> Color32 {
  return PackedRGBA(shade, shade, shade, alpha);
}
PackedWhite :: (shade: Color32 = 255, alpha: Color32 = 255) -> Color32 {
  return PackedRGBA(shade, shade, shade, alpha);
}

// Packed misc
PackedLerp :: (a: Color32, b: Color32, t: float) -> Color32 {
   return ColorPack(lerp(ColorUnpack(a), ColorUnpack(b), t));
}

PackedNegativeRGB :: (color: Color32) -> Color32
{
  rgb := (~color) & 0xff_ff_ff;
  color &= 0xff_00_00_00;
  color |= rgb;
  return color;
}

PackedSetAlphaI :: (color: Color32, a: u32) -> Color32
{
  no_alpha := color & ~((0xff << 24).(u32));
  return (no_alpha | (a << 24));
}
PackedSetAlphaF :: (color: Color32, a: float) -> Color32
{
  ai := (a * 255.0).(u32);
  return PackedSetAlphaI(color, ai);
}
