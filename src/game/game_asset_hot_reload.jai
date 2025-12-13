#scope_file;
using,only(AST,HR) COMPS;
#import "File_Watcher";
#scope_export;

HOT_RELOAD :: true;
// @todo Discard all hot-reload calls #if HOT_RELOAD == false.

HotReloadState :: struct
{
  watcher: File_Watcher;
};

HR_InitWatcher :: ()
{
  init(*HR.watcher, HR_FileWatcherCallback, watch_recursively=false);
  add_directories(*HR.watcher, ".");
}

HR_ProcessNewPIEFile :: (file_path: string)
{
  log("HR is disabled for now; @todo reenable it");
  if (1) return;

  if !AST.pie.err ASSET_LoadPieFile(file_path);
  if !AST.pie.err ASSET_InitShaders();
  GPU_InitPipelines(); // @todo in the future detect what changes were found in .pie file and re-init only needed parts of the engine.
}

HR_Iterate :: ()
{
  PerfFunc();
  process_changes(*HR.watcher);
}

HR_FileWatcherCallback :: (watcher: *File_Watcher(void), change: *File_Change, user_data: *void)
{
  log("[HOT_RELOAD] Change for path %: %", change.full_path, change.events);
  if change.events & .MODIFIED
  {
    if EndsWith(change.full_path, "assets.pie")
    {
      HR_ProcessNewPIEFile(change.full_path);
    }
  }
}
