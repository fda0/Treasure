BK_State :: struct
{
  // global settings
  tex_format: PIE_TexFormat;

  // threading
  core_count: s64;
  lanes: [] BK_Lane;

  // profiling
  init_time: Apollo_Time;
  last_time: Apollo_Time;

  // final .pie file builder
  pie: PIE_Builder;
}
B: BK_State;

BK_Lane :: struct
{
  models: [..] PIE_Model;
  vertices: [..] RD_WorldVertex;
  indices: [..] u16;
  skeletons: [..] PIE_Skeleton;
  materials: [..] PIE_Material;
}

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
