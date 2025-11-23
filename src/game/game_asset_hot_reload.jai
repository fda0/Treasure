#scope_file;
using,only(AST) COMPS;
#scope_export;

HOT_RELOAD :: true;
// @todo Discard all hot-reload calls #if HOT_RELOAD == false.

#scope_file;
#import "File_Watcher";
#scope_export;

HOT_RELOAD_State :: struct
{
  watcher: File_Watcher;
};

HOT_RELOAD_InitWatcher :: ()
{
  using G.hr;
  init(*watcher, HOT_RELOAD_FileWatcherCallback, watch_recursively=false);
  add_directories(*watcher, ".");
}

HOT_RELOAD_ProcessNewPIEFile :: (file_path: string)
{
  push_allocator(AST.arena);
  if !AST.pie.err ASSET_LoadPieFile(file_path);
  if !AST.pie.err ASSET_InitShaders();
  GPU_InitPipelines(); // @todo in the future detect what changes were found in .pie file and re-init only needed parts of the engine.
}

HOT_RELOAD_Iterate :: ()
{
  PerfFunc();
  process_changes(*G.hr.watcher);
}

HOT_RELOAD_FileWatcherCallback :: (watcher: *File_Watcher(void), change: *File_Change, user_data: *void)
{
  log("[HOT_RELOAD] Change for path %: %", change.full_path, change.events);
  if change.events & .MODIFIED
  {
    if EndsWith(change.full_path, "data.pie")
    {
      HOT_RELOAD_ProcessNewPIEFile(change.full_path);
    }
  }
}
