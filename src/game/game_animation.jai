#scope_file;
using,only(AST,G) COMPS;
#scope_export;

Skeleton :: struct
{
  root_transform: Mat4;
  animations: [] Animation;
  animation_records: [#run EnumCount(AnimationID)] AnimationRecord;

  joints_count: u32; // all arrays below have count equal to joints_count
  joint_names: [] string;
  inverse_matrices: [] Mat4; // inverse bind matrices
  child_index_buffer: [] u32;
  child_index_ranges: [] Range(u32);

  bind_translations: [] V3;
  bind_rotations: [] Quat;
  bind_scales: [] V3;
};

Animation :: struct
{
  name: string;
  t_min, t_max: float;
  channels: [] AnimationChannel;
};

AnimationChannel :: struct
{
  type: PIE_AnimationChannelType;
  joint_index: u32;
  inputs: [] float;
  outputs: [] float; // .count = inputs.count * (ifx type == .Rotation then 4 else 3);
};

//
//
//

AnimationRecord :: struct
{
  animation_index: s32;
  joint_weights: [] float; // Animations like punching shouldn't really apply to legs etc
  // count = 0 -> all weights are equal to one
}

AnimationID :: enum u8
{
  IDLE;
  WALK;
  RUN;
  PUNCH;
  PUNCH_HANDS;
  JAB;
  JAB_HANDS;
  HIT;
  DEATH;
}

AnimationRequest :: struct
{
  tick: ServerTick;
  id: AnimationID;
}

AnimationTrack :: struct
{
  id: AnimationID;
  t: float;
  weight: float;
}

AN_InitSkeletons :: ()
{
  PerfFunc();

  MaskJoints :: (joint_name: string, value: float) #expand
  {
    AN_WaterfallToChildren(.ASSIGN, `skeleton, AN_JointNameToIndex(`skeleton, joint_name), `temp_weights, value);
  }

  skeleton := ModelFromAlias(.Dude).skeleton;
  if skeleton
  {
    for enum_values_as_enum(AnimationID)
    {
      r := *skeleton.animation_records[it];

      temp_weights := NewArray(skeleton.joints_count, float,, temp);
      for *temp_weights it.* = 1.0;

      if it == {
        case .IDLE;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Idle_Loop");

        case .WALK;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Walk_Loop");

        case .RUN;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Jog_Fwd_Loop");
        // temp_weights[AN_JointNameToIndex(skeleton, "DEF-spine.001")] = 0.5;

        case .PUNCH_HANDS;
        MaskJoints("root", 0.0);
        MaskJoints("DEF-spine.003", 1.0);
        #through;
        case .PUNCH;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Punch_Cross");

        case .JAB_HANDS;
        MaskJoints("root", 0.0);
        MaskJoints("DEF-spine.003", 1.0);
        #through;
        case .JAB;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Punch_Jab");

        case .HIT;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Hit_Head");
        MaskJoints("root", 0.0);
        MaskJoints("DEF-spine.001", 1.0);
        MaskJoints("DEF-shoulder.L", 0.0);
        MaskJoints("DEF-shoulder.R", 0.0);

        case .DEATH;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Death01");
      }

      has_non_one := false;
      for temp_weights if it != 1.0 then has_non_one = true;
      if has_non_one then r.joint_weights = array_copy(temp_weights);
    }
  }

  skeleton = ModelFromAlias(.Zombie).skeleton;
  if skeleton
  {
    for enum_values_as_enum(AnimationID)
    {
      r := *skeleton.animation_records[it];

      temp_weights := NewArray(skeleton.joints_count, float,, temp);
      for *temp_weights it.* = 1.0;

      if it == {
        case .IDLE;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Idle");

        case .WALK;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Walk");

        case .RUN;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Run");

        case .PUNCH_HANDS; #through;
        case .PUNCH; #through;
        case .JAB_HANDS; #through;
        case .JAB;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Punch");

        case .HIT;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "HitReact");

        case .DEATH;
        r.animation_index = AN_AnimationNameToIndex(skeleton, "Death");
      }

      has_non_one := false;
      for temp_weights if it != 1.0 then has_non_one = true;
      if has_non_one then r.joint_weights = array_copy(temp_weights);
    }
  }
}

AN_UpdateGhostTimers :: (ghost: *Ghost)
{
  activity := *ghost.activity;
  animate_rotation := OBJ_HasAnyFlag(ghost, .ANIMATE_ROTATION);
  animate_position := OBJ_HasAnyFlag(ghost, .ANIMATE_POSITION);

  if OBJ_HasAnyFlag(ghost, .IS_TURRET)
  {
    t := WrapFloat(activity.attack_t, 0.0, ghost.attack_cooldown_t);
    max_t := min(1.25, ghost.attack_cooldown_t);
    t = min(t, max_t) / max_t;

    pos_t := EasingInOut(t, ghost.attack_landed_t, .IN_SINE, .OUT_BOUNCE);
    rot_t := EasingInOut(t, ghost.attack_landed_t, .IN_SINE, .OUT_BOUNCE, in_scale = 3.0, out_scale = -1.0);

    ghost.anim.position.xy = ghost.p.xy;
    if activity.is_attacking || activity.attack_t < 0.0
    {
      ghost.anim.position.z = pos_t * 1.0;
      ghost.anim.rotation = RotationAroundAxis(AxisV3(.Z), rot_t*0.5);
    }
    else
    {
      animate_rotation = true;
      animate_position = true;
    }
  }

  if OBJ_HasAnyFlag(ghost, .TARGETED_PROJECTILE)
  {
    rng := OBJ_EntropyFromObj(ghost);
    weight0 := RngF_01(*rng);
    weight1 := (1.0 - weight0)*0.5 + RngF_01(*rng)*0.5;
    offset0 := RngF_01(*rng);
    offset1 := RngF_01(*rng);

    t := Elapsed(G.frame_timestamp, ghost.creation_time);
    ghost.anim.rotation =
    RotationAroundAxis(AxisV3(.X), t*weight0 + offset0) *
    RotationAroundAxis(AxisV3(.Y), t*weight1 + offset1);
  }

  if animate_rotation
  {
    ROTATION_SPEED :: 16.0;

    q0 := ghost.anim.rotation;
    q1 := ghost.rotation;

    w1 := min(1.0, G.dt * ROTATION_SPEED);
    w0 := 1.0 - w1;

    if dot(q0, q1) < 0.0
    w1 = -w1;

    ghost.anim.rotation = normalize(Mix(q0, q1, w0, w1));
  }
  else if !OBJ_HasAnyFlag(ghost, .MANUAL_ROTATION)
  {
    ghost.anim.rotation = ghost.rotation;
  }

  if animate_position
  {
    POSITION_SPEED :: 10.0;

    delta := ghost.p - ghost.anim.position;
    move_by := delta * (G.dt * POSITION_SPEED);
    ghost.anim.position += move_by;

    for *ghost.anim.position.component
    {
      if abs(delta.component[it_index]) < 0.01
      it.* = ghost.p.component[it_index];
    }
  }
  else if !OBJ_HasAnyFlag(ghost, .MANUAL_POSITION)
  {
    ghost.anim.position = ghost.p;
  }

  if OBJ_HasAnyFlag(ghost, .ANIMATE_TRACKS)
  {
    an := *ghost.anim;
    model := ModelFromAlias(ghost.model);
    if model.is_skinned
    {
      DISTANCE_TO_WALK_ANIMATION_COEFFICIENT :: 0.016;

      // idle_cycle
      an.idle_cycle += G.dt;
      an.idle_cycle = WrapFloat(an.idle_cycle, 0, 1);

      // walk_cycle
      moved_distance := length(ghost.moved_dp);
      meters_per_second := moved_distance * TICK_RATE;

      moved_cycle_delta := meters_per_second * DISTANCE_TO_WALK_ANIMATION_COEFFICIENT;
      an.walk_cycle += moved_cycle_delta;
      an.walk_cycle = WrapFloat(an.walk_cycle, 0, 100);

      // is_walking_weight
      target_is_walking := 0.0;
      if (meters_per_second > 0) target_is_walking += 1; // walk
      if (meters_per_second > 3.0) target_is_walking += 1; // run

      is_walking_t := clamp(G.dt * 10.0, 0, 1);
      an.is_walking_weight = lerp(an.is_walking_weight, target_is_walking, is_walking_t);

      // is_attacking_weight
      an.is_attacking_weight += G.dt * (ifx activity.is_attacking then 5.0 else -1.0 + -2.0 * target_is_walking);
      an.is_attacking_weight = clamp(an.is_attacking_weight, 0, 1);

      if (ghost.key == G.player_key) {
        // log("moved_distance: %; an.is_walking_weight %; is_attacking_weight %; target_is_walking: %; X %",
        //   moved_distance, an.is_walking_weight, an.is_attacking_weight, target_is_walking, .0001*TICK_RATE);
      }

      //
      // @todo [client side vs server side animation state]
      // It's a bit weird to calculate all these things above client-side only. This might be especially tricky for fog-of-war.
      // Perhaps it would be both simpler and better to move some of these calculations to server-side and just lerp them client side.
      //
    }
  }
}

AN_GetAnimationTracks :: (ghost: Ghost) -> tracks: [] AnimationTrack
{
  result: [] AnimationTrack;

  model := ModelFromAlias(ghost.model);
  if model.is_skinned
  {
    WALK_TO_RUN_COEFFICIENT :: 0.2;
    a := *ghost.anim;

    tracks: Fixed(AnimationTrack, 16);

    NotAllWeightsAreFull :: () -> bool #expand {
      if (tracks.count == 0) return true;
      track := tracks[tracks.count - 1];
      if (track.weight != 1.0) return true;
      record := model.skeleton.animation_records[track.id];
      return record.joint_weights.count != 0;
    }

    if NotAllWeightsAreFull() {
      track := array_add(*tracks);
      track.id = .DEATH;
      track.t = Elapsed(G.frame_timestamp, ghost.death_time) * 1.0;
      track.weight = ifx ghost.death_tick then min(1.0, track.t * 10.0) else 0.0;
    }

    if NotAllWeightsAreFull() {
      t := WrapFloat(ghost.activity.attack_t / ghost.attack_cooldown_t, 0.0, 1.0);
      t = AN_Time01ToAnimT(model.skeleton, .PUNCH, t);

      hands := array_add(*tracks);
      hands.weight = sqrt(a.is_attacking_weight);
      hands.id = .PUNCH_HANDS;
      hands.t = t;

      punch := array_add(*tracks);
      punch.weight = a.is_attacking_weight;
      punch.id = .PUNCH;
      punch.t = t;
    }

    if NotAllWeightsAreFull() {
      track := array_add(*tracks);
      track.id = .RUN;
      track.weight = Smoothstep(a.is_walking_weight, 1, 2);
      track.t = AN_Time01ToAnimT(model.skeleton, track.id, WrapFloat(a.walk_cycle * WALK_TO_RUN_COEFFICIENT, 0, 1));
    }

    if NotAllWeightsAreFull() {
      track := array_add(*tracks);
      track.id = .WALK;
      track.weight = Smoothstep(a.is_walking_weight, 0, 1);
      track.t = AN_Time01ToAnimT(model.skeleton, track.id, WrapFloat(a.walk_cycle, 0, 1));
    }

    if NotAllWeightsAreFull() {
      track := array_add(*tracks);
      track.id = .IDLE;
      track.weight = 1.0;
      track.t = AN_Time01ToAnimT(model.skeleton, track.id, a.idle_cycle);
    }

    result = copy_array(to_view(tracks),, temp);
  }

  return result;
}

AN_GetPoseTransforms :: (skeleton: Skeleton, tracks: [] AnimationTrack) -> [] Mat4
{
  PerfFunc();
  push_allocator(temp);

  accumulated_scales       := array_copy(skeleton.bind_scales);
  accumulated_rotations    := array_copy(skeleton.bind_rotations);
  accumulated_translations := array_copy(skeleton.bind_translations);
  result_matrices := NewArray(skeleton.joints_count, Mat4);

  // mix default rest pose + animation channels using temporary memory
  first_loop := true;
  for < track: tracks
  {
    defer first_loop = false;
    if track.weight <= 0 continue;

    auto_release_temp();
    scales := ifx first_loop then accumulated_scales else array_copy(skeleton.bind_scales);
    rotations := ifx first_loop then accumulated_rotations else array_copy(skeleton.bind_rotations);
    translations := ifx first_loop then accumulated_translations else array_copy(skeleton.bind_translations);

    record := AN_RecordFromType(skeleton, track.id);

    // Overwrite translations, rotations, scales with values from animation
    {
      anim := *skeleton.animations[record.animation_index];
      time := clamp(track.t, anim.t_min, anim.t_max);

      for channel: anim.channels
      {
        if channel.joint_index >= skeleton.joints_count
        {
          assert(false);
          continue;
        }

        if record.joint_weights.count > 0 && record.joint_weights[channel.joint_index] <= 0.0
          continue;

        t := 1.0;
        sample_start: u32;
        sample_end: u32;
        // find t, sample_start, sample_end
        {
          // @speed binary search might be faster?
          for channel.inputs
          {
            if it >= time
              break;
            sample_start = xx it_index;
          }

          sample_end = sample_start + 1;
          if (sample_end >= channel.inputs.count)
            sample_end = sample_start;

          time_start := channel.inputs[sample_start];
          time_end := channel.inputs[sample_end];

          if time_start < time_end
          {
            time_range := time_end - time_start;
            t = (time - time_start) / time_range;
          }
        }

        if channel.type == .Rotation
        {
          q0 := channel.outputs.data.(*Quat)[sample_start];
          q1 := channel.outputs.data.(*Quat)[sample_end];
          value := Slerp(q0, q1, t); // @todo NLerp with "neighborhood operator" could be used here?

          rotations[channel.joint_index] = value;
        }
        else
        {
          v0 := channel.outputs.data.(*V3)[sample_start];
          v1 := channel.outputs.data.(*V3)[sample_end];
          value := lerp(v0, v1, t);

          if channel.type == .Translation
            translations[channel.joint_index] = value;
          else
            scales[channel.joint_index] = value;
        }
      }
    }

    if !first_loop
    {
      for joint_index: MakeRange(skeleton.joints_count)
      {
        joint_weight := 1.0;
        if record.joint_weights.count > 0 {
          joint_weight = record.joint_weights[joint_index];
        }

        weight := track.weight * joint_weight;
        if weight <= 0 then continue;

        accumulated_scales[it_index]       = lerp(accumulated_scales[it_index],       scales[it_index],       weight);
        accumulated_rotations[it_index]    = Slerp(accumulated_rotations[it_index],   rotations[it_index],    weight);
        accumulated_translations[it_index] = lerp(accumulated_translations[it_index], translations[it_index], weight);
      }
    }
  }

  for *result_matrices
  {
    scale := ScaleMatrix(accumulated_scales[it_index]);
    rot := RotationMatrix(accumulated_rotations[it_index]);
    trans := TranslationMatrix(accumulated_translations[it_index]);
    it.* = trans * (rot * scale);
  }

  AN_WaterfallToChildren(.MULTIPLY, skeleton, 0, result_matrices, skeleton.root_transform);

  for *result_matrices {
    it.* = it.* * skeleton.inverse_matrices[it_index];
  }
  return result_matrices;
}

#scope_file;
AN_RecordFromType :: (skeleton: Skeleton, id: AnimationID) -> *AnimationRecord
{
  return *skeleton.animation_records[id];
}

AN_AnimationFromType :: (skeleton: Skeleton, id: AnimationID) -> *Animation
{
  return *skeleton.animations[AN_RecordFromType(skeleton, id).animation_index];
}

AN_WrapTime :: (skeleton: Skeleton, id: AnimationID, t: float) -> float
{
  anim_index := skeleton.animation_records[id].animation_index;
  anim := skeleton.animations[anim_index];
  result := WrapFloat(t, anim.t_min, anim.t_max);
  return result;
}

AN_Time01ToAnimT :: (skeleton: Skeleton, id: AnimationID, t: float) -> float
{
  anim_index := skeleton.animation_records[id].animation_index;
  anim := skeleton.animations[anim_index];
  result := (anim.t_max - anim.t_min) * t + anim.t_min;
  return result;
}

AN_WaterfallToChildren :: ($mode: enum {MULTIPLY; ASSIGN;},
  skeleton: Skeleton, joint_index: u32, values: [] $T, parent_value: T)
{
  // This function traverses skeleton joint hierarchy from root joint to children.

  if (joint_index >= skeleton.joints_count)
  {
    assert(false);
    return;
  }

  #if #complete mode == {
    case .MULTIPLY; values[joint_index] = parent_value * values[joint_index];
    case .ASSIGN; values[joint_index] = parent_value;
  }

  child_range := skeleton.child_index_ranges[joint_index];
  for child_range
  {
    if it >= skeleton.joints_count
    {
      assert(false);
      return;
    }

    child_joint_index := skeleton.child_index_buffer[it];
    AN_WaterfallToChildren(mode, skeleton, child_joint_index, values, values[joint_index]);
  }
}

//
//
//
AN_AnimationNameToIndex :: (skeleton: Skeleton, name: string) -> index: s32, found: bool
{
  for skeleton.animations
  {
    if name == it.name
      return xx it_index, true;
  }
  log("Animation name not found: %", name, flags=.WARNING);
  return 0, false;
}

AN_JointNameToIndex :: (skeleton: Skeleton, name: string) -> index: u32, found: bool
{
  for skeleton.joint_names
  {
    if name == it
      return xx it_index, true;
  }
  log("Joint name not found: %", name, flags=.WARNING);
  return 0, false;
}
