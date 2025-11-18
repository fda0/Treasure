INJECT :: (component_name: string, $loc := #caller_location) #expand
{
  #insert -> string {
    FORMAT_STR :: #string STR
    `C0 := *COMPS.C0.state;

    #run {
      file_name := FileNameFromLoc(loc);
      allowed := IsFileAllowedByComponent(file_name, COMPS.C0);
      assert(allowed,
        "INJECT(\"%\") was rejected. '%' loc string doesn't contain any of: %",
        component_name, file_name, COMPS.C0.USED_BY_FILES);
    }
STR;

    result := String.replace(FORMAT_STR, "C0", component_name);
    return result;
  }
}


FileNameMatch :: (loc: Source_Code_Location, whitelist: ..string) -> bool
{
  result := true;
  file_name := FileNameFromLoc(loc);
  for whitelist
  {
    result &= Contains(file_name, it);
  }
  return result;
}


#scope_file;
COMPS: Components;
Components :: struct
{
  CL: Component(CL_State);
  SV: Component(SV_State, #run Files("server", "simulation"));
}

Files :: (files: ..string) -> [8] string
{
  result: [8] string;
  assert(files.count <= result.count, "Too many arguments provided to Files");
  for files
  {
    result[it_index] = it;
  }
  return result;
}

Component :: struct($T: Type, $USED_BY_FILES: [8] string = .["","","","","","","",""])
{
  state: T;
}

IsFileAllowedByComponent :: (file_name: string, comp: Component) -> bool
{
  has_non_empty_files := false;
  file_match_found := false;
  for comp.USED_BY_FILES
  {
    if !it continue;
    has_non_empty_files |= true;
    file_match_found |= Contains(file_name, it);
  }
  return has_non_empty_files == file_match_found;
}

FileNameFromLoc :: (loc: Source_Code_Location) -> string
{
  loc_file := loc.fully_pathed_filename;
  slash_idx, slash_found := Find(loc_file, "/", .SlashInsensitive | .FindLast);
  if (slash_found) slash_idx += 1;
  loc_file = Skip(loc_file, slash_idx);
  return loc_file;
}