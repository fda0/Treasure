INJECT :: (comp_name: string, $loc := #caller_location) #expand
{
  #insert -> string {
    FORMAT_STR :: #string STR
    comp := *COMPONENTS.%;
    `% := *comp.c;
STR;
    return tprint(FORMAT_STR, comp_name, comp_name);
  }

  // Validate that loc matches USED_BY_FILES list.
  #run {
    loc_file := loc.fully_pathed_filename;
    slash_idx, slash_found := Find(loc_file, "/", .SlashInsensitive | .FindLast);
    if (slash_found) slash_idx += 1;
    loc_file = Skip(loc_file, slash_idx);

    has_non_empty_files := false;
    file_match_found := false;
    for comp.USED_BY_FILES
    {
      if !it continue;
      idx, found := Find(loc_file, it);
      has_non_empty_files |= true;
      file_match_found |= found;
    }

    assert(has_non_empty_files == file_match_found,
      "INJECT(\"%\") was rejected. '%' loc string doesn't contain any of: %", comp_name, loc_file, comp.USED_BY_FILES);
  }
}

#scope_file;
COMPONENTS: ComponentState;
ComponentState :: struct
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
  c: T;
}
