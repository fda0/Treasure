#if OS == .LINUX {
  SystemMessageBox :: (header: string, message: string)
  {
    log_error(header);
    log_error(message);
  }

  //
  // OS Barrier
  //
  Barrier :: s64;
  BarrierInit :: (barrier: *Barrier, thread_count: s32) {
  }
  BarrierWait :: (barrier: *Barrier) {
  }
  BarrierDelete :: (barrier: *Barrier) {
  }
}

#if OS == .WINDOWS {
  #scope_file;
  #import "Windows_Utf8";
  #import "Windows";
  #scope_export;

  SystemMessageBox :: (header: string, message: string)
  {
    push_allocator(temp);
    MessageBoxW(null,
      utf8_to_wide(message),
      utf8_to_wide(header),
      MB_OK | MB_ICONERROR | MB_TOPMOST);
  }

  //
  // OS Barrier
  //
  Barrier :: SYNCHRONIZATION_BARRIER;
  BarrierInit :: (barrier: *Barrier, thread_count: s32) {
    InitializeSynchronizationBarrier(barrier, thread_count, -1);
  }
  BarrierWait :: (barrier: *Barrier) {
    EnterSynchronizationBarrier(barrier, 0);
  }
  BarrierDelete :: (barrier: *Barrier) {
    DeleteSynchronizationBarrier(barrier);
  }
}