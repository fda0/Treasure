#scope_file;
using,only(AN,AST,G) COMPS;
#scope_export;

AnimationState :: struct
{
  per_lane: [] Lane;

  Lane :: struct
  {
    free_nodes: *AnimationNode;
  }
}

Skeleton :: struct
{
  using base: BaseSkeleton;
  joints_count: s64;
  tag_to_sequence: [AnimationTag_COUNT] AnimationSequence;
  joint_masks: [AnimationMask_COUNT] [/*per joint*/] bool; // @todo 1compress with bit vector thing
}

AnimationTag :: enum u8
{
  IDLE;
  WALK;
  RUN;
  PUNCH;
  JAB;
  HIT;
  DEATH;

  SPELL;
  SPELL_ENTER;
  SPELL_IDLE;
  SPELL_EXIT;
}
AnimationTag_COUNT :: #run EnumCount(AnimationTag);

AnimationMask :: enum u8
{
  ALL;
  ARMS;
  HEAD;
}
AnimationMask_COUNT :: #run EnumCount(AnimationMask);

AnimationSequence :: struct
{
  clip_idxs: [] s64;
  mask: AnimationMask;
}

AnimationNode :: struct
{
  weight: float;
  t: float;
  tag: AnimationTag;
  flags: enum_flags u8
  {
    INCREMENT_T;
    INCREMENT_WEIGHT;
    DENORMALIZE_T; // t is normalized to [0:1] range, transform it into animation time range
    PLAYER_SLIDESHOW; // advance to next player idx on finished animation
    REMOVE_WHEN_FINISHED;
  }

  next, prev: *AnimationNode;
}

AnimationData :: struct
{
  rotation: Quat; // animates towards at.obj.rotation
  position: V3; // animates towards at.obj.p
  node: *AnimationNode; // can be null
}

AnimationRequest :: struct
{
  tick: ServerTick;
  tag: AnimationTag;
}

//
//
//
AN_UpdateGhost :: (ghost: *Ghost)
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
      if abs(delta.component[it_index]) < 0.01 {
        it.* = ghost.p.component[it_index];
      }
    }
  }
  else if !OBJ_HasAnyFlag(ghost, .MANUAL_POSITION)
  {
    ghost.anim.position = ghost.p;
  }

  if OBJ_HasAnyFlag(ghost, .ANIMATE_TRACKS)
  {
    an := *ghost.anim;

    if IsNil(ghost.anim.node)
    {
      ghost.anim.node = AN_AllocNode();
      idle := ghost.anim.node;
      walk := AN_AllocNode(idle);
      run := AN_AllocNode(walk);
      attack := AN_AllocNode(run);

      idle.weight = 1.0;
      idle.tag = .IDLE;
      idle.flags = .DENORMALIZE_T;

      walk.tag = .WALK;
      run.tag = .RUN;
      attack.tag = .PUNCH;
    }

    idle := ghost.anim.node;
    walk := idle.next;
    run := walk.next;
    attack := run.next;

    DISTANCE_TO_WALK_ANIMATION_COEFFICIENT :: 0.016;

    // idle_cycle
    idle.t = WrapFloat(idle.t + G.dt, 0, 1);

    // walk_cycle
    moved_distance := length(ghost.moved_dp);
    meters_per_second := moved_distance * TICK_RATE;
    moved_cycle_delta := meters_per_second * DISTANCE_TO_WALK_ANIMATION_COEFFICIENT;
    walk.t = WrapFloat(walk.t + moved_cycle_delta, 0, 100);
    run.t = walk.t;

    // walk / run weight
    walk.weight += G.dt * 10.0 * BoolSign(meters_per_second > 0.0);
    run.weight += G.dt * 10.0 * BoolSign(meters_per_second > 3.0);
    walk.weight = clamp(walk.weight, 0, 1);
    run.weight = clamp(run.weight, 0, 1);

    // attack weight
    attack.weight += G.dt * (ifx activity.is_attacking then 5.0 else -1.0 + (ifx meters_per_second > 0.0 then -2.0));
    attack.weight = clamp(attack.weight, 0, 1);

    for ghost.animation_requests
    {
      if IsTickDue(it.tick, ghost)
      {
        node := AN_AllocNode(AN_LastNode(attack));
        node.tag = it.tag;
        node.flags = .INCREMENT_T | .INCREMENT_WEIGHT | .REMOVE_WHEN_FINISHED;
      }
    }

    model := ModelFromAlias(ghost.model);
    if model.is_skinned
    {
      skeleton := SkeletonFromSlot(model.skeleton_slot);

      node := ghost.anim.node;
      while !IsNil(node)
      {
        next_node := node.next;
        defer node = next_node;

        if node.flags & .INCREMENT_T {
          node.t += G.dt;
        }
        if node.flags & .INCREMENT_WEIGHT {
          node.weight = clamp(node.weight + G.dt, 0, 1);
        }
        if node.flags & .REMOVE_WHEN_FINISHED {
          clip := AN_ClipFromTag(skeleton, node.tag);
          if node.t >= clip.t_max {
            AN_FreeNode(node);
            continue;
          }
        }
      }
    }


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

AN_GetTracks :: (ghost: Ghost) -> tracks: [] AnimationTrack
{
  model := ModelFromAlias(ghost.model);
  if !model.is_skinned return .[];

  skeleton := SkeletonFromSlot(model.skeleton_slot);

  WALK_TO_RUN_COEFFICIENT :: 0.2;
  a := *ghost.anim;

  tracks: Fixed(AnimationTrack, 16);

  NotAllWeightsAreFull :: () -> bool #expand
  {
    if (tracks.count == 0) return true;
    track := tracks[tracks.count - 1];
    if (track.weight != 1.0) return true;
    weights := SkeletonFromSlot(model.skeleton_slot).animation_weights[track.tag];
    return weights.joint_weights.count != 0;
  }

  if NotAllWeightsAreFull()
  {
    track := array_add(*tracks);
    track.tag = .DEATH;
    track.t = Elapsed(G.frame_timestamp, ghost.death_time) * 1.0;
    track.weight = ifx ghost.death_tick then min(1.0, track.t * 10.0) else 0.0;
  }

  for ghost.anim.playbacks
  {
    if NotAllWeightsAreFull()
    {
      track := array_add(*tracks);
      track.tag = it.tag;
      track.t = Elapsed(G.frame_timestamp, it.start_time);
      track.weight = 1.0;
    }
  }

  if NotAllWeightsAreFull()
  {
    t := WrapFloat(ghost.activity.attack_t / ghost.attack_cooldown_t, 0.0, 1.0);
    t = AN_Time01ToAnimT(skeleton, .PUNCH, t);

    hands := array_add(*tracks);
    hands.weight = sqrt(a.is_attacking_weight);
    hands.tag = .PUNCH_HANDS;
    hands.t = t;

    punch := array_add(*tracks);
    punch.weight = a.is_attacking_weight;
    punch.tag = .PUNCH;
    punch.t = t;
  }

  if NotAllWeightsAreFull()
  {
    track := array_add(*tracks);
    track.tag = .RUN;
    track.weight = Smoothstep(a.is_walking_weight, 1, 2);
    track.t = AN_Time01ToAnimT(skeleton, track.tag, WrapFloat(a.walk_cycle * WALK_TO_RUN_COEFFICIENT, 0, 1));
  }

  if NotAllWeightsAreFull()
  {
    track := array_add(*tracks);
    track.tag = .WALK;
    track.weight = Smoothstep(a.is_walking_weight, 0, 1);
    track.t = AN_Time01ToAnimT(skeleton, track.tag, WrapFloat(a.walk_cycle, 0, 1));
  }

  if NotAllWeightsAreFull()
  {
    track := array_add(*tracks);
    track.tag = .IDLE;
    track.weight = 1.0;
    track.t = AN_Time01ToAnimT(skeleton, track.tag, a.idle_cycle);
  }

  result := copy_array(to_view(tracks),, temp);
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

    weights := AN_WeightsFromTag(skeleton, track.tag);

    // Overwrite translations, rotations, scales with values from animation
    {
      clip := *skeleton.clips[weights.clip_idx];
      time := clamp(track.t, clip.t_min, clip.t_max);

      for channel: clip.channels
      {
        if channel.joint_index >= skeleton.joints_count
        {
          assert(false);
          continue;
        }

        if weights.joint_priority[channel.joint_index] == 0 // @todo_now improve logic here
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

    if !first_loop && track.weight > 0
    {
      for MakeRange(skeleton.joints_count)
      {
        accumulated_scales[it]       = lerp(accumulated_scales[it],       scales[it],       weight);
        accumulated_rotations[it]    = Slerp(accumulated_rotations[it],   rotations[it],    weight);
        accumulated_translations[it] = lerp(accumulated_translations[it], translations[it], weight);
      }
    }
  }

  for * result_matrices
  {
    scale := ScaleMatrix(accumulated_scales[it_index]);
    rot := RotationMatrix(accumulated_rotations[it_index]);
    trans := TranslationMatrix(accumulated_translations[it_index]);
    it.* = trans * (rot * scale);
  }

  AN_WaterfallToChildren(.MULTIPLY, skeleton, 0, result_matrices, skeleton.root_transform);

  for * result_matrices {
    it.* = it.* * skeleton.inverse_matrices[it_index];
  }
  return result_matrices;
}

AN_Init :: ()
{
  PerfFunc();

  AN.per_lane = NewArray(GLOBAL.core_count, AnimationState.Lane);


  SetMask :: (joint_name: string, value: bool) #expand
  {
    AN_WaterfallToChildren(.ASSIGN, skeleton, AN_JointNameToIndex(skeleton, joint_name), `it.*, value);
  }

  skeleton := SkeletonFromSlot(ModelFromAlias(.Dude).skeleton_slot);
  if skeleton
  {
    for * skeleton.joint_masks
    {
      it.* = NewArray(skeleton.joints_count, bool);

      if it_index.(AnimationMask) == {
        case .ALL;
        SetMask("root", true);

        case .ARMS;
        SetMask("DEF-spine.003", true);

        case .HEAD;
        SetMask("DEF-spine.001", true);
        SetMask("DEF-shoulder.L", false);
        SetMask("DEF-shoulder.R", false);
      }
    }
  }

  skeleton = SkeletonFromSlot(ModelFromAlias(.Zombie).skeleton_slot);
  if skeleton
  {
    for * skeleton.joint_masks
    {
      it.* = NewArray(skeleton.joints_count, bool);

      if it_index.(AnimationMask) == {
        case .ALL;
        SetMask("Root", true);

        case .ARMS;
        // SetMask("DEF-spine.003", true);

        case .HEAD;
        // SetMask("DEF-spine.001", true);
        // SetMask("DEF-shoulder.L", false);
        // SetMask("DEF-shoulder.R", false)
      }
    }
  }
}

#scope_file;
AN_ClipFromTag :: inline (skeleton: Skeleton, tag: AnimationTag) -> *AnimationClip
{
  // @todo handle multiple clips
  idx := skeleton.tag_to_sequence[tag].clip_idxs[0];
  return *skeleton.clips[idx];
}

AN_WrapTime :: inline (skeleton: Skeleton, tag: AnimationTag, t: float) -> float
{
  clip := AN_ClipFromTag(skeleton, tag);
  return WrapFloat(t, clip.t_min, clip.t_max);
}

AN_Time01ToAnimT :: inline (skeleton: Skeleton, tag: AnimationTag, t: float) -> float
{
  clip := AN_ClipFromTag(skeleton, tag);
  return (clip.t_max - clip.t_min) * t + clip.t_min;
}

AN_WaterfallToChildren :: ($mode: enum { MULTIPLY; ASSIGN; },
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
AN_IdxFromClipName :: (skeleton: Skeleton, name: string) -> index: s32, found: bool
{
  for skeleton.clips
  {
    if name == it.name
      return xx it_index, true;
  }
  log("AnimationData name not found: %", name, flags=.WARNING);
  return 0, false;
}

AN_JointNameToIndex :: (skeleton: Skeleton, name: string) -> index: u32, found: bool
{
  for skeleton.names
  {
    if name == it {
      return xx it_index, true;
    }
  }
  log("Joint name not found: %", name, flags=.WARNING);
  return 0, false;
}

//
// AnimationNode
//
NIL_AnimationNode :: AnimationNode.{}; // @todo alloc memory, setup self-ref ptrs, call VirtualProtect on it to make it read-only

IsNil :: (node: *AnimationNode) -> bool {
  return !node || node == *NIL_AnimationNode;
}

AN_AllocNode :: (prev_node: *AnimationNode = null) -> *AnimationNode
{
  result: *AnimationNode;
  l := *AN.per_lane[LaneIdx()];
  if l.free_nodes
  {
    result = l.free_nodes;
    l.free_nodes = l.free_nodes.next;
    Initialize(result);
  }
  else
  {
    result = New(AnimationNode);
  }

  result.prev = *NIL_AnimationNode;
  result.next = *NIL_AnimationNode;
  if !IsNil(prev_node) {
    AN_LinkNode(prev_node, result);
  }
  return result;
}

AN_FreeNode :: (node: *AnimationNode)
{
  AN_UnlinkNode(node);
  l := *AN.per_lane[LaneIdx()];
  node.next = l.free_nodes;
  l.free_nodes = node;
}

AN_LinkNode :: (prev_node: *AnimationNode, node: *AnimationNode)
{
  if !IsNil(prev_node.next)
  {
    node.next = prev_node.next;
    prev_node.next.prev = node;
  }
  node.prev = prev_node;
  prev_node.next = node;
}

AN_UnlinkNode :: (node: *AnimationNode)
{
  if !IsNil(node.prev)
  {
    node.prev.next = node.next;
  }
  if !IsNil(node.next)
  {
    node.next.prev = node.prev;
  }
  node.prev = *NIL_AnimationNode;
  node.next = *NIL_AnimationNode;
}

AN_LastNode :: (node: *AnimationNode) -> *AnimationNode
{
  while !IsNil(node.next)
  {
    node = node.next;
  }
  return node;
}
