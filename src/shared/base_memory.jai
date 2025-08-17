// Bump allocator wrapper - that bundles pool & allocator structs.
Arena :: struct
{
  pool: Flat_Pool;
  #as using alloc: Allocator;
};

ARENA_DEFAULT_VIRTUAL_MEMORY_RESERVE :: 256 * 1024 * 1024;
#import "Flat_Pool";

init :: (arena: *Arena, reserve := ARENA_DEFAULT_VIRTUAL_MEMORY_RESERVE)
{
  init(*arena.pool, reserve);
  arena.alloc.proc = flat_pool_allocator_proc;
  arena.alloc.data = *arena.pool;
}


Scratch :: struct
{
  #as using arena: *Arena;
  start_point: *u8;
};
GLOBAL_SCRATCH_ARENA: Arena; // This will be upgraded in the future (to ~array of Arenas) + it should have separate Arenas per thread.

ScopeScratch :: () -> Scratch #expand
{
  scratch := PushScratch();
  `defer PopScratch(scratch);
  return scratch;
}

PushScratch :: () -> Scratch
{
  scratch := Scratch.{
    arena = *GLOBAL_SCRATCH_ARENA,
    start_point = GLOBAL_SCRATCH_ARENA.pool.current_point
  };
  return scratch;
}

PopScratch :: (using scratch: Scratch)
{
  if start_point <= pool.current_point
    pool.current_point = start_point;
  else
    assert(false);
}
