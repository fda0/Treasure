Barrier :: SYNCHRONIZATION_BARRIER;

BarrierInit :: (barrier: *Barrier, thread_count: s32)
{
  InitializeSynchronizationBarrier(barrier, thread_count, -1);
}

BarrierWait :: (barrier: *Barrier)
{
  EnterSynchronizationBarrier(barrier, 0);
}

BarrierDelete :: (barrier: *Barrier)
{
  DeleteSynchronizationBarrier(barrier);
}

#scope_file;
#import "Windows";
