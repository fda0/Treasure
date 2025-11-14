TICK_RATE :: 200;
TICK_MILLISECONDS_STEP :: 1000 / TICK_RATE;
TICK_FLOAT_STEP :: 1.0 / TICK_RATE;

MINIMUM_MOVE_START_DISTANCE :: 0.05;
MELEE_ATTACK_DISTANCE :: 0.8;
PROJECTILE_HIT_DISTANCE :: 0.1;

PlayerInput :: struct
{
  type: enum
  {
    IDLE;
    PATHING;
    ATTACK;
    SKILL_Q;
  }

  world_p: V3; // used by PATHING*
  target_object: OBJ_Key; // used by ATTACK

  skills: enum_flags u8 { Q; W; E; R; }
}

SIM_AdvanceByTick :: ()
{
  PerfFunc();
  assert(context.role == .SERVER);

  if SecondsBetweenTicks(SV.tick, SV.last_sleeper_group_spawn, false) >= 40.0
  {
    SV.sleepers_spawned_in_group_count = 0;
    SV.last_sleeper_group_spawn = SV.tick;
  }

  if SV.sleepers_spawned_in_group_count < 5 &&
     SecondsBetweenTicks(SV.tick, SV.last_sleeper_spawn, false) >= 0.5
  {
    SV.last_sleeper_spawn = SV.tick;
    SV.sleepers_spawned_in_group_count += 1;

    for team: BOTH_TEAMS
    {
      sleeper := SV_CreateObject(.MOVE | .COLLIDE | .DRAW_MODEL | .ANIMATE_ROTATION |
         .ANIMATE_TRACKS | .HAS_HP | .TARGETABLE | .PLAY_SOUNDS | .HAS_ACTIVITY | .DELETE_ON_DEATH);
      if !OBJ_IsNil(sleeper)
      {
        sleeper.model = ModelKey("Zombie");
        sleeper.hp = 60.0;
        sleeper.max_hp = 60.0;
        dim := 0.3;
        sleeper.collider = OBJ_ColliderFromRect(.{dim,dim});

        sign := ifx team == .RED then -1.0 else 1.0;
        sleeper.p.xy = V2.{-sign, sign} * V2.{28, 28}/3;

        sleeper.team = team;

        sleeper.activity = .{
          wants_to_attack = true,
          target = SV_FindNearestToObject(sleeper, .{require_flags = .IS_TURRET, common2 = .ARE_ENEMIES}).key,
        };
      }
    }
  }

  // temporary - player health regen
  for SV.users
  {
    player := SV_GetObject(it.key);
    if !OBJ_Test(player, .{common = .IS_ALIVE }) continue;
    player.hp = min(player.hp + TICK_FLOAT_STEP * 20.0, player.max_hp);
  }

  // transfer input to player objects
  for *SV.users
  {
    player := SV_GetObject(it.key);
    if OBJ_IsNil(player) continue;

    input := SV_GetNextPlayerInput(it);
    SIM_ApplyInputsToObject(player, input);
  }

  // Advance state machine
  for *obj: SV.objects
  {
    SIM_ProcessActivity(obj);
  }

  for *turret: SV.objects
  {
    if !OBJ_Test(turret, .{require_flags = .IS_TURRET, common = .IS_ALIVE_OR_NO_HP}) continue;
    activity := *turret.activity;

    valid_enemy_test := OBJ_TestParams.{
      require_flags = .TARGETABLE,
      reject_flags = .IS_TURRET,
      common = .IS_ALIVE,
      common2 = .ARE_ENEMIES,
    };

    attack_target := SV_GetObject(activity.target);
    nearest_target := SV_FindNearestToObject(turret, valid_enemy_test);

    SHOOT_RANGE :: 4.0;

    if !OBJ_Test(attack_target, valid_enemy_test)
    {
      attack_target = OBJ_NilObject();
    }
    if !OBJ_IsNil(attack_target)
    {
      dist_sq := OBJ_Distance2DSquared(turret, attack_target);
      if square(SHOOT_RANGE) < dist_sq then attack_target = OBJ_NilObject();
    }
    if OBJ_IsNil(attack_target) && !OBJ_IsNil(nearest_target)
    {
      dist_sq := OBJ_Distance2DSquared(turret, nearest_target);
      if square(SHOOT_RANGE) >= dist_sq then attack_target = nearest_target;
    }

    activity.target = attack_target.key;
    activity.is_attacking = !OBJ_IsNil(attack_target);

    attack_t_delta := TICK_FLOAT_STEP * turret.attack_speed;
    if OBJ_IsNil(SV_GetObject(activity.last_projectile))
    {
      additional_delta := TICK_FLOAT_STEP * 100.0;
      // delta is applied only if turret is on cooldown
      additional_delta = min(additional_delta, -activity.attack_t);
      additional_delta = max(additional_delta, 0.0);
      attack_t_delta += additional_delta;
    }

    activity.attack_t += attack_t_delta;
    activity.visual_attack_t += attack_t_delta;

    if activity.is_attacking
    {
      attack_damage := 16.0;

      while activity.attack_t >= turret.attack_landed_t
      {
        activity.attack_t -= turret.attack_cooldown_t;
        // attack_target.hp -= attack_damage;

        projectile := SV_CreateObject(.DRAW_MODEL | .TARGETED_PROJECTILE | .MANUAL_ROTATION);
        if !OBJ_IsNil(projectile)
        {
          projectile.model = ModelKey("Potion");
          projectile.p.xy = turret.p.xy;
          projectile.p.z = 4.1;
          projectile.activity.target = attack_target.key;

          turret.activity.last_projectile = projectile.key;
        }

        SIM_PlaySound(attack_target, RngEnum_MinMaxClosed(*G.rng, AUDIO_SoundType.SWISH01, .SWISH05));
      }
    }
    else
    {
      activity.attack_t = min(activity.attack_t, 0.0);
      activity.target = .{};
    }
  }

  for *projectile: SV.objects
  {
    if !OBJ_HasAnyFlag(projectile, .TARGETED_PROJECTILE) continue;
    activity := *projectile.activity;

    target := SV_GetObject(activity.target);
    if OBJ_IsNil(target)
    {
      SV_DeleteObject(projectile);
    }
    else
    {
      apply_hit := false;

      // move projectile
      target_p := target.p;
      target_p.z = 1.0;

      gap := target_p - projectile.p;
      gap_length := length(gap);

      fly_speed := 1.0 + 5.0*min(1.0, SecondsBetweenTicks(SV.tick, projectile.creation_tick));
      fly_speed *= TICK_FLOAT_STEP;

      if gap_length > 0.0
      {
        direction := gap * (1.0 / gap_length);
        projectile_shift := direction * min(fly_speed, gap_length);
        projectile.p += projectile_shift;
      }
      else apply_hit = true;

      // test for hit in 2D
      dist_2d_sq := OBJ_Distance2DSquared(target, projectile);
      apply_hit |= dist_2d_sq <= square(PROJECTILE_HIT_DISTANCE);

      if apply_hit
      {
        attack_damage := 25.0;
        target.hp -= attack_damage;
        SIM_PlaySound(target, .HIT);
        SV_DeleteObject(projectile);
      }
    }
  }

  for *obj: SV.objects
  {
    if OBJ_IsNil(obj) continue;
    if OBJ_Test(obj, .{common = .IS_ALIVE_OR_NO_HP})
    {
      obj.death_tick = 0;
    }
    else // IS_DEAD
    {
      if !obj.death_tick then obj.death_tick = SV.tick;

      death_t := SecondsBetweenTicks(SV.tick, obj.death_tick);

      if OBJ_HasAnyFlag(obj, .DELETE_ON_DEATH | .RESPAWN)
      {
        obj.p.z = -clamp(death_t - 2.0, 0.0, 10.0);
      }

      if OBJ_HasAnyFlag(obj, .RESPAWN) && death_t > 4.0
      {
        obj.p = .{};
        obj.hp = obj.max_hp;
        obj.death_tick = 0;
      }

      if OBJ_HasAnyFlag(obj, .DELETE_ON_DEATH) && death_t > 4.0
      {
        SV_DeleteObject(obj);
      }

    }
  }

  SIM_MoveAndCollideObjects();

  for *obj: SV.objects
  {
    if OBJ_HasAllFlags(obj, .ANIMATE_ROTATION)
    {
      if HasLength(obj.moved_dp)
        obj.rotation = DirectionXYToRotationZ(obj.moved_dp);
    }
  }
}

SIM_ApplyInputsToObject :: (obj: *Object, input: PlayerInput)
{
  if OBJ_IsNil(obj) return;

  obj.desired_dp = .{};
  activity := *obj.activity;

  if !OBJ_Test(obj, .{common = .IS_ALIVE_OR_NO_HP})
  {
    activity.* = .{};
    return;
  }

  if input.skills & .Q
  {
    // @todo launch a skillshot projectile
  }

  if input.skills & .W
  {
    obj.move_speed += 2.0;
  }

  if input.skills & .E
  {
    // @todo blink somewhere and deal dmg
  }

  // ATTACK yes/no
  if input.type == .ATTACK
  {
    activity.wants_to_attack = true;

    if activity.target != input.target_object
    {
      activity.is_attacking = false;
      activity.attack_t = min(activity.attack_t, 0.0);
    }
    activity.target = input.target_object;
  }
  if input.type != .ATTACK
  {
    activity.wants_to_attack = false;
    activity.is_attacking = false;
    activity.target = .{};
  }

  // PATHING yes/no
  pathing_direction: V2;
  if input.type == .PATHING
  {
    activity.is_walking = true;
    activity.walking_to = input.world_p.xy;
  }
  if input.type != .PATHING
  {
    activity.is_walking = false;
    activity.walking_to = .{};
  }
}

SIM_ProcessActivity :: (obj: *Object)
{
  if OBJ_IsNil(obj) return;
  if !OBJ_HasAnyFlag(obj, .HAS_ACTIVITY) return;
  activity := *obj.activity;

  // Find attack target (and invalidate if needed)
  target := OBJ_NilObject();
  if activity.wants_to_attack || activity.is_attacking
  {
    activity.is_walking = false;

    target = SV_GetObject(activity.target);
    target_is_valid_enemy := OBJ_Test2(target, obj, .{common = .IS_ALIVE, common2 = .ARE_ENEMIES});
    if !target_is_valid_enemy
    {
      target = OBJ_NilObject();
      activity.target = .{};
      activity.is_attacking = false;
    }
  }

  // Check if attack is in range; if not start moving
  attack_is_out_of_range := true;
  if !OBJ_IsNil(target) && activity.wants_to_attack
  {
    obj_to_target := target.p.xy - obj.p.xy;
    distance_to_target := length(obj_to_target);
    attack_is_out_of_range = distance_to_target > MELEE_ATTACK_DISTANCE;

    activity.is_walking = !activity.is_attacking && attack_is_out_of_range;
    if activity.is_walking
    {
      activity.walking_to = target.p.xy;
    }

    if !attack_is_out_of_range
    {
      activity.is_attacking = true;
    }
  }

  assert(!(activity.is_attacking && activity.is_walking));

  // Find pathing direction
  pathing_direction: V2;
  if activity.is_walking
  {
    obj_to_destination := activity.walking_to - obj.p.xy;
    distance := length(obj_to_destination);
    if distance >= MINIMUM_MOVE_START_DISTANCE then pathing_direction = obj_to_destination;

    obj_speed := obj.move_speed * TICK_FLOAT_STEP;
    obj.desired_dp = V3.{xy = normalize(pathing_direction) * obj_speed, z = 0};
  }
  else
  {
    obj.desired_dp = .{};
  }

  // Advance attack timers
  attack_t_delta := TICK_FLOAT_STEP * obj.attack_speed;
  activity.attack_t += attack_t_delta;

  // advance visual_attack_t
  if activity.is_attacking
  {
    activity.visual_attack_t += attack_t_delta;
  }
  else
  {
    if activity.visual_attack_t != 0.0
    {
      wrapped := WrapFloat(obj.attack_cooldown_t, activity.visual_attack_t, 0.0);
      dir := ifx wrapped >= obj.attack_landed_t then 1.0 else -1.0;
      activity.visual_attack_t += dir * attack_t_delta;

      wrapped2 := WrapFloat(activity.visual_attack_t, 0.0, obj.attack_cooldown_t);
      dir2 := ifx wrapped2 >= obj.attack_landed_t then 1.0 else -1.0;

      if (dir != dir2) activity.visual_attack_t = 0.0;
    }
  }

  if activity.is_attacking
  {
    obj.rotation = DirectionXYToRotationZ(target.p - obj.p);

    attack_damage := 10.0;
    while activity.attack_t >= obj.attack_landed_t
    {
      activity.attack_t -= obj.attack_cooldown_t;
      target.hp -= attack_damage;

      SIM_PlayAnimation(target, .HIT);
      SIM_PlaySound(target, .HIT);

      stop_attacking := false;
      stop_attacking |= attack_is_out_of_range;
      stop_attacking |= !OBJ_Test(target, .{common = .IS_ALIVE});
      if stop_attacking
      {
        activity.is_attacking = false;
        break;
      }
    }

  }
  if !activity.is_attacking
  {
    activity.attack_t = min(activity.attack_t, 0.0);
  }
}

SIM_MoveAndCollideObjects :: ()
{
  PerfFunc();
  for * obj: SV.objects
  {
    if !OBJ_Test(obj, .{require_flags = .MOVE, common = .IS_ALIVE_OR_NO_HP}) continue;

    // movement simulation
    obj_dp := obj.desired_dp.xy;
    obj_pos := obj.p.xy + obj_dp; // move obj

    // check collision
    for collision_iteration: 0..2 // support up to 3 overlapping wall collisions
    {
      closest_obstacle_separation_dist := FLOAT32_MAX;
      closest_obstacle_wall_normal: V2;

      obj_collider := obj.collider;
      OBJ_OffsetCollider(*obj_collider, obj_pos);

      for * obstacle: SV.objects
      {
        if obj == obstacle continue;
        if !OBJ_Test(obstacle, .{require_flags = .COLLIDE, common = .IS_ALIVE_OR_NO_HP}) continue;

        obstacle_pos := obstacle.p.xy;

        // @todo temporary hacky perf. optimization. This should be based on obj vs collider bounding boxes.
        if distance_squared(obj_pos, obstacle_pos) >= square(1.0) continue;

        obstacle_collider := obstacle.collider;
        OBJ_OffsetCollider(*obstacle_collider, obstacle_pos);

        biggest_dist := -FLOAT32_MAX;
        wall_normal: V2;

        // @info(mg) SAT algorithm needs 2 iterations
        // from the perspective of the obj
        // and from the perspective of the obstacle.
        for sat_iteration: 0..1
        {
          normal_source := ifx sat_iteration == 0 then obstacle_collider else obj_collider;

          projection_obj := OBJ_CalculateColliderProjection(normal_source, obj_collider);
          projection_obstacle := OBJ_CalculateColliderProjection(normal_source, obstacle_collider);

          for MakeRange(projection_obj.ranges.count)
          {
            normal := normal_source.normals[it];
            obstacle_dir := obstacle_pos - obj_pos;
            if dot(normal, obstacle_dir) < 0
            continue;

            d := DistanceBetweenRanges(projection_obj.ranges[it], projection_obstacle.ranges[it]);
            if d > 0.0
            {
              // @info(mg) We can exit early from checking this
              //   obstacle since we found an axis that has
              //   a separation between obj and obstacle.
              continue obstacle; // skip this obstacle
            }

            if d > biggest_dist
            {
              biggest_dist = d;
              wall_normal = -normal;
            }
          } // projection loop
        } // sat_iteration loop

        if closest_obstacle_separation_dist > biggest_dist
        {
          closest_obstacle_separation_dist = biggest_dist;
          closest_obstacle_wall_normal = wall_normal;
        }
      } // obstacle loop

      if closest_obstacle_separation_dist < 0.0
      {
        move_out_dir := closest_obstacle_wall_normal;
        move_out_magnitude := -closest_obstacle_separation_dist;
        move_out := move_out_dir * move_out_magnitude;
        obj_pos = obj_pos + move_out;

        // Remove all velocity on collision axis
        // We might want to do something different here in the future!
        if move_out.x obj_dp.x = 0;
        if move_out.y obj_dp.y = 0;
      }
      else
      {
        // Collision not found, stop iterating
        break;
      }
    } // collision_iteration loop

    prev_obj_pos := obj.p;
    obj.p.x = obj_pos.x;
    obj.p.y = obj_pos.y;
    obj.moved_dp = obj.p - prev_obj_pos;
    if length(obj.moved_dp) < 0.1 * MINIMUM_MOVE_START_DISTANCE * TICK_FLOAT_STEP // some arbitary small number
      obj.moved_dp = .{}; // Other systems like animation should ignore these tiny movemements.
  } // obj loop
}


SIM_PlaySound :: (obj: *Object, type: AUDIO_SoundType)
{
  QueuePush(*obj.sound_requests, .{SV.tick, type});
}
SIM_PlayAnimation :: (obj: *Object, type: ANIMATION_Type)
{
  QueuePush(*obj.animation_requests, .{SV.tick, type});
}
