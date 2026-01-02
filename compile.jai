LOG_RUN :: true;
BUILD_DIRECTORY :: "build";
release_build := false;

#run build();
build :: ()
{
  modify_print_style();
  set_build_options_dc(.{do_output=false});
  os_dir := ifx OS == .WINDOWS then "win" else "lin";

  // Parse command-line arguments
  kill_processes := false;
  clean_targets: enum_flags
  {
    BUILD;
    SDL;
    ALL :: ~0;
  }
  build_targets: enum_flags
  {
    TREASURE;
    BAKER;
    SDL;
    CGLTF;
    ALL :: ~0;
  }
  run_baker := false;

  options := get_build_options();
  for options.compile_time_command_line
  {
    if it == {
      case "release";     release_build = true;
      case "kill";        kill_processes = true;
      case "clean_sdl";   clean_targets |= .SDL;
      case "clean_build"; clean_targets |= .BUILD;
      case "clean_all";   clean_targets |= .ALL;
      case "treasure";    build_targets |= .TREASURE;
      case "baker";       build_targets |= .BAKER;
      case "sdl";         build_targets |= .SDL;
      case "cgltf";       build_targets |= .CGLTF;
      case "build_all";   build_targets |= .ALL;
      case "run_baker";   run_baker = true;
      case; log_error("Unknown argument: %", it); exit(1);
    }
  }

  if release_build log("Release mode");

  if build_targets == 0
  {
    build_targets = .TREASURE | .BAKER;
    log("No build targets provided. Adding defaults: treasure baker");
  }

  if kill_processes
  {
    Run("taskkill /im Treasure.exe", silent=true);
    Run("taskkill /im Baker.exe", silent=true);
  }

  if clean_targets & .BUILD
  {
    log("- deleting build directory -");
    delete_directory("build");
  }
  make_directory_if_it_does_not_exist(BUILD_DIRECTORY);

  if clean_targets & .SDL
  {
    log("- deleting SDL build directories -");
    delete_directory("libs/SDL/build");
    delete_directory("libs/SDL_net/build");
    delete_directory("libs/SDL_image/build");
    delete_directory("libs/SDL_ttf/build");
  }

  if build_targets & .SDL
  {
    error_message = "Encountered an error when building SDL3 & generating bindings.";

    stage1 := join("cmake -S . -B build/", os_dir);
    stage2 := join("cmake --build build/", os_dir);
    stage1b := join(stage1, " -DSDL3_DIR=../SDL/build/", os_dir);

    workdir := "libs/SDL";
    log("- building % -", workdir);
    Check(Run(stage1, workdir));
    Check(Run(stage2, workdir));

    workdir = "libs/SDL_net";
    log("- building % -", workdir);
    Check(Run(stage1b, workdir));
    Check(Run(stage2, workdir));

    workdir = "libs/SDL_image";
    log("- building % -", workdir);
    Check(Run(join(stage1b, " -DSDLIMAGE_VENDORED=OFF"), workdir));
    Check(Run(stage2, workdir));

    log("- generating SDL bindings -");
    SDL :: #import,file "libs/bindings/generate_bindings_sdl3.jai";
    Check(SDL.GenerateBindings(.{targets = .BASE,
                                 optimizations = .DEBUG,
                                 base_directory = "libs/",
                                 output_filename = "sdl3_base.jai"}));
    Check(SDL.GenerateBindings(.{targets = .BASE | .NET,
                                 optimizations = .DEBUG,
                                 base_directory = "libs/",
                                 output_filename = "sdl3_base+net.jai"}));
    Check(SDL.GenerateBindings(.{targets = .BASE | .IMAGE,
                                 optimizations = .DEBUG,
                                 base_directory = "libs/",
                                 output_filename = "sdl3_base+image.jai"}));
  }

  // copy SDL dll dependencies into build directory if missing
  {
    opt_dir := ifx OS == .WINDOWS then "/Debug";
    prefix := ifx OS == .LINUX then "/lib" else "/";
    ext := ifx OS == .LINUX then ".so" else ".dll";

    copies: [] struct {dst, src: string;} = .[
      .{join("build/", prefix, "SDL3", ext),
        join("libs/SDL/build/", os_dir, opt_dir, prefix, "SDL3", ext)},
      .{join("build/", prefix, "SDL3_net", ext),
        join("libs/SDL_net/build/", os_dir, opt_dir, prefix, "SDL3_net", ext)},
      .{join("build/", prefix, "SDL3_image", ext),
        join("libs/SDL_image/build/", os_dir, opt_dir, prefix, "SDL3_image", ext)},
      .{"build/PerformanceAPI.dll", "libs/superluminal/PerformanceAPI.dll"},
    ];
    for copies if !file_exists(it.dst) then copy_file(it.src, it.dst);
  }

  if build_targets & .CGLTF
  {
    CGLTF :: #import,file "libs/bindings/build_cgltf.jai";
    CGLTF.Build();
  }

  if build_targets & .BAKER
  {
    Build(.{workspace_name = "Baker",
            output_name = "Baker",
            entry_file = "src/baker/baker_main.jai",
            icon_path = "res/ico/cook.ico",
            autorun = run_baker});
  }

  if build_targets & .TREASURE
  {
    Build(.{workspace_name = "Treasure",
            output_name = "Treasure",
            entry_file = "src/game/game_main.jai",
            icon_path = "res/ico/coin.ico"});
  }

  MessageLoop();
}

BuildConfig :: struct
{
  workspace_name: string;
  output_name: string;
  entry_file: string;
  icon_path: string;
  autorun: bool;
};

BuildInProgress :: struct
{
  w: Workspace;
  using config: BuildConfig;
};

builds_in_progress: [..] BuildInProgress;

Build :: (config: BuildConfig)
{
  w := compiler_create_workspace(config.workspace_name);
  options := get_build_options(w);
  options.output_path = BUILD_DIRECTORY;
  options.output_executable_name = config.output_name;
  options.text_output_flags = .OUTPUT_TIMING_INFO;

  modules_path: [..] string;
  array_add(*modules_path, "libs/");
  array_add(*modules_path, "src/modules/");
  array_add(*modules_path, ..options.import_path);
  options.import_path = modules_path;

  if release_build
  {
    set_optimization(*options, .OPTIMIZED);
    options.stack_trace = false;
  }
  else
  {
    options.backend = .X64;
  }

  set_build_options(options, w);
  compiler_begin_intercept(w, .SKIP_ALL);
  add_build_file(config.entry_file, w);

  array_add(*builds_in_progress, .{w, config});
}

MessageLoop :: ()
{
  finished_builds := 0;
  while finished_builds < builds_in_progress.count
  {
    message := compiler_wait_for_message();
    if message.kind == .COMPLETE then finished_builds += 1;
    if message.kind == .PHASE
    {
      phase := message.(*Message_Phase);
      if phase.phase == .POST_WRITE_EXECUTABLE
      {
        // Find config that matches this workspace
        config: BuildConfig;
        for builds_in_progress
        {
          if it.w == message.workspace
          {
            config = it.config;
            break;
          }
        }

        if config.icon_path
        {
          exe_filename := tprint("%/%", get_build_options(message.workspace).output_path, phase.executable_name);
          #if OS == .WINDOWS
          {
            #import "Windows_Resources";
            success := set_icon_by_filename(exe_filename, config.icon_path);
            if !success then log_error("Failed to set the icon for exe '%' to filename '%'.", exe_filename, config.icon_path);
          }
        }

        if config.autorun
        {
          Run(join(BUILD_DIRECTORY, "/", config.output_name), work_dir = BUILD_DIRECTORY);
        }
      }
    }
  }
}

Run :: (args: string, work_dir := "", silent := false) -> success:bool
{
  if LOG_RUN log("Run(`%`, `%`);", args, work_dir);
  return run_command(..break_command_into_strings(args), working_directory=work_dir, capture_and_return_output=silent).exit_code == 0;
}

modify_print_style :: ()
{
  using context.print_style.default_format_struct;
  use_newlines_if_long_form = true;
  indentation_width = 2;
}

error_message: string;
Check :: (success: bool, loc := #caller_location)
{
  if !success
  {
    log_error("% - %", error_message, loc);
    exit(1);
  }
}

#import "Compiler";
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Process";
