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
  tags: [AnimationTag_COUNT] AnimationTagInfo;
  joint_masks: [AnimationMask_COUNT] AnimationJointMask; // @todo 1compress with bit vector thing
}

AnimationTag :: enum u8
{
  IDLE;
  WALK;
  RUN;
  PUNCH;
  JAB;
  DEATH;
  HIT;

  // SPELL;
  // SPELL_ENTER;
  // SPELL_IDLE;
  // SPELL_EXIT;
}
AnimationTag_COUNT :: #run EnumCount(AnimationTag);

AnimationMask :: enum u8
{
  ALL;
  ARMS;
  HEAD;
}
AnimationMask_COUNT :: #run EnumCount(AnimationMask);

AnimationJointMask :: #type [] bool;

AnimationTagInfo :: struct
{
  clip: *AnimationClip;
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
    WRAP_T; // wrap overflow
    PLAYER_SLIDESHOW; // advance to next player idx on finished animation
    REMOVE_WHEN_FINISHED;
  }

  next, prev: *AnimationNode;
}

AnimationTrack :: struct
{
  weight: float;
  t: float;
  tag: AnimationTag;
  joint_mask: AnimationJointMask; // @todo replace with bitvector thing
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
      death := AN_AllocNode(attack);

      idle.weight = 1.0;
      idle.tag = .IDLE;
      idle.flags = .DENORMALIZE_T | .WRAP_T;

      walk.tag = .WALK;
      walk.flags = .WRAP_T;

      run.tag = .RUN;
      run.flags = .WRAP_T;

      attack.tag = .PUNCH;
      attack.flags = .DENORMALIZE_T | .WRAP_T;

      death.tag = .DEATH;
    }

    idle := ghost.anim.node;
    walk := idle.next;
    run := walk.next;
    attack := run.next;
    death := AN_NodeBeforeDeath(attack).next;

    DISTANCE_TO_WALK_ANIMATION_COEFFICIENT :: 0.016;
    WALK_TO_RUN_COEFFICIENT :: 0.2;

    // idle_cycle
    idle.t = WrapFloat(idle.t + G.dt*0.4, 0, 1);

    // walk_cycle
    moved_distance := length(ghost.moved_dp);
    meters_per_second := moved_distance * TICK_RATE;
    moved_cycle_delta := meters_per_second * DISTANCE_TO_WALK_ANIMATION_COEFFICIENT;
    walk.t = WrapFloat(walk.t + moved_cycle_delta, 0, 100);
    run.t = walk.t * WALK_TO_RUN_COEFFICIENT;

    // walk / run weight
    walk.weight += G.dt * 10.0 * BoolSign(meters_per_second > 0.0);
    run.weight += G.dt * 10.0 * BoolSign(meters_per_second > 3.0);
    walk.weight = clamp01(walk.weight);
    run.weight = clamp01(run.weight);

    // attack weight
    attack.t = activity.visual_attack_t;
    if activity.is_attacking {
      attack.weight += G.dt * 5.0;
    }
    if !activity.is_attacking && attack.t < 0.01 {
      attack.weight -= G.dt * 2.0;
    }
    attack.weight = clamp01(attack.weight);

    // death weight / time
    death.t = Elapsed(G.frame_timestamp, ghost.death_time);
    death.weight = clamp01(death.weight + G.dt*4.0*BoolSign(death.t > 0.0));

    for ghost.animation_requests
    {
      if IsTickDue(it.tick, ghost)
      {
        node := AN_AllocNode(AN_NodeBeforeDeath(attack));
        node.tag = it.tag;
        node.flags = .INCREMENT_T | .INCREMENT_WEIGHT | .REMOVE_WHEN_FINISHED;
      }
    }

    skeleton: *Skeleton;
    model := ModelFromAlias(ghost.model);
    if (model.is_skinned) skeleton = SkeletonFromSlot(model.skeleton_slot);

    {
      node := ghost.anim.node;
      while !IsNil(node)
      {
        next_node := node.next;
        defer node = next_node;

        if node.flags & .INCREMENT_T
        {
          node.t += G.dt;
        }

        if node.flags & .INCREMENT_WEIGHT
        {
          node.weight = clamp01(node.weight + G.dt);
        }

        if node.flags & .REMOVE_WHEN_FINISHED && skeleton
        {
          clip := skeleton.tags[node.tag].clip;
          if node.t >= clip.t_max
          {
            AN_FreeNode(node);
            continue;
          }
        }
      }
    }
  }
}

AN_GetTracks :: (ghost: Ghost) -> tracks: [] AnimationTrack
{
  model := ModelFromAlias(ghost.model);
  if !model.is_skinned return .[];

  skeleton := SkeletonFromSlot(model.skeleton_slot);
  push_allocator(temp);
  tracks: [..] AnimationTrack;

  // Nodes -> Tracks
  {
    node := ghost.anim.node;
    while !IsNil(node)
    {
      defer node = node.next;
      if (node.weight == 0.0) continue;

      clip := skeleton.tags[node.tag].clip;

      track := array_add(*tracks);
      track.weight = node.weight;
      track.t = node.t;
      track.tag = node.tag;

      if node.flags & .DENORMALIZE_T
      {
        range := clip.t_max - clip.t_min;
        track.t = track.t * range + clip.t_min;
      }

      if node.flags & .WRAP_T
      {
        track.t = WrapFloat(track.t, clip.t_min, clip.t_max);
      }

      mask := skeleton.tags[track.tag].mask;
      track.joint_mask = array_copy(skeleton.joint_masks[mask]);
    }
  }

  // When weight of an upper layer is equal to 1.0 - the layers below become masked-off.
  // This loop will back-propagate `false` values into joint_masks of lower layers.
  for < upper_idx: MakeRange(tracks.count)
  {
    if (tracks[upper_idx].weight < 1.0) continue;

    for lower_idx: MakeRange(upper_idx)
    {
      for mask_idx: MakeRange(tracks[0].joint_mask.count)
      {
        if tracks[upper_idx].joint_mask[mask_idx] == true {
          tracks[lower_idx].joint_mask[mask_idx] = false;
        }
      }
    }
  }

  // Mark weight as 0 (dead) if joints are all false.
  for * tracks
  {
    all_joints_are_false := true;
    for it.joint_mask
    {
      if it == true
      {
        all_joints_are_false = false;
        break;
      }
    }
    if all_joints_are_false {
      it.weight = 0.0;
    }
  }

  return tracks;
}

AN_GetPoseTransforms :: (skeleton: Skeleton, tracks: [] AnimationTrack) -> [] Mat4
{
  PerfFunc();

  push_allocator(temp);
  result_matrices := NewArray(skeleton.joints_count, Mat4);

  auto_release_temp();
  accumulated_scales       := array_copy(skeleton.bind_scales);
  accumulated_rotations    := array_copy(skeleton.bind_rotations);
  accumulated_translations := array_copy(skeleton.bind_translations);

  // mix default rest pose + animation channels using temporary memory
  first_loop := true;
  for track: tracks
  {
    if (track.weight == 0.0) continue;
    defer first_loop = false;

    auto_release_temp();
    scales := ifx first_loop then accumulated_scales else array_copy(skeleton.bind_scales);
    rotations := ifx first_loop then accumulated_rotations else array_copy(skeleton.bind_rotations);
    translations := ifx first_loop then accumulated_translations else array_copy(skeleton.bind_translations);

    // Overwrite translations, rotations, scales with values from animation
    clip := skeleton.tags[track.tag].clip;
    track_time := clamp(track.t, clip.t_min, clip.t_max);

    for channel: clip.channels
    {
      if !track.joint_mask[channel.joint_index] {
        continue;
      }

      t := 1.0;
      sample_start: u32;
      sample_end: u32;
      // find t, sample_start, sample_end
      {
        // @speed binary search might be faster?
        for channel.inputs
        {
          if it >= track_time {
            break;
          }
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
          t = (track_time - time_start) / time_range;
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

        if channel.type == .Translation {
          translations[channel.joint_index] = value;
        } else {
          scales[channel.joint_index] = value;
        }
      }
    }

    if !first_loop
    {
      for MakeRange(skeleton.joints_count)
      {
        if !track.joint_mask[it] {
          continue;
        }
        accumulated_scales[it]       = lerp(accumulated_scales[it],       scales[it],       track.weight);
        accumulated_rotations[it]    = Slerp(accumulated_rotations[it],   rotations[it],    track.weight);
        accumulated_translations[it] = lerp(accumulated_translations[it], translations[it], track.weight);
      }
    }
  }

  // Calculate final result matrices
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

      if #complete it_index.(AnimationMask) == {
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

    for * skeleton.tags
    {
      if #complete it_index.(AnimationTag) == {
        case .IDLE;  it.clip = AN_ClipFromName(skeleton, "Idle_Loop");
        case .WALK;  it.clip = AN_ClipFromName(skeleton, "Walk_Loop");
        case .RUN;   it.clip = AN_ClipFromName(skeleton, "Jog_Fwd_Loop");
        case .PUNCH; it.* = .{AN_ClipFromName(skeleton, "Punch_Cross"), .ARMS};
        case .JAB;   it.* = .{AN_ClipFromName(skeleton, "Punch_Jab"), .ARMS};
        case .DEATH; it.clip = AN_ClipFromName(skeleton, "Death01");
        case .HIT;   it.* = .{AN_ClipFromName(skeleton, "Hit_Head"), .HEAD};
      }
    }
  }

  skeleton = SkeletonFromSlot(ModelFromAlias(.Zombie).skeleton_slot);
  if skeleton
  {
    for * skeleton.joint_masks
    {
      it.* = NewArray(skeleton.joints_count, bool);

      if #complete it_index.(AnimationMask) == {
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

    for * skeleton.tags
    {
      if #complete it_index.(AnimationTag) == {
        case .IDLE;  it.clip = AN_ClipFromName(skeleton, "Idle");
        case .WALK;  it.clip = AN_ClipFromName(skeleton, "Walk");
        case .RUN;   it.clip = AN_ClipFromName(skeleton, "Run");
        case .PUNCH; it.clip = AN_ClipFromName(skeleton, "Punch");
        case .JAB;   it.clip = AN_ClipFromName(skeleton, "Punch");
        case .DEATH; it.clip = AN_ClipFromName(skeleton, "Death");
        case .HIT;   it.clip = AN_ClipFromName(skeleton, "HitReact");
      }
    }
  }
}

NIL_AnimationNode :: AnimationNode.{}; // @todo alloc memory, setup self-ref ptrs, call VirtualProtect on it to make it read-only
IsNil :: (node: *AnimationNode) -> bool {
  return !node || node == *NIL_AnimationNode;
}

#scope_file;
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
AN_ClipFromName :: (skeleton: Skeleton, name: string) -> *AnimationClip
{
  for * skeleton.clips
  {
    if name == it.name {
      return it;
    }
  }
  log("AnimationData name not found: %", name, flags=.WARNING);
  return *skeleton.clips[0];
}

AN_JointNameToIndex :: (skeleton: Skeleton, name: string) -> index: u32
{
  for skeleton.names
  {
    if name == it {
      return xx it_index;
    }
  }
  log("Joint name not found: %", name, flags=.WARNING);
  return 0;
}

//
// AnimationNode
//
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

AN_NodeBeforeDeath :: (node: *AnimationNode) -> *AnimationNode
{
  // return a node that's last or before death
  while !IsNil(node.next) && node.next.tag != .DEATH {
    node = node.next;
  }
  return node;
}
