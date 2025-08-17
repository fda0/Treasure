FONT_ATLAS_LAYERS :: 4;
FONT_ATLAS_LAYER_MAX_LINES :: 64;
FONT_ATLAS_LAYER_MAX_GLYPHS :: 4096;
FONT_ATLAS_MARGIN :: 1;

#scope_file
#import "freetype-2.12.1";
#scope_export

FONT_Glyph :: struct
{
  hash: u64;
  p: Vec2(u16);
  dim: Vec2(u16);
  layer: u8;
  next: u16;
  // metrics
  bearing: V2;
  advance: float;
};

FONT_Layer :: struct
{
  line_heights:  [FONT_ATLAS_LAYER_MAX_LINES] u16;
  line_advances: [FONT_ATLAS_LAYER_MAX_LINES] u16;
  line_count: u16;

  hash_table:      [FONT_ATLAS_LAYER_MAX_GLYPHS] FONT_Glyph;
  collision_array: [FONT_ATLAS_LAYER_MAX_GLYPHS] FONT_Glyph;
  collision_count: u16;
};

FONT_Family :: enum u8
{
  PlayfairDisplay;
  Jacquard24;
  Inconsolata;
  NotoColorEmoji;
};

FONT_State :: struct
{
  err: s32;

  texture_dim: u16;

  layers: [FONT_ATLAS_LAYERS] FONT_Layer;
  active_layer_index: u8;

  ft_library: FT_Library;
  ft_faces: [#run EnumCount(FONT_Family)] FT_Face;
};

FONT_Init :: ()
{
  using G.font;
  if err then return;

  err = FT_Init_FreeType(*ft_library);
  for enum_values_as_enum(FONT_Family)
  {
    if err break;
    if it.(s64) > G.ast.fonts.count
    {
      log_error("Font %(%) is missing in .pie file. Loaded fonts count: %", it, it.(s64), G.ast.fonts.count);
      break;
    }

    font_data := G.ast.fonts[it];
    err = FT_New_Memory_Face(ft_library, font_data.data, xx font_data.count, 0, *ft_faces[it]);
  }

  FONT_MaybeResizeAtlasTexture();
}

FONT_MaybeResizeAtlasTexture :: ()
{
  using G.font;

  window_area := sqrt(G.window_dim.x * G.window_dim.y);
  new_texture_dim := max(CeilPow2(window_area.(u32)).(u16), 512);

  // Do the atlas texture resize if new_texture_dim is 2x too small or more than 2x too big compared to previous texture_dim.
  if new_texture_dim >= texture_dim * 2 || new_texture_dim*2 < texture_dim
  {
    log("UI texture atlas resizing from % to %", texture_dim, new_texture_dim, flags=.VERBOSE_ONLY);
    texture_dim = new_texture_dim;

    {
      SDL_ReleaseGPUTexture(G.gpu.device, G.gpu.ui.gpu_atlas_texture);
      tex_info := SDL_GPUTextureCreateInfo.{
        type = .SDL_GPU_TEXTURETYPE_2D_ARRAY,
        format = .SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        width = texture_dim,
        height = texture_dim,
        layer_count_or_depth = FONT_ATLAS_LAYERS,
        num_levels = 1,
        usage = SDL_GPU_TEXTUREUSAGE_SAMPLER
      };
      G.gpu.ui.gpu_atlas_texture = SDL_CreateGPUTexture(G.gpu.device, *tex_info);
      SDL_SetGPUTextureName(G.gpu.device, G.gpu.ui.gpu_atlas_texture, "UI Atlas Texture");
    }

    ZeroArray(layers);
    // Pre-seed layers to be full.
    // This isn't necessary but will result in more optimal fill order.
    for * layers
    {
      it.line_count = 1;
      it.line_heights[0] = texture_dim;
      it.line_advances[0] = texture_dim;
    }
  }
}

FONT_FaceMetrics :: struct
{
  ascent: float;
  descent: float;
  linespace: float;
};

FONT_GetFaceMetrics :: (font: FONT_Family, pixel_height: u16) -> FONT_FaceMetrics
{
  ft_face := G.font.ft_faces[font];
  FT_Set_Pixel_Sizes(ft_face, 0, pixel_height);

  result := FONT_FaceMetrics.{
    ascent    = ft_face.size.metrics.ascender.(float)  / 64.0,
    descent   = ft_face.size.metrics.descender.(float) / 64.0,
    linespace = ft_face.size.metrics.height.(float)    / 64.0,
  };
  return result;
}

//
// Glyphs in atlas
//

FONT_CodepointHash :: (codepoint: u32, font: FONT_Family, pixel_height: u16) -> u64
{
  hash := Hash64Any(font, pixel_height, codepoint);
  return hash;
}

FONT_FindGlyphInLayer :: (layer: *FONT_Layer, hash: u64, create_mode: bool) -> *FONT_Glyph
{
  key := hash % layer.hash_table.count;
  slot := *layer.hash_table[key];

  while true
  {
    if !slot.hash // it's empty
      break;

    if slot.hash == hash // found glyph run
      break;

    if slot.next // follow next index
    {
      slot = *layer.collision_array[slot.next];
      continue;
    }

    // hash isn't matching, no next slot in chain
    if !create_mode // exit if not in create mode
      break;

    // chain new element from collision table
    if layer.collision_count < layer.collision_array.count
    {
      slot.next = layer.collision_count;
      layer.collision_count += 1;
      slot = *layer.collision_array[slot.next];
      break;
    }

    // all hope is lost, collision table is full
    break;
  }

  return slot;
}

FONT_CreateGlyphInLayer :: (layer: *FONT_Layer, hash: u64, orig_width: u16, orig_height: u16) -> *FONT_Glyph
{
  using G.font;

  if orig_width <= 0 || orig_height <= 0
  {
    slot := FONT_FindGlyphInLayer(layer, hash, true);
    if !slot.hash
    {
      slot.hash = hash;
      slot.layer = FONT_LayerIndexFromPointer(layer);
      return slot;
    }
    else
      return null;
  }

  margin: u16 = FONT_ATLAS_MARGIN;
  margin2 := margin * 2;

  width := orig_width + margin2;
  height := orig_height + margin2;
  max_dim := G.font.texture_dim;
  all_lines_height: u16;

  // find best line
  best_line_index := U32_MAX;
  for line_index: MakeRange(layer.line_count)
  {
    line_height := layer.line_heights[line_index];
    line_advance := layer.line_advances[line_index];
    horizontal_left_in_line := max_dim - line_advance;

    all_lines_height += line_height;

    can_use_line := true;
    if line_height < height            then can_use_line = false;
    if horizontal_left_in_line < width then can_use_line = false;

    if can_use_line
    {
      if best_line_index >= FONT_ATLAS_LAYER_MAX_LINES // first acceptable line found
        best_line_index = line_index;
      else if layer.line_heights[best_line_index] < line_height // check if this line is better than current best line
        best_line_index = line_index;
    }
  }

  height_left := max_dim - all_lines_height;
  if best_line_index < FONT_ATLAS_LAYER_MAX_LINES && height_left >= height
  {
    // We have a line that can be used. But it's still possible to create a new line.
    // Let's check if we should create a new line - it's a heuristic that tries to minimize
    // avoid wasting space in lines that are too big for this glyph run.
    best_line_height := layer.line_heights[best_line_index];
    waste_px := best_line_height - height;
    waste_share := waste_px.(float) / best_line_height.(float);

    // If layer is almost full the threshold for starting a new line is very big.
    used_height_share := all_lines_height / max_dim;
    share_threshold := 0.2 + 0.8*used_height_share;

    if waste_px > 8 && waste_share > share_threshold
      best_line_index = FONT_ATLAS_LAYER_MAX_LINES;
  }

  // if no best line - try to create a create new line
  if best_line_index >= FONT_ATLAS_LAYER_MAX_LINES && height_left >= height
  {
    if layer.line_count < FONT_ATLAS_LAYER_MAX_LINES
    {
      best_line_index = layer.line_count;
      layer.line_count += 1;

      layer.line_heights[best_line_index] = height;
    }
  }

  // We have best line line with free space - try to allocate a slot in hash table
  if best_line_index < FONT_ATLAS_LAYER_MAX_LINES
  {
    slot := FONT_FindGlyphInLayer(layer, hash, true);
    if !slot.hash
    {
      line_y_offset: u16;
      for line_index: MakeRange(best_line_index)
        line_y_offset += layer.line_heights[line_index];

      slot.hash = hash;
      slot.p = .{
        x = layer.line_advances[best_line_index] + margin,
        y = line_y_offset + margin,
      };
      slot.dim = .{
        x = orig_width,
        y = orig_height,
      };
      slot.layer = FONT_LayerIndexFromPointer(layer);

      layer.line_advances[best_line_index] += width;
      return slot;
    }
  }

  // Failed to allocate glyph run in this layer
  return null;
}

FONT_LayerIndexFromPointer :: (layer: *FONT_Layer) -> u8
{
  using G.font;
  index := (layer.(u64) - layers.data.(u64)) / size_of(FONT_Layer);
  return index.(u8);
}

FONT_GetGlyph :: (codepoint: u32, preferred_font: FONT_Family, pixel_height: u16) -> FONT_Glyph
{
  using G.font;
  assert(!G.headless);

  margin: u16 = FONT_ATLAS_MARGIN;
  margin2 := margin * 2;

  hash := FONT_CodepointHash(codepoint, preferred_font, pixel_height);
  font := preferred_font;

  // Find already existing glyph run
  for layer_offset: 0 .. layers.count-2
  {
    layer_index := (active_layer_index + layer_offset) % layers.count;
    glyph_run := FONT_FindGlyphInLayer(*layers[layer_index], hash, false);
    if (glyph_run.hash == hash)
      return glyph_run.*;
  }

  // Load and render glyph
  glyph: *FT_GlyphSlotRec_;
  bitmap_dim: Vec2(s32);
  glyph_pixels_size: s32;
  glyph_pixels: *u32;

  for font_fallback: 0..1
  {
    if glyph then break;
    // If glyph wasn't found then try looking in in NotoColorEmoji font.
    if font_fallback > 0
    {
      if font == .NotoColorEmoji then break;
      font = .NotoColorEmoji;
    }

    ft_face := ft_faces[font];
    FT_Set_Pixel_Sizes(ft_face, 0, pixel_height);
    glyph_index := FT_Get_Char_Index(ft_face, codepoint);
    if !glyph_index then continue;

    FT_Load_Glyph(ft_face, glyph_index, FT_LOAD_COLOR);
    FT_Render_Glyph(ft_face.glyph, .FT_RENDER_MODE_NORMAL);

    glyph = ft_face.glyph;
    if glyph.format == .SVG
    {
      log("Unsupported SVG format was used for codepoint % (from font %).", codepoint, font, flags=.WARNING);
      // @todo Support these formats with https://github.com/sammycage/plutosvg
      //       Or use SDL_ttf which uses it.
    }

    bitmap := glyph.bitmap;
    bitmap_dim = .{xx bitmap.width, xx bitmap.rows};
    if bitmap_dim.x > 0 && bitmap_dim.y > 0
    {
      bitmap_and_margin_dim := bitmap_dim + Vec2(s32).{margin2, margin2};

      // Reject surfaces that are too big
      if bitmap_and_margin_dim.x > texture_dim || bitmap_and_margin_dim.y > texture_dim
        return .{};

      // Copy bitmap into a new buffer in a correct format (RGBA) with margin
      glyph_pixels_size = bitmap_and_margin_dim.x * bitmap_and_margin_dim.y * 4;
      glyph_pixels = talloc(glyph_pixels_size);
      ZeroAddress(glyph_pixels, glyph_pixels_size); // clear margin

      if bitmap.pixel_mode == xx FT_Pixel_Mode_.GRAY
      {
        glyph_pixels_no_margin := *glyph_pixels[bitmap_and_margin_dim.x/*skip margin rows*/ + margin/*skip margin columns*/];
        for y: MakeRange(bitmap_dim.y)
        {
          bitmap_row: *u8 = *bitmap.buffer[bitmap.pitch * y];
          glyph_row: *u32 = *glyph_pixels_no_margin[bitmap_and_margin_dim.x * y];
          for x: MakeRange(bitmap_dim.x)
            glyph_row[x] = Color32_RGBAi(255, 255, 255, bitmap_row[x]).(u32);
        }
      }
      else
      {
        log("Unsupported bitmap pixel_mode coming from freetype: %\n", bitmap.pixel_mode, flags=.WARNING);
        return .{};
      }
    }
  }

  if !glyph
  {
    log("Can't find glyph_index in font % (or fallbacks) for codepoint %", preferred_font, codepoint, flags=.VERBOSE_ONLY);
    return .{};
  }


  // Find glyph slot in atlas.
  // Look for glyph slot in existing atlas layers.
  slot: *FONT_Glyph;
  for layer_offset: 0 .. layers.count-2
  {
    layer_index := (active_layer_index + layer_offset) % layers.count;
    slot = FONT_CreateGlyphInLayer(*layers[layer_index], hash, xx bitmap_dim.x, xx bitmap_dim.y);
    if slot then break;
  }

  if !slot // Couldn't find space in any layer. Clear the oldest layer to make space for new glyph.
  {
    // Advance active_layer index (backwards) and clear active layer.
    active_layer_index += layers.count - 1;
    active_layer_index %= layers.count;

    active_layer := *layers[active_layer_index];
    ZeroType(active_layer);

    slot = FONT_CreateGlyphInLayer(active_layer, hash, xx bitmap_dim.x, xx bitmap_dim.y);
  }

  // Upload surface to GPU (if free slot was found).
  if slot
  {
    // Fill glyph metrics
    slot.bearing = .{
      glyph.metrics.horiBearingX.(float) / 64.0,
      glyph.metrics.horiBearingY.(float) / -64.0,
    };
    slot.advance = glyph.metrics.horiAdvance.(float) / 64.0;

    // @speed Check if it makes sense to batch these transfers.
    if glyph_pixels
    {
      trans_cpu := SDL_GPUTransferBufferCreateInfo.{
        usage = .SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        size = xx glyph_pixels_size
      };
      buf_transfer := SDL_CreateGPUTransferBuffer(G.gpu.device, *trans_cpu);

      // CPU memory -> GPU memory
      {
        mapped_memory := SDL_MapGPUTransferBuffer(G.gpu.device, buf_transfer, false);
        memcpy(mapped_memory, glyph_pixels, glyph_pixels_size);
        SDL_UnmapGPUTransferBuffer(G.gpu.device, buf_transfer);
      }

      // GPU memory -> GPU texture
      {
        cmd := SDL_AcquireGPUCommandBuffer(G.gpu.device);
        copy_pass := SDL_BeginGPUCopyPass(cmd);

        trans_gpu := SDL_GPUTextureTransferInfo.{
          transfer_buffer = buf_transfer,
          offset = 0,
        };

        assert(slot.p.x >= margin);
        assert(slot.p.y >= margin);
        assert(slot.p.x + slot.dim.x + margin <= G.font.texture_dim);
        assert(slot.p.y + slot.dim.y + margin <= G.font.texture_dim);
        dst_region := SDL_GPUTextureRegion.{
          texture = G.gpu.ui.gpu_atlas_texture,
          layer = slot.layer,
          x = slot.p.x - margin,
          y = slot.p.y - margin,
          w = slot.dim.x + margin2,
          h = slot.dim.y + margin2,
          d = 1,
        };
        SDL_UploadToGPUTexture(copy_pass, *trans_gpu, *dst_region, false);

        SDL_EndGPUCopyPass(copy_pass);
        SDL_SubmitGPUCommandBuffer(cmd);
      }

      SDL_ReleaseGPUTransferBuffer(G.gpu.device, buf_transfer);
    }

    return slot.*;
  }

  return .{};
}
