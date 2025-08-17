// MeowHash
Meow :: #import "meow_hash";

// Single block API
Hash64 :: (input: *void, size: u64) -> u64
{
  #asm { hash: vec; }
  Meow.MeowHash(Meow.MeowDefaultSeed, size, input, hash);
  res := Meow.MeowU64From(hash, 0);
  return res;
}

// Chunked API
Hash64_State :: Meow.meow_state;

Hash64_Begin :: () -> Hash64_State
{
  state: Hash64_State = ---;
  Meow.MeowBegin(*state, Meow.MeowDefaultSeed);
  return state;
}

Hash64_Absorb :: (state: *Hash64_State, input: *void, size: u64)
{
  Meow.MeowAbsorb(state, size, input);
}

Hash64_End :: (state: *Hash64_State) -> u64
{
  #asm { hash: vec; };
  Meow.MeowEnd(state, hash);
  res := Meow.MeowU64From(hash, 0);
  return res;
}

// Helpers
Hash64Any :: (items: ..Any) -> u64
{
  state := Hash64_Begin();
  for items
  {
    using Type_Info_Tag;
    if it.type.type == {
      case STRING;
      str := (.*) cast(*string) it.value_pointer;
      Hash64_Absorb(*state, str);

      case BOOL; #through;
      case INTEGER; #through;
      case FLOAT; #through;
      case STRUCT; #through;
      case ENUM;
      Hash64_Absorb(*state, it.value_pointer, xx it.type.runtime_size);

      case ARRAY; #through; // could be supported in the future - see print_array func
      case;
      assert(false, "Unhandled Any type in Hash64Any");
    }
  }
  return Hash64_End(*state);
}

Hash64_Absorb :: (state: *Hash64_State, str: string)
{
  Hash64_Absorb(state, str.data, xx str.count);
}