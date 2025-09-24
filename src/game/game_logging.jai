LOG_State :: struct
{
  builder: String_Builder;
  file: File;
  file_opened: bool;
  counter: s64;
}

LOG_FileLogger  :: (message: string, data: *void, info: Log_Info)
{
  print_to_builder(*G.log.builder, message);
  if message.count <= 0 || message.data[message.count-1] != #char "\n"
  {
    print_to_builder(*G.log.builder, "\n");
  }
}

LOG_FileFlush :: ()
{
  flush_size := builder_string_length(*G.log.builder);
  if flush_size > 0
  {
    if !G.log.file_opened
    {
      file_path := tprint("Treasure_log_%.txt", ifx NET_IsServer() then "server" else "client");
      file, success := file_open(file_path, for_writing = true, keep_existing_content = true);

      G.log.file = file;
      G.log.file_opened = success;
    }

    if G.log.file_opened
    {
      file_write(*G.log.file, *G.log.builder, do_reset = true);
    }
  }
}
