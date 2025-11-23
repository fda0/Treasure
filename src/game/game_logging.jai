#scope_file;
using,only(LOG) COMPS;
#scope_export;

LOG_State :: struct
{
  builder: String_Builder;
  file: File;
  file_opened: bool;
  counter: s64;
}

LOG_FileLogger  :: (message: string, data: *void, info: Log_Info)
{
  print_to_builder(*LOG.builder, message);
  if message.count <= 0 || message.data[message.count-1] != #char "\n"
  {
    print_to_builder(*LOG.builder, "\n");
  }
}

LOG_FileFlush :: ()
{
  flush_size := builder_string_length(*LOG.builder);
  if flush_size > 0
  {
    if !LOG.file_opened
    {
      server := ifx GLOBAL.is_server then "server" else "";
      client := ifx GLOBAL.is_client then "client" else "";

      file_path := tprint("Treasure_log_%%.txt", server, client);
      file, success := file_open(file_path, for_writing = true, keep_existing_content = true);

      LOG.file = file;
      LOG.file_opened = success;
    }

    if LOG.file_opened
    {
      file_write(*LOG.file, *LOG.builder, do_reset = true);
    }
  }
}
