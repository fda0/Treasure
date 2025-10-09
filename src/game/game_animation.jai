Skeleton :: struct
{
  root_transform: Mat4;
  animations: [] Animation;
  animation_records: [#run EnumMaxPlus1(ANIMATION_Type)] ANIMATION_Record;

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
  channels: [] ANIMATION_Channel;
};

ANIMATION_Channel :: struct
{
  type: PIE_AnimationChannelType;
  joint_index: u32;
  inputs: [] float;
  outputs: [] float; // .count = inputs.count * (ifx type == .Rotation then 4 else 3);
};

//
//
//
ANIMATION_AdvanceMode :: enum
{
  TIME;
  DISTANCE;
  MANUAL01;
  MANUAL;
}

ANIMATION_Record :: struct
{
  animation_index: s32;
  joint_weights: [] float; // Animations like punching shouldn't really apply to legs etc
  // count = 0 -> all weights are equal to one
}

ANIMATION_Type :: enum u8
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

ANIMATION_Request :: struct
{
  start: Tick = Tick_MAX;
  type: ANIMATION_Type;
}

ANIMATION_Track :: struct
{
  type: ANIMATION_Type;
  t: float;
  weight: float;
}

ANIMATION_InitSkeletons :: ()
{
  PerfFunc();

  MaskJoints :: (joint_name: string, value: float) #expand
  {
    WaterfallToChildren(.ASSIGN, `skeleton, JointNameToIndex(`skeleton, joint_name), `temp_weights, value);
  }

  skeleton := GetModel(ModelKey("Dude")).skeleton;
  if skeleton
  {
    for enum_values_as_enum(ANIMATION_Type)
    {
      r := *skeleton.animation_records[it];

      temp_weights := NewArray(skeleton.joints_count, float,, temp);
      for *temp_weights it.* = 1.0;

      if it == {
        case .IDLE;
        r.animation_index = AnimationNameToIndex(skeleton, "Idle_Loop");

        case .WALK;
        r.animation_index = AnimationNameToIndex(skeleton, "Walk_Loop");

        case .RUN;
        r.animation_index = AnimationNameToIndex(skeleton, "Jog_Fwd_Loop");
        // temp_weights[JointNameToIndex(skeleton, "DEF-spine.001")] = 0.5;

        case .PUNCH_HANDS;
        MaskJoints("root", 0.0);
        MaskJoints("DEF-spine.003", 1.0);
        #through;
        case .PUNCH;
        r.animation_index = AnimationNameToIndex(skeleton, "Punch_Cross");

        case .JAB_HANDS;
        MaskJoints("root", 0.0);
        MaskJoints("DEF-spine.003", 1.0);
        #through;
        case .JAB;
        r.animation_index = AnimationNameToIndex(skeleton, "Punch_Jab");

        case .HIT;
        r.animation_index = AnimationNameToIndex(skeleton, "Hit_Head");
        MaskJoints("root", 0.0);
        MaskJoints("DEF-spine.001", 1.0);
        MaskJoints("DEF-shoulder.L", 0.0);
        MaskJoints("DEF-shoulder.R", 0.0);

        case .DEATH;
        r.animation_index = AnimationNameToIndex(skeleton, "Death01");
      }

      has_non_one := false;
      for temp_weights if it != 1.0 then has_non_one = true;
      if has_non_one then r.joint_weights = array_copy(temp_weights,, G.ast.arena);
    }
  }

  skeleton = GetModel(ModelKey("Zombie")).skeleton;
  if skeleton
  {
    for enum_values_as_enum(ANIMATION_Type)
    {
      r := *skeleton.animation_records[it];

      temp_weights := NewArray(skeleton.joints_count, float,, temp);
      for *temp_weights it.* = 1.0;

      if it == {
        case .IDLE;
        r.animation_index = AnimationNameToIndex(skeleton, "Idle");

        case .WALK;
        r.animation_index = AnimationNameToIndex(skeleton, "Walk");

        case .RUN;
        r.animation_index = AnimationNameToIndex(skeleton, "Run");

        case .PUNCH_HANDS; #through;
        case .PUNCH; #through;
        case .JAB_HANDS; #through;
        case .JAB;
        r.animation_index = AnimationNameToIndex(skeleton, "Punch");

        case .HIT;
        r.animation_index = AnimationNameToIndex(skeleton, "HitReact");

        case .DEATH;
        r.animation_index = AnimationNameToIndex(skeleton, "Death");
      }

      has_non_one := false;
      for temp_weights if it != 1.0 then has_non_one = true;
      if has_non_one then r.joint_weights = array_copy(temp_weights,, G.ast.arena);
    }
  }
}

ANIMATION_AnimateObjects :: ()
{
  PerfFunc();
  AssertThatScopeIsSingleThreaded();

  for *obj: context.R.obj.all_objects
  {
    state_machine := *obj.s.state_machine;
    animate_rotation := OBJ_HasAnyFlag(obj, .ANIMATE_ROTATION);
    animate_position := OBJ_HasAnyFlag(obj, .ANIMATE_POSITION);

    if OBJ_HasAnyFlag(obj, .IS_TURRET)
    {
      t := WrapFloat(state_machine.attack_t, 0.0, obj.s.attack_cooldown_t);
      max_t := min(1.25, obj.s.attack_cooldown_t);
      t = min(t, max_t) / max_t;

      pos_t := EasingInOut(t, obj.s.attack_landed_t, .IN_SINE, .OUT_BOUNCE);
      rot_t := EasingInOut(t, obj.s.attack_landed_t, .IN_SINE, .OUT_BOUNCE, in_scale = 3.0, out_scale = -1.0);

      obj.l.animated_p.xy = obj.s.p.xy;
      if state_machine.is_attacking || state_machine.attack_t < 0.0
      {
        obj.l.animated_p.z = pos_t * 1.0;
        obj.l.animated_rot = RotationAroundAxis(AxisV3(.Z), rot_t*0.5);
      }
      else
      {
        animate_rotation = true;
        animate_position = true;
      }
    }

    if OBJ_HasAnyFlag(obj, .TARGETED_PROJECTILE)
    {
      rng := OBJ_EntropyFromObj(obj);
      weight0 := RngF_01(*rng);
      weight1 := (1.0 - weight0)*0.5 + RngF_01(*rng)*0.5;
      offset0 := RngF_01(*rng);
      offset1 := RngF_01(*rng);

      t := ElapsedSeconds(obj.s.creation_time);
      obj.l.animated_rot =
        RotationAroundAxis(AxisV3(.X), t*weight0 + offset0) *
        RotationAroundAxis(AxisV3(.Y), t*weight1 + offset1);
    }

    if animate_rotation
    {
      ROTATION_SPEED :: 16.0;

      q0 := obj.l.animated_rot;
      q1 := obj.s.rotation;

      w1 := min(1.0, G.dt * ROTATION_SPEED);
      w0 := 1.0 - w1;

      if dot(q0, q1) < 0.0
        w1 = -w1;

      obj.l.animated_rot = normalize(Mix(q0, q1, w0, w1));
    }
    else if !OBJ_HasAnyFlag(obj, .MANUAL_ROTATION)
    {
      obj.l.animated_rot = obj.s.rotation;
    }

    if animate_position
    {
      POSITION_SPEED :: 10.0;

      delta := obj.s.p - obj.l.animated_p;
      move_by := delta * (G.dt * POSITION_SPEED);
      obj.l.animated_p += move_by;

      for *obj.l.animated_p.component
      {
        if abs(delta.component[it_index]) < 0.01
          it.* = obj.s.p.component[it_index];
      }
    }
    else if !OBJ_HasAnyFlag(obj, .MANUAL_POSITION)
    {
      obj.l.animated_p = obj.s.p;
    }

    if OBJ_HasAnyFlag(obj, .ANIMATE_TRACKS)
    {
      AS := *obj.l.animation_state;
      model := GetModel(obj.s.model);
      if model.is_skinned
      {
        WALK_T_SPEED :: 0.016;
        WALK_TO_RUN :: 0.2;
        RUN_T_SPEED :: WALK_T_SPEED * WALK_TO_RUN;

        moved_distance := length(obj.s.moved_dp);
        moved_cycle_delta := moved_distance * WALK_T_SPEED * TICK_RATE; // @todo this is nonsense; this has to be multiplied by dt actually

        AS.walk_cycle += moved_cycle_delta;
        AS.walk_cycle = WrapFloat(AS.walk_cycle, 0, 100);

        is_walking_sign := Smoothstep(moved_distance, .00001*TICK_RATE, .00002*TICK_RATE)*2.0 - 1.0;
        AS.is_walking += is_walking_sign * G.dt * 10.0;
        AS.is_walking = clamp(AS.is_walking, 0.0, 1.0);

        is_running_sign := Smoothstep(moved_distance, .0002*TICK_RATE, .00022*TICK_RATE)*2.0 - 1.0;
        AS.is_running += is_running_sign * G.dt * 10.0;
        AS.is_running = clamp(AS.is_running, 0.0, 1.0);

        if (obj.s.key == G.client.player_key) {
          log("moved_distance: %; is_walking_sign: %; AS.is_walking %", moved_distance, is_walking_sign, AS.is_walking);
          log("is_running_sign: %; AS.is_running %", is_running_sign, AS.is_running);
        }

        AS.tracks[0].weight = 1.0;
        AS.tracks[0].type = .IDLE;
        AS.tracks[0].t += G.dt;
        AS.tracks[0].t = WrapTime(model.skeleton, AS.tracks[0].type, AS.tracks[0].t);

        AS.tracks[1].weight = AS.is_walking;
        AS.tracks[1].type = .WALK;
        walk_anim := AnimationFromType(model.skeleton, AS.tracks[1].type);
        AS.tracks[1].t = (walk_anim.t_max - walk_anim.t_min) * WrapFloat(AS.walk_cycle, 0, 1) + walk_anim.t_min;

        AS.tracks[2].weight = AS.is_running;
        AS.tracks[2].type = .RUN;
        run_anim := AnimationFromType(model.skeleton, AS.tracks[2].type);
        AS.tracks[2].t = (run_anim.t_max - run_anim.t_min) * WrapFloat(AS.walk_cycle * WALK_TO_RUN, 0, 1) + run_anim.t_min;

        #if 0 {
          // Movement calculations
          {

            obj.l.animation_distance01 = WrapFloat(obj.l.animation_distance01 + distance01_delta, 0.0, 1.0);
            AddClamp01(*obj.l.animation_moving_hot_t, (ifx moved_distance > 0 then G.dt else -G.dt) * 10);

            if obj.l.animation_moving_hot_t == 0
              obj.l.animation_distance01 = 0;
          }

          // Attack calculations
          if !state_machine.is_attacking
          {
            obj.l.animation_attack_hide_cooldown = true;
          }
          if state_machine.is_attacking && state_machine.attack_t >= 0.0
          {
            obj.l.animation_attack_hide_cooldown = false;
          }

          is_punching := state_machine.is_attacking && !obj.l.animation_attack_hide_cooldown;
          AddClamp01(*obj.l.animation_hands_punching_hot_t, (ifx is_punching then G.dt*4 else -G.dt*8) * obj.s.attack_speed);
          AddClamp01(*obj.l.animation_full_punching_hot_t, (ifx is_punching then G.dt*2 else -G.dt*20) * obj.s.attack_speed);
          attack_normalized_t := WrapFloat(state_machine.attack_t, 0.0, obj.s.attack_cooldown_t);
          attack_normalized_t /= obj.s.attack_cooldown_t;
          use_jab_animation := WrapFloat(state_machine.visual_attack_t, 0.0, obj.s.attack_cooldown_t*2) > obj.s.attack_cooldown_t;

          // Fill animation tracks
          all_joints_are_masked := false;
          for < *obj.l.animation_tracks
          {
            if all_joints_are_masked
              it.weight = 0.0;

            anim_mode: ANIMATION_AdvanceMode = .MANUAL;
            time: float;

            // Select an animation per slot
            if it_index == 0
            {
              anim_mode = .TIME;
              it.weight = 1.0;
              it.type = .IDLE;
            }
            else if it_index == 1
            {
              anim_mode = .DISTANCE;
              it.weight = obj.l.animation_moving_hot_t;
              it.type = .WALK;
            }
            else if it_index == 2
            {
              anim_mode = .DISTANCE;
              it.weight = 0.0;
              it.type = .RUN;
            }
            else if it_index == 3
            {
              anim_mode = .MANUAL01;
              it.type = ifx use_jab_animation then .JAB_HANDS else .PUNCH_HANDS;
              it.t = attack_normalized_t; // @todo pick anim.t_min & anim.t_max instead of 0.0 and 1.0; -> this is repeating pattern!
              it.weight = obj.l.animation_hands_punching_hot_t;
            }
            else if it_index == 4
            {
              anim_mode = .MANUAL01;
              it.type = ifx use_jab_animation then .JAB else .PUNCH;
              it.t = attack_normalized_t; // @todo pick anim.t_min & anim.t_max instead of 0.0 and 1.0; -> this is repeating pattern!
              it.weight = obj.l.animation_full_punching_hot_t;
            }
            else if it_index == 5
            {
              anim_mode = .MANUAL01;
              p := QueuePeek(obj.s.animation_requests, 2);
              pt := ClientSecondsSinceServerTick(p.start, max_on_fail=true) * 1.0;
              it.type = p.type;
              it.t = pt;
              it.weight = ifx pt <= 1.0 then 1.0 else 0.0;
            }
            else if it_index == 6
            {
              anim_mode = .MANUAL01;
              p := QueuePeek(obj.s.animation_requests, 1);
              pt := ClientSecondsSinceServerTick(p.start, max_on_fail=true) * 1.0;
              it.type = p.type;
              it.t = pt;
              it.weight = ifx pt <= 1.0 then 1.0 else 0.0;
            }
            else if it_index == 7
            {
              anim_mode = .MANUAL01;
              p := QueuePeek(obj.s.animation_requests, 0);
              pt := ClientSecondsSinceServerTick(p.start, max_on_fail=true) * 1.0;
              it.type = p.type;
              it.t = pt;
              it.weight = ifx pt <= 1.0 then 1.0 else 0.0;
            }
            else if it_index == 8
            {
              if obj.s.death_time
              {
                it.type = .DEATH;
                it.t = ElapsedSeconds(obj.s.death_time) * 1.0;
                it.weight = min(1.0, it.t * 10.0);
              }
              else it.weight = 0.0;
            }
            else
            {
              it.weight = 0.0;
            }


            // Advance T
            if anim_mode == .DISTANCE
            {
              anim := AnimationFromType(model.skeleton, it.type);
              dist_t := (anim.t_max - anim.t_min) * obj.l.animation_distance01 + anim.t_min;
              it.t = WrapTime(model.skeleton, it.type, dist_t);
            }
            else if anim_mode == .TIME
            {
              it.t += G.dt;
              it.t = WrapTime(model.skeleton, it.type, it.t);
            }
            else if anim_mode == .MANUAL01
            {
              anim := AnimationFromType(model.skeleton, it.type);
              it.t = (anim.t_max - anim.t_min) * it.t + anim.t_min;
            }


            record := RecordFromType(model.skeleton, it.type);
            if record.joint_weights.count == 0 && it.weight == 1.0
              all_joints_are_masked = true;
          }
        }


      }
    }
  }
}

ANIMATION_GetPoseTransforms :: (skeleton: Skeleton, params: [] ANIMATION_Track) -> [] Mat4
{
  PerfFunc();

  accumulated_scales       := array_copy(skeleton.bind_scales,,       temp);
  accumulated_rotations    := array_copy(skeleton.bind_rotations,,    temp);
  accumulated_translations := array_copy(skeleton.bind_translations,, temp);

  // mix default rest pose + animation channels using temporary memory
  for param, param_index: params
  {
    if param.weight <= 0 continue;

    auto_release_temp();
    scales: [] V3;
    rotations: [] Quat;
    translations: [] V3;

    if param_index == 0
    {
      scales = accumulated_scales;
      rotations = accumulated_rotations;
      translations = accumulated_translations;
    }
    else
    {
      scales       = array_copy(skeleton.bind_scales,,       temp);
      rotations    = array_copy(skeleton.bind_rotations,,    temp);
      translations = array_copy(skeleton.bind_translations,, temp);
    }

    record := RecordFromType(skeleton, param.type);

    // Overwrite translations, rotations, scales with values from animation
    {
      anim := *skeleton.animations[record.animation_index];
      time := clamp(param.t, anim.t_min, anim.t_max);

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

    if param_index > 0
    {
      for joint_index: MakeRange(skeleton.joints_count)
      {
        joint_weight := 1.0;
        if record.joint_weights.count > 0
          joint_weight = record.joint_weights[joint_index];

        weight := param.weight * joint_weight;
        if weight <= 0 then continue;

        accumulated_scales[it_index]       = lerp(accumulated_scales[it_index],       scales[it_index],       weight);
        accumulated_rotations[it_index]    = Slerp(accumulated_rotations[it_index],   rotations[it_index],    weight);
        accumulated_translations[it_index] = lerp(accumulated_translations[it_index], translations[it_index], weight);
      }
    }
  }

  result_matrices := NewArray(skeleton.joints_count, Mat4,, temp);
  for *result_matrices
  {
    scale := ScaleMatrix(accumulated_scales[it_index]);
    rot := RotationMatrix(accumulated_rotations[it_index]);
    trans := TranslationMatrix(accumulated_translations[it_index]);
    it.* = trans * (rot * scale);
  }

  WaterfallToChildren(.MULTIPLY, skeleton, 0, result_matrices, skeleton.root_transform);

  for *result_matrices
    it.* = it.* * skeleton.inverse_matrices[it_index];

  return result_matrices;
}

#scope_file;
RecordFromType :: (skeleton: Skeleton, type: ANIMATION_Type) -> *ANIMATION_Record
{
  return *skeleton.animation_records[type];
}

AnimationFromType :: (skeleton: Skeleton, type: ANIMATION_Type) -> *Animation
{
  return *skeleton.animations[RecordFromType(skeleton, type).animation_index];
}

WrapTime :: (skeleton: Skeleton, anim_index: s32, time: float) -> float
{
  anim := skeleton.animations[anim_index];
  time = WrapFloat(time, anim.t_min, anim.t_max);
  return time;
}
WrapTime :: (skeleton: Skeleton, type: ANIMATION_Type, time: float) -> float
{
  return WrapTime(skeleton, skeleton.animation_records[type].animation_index, time);
}

WaterfallToChildren :: ($mode: enum {MULTIPLY; ASSIGN;},
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
    WaterfallToChildren(mode, skeleton, child_joint_index, values, values[joint_index]);
  }
}

//
//
//
AnimationNameToIndex :: (skeleton: Skeleton, name: string) -> index: s32, found: bool
{
  for skeleton.animations
  {
    if name == it.name
      return xx it_index, true;
  }
  log("Animation name not found: %", name, flags=.WARNING);
  return 0, false;
}

JointNameToIndex :: (skeleton: Skeleton, name: string) -> index: u32, found: bool
{
  for skeleton.joint_names
  {
    if name == it
      return xx it_index, true;
  }
  log("Joint name not found: %", name, flags=.WARNING);
  return 0, false;
}
