STATS_State :: struct
{
  gpu_batch_transfer_buffers_created: STATS_Counter;
  gpu_batch_transfer_buffers_size: STATS_Counter;
}

STATS_Counter :: struct
{
  total: s64;
  this_frame: s64;
  prev_frame: s64;
  on_peak_frame: s64;
  peak_frame_number: s64;
}

Increment :: (c: *STATS_Counter, to_add: s64)
{
  c.total += to_add;
  c.this_frame += to_add;
}

STATS_PostFrame :: ()
{
  ResetCounter :: (c: *STATS_Counter)
  {
    if c.on_peak_frame < c.this_frame
    {
      c.on_peak_frame = c.this_frame;
      c.peak_frame_number = G.frame_number;
    }
    c.prev_frame = c.this_frame;
    c.this_frame = 0;
  }

  // Generate code that iterates through all members
  // of type STATS_Counter in G.stats and
  // call ResetCounter on them.
  using G.stats;

  #insert -> string {
    tis := type_info(STATS_State);
    sb: String_Builder;
    for tis.members
    {
      if it.type == type_info(STATS_Counter)
      print_to_builder(*sb, "ResetCounter(*%);\n", it.name);
    }
    result := builder_to_string(*sb);
    // log("Inserted code: ```%```", result);
    return result;
  }
}
