UI_TextLineParams :: struct
{
  draw: bool;
  draw_p: V2; // .y is the baseline position - it's under the text.
  draw_color: Color32;

  dimensions: V2; // out
};

// All in one text function - can do layout, drawing and/or text dimension measurement
UI_ProcessTextLine :: (text: string, font: FONT_Family, pixel_height: u16, using params: *UI_TextLineParams)
{
  metrics := FONT_GetFaceMetrics(font, pixel_height);

  // measure
  dimensions.y = metrics.ascent + metrics.descent;

  // draw
  text_pos := draw_p;
  // text_pos += V2.{0, Cos01(G.at)*20.0};
  // text_pos += V2.{0, dimensions.y};

  t := text;
  while t.count
  {
    codepoint, byte_length := STR_DecodeUTF8(t);
    t = STR_Skip(t, byte_length);

    glyph := FONT_GetGlyph(codepoint, font, pixel_height);

    if draw
    {
      tex_p   := V2.{xx glyph.p.x, xx glyph.p.y};
      tex_dim := V2.{xx glyph.dim.x, xx glyph.dim.y};

      if tex_dim.x > 0 && tex_dim.y > 0 // Skip glyphs without bitmap
      {
        // Adding glyph.bearing applies glyph specific offset to align it to the baseline.
        p := text_pos + glyph.bearing;
        p.x = Round(p.x);
        p.y = Round(p.y);

        shape := UI_Shape.{
          rect = MakeRangeMinDim(p, tex_dim),
          tex_rect = MakeRangeMinDim(tex_p, tex_dim),
          tex_layer = xx glyph.layer,
          color = draw_color,
        };
        UI_Draw2D(shape);
      }

      text_pos.x += glyph.advance;
    }

    dimensions.x += glyph.advance;
  }
}

UI_DrawTextLine :: (text: string, font: FONT_Family, pixel_height: u16, color: Color32, pos: V2)
{
  params := UI_TextLineParams.{
    draw = true,
    draw_p = pos,
    draw_color = color,
  };
  UI_ProcessTextLine(text, font, pixel_height, *params);
}


UI_MeasureText :: (params: Layout.MeasureTextParams) -> V2
{
  font := params.font.(FONT_Family);
  pixel_height := Round(params.font_size_px).(u16);

  process_params: UI_TextLineParams;
  UI_ProcessTextLine(params.text, font, pixel_height, *process_params);
  return process_params.dimensions;
}
