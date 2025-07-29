Entropy :: struct
{
  state: u64;
  inc: u64;
}

rng_full_u32 :: (rng: *Entropy) -> u32
{
  old_state := rng.state;

  // Advance internal state
  rng.state = old_state * 6364136223846793005 + (rng.inc|1);

  // Calculate output function (XSH RR), uses old state for max ILP
  xor_shifted := cast,trunc(u32) (((old_state >> 18) ^ old_state) >> 27);
  rot := old_state >> 59;

  return (xor_shifted >> rot) | (xor_shifted << ((- cast(s32)rot) & 31));
}

rng_u32 :: (rng: *Entropy, range: u32) -> u32
{
  x := rng_full_u32(rng);
  m := x.(u64) * range.(u64);
  return xx,trunc (m >> 32);
}

rng_s32 :: (rng: *Entropy, min: s32, max: s32) -> s32
{
  range := (max - min).(u32);
  return rng_u32(rng, range).(s32) + min;
}

rng_s32 :: (rng: *Entropy, radius: s32) -> s32
{
  range := (radius*2).(u32);
  return rng_u32(rng, range).(s32) - radius;
}

rngf_01 :: (rng: *Entropy) -> float
{
  return 0h2F800000 * rng_full_u32(rng).(float);
}

rngf_11 :: (rng: *Entropy) -> float
{
  return rngf_01(rng)*2.0 - 1.0;
}

rng_bool :: (rng: *Entropy) -> bool
{
  return !(rng_full_u32(rng) & (1 << 14));
}
