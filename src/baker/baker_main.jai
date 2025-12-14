// @speed - multithread
// @speed - cache
main :: ()
{
  Timer("init");

  B.tex_format = .R8G8B8A8;
  PIE_InitBuilder();

  B.core_count = get_number_of_processors();
  lane_group := LaneGroupCreate(B.core_count);
  LaneGroupLaunch(BK_ProcessAssets, lane_group, true);
}

BK_ProcessAssets :: (thread: *Thread) -> s64
{
  thread_name := sprint("Client_%", LaneIdx());
  // PerfThreadName(thread_name);

  if LaneIdx() != 0 return 0;

  // Load .gltf models
  {
    rot_x := RotationAroundAxis(AxisV3(.X), 0.25);
    rot_y := RotationAroundAxis(AxisV3(.Y), 0.25);
    rot_z := RotationAroundAxis(AxisV3(.Z), 0.25);
    rot_xz := rot_z * rot_x;

    // @todo detect duplicated skeleton & animations and reuse it
    // BK_GLTF_Load("../res/models/UltimateModularWomen/Worker.gltf", spec);
    // BK_GLTF_Load("../res/models/UltimateModularWomen/Formal.gltf", spec);
    // BK_GLTF_Load("../res/models/UltimateModularWomen/Casual.gltf", spec);

    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/UniversalAnimationLibrary/Dude.glb", height = 1.7, rot = rot_xz});
    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/ZombieApocalypseKit/Zombie.gltf", height = 1.0, rot = rot_xz});

    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/MedievalVillage/Corner_ExteriorWide_Wood.gltf", height = 3.0, rot = rot_xz, name = "Plank"});

    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/Fantasy/Potion_1.gltf", height = 0.2, rot = rot_xz, name = "Potion"});
    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/Fantasy/Stool.gltf", height = 0.4, rot = rot_xz});
    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/Fantasy/Carrot.gltf", height = 1.0, rot = rot_xz});
    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/Fantasy/Bed_Twin2.gltf", height = 0.5, rot = rot_xz, name = "Bed"});
    BK_GLTF_Load(.{file_path = "../res/models/Quaternius/PirateKit/UI_Red_X.gltf", height = 0.05, rot = rot_xz, name = "Cross"});


    BK_GLTF_Load(.{file_path = "../res/models/Other/Flag/Flag.glb", height = 1.0, rot = rot_x});
    BK_GLTF_Load(.{file_path = "../res/models/Other/tree_low-poly/scene.gltf", disable_z0 = true, height = 5.0, name = "Tree"});
    Timer("GLTF models loaded");
  }

  // Load texture files
  {
    // @todo adjust after adding tone mapping
    spec_tiny := Color32_Grayf(0.05);
    spec_low := Color32_Grayf(0.1);
    spec_mid := Color32_Grayf(0.2);
    spec_big := Color32_Grayf(0.4);
    // BK_TEX_LoadPBRs("Bricks071", spec_mid);
    // BK_TEX_LoadPBRs("Bricks097", spec_mid);
    BK_TEX_LoadPBRs("Clay002", spec_big);
    BK_TEX_LoadPBRs("Grass004", spec_tiny);
    // BK_TEX_LoadPBRs("Ground037", spec_tiny);
    // BK_TEX_LoadPBRs("Ground068", spec_tiny);
    BK_TEX_LoadPBRs("Ground075", spec_mid);
    // BK_TEX_LoadPBRs("Ground078", spec_tiny);
    BK_TEX_LoadPBRs("Leather011", spec_big);
    // BK_TEX_LoadPBRs("PavingStones067", spec_low);
    // BK_TEX_LoadPBRs("Tiles087", spec_big);
    // BK_TEX_LoadPBRs("Tiles101", spec_big);
    // BK_TEX_LoadPBRs("TestPBR001", spec_mid);
    Timer("PBR textures loaded");
  }

  // Compile shaders
  {
    #import "dxc_compiler";

    source_flags :: #run -> string {
      b: String_Builder;
      for enum_names(RD_WorldShaderFlags)
        print_to_builder(*b, "#define WORLD_FLAG_% (1u << %u)\n", it, it_index);
      return builder_to_string(*b);
    };
    // log("generated source_flags:\n%", source_flags);

    base_dir := "../src/shaders/";
    source_util := read_entire_file(join(base_dir, "shader_util.hlsl"));

    GetArgs :: (source_file: string, entry: string, shader_type: Shader_Type) -> Dxc_Shader_Compiler_Args #expand
    {
      source_path := join(base_dir, source_file);
      source := read_entire_file(source_path);

      full_source := join(source_flags, source_util, source);

      config := Dxc_Shader_Compiler_Args.{
        shader_name = entry,
        shader_source = full_source,
        shader_model_version = "6_0",
        shader_type = shader_type,
        entry_point = entry,
        // defines: [] string;
        // extra_args: [] string;
        // add_debug_info: bool;
        // warnings_as_error: bool;
        // skip_optimization: bool;
        // compile_as_spirv: bool;
        // use_spirv_1_4: bool;
      };
      return config;
    }

    world_vs := DXC_Compile(GetArgs("shader_world.hlsl", "WORLD_DxShaderVS", .Vertex));
    world_ps := DXC_Compile(GetArgs("shader_world.hlsl", "WORLD_DxShaderPS", .Fragment));
    ui_vs := DXC_Compile(GetArgs("shader_ui.hlsl", "UI_DxShaderVS", .Vertex));
    ui_ps := DXC_Compile(GetArgs("shader_ui.hlsl", "UI_DxShaderPS", .Fragment));
    // @todo Things like entrypoint name could be saved into .pie file too.
    PIE_ListSetArray(*array_add(*B.pie.shaders).data, world_vs);
    PIE_ListSetArray(*array_add(*B.pie.shaders).data, world_ps);
    PIE_ListSetArray(*array_add(*B.pie.shaders).data, ui_vs);
    PIE_ListSetArray(*array_add(*B.pie.shaders).data, ui_ps);
    Timer("Shaders compiled");
  }

  // Load fonts
  {
    font_names := string.[
      "PlayfairDisplay-Regular",
      "Jacquard24-Regular",
      "Inconsolata-Regular",
      "NotoColorEmoji-Regular",
    ];

    base_dir := "../res/fonts/";
    for font_names
    {
      path := join(base_dir, it, ".ttf");
      data, success := read_entire_file(path);
      Check(success, "Failed to load font file %", path);

      blob: PIE_Blob;
      PIE_ListSetString(*blob.data, data);
      PIE_ListSetString(*blob.info, it);
      array_add(*B.pie.fonts, blob);
    }

    Timer("Loaded font files");
  }

  // Load sounds
  {
    sound_names := string.[
      "punch_general_body_impact_03",
      "Turret/Swish03",
      "Turret/Swish04",
      "Turret/Swish05",
      "Turret/Swish01",
      "Turret/Swish02",
    ];


    base_dir := "../res/sounds/";
    for sound_names
    {
      path := join(base_dir, it, ".wav");

      data_ptr: *u8;
      data_size: u32;
      audio_spec: SDL_AudioSpec;
      success := SDL_LoadWAV(temp_c_string(path), *audio_spec, *data_ptr, *data_size);
      Check(success, "Failed to load sound file %", path);
      defer SDL_free(data_ptr);

      data_string := string.{count = xx data_size, data = data_ptr};
      pie_sound: PIE_Sound;
      PIE_ListSetString(*pie_sound.data, data_string);
      pie_sound.format = audio_spec;
      array_add(*B.pie.sounds, pie_sound);
    }

    Timer("Loaded sound files");
  }

  PIE_FinalizeBuilder();
  PIE_SaveToFile("assets.pie");
  Timer("Saved to file");
  return 0;
}

#import "Basic";
#import "String";
#import "Flat_Pool";
#import "File";
#import "Thread";
#import "System";


#import "cgltf";
using,except(MSG) SDL :: #import "sdl3_base+image";

#load "baker_core.jai";
#load "baker_gltf.jai";
#load "baker_textures.jai";
#load "baker_pie.jai";
#load "../shared/base_lanes.jai";
#load "../shared/base_utils.jai";
#load "../shared/base_math.jai";
#load "../shared/base_string.jai";
#load "../shared/base_hash.jai";
#load "../shared/base_array.jai";
#load "../shared/base_color.jai";
#load "../shared/pie_file_format.jai";
#load "../shared/game_render_shared.jai";
