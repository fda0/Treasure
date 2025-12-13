BK_State :: struct
{
  pie: PIE_Builder;

  tex_format: PIE_TexFormat;

  init_time: Apollo_Time;
  last_time: Apollo_Time;
};
B: BK_State;

BK_SetDefaultsPIEMaterial :: (pie_material: *PIE_Material)
{
  pie_material.params.diffuse = xx Color32_RGBi(128,128,128);
  pie_material.params.specular = xx Color32_RGBf(0.05, 0.02, 0.01);
  pie_material.params.roughness = 0.5;
}

Check :: (arg: bool, message := "", args: .. Any, loc := #caller_location) #no_debug #expand {
  if !arg && assert_helper(message, ..args, loc) then debug_break();
}

Timer :: (label: string)
{
  new_time := current_time_monotonic();
  if !B.init_time
  {
    B.init_time = new_time;
    B.last_time = new_time;
  }
  else
  {
    delta_itself := new_time - B.last_time;
    delta_total := new_time - B.init_time;
    ms :: to_milliseconds;
    log("[Timer %] itself: %ms; total: %ms", label, ms(delta_itself), ms(delta_total));
    B.last_time = new_time;
  }
}

#import "Basic";
#import "String";
#import "Flat_Pool";
#import "File";
#import "sdl3_base+image";
#load "baker_gltf.jai";
#load "baker_textures.jai";
#load "baker_pie.jai";
#load "../shared/base_utils.jai";
#load "../shared/base_math.jai";
#load "../shared/base_string.jai";
#load "../shared/base_hash.jai";
#load "../shared/base_array.jai";
#load "../shared/base_color.jai";
#load "../shared/pie_file_format.jai";
#load "../shared/game_render_shared.jai";
