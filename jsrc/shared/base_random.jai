Entropy :: struct
{
  state: u64;
  inc: u64;
}

RngU32_Full :: (rng: *Entropy) -> u32
{
  old_state := rng.state;

  // Advance internal state
  rng.state = old_state * 6364136223846793005 + (rng.inc|1);

  // Calculate output function (XSH RR), uses old state for max ILP
  xor_shifted := cast,trunc(u32) (((old_state >> 18) ^ old_state) >> 27);
  rot := old_state >> 59;

  return (xor_shifted >> rot) | (xor_shifted << ((- cast(s32)rot) & 31));
}

RngU32_MaxOpen :: (rng: *Entropy, range: u32) -> u32
{
  x := RngU32_Full(rng);
  m := x.(u64) * range.(u64);
  return xx,trunc (m >> 32);
}

RngS32_MinMaxOpen :: (rng: *Entropy, min: s32, max: s32) -> s32
{
  range := (max - min).(u32);
  return RngU32_MaxOpen(rng, range).(s32) + min;
}

RngS32_Radius :: (rng: *Entropy, radius: s32) -> s32
{
  range := (radius*2).(u32);
  return RngU32_MaxOpen(rng, range).(s32) - radius;
}

RngF_01 :: (rng: *Entropy) -> float
{
  return 0h2F800000 * RngU32_Full(rng).(float);
}

RngF_11 :: (rng: *Entropy) -> float
{
  return RngF_01(rng)*2.0 - 1.0;
}

RngBool :: (rng: *Entropy) -> bool
{
  return !(RngU32_Full(rng) & (1 << 14));
}

RngEnum_MinMaxClosed :: (rng: *Entropy, min: $T, max: T) -> T
{
  result := RngS32_MinMaxOpen(rng, min.(s32), max.(s32) + 1);
  return xx result;
}
