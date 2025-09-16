
// CURRENTLY UNUSED
// CURRENTLY UNUSED
// CURRENTLY UNUSED

#module_parameters (COUNT_COLLISIONS := false)();

// A hash table that maps hashes (u64 by default) to values.
Table :: struct (
  Value_Type: Type,
  Hash_Type: Type = u64,
  given_compare_function: (Hash_Type, Hash_Type) -> bool = null, // operator == is the default
  LOAD_FACTOR_PERCENT: u32 = 70,
  REFILL_REMOVED := true)
{
  count: s64;   // The number of valid items in the table.
  allocated: s64;   // The number of slots for which we have allocated memory.
  slots_filled: s64;   // The number of slots that can't be used for new items (either currently valid items or items that were removed).
  allocator: Allocator;

  Entry :: struct
  {
    hash:  Hash_Type;
    value: Value_Type;
    next: *Entry;
  }
  entries: [] Entry;

  // We either use the hash compare function that was passed to us, or,
  // if it was null, we use a default one.
  #if given_compare_function {
    compare_function :: given_compare_function;
  } else {
    compare_function :: (a: Hash_Type, b: Hash_Type) -> bool { return a == b; };
  }

  #if COUNT_COLLISIONS
  {
    add_collisions: s64;
    find_collisions: s64;
  }

  SIZE_MIN :: 32;
}

for_expansion :: (table: *$T/Table, body: Code, flags: For_Flags) #expand {
  #assert(!(flags & .REVERSE)); // We don't handle the reverse flag.
  for * entry, i: table.entries
  {
    if entry.hash < FIRST_VALID_HASH continue;

    #if flags & .POINTER `it := *entry.value;
    else                 `it := entry.value;

    `it_index := entry.hash;

    #insert (remove={entry.hash=REMOVED_HASH; table.count-=1;}) body;
  }
}

// Initialize a `Table` and allocates the given number of slots.
// You don't have to call init; if you don't, you'll get
// an initial table of size `SIZE_MIN`.

init :: (using table: *Table, slots_to_allocate: s64 = 0)
{
  Basic.remember_allocators(table);
  resize(table, slots_to_allocate);
}

resize :: (using table: *Table, slots_to_allocate: s64 = 0)
{
  if slots_to_allocate == 0 slots_to_allocate = SIZE_MIN;
  n := next_power_of_two(slots_to_allocate);
  table.allocated = n;

  // Right now we align to 8 bytes. Should we handle arbitrary alignment of both
  // hashes and values? Maybe, but that will complicate the table,
  // so let's not worry about it now unless we need it.

  // We used to create entries[] uninitialized for performance reasons,
  // but this led to problems when people would for example try to assign
  // hash tables containing strings to global data; the compiler would
  // try to copy the uninitialized strings and crash (because it has no way
  // to know they are uninitialized). For now we will go back to zero-initializing
  // by putting 'true' here, but I don't love this.  -jblow, 24 November 2024.
  entries = Basic.NewArray(n, Entry, true,, table.allocator);
  for * entries  it.hash = 0;
}

// Frees the memory allocated by the table.
deinit :: (table: *Table)
{
  Basic.free(table.entries.data,, table.allocator);
}

// This reset keeps the current number of allocated slots;
// it just clears occupancy.
// @@ IC: I like this behavior, but array_reset frees memory and that is confusing. See array_reset for more discussion.
table_reset :: (using table: *Table)
{
  count        = 0;
  slots_filled = 0;
  for * entries  it.hash = 0;
}

//
// Walk_Table is a macro that factors out the details of traversing the hash table,
// so that they can be re-used by multiple routines without having to keep these details
// in sync. We expect the calling site to define:
//
//    table: Table;
//    hash:  table.Hash_Type;
//
// We write back into the caller:
//
//    index: Hash_Type;
//    table_while_loop: iterator variable you can use to 'continue', etc.
// Walk_Table is intended for our own internal use. User-level traversal should
// probably use the for_expansion.
//
Walk_Table :: (code: Code) #expand
{
  mask := cast,trunc(`table.Hash_Type)(`table.allocated - 1);

  if `hash < FIRST_VALID_HASH then `hash += FIRST_VALID_HASH;

  `index := `hash & mask;

  // We use the 'triangular numbers' version of quadratic probing.
  // It yields more collisions per insertion than double hashing
  // (double hashing gives us 0.74, triangular numbers give us 0.84)
  // but the collisions are cheaper because the initial probes
  // are cache-coherent, unlike with double hashing. At large table sizes
  // this ends up mattering substantially. (examples/hash_table_test.jai,
  // at the 128 million entry table size, takes 15.5 seconds with triangular
  // numbers, 17.8 seconds with double hashing.)

  // Triangular numbers are guaranteed to hit every entry in the table:
  // https://fgiesen.wordpress.com/2015/02/22/triangular-numbers-mod-2n/

  probe_increment : u32 = 1;

  // If table.entries[index] is zero, that slot is unoccupied, so we are done walking.
  // If it's nonzero, we do whatever the caller wants to do (for example, check whether
  // it is the entry we are looking for).
  while `table_while_loop := `table.entries[index].hash
  {
    #insert code;   // Do whatever the caller wants to do for this slot index.

      index = (index + probe_increment) & mask;    // Since table.allocated is always power of two, the & wraps our index within the table. (Requires that probe_increment is not big enough to wrap index into negative numbers, which it won't be because it's u32 and index is s64.);
      probe_increment += 1;
  }
}


// Call this if you want to be able to add 'items' number of things to the table without the table
// resizing in the middle. Useful in cases where you want to add multiple items to a table inside
// one block of code, while keeping pointers to those items, and wanting those pointers to remain valid.
table_ensure_space :: (table: *Table, items: s64)
{
  if (table.slots_filled + items)*100 >= table.allocated*table.LOAD_FACTOR_PERCENT  expand(table);
}


// Adds the given hash value pair to the table, returns a pointer to the inserted value.
// If you add a hash twice, the table will not currently notice that this has happened,
// so you'll just get the first one.
table_add :: (table: *Table, hash: table.Hash_Type, value: table.Value_Type) -> *table.Value_Type
{
  // The + 1 is here to handle the weird case when the table size is 1 and you add the first item...
  // If we just do table_count * 2 >= table.allocated, we would fill the table, causing an infinite loop on find.

  #assert table.LOAD_FACTOR_PERCENT < 100;  // A 100% full table will infinite loop (and you will want to be substantially smaller than this for reasonable performance).

  // Without dividing, we want to test:
  //    (filled / allocated >= 70/100)
  // Therefore, we say
  //    (filled * 100 >= allocated * 70)

  if (table.slots_filled + 1)*100 >= table.allocated*table.LOAD_FACTOR_PERCENT  expand(table);

  Basic.assert(table.slots_filled < table.allocated);

  Walk_Table(#code {
    #if table.REFILL_REMOVED {
      if table.entries[index].hash == REMOVED_HASH {
        table.slots_filled -= 1;  // 1 will get re-added below, for total increment 0.
        break;
      }
    }

    #if COUNT_COLLISIONS  table.add_collisions += 1;
  });

  // Walk_Table walked us to an unused entry, so, add our new data into this slot.

  table.count        += 1;
  table.slots_filled += 1;

  entry := *table.entries[index];
  entry.hash  = hash;
  entry.value = value;

  return *entry.value;
}

// Adds or replaces the given hash value pair.
table_set :: (table: *Table, hash: table.Hash_Type, value: table.Value_Type) -> *table.Value_Type
{
  value_ptr := table_find_pointer(table, hash);
  if value_ptr
  {
    value_ptr.* = value;
    return value_ptr;
  }
  else
  {
    return table_add(table, hash, value);
  }
}

// Returns whether a table contains hash. Useful when table is being used as a set.
table_contains :: (table: *Table, hash: table.Hash_Type) -> bool
{
  return table_find_pointer(table, hash) != null;
}


// We now take 'table' by pointer so that if COUNT_COLLISIONS, we can modify
// the collision count, which is stored on the table. If we stored it elsewhere
// this would no longer be necessary (but might be slower?)  - 8 July 2022
table_find_pointer :: (table: *Table, hash: table.Hash_Type) -> *table.Value_Type
{
  if !table.allocated  return null;

  Walk_Table(#code {
    entry := *table.entries[index];
    if inline table.compare_function(entry.hash, hash) {
      return *entry.value;
    }

    #if COUNT_COLLISIONS  table.find_collisions += 1;
  });

  return null;
}

table_find_new :: (table: *Table, hash: table.Hash_Type) -> (success: bool, table.Value_Type)
{
  pointer := inline table_find_pointer(table, hash);
  if pointer  return true, pointer.*;

  dummy: table.Value_Type;
  return false, dummy;
}

// Remove the first entry at the given hash. Returns false if the hash was not found.
table_remove :: (table: *Table, hash: table.Hash_Type) -> (success: bool, value: table.Value_Type)
{
  if !table.allocated
  {
    dummy: table.Value_Type;
    return false, dummy;  // Empty table, means not found!
  }

  Walk_Table(#code {
    entry := *table.entries[index];

    if inline table.compare_function(entry.hash, hash) {
      entry.hash = REMOVED_HASH;  // No valid entry will ever hash to REMOVED_HASH.
      table.count -= 1;
      return true, entry.value;
    }
  });

  dummy: table.Value_Type;
  return false, dummy;
}


// find_or_add is kind of like table_set, but used when you
// just want a pointer to the value, which you can fill in.
find_or_add :: (table: *Table, hash: table.Hash_Type) -> (entry: *table.Value_Type, newly_added: bool)
{
  value := table_find_pointer(table, hash);
  if value return value, false;

  new_value: table.Value_Type;
  value = table_add(table, hash, new_value);
  return value, true;
}


// We expose these reserved hash values just in case you want
// to write your own hash table iterator.
NEVER_OCCUPIED_HASH :: 0;
REMOVED_HASH        :: 1;
FIRST_VALID_HASH    :: 2;

// A beta user requested being able to call expand(), so, here:
expand :: (table: *Table)
{
  old_entries := table.entries;

  // If we were adding and removing lots of stuff from the table,
  // we might have lots of slots filled with REMOVED_HASH, so,
  // in that case, don't grow!
  new_allocated: s64 = ---;

  if (table.count * 2 + 1) * 100 < table.allocated * table.LOAD_FACTOR_PERCENT {  // The *2 is to say, if we double the size, are we still small enough to fit into the current memory? The reason we are doing this test is, if we removed a bunch of elements, maybe we are full of REMOVED_HASH markers, and if we just rehash to the same size, we can get rid of those. An alternate version (simpler?) might be to check table.count vs table.slots_filled. Note that this becomes less necessary if REFILL_REMOVED is enabled.
    // Just go with the current size, but clean out the removals.
    new_allocated = table.allocated;
  } else {
    // We need to go deeper!
    new_allocated = table.allocated * 2;
  }

  if new_allocated < table.SIZE_MIN  new_allocated = table.SIZE_MIN;

  resize(table, new_allocated);

  table.count        = 0;   // count and slots_filled will be incremented by table_add.
  table.slots_filled = 0;

  for * entry, index: old_entries {
    // Note that if we removed some stuff, we will over-allocate the next table.
    // Maybe we should count the number of clobbers and subtract that. I dunno.
    if entry.hash >= FIRST_VALID_HASH  table_add(table, entry.hash, entry.value);
  }

  Basic.free(old_entries.data,, table.allocator);
}

next_power_of_two :: inline (x : int) -> int
{
  Basic.assert(x != 0);
  x -= 1;
  x |= x >> 1;
  x |= x >> 2;
  x |= x >> 4;
  x |= x >> 8;
  x |= x >> 16;
  x |= x >> 32;
  x += 1;
  return x;
}

#scope_file
Basic :: #import "Basic";
