TICK_RATE :: 100;
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
  assert(GAME_ServerEnabled());

  if ServerSecondsSinceServerTick(G.last_sleeper_group_spawn, false) >= 40.0
  {
    G.sleepers_spawned_in_group_count = 0;
    G.last_sleeper_group_spawn = GetServerTick();
  }

  if G.sleepers_spawned_in_group_count < 5 &&
     ServerSecondsSinceServerTick(G.last_sleeper_spawn, false) >= 0.5
  {
    G.last_sleeper_spawn = GetServerTick();
    G.sleepers_spawned_in_group_count += 1;

    for team: BOTH_TEAMS
    {
      sleeper := OBJ_Create(.NETWORK,
        .MOVE | .COLLIDE | .DRAW_MODEL | .ANIMATE_ROTATION | .ANIMATE_TRACKS |
        .HAS_HP | .TARGETABLE | .PLAY_SOUNDS | .HAS_ACTIVITY | .DELETE_ON_DEATH);
      if !OBJ_IsNil(sleeper)
      {
        sleeper.s.model = ModelKey("Zombie");
        sleeper.s.hp = 60.0;
        sleeper.s.max_hp = 60.0;
        dim := 0.3;
        sleeper.s.collider = OBJ_ColliderFromRect(.{dim,dim});

        sign := ifx team == .RED then -1.0 else 1.0;
        sleeper.s.p.xy = V2.{-sign, sign} * V2.{28, 28}/3;

        sleeper.s.team = team;

        sleeper.s.state_machine = .{
          wants_to_attack = true,
          target = OBJ_FindNearestToObj(sleeper, .NETWORK,
            .{require_flags = .IS_TURRET, common2 = .ARE_ENEMIES}).s.key,
        };

        zxczxc := 10;
        zxczxc+= 1;
      }
    }
  }

  // temporary - player health regen
  for G.server.users
  {
    player := OBJ_Get(.NETWORK, it.key);
    if !OBJ_Test(player, .{common = .IS_ALIVE }) continue;
    player.s.hp = min(player.s.hp + TICK_FLOAT_STEP * 20.0, player.s.max_hp);
  }

  // transfer input to player objects
  for *G.server.users
  {
    player := OBJ_Get(.NETWORK, it.key);
    if OBJ_IsNil(player) continue;

    input := SERVER_GetNextPlayerInput(it);
    SIM_ApplyInputsToObject(player, input);
  }

  // Advance state machine
  for *obj: context.R.obj.network_objects
  {
    SIM_ProcessStateMachine(obj);
  }

  for *turret: context.R.obj.network_objects
  {
    if !OBJ_Test(turret, .{require_flags = .IS_TURRET, common = .IS_ALIVE_OR_NO_HP}) continue;
    state_machine := *turret.s.state_machine;

    valid_enemy_test := OBJ_TestParams.{
      require_flags = .TARGETABLE,
      reject_flags = .IS_TURRET,
      common = .IS_ALIVE,
      common2 = .ARE_ENEMIES,
    };

    attack_target := OBJ_Get(.NETWORK, state_machine.target);
    nearest_target := OBJ_FindNearestToObj(turret, .NETWORK, valid_enemy_test);

    SHOOT_RANGE :: 4.0;

    if !OBJ_Test(attack_target, valid_enemy_test)
    {
      attack_target = OBJ_GetNil();
    }
    if !OBJ_IsNil(attack_target)
    {
      dist_sq := OBJ_Distance2DSquared(turret, attack_target);
      if square(SHOOT_RANGE) < dist_sq then attack_target = OBJ_GetNil();
    }
    if OBJ_IsNil(attack_target) && !OBJ_IsNil(nearest_target)
    {
      dist_sq := OBJ_Distance2DSquared(turret, nearest_target);
      if square(SHOOT_RANGE) >= dist_sq then attack_target = nearest_target;
    }

    state_machine.target = attack_target.s.key;
    state_machine.is_attacking = !OBJ_IsNil(attack_target);

    attack_t_delta := TICK_FLOAT_STEP * turret.s.attack_speed;
    if OBJ_IsNil(OBJ_Get(.NETWORK, state_machine.last_projectile))
    {
      additional_delta := TICK_FLOAT_STEP * 100.0;
      // delta is applied only if turret is on cooldown
      additional_delta = min(additional_delta, -state_machine.attack_t);
      additional_delta = max(additional_delta, 0.0);
      attack_t_delta += additional_delta;
    }

    state_machine.attack_t += attack_t_delta;
    state_machine.visual_attack_t += attack_t_delta;

    if state_machine.is_attacking
    {
      attack_damage := 16.0;

      while state_machine.attack_t >= turret.s.attack_landed_t
      {
        state_machine.attack_t -= turret.s.attack_cooldown_t;
        // attack_target.s.hp -= attack_damage;

        projectile := OBJ_Create(.NETWORK, .DRAW_MODEL | .TARGETED_PROJECTILE | .MANUAL_ROTATION);
        if !OBJ_IsNil(projectile)
        {
          projectile.s.model = ModelKey("Potion");
          projectile.s.p.xy = turret.s.p.xy;
          projectile.s.p.z = 4.1;
          projectile.s.state_machine.target = attack_target.s.key;

          turret.s.state_machine.last_projectile = projectile.s.key;
        }

        OBJ_PlaySound(attack_target, RngEnum_MinMaxClosed(*G.rng, AUDIO_SoundType.SWISH01, .SWISH05));
      }
    }
    else
    {
      state_machine.attack_t = min(state_machine.attack_t, 0.0);
      state_machine.target = .{};
    }
  }

  for *projectile: context.R.obj.network_objects
  {
    if !OBJ_HasAnyFlag(projectile, .TARGETED_PROJECTILE) continue;
    state_machine := *projectile.s.state_machine;

    target := OBJ_Get(.NETWORK, state_machine.target);
    if OBJ_IsNil(target)
    {
      OBJ_Delete(projectile);
    }
    else
    {
      apply_hit := false;

      // move projectile
      target_p := target.s.p;
      target_p.z = 1.0;

      gap := target_p - projectile.s.p;
      gap_length := length(gap);

      fly_speed := 1.0 + 5.0*min(1.0, ElapsedSeconds(projectile.s.creation_time));
      fly_speed *= TICK_FLOAT_STEP;

      if gap_length > 0.0
      {
        direction := gap * (1.0 / gap_length);
        projectile_shift := direction * min(fly_speed, gap_length);
        projectile.s.p += projectile_shift;
      }
      else apply_hit = true;

      // test for hit in 2D
      dist_2d_sq := OBJ_Distance2DSquared(target, projectile);
      apply_hit |= dist_2d_sq <= square(PROJECTILE_HIT_DISTANCE);

      if apply_hit
      {
        attack_damage := 25.0;
        target.s.hp -= attack_damage;
        OBJ_PlaySound(target, .HIT);
        OBJ_Delete(projectile);
      }
    }
  }

  for *obj: context.R.obj.network_objects
  {
    if OBJ_IsNil(obj) continue;
    if OBJ_Test(obj, .{common = .IS_ALIVE_OR_NO_HP})
    {
      obj.s.death_time = 0;
    }
    else // IS_DEAD
    {
      if !obj.s.death_time then obj.s.death_time = GetTimestamp();

      death_t := ElapsedSeconds(obj.s.death_time);

      if OBJ_HasAnyFlag(obj, .DELETE_ON_DEATH | .RESPAWN)
      {
        obj.s.p.z = -clamp(death_t - 2.0, 0.0, 10.0);
      }

      if OBJ_HasAnyFlag(obj, .RESPAWN) && death_t > 4.0
      {
        obj.s.p = .{};
        obj.s.hp = obj.s.max_hp;
        obj.s.death_time = 0;
      }

      if OBJ_HasAnyFlag(obj, .DELETE_ON_DEATH) && death_t > 4.0
      {
        OBJ_Delete(obj);
      }

    }
  }

  SIM_MoveAndCollideObjects();

  for * obj: context.R.obj.all_objects
  {
    if OBJ_HasAllFlags(obj, .ANIMATE_ROTATION)
    {
      if HasLength(obj.s.moved_dp)
        obj.s.rotation = DirectionXYToRotationZ(obj.s.moved_dp);
    }
  }
}

SIM_ApplyInputsToObject :: (obj: *Object, input: PlayerInput)
{
  if OBJ_IsNil(obj) return;

  obj.s.desired_dp = .{};
  state_machine := *obj.s.state_machine;

  if !OBJ_Test(obj, .{common = .IS_ALIVE_OR_NO_HP})
  {
    state_machine.* = .{};
    return;
  }

  if input.skills & .Q
  {
    // @todo launch a skillshot projectile
  }

  if input.skills & .W
  {
    obj.s.move_speed += 2.0;
  }

  if input.skills & .E
  {
    // @todo blink somewhere and deal dmg
  }

  // ATTACK yes/no
  if input.type == .ATTACK
  {
    state_machine.wants_to_attack = true;

    if state_machine.target != input.target_object
    {
      state_machine.is_attacking = false;
      state_machine.attack_t = min(state_machine.attack_t, 0.0);
    }
    state_machine.target = input.target_object;
  }
  if input.type != .ATTACK
  {
    state_machine.wants_to_attack = false;
    state_machine.is_attacking = false;
    state_machine.target = .{};
  }

  // PATHING yes/no
  pathing_direction: V2;
  if input.type == .PATHING
  {
    state_machine.is_walking = true;
    state_machine.walking_to = input.world_p.xy;
  }
  if input.type != .PATHING
  {
    state_machine.is_walking = false;
    state_machine.walking_to = .{};
  }
}

SIM_ProcessStateMachine :: (obj: *Object)
{
  if OBJ_IsNil(obj) return;
  if !OBJ_HasAnyFlag(obj, .HAS_ACTIVITY) return;
  state_machine := *obj.s.state_machine;

  // Find attack target (and invalidate if needed)
  target := OBJ_GetNil();
  if state_machine.wants_to_attack || state_machine.is_attacking
  {
    state_machine.is_walking = false;

    target = OBJ_Get(.NETWORK, state_machine.target);
    target_is_valid_enemy := OBJ_Test2(target, obj, .{common = .IS_ALIVE, common2 = .ARE_ENEMIES});
    if !target_is_valid_enemy
    {
      target = OBJ_GetNil();
      state_machine.target = .{};
      state_machine.is_attacking = false;
    }
  }

  // Check if attack is in range; if not start moving
  attack_is_out_of_range := true;
  if !OBJ_IsNil(target) && state_machine.wants_to_attack
  {
    obj_to_target := target.s.p.xy - obj.s.p.xy;
    distance_to_target := length(obj_to_target);
    attack_is_out_of_range = distance_to_target > MELEE_ATTACK_DISTANCE;

    state_machine.is_walking = !state_machine.is_attacking && attack_is_out_of_range;
    if state_machine.is_walking
    {
      state_machine.walking_to = target.s.p.xy;
    }

    if !attack_is_out_of_range
    {
      state_machine.is_attacking = true;
    }
  }

  assert(!(state_machine.is_attacking && state_machine.is_walking));

  // Find pathing direction
  pathing_direction: V2;
  if state_machine.is_walking
  {
    obj_to_destination := state_machine.walking_to - obj.s.p.xy;
    distance := length(obj_to_destination);
    if distance >= MINIMUM_MOVE_START_DISTANCE then pathing_direction = obj_to_destination;

    obj_speed := obj.s.move_speed * TICK_FLOAT_STEP;
    obj.s.desired_dp = V3.{xy = normalize(pathing_direction) * obj_speed, z = 0};
  }
  else
  {
    obj.s.desired_dp = .{};
  }

  // Advance attack timers
  attack_t_delta := TICK_FLOAT_STEP * obj.s.attack_speed;
  state_machine.attack_t += attack_t_delta;

  // advance visual_attack_t
  if state_machine.is_attacking
  {
    state_machine.visual_attack_t += attack_t_delta;
  }
  else
  {
    if state_machine.visual_attack_t != 0.0
    {
      wrapped := WrapFloat(0.0, obj.s.attack_cooldown_t, state_machine.visual_attack_t);
      dir := ifx wrapped >= obj.s.attack_landed_t then 1.0 else -1.0;
      state_machine.visual_attack_t += dir * attack_t_delta;

      wrapped2 := WrapFloat(0.0, obj.s.attack_cooldown_t, state_machine.visual_attack_t);
      dir2 := ifx wrapped2 >= obj.s.attack_landed_t then 1.0 else -1.0;

      if (dir != dir2) state_machine.visual_attack_t = 0.0;
    }
  }

  if state_machine.is_attacking
  {
    obj.s.rotation = DirectionXYToRotationZ(target.s.p - obj.s.p);

    attack_damage := 10.0;
    while state_machine.attack_t >= obj.s.attack_landed_t
    {
      state_machine.attack_t -= obj.s.attack_cooldown_t;
      target.s.hp -= attack_damage;

      OBJ_PlayAnimation(target, .HIT);
      OBJ_PlaySound(target, .HIT);

      stop_attacking := false;
      stop_attacking |= attack_is_out_of_range;
      stop_attacking |= !OBJ_Test(target, .{common = .IS_ALIVE});
      if stop_attacking
      {
        state_machine.is_attacking = false;
        break;
      }
    }

  }
  if !state_machine.is_attacking
  {
    state_machine.attack_t = min(state_machine.attack_t, 0.0);
  }
}

SIM_MoveAndCollideObjects :: ()
{
  PerfFunc();
  for * obj: context.R.obj.network_objects
  {
    if !OBJ_Test(obj, .{require_flags = .MOVE, common = .IS_ALIVE_OR_NO_HP}) continue;

    // movement simulation
    obj_dp := obj.s.desired_dp.xy;
    obj_pos := obj.s.p.xy + obj_dp; // move obj

    // check collision
    for collision_iteration: 0..2 // support up to 3 overlapping wall collisions
    {
      closest_obstacle_separation_dist := FLOAT32_MAX;
      closest_obstacle_wall_normal: V2;

      obj_collider := obj.s.collider;
      OBJ_OffsetCollider(*obj_collider, obj_pos);

      for * obstacle: context.R.obj.network_objects
      {
        if obj == obstacle continue;
        if !OBJ_Test(obstacle, .{require_flags = .COLLIDE, common = .IS_ALIVE_OR_NO_HP}) continue;

        obstacle_pos := obstacle.s.p.xy;

        // @todo temporary hacky perf. optimization. This should be based on obj vs collider bounding boxes.
        if distance_squared(obj_pos, obstacle_pos) >= square(1.0) continue;

        obstacle_collider := obstacle.s.collider;
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

    prev_obj_pos := obj.s.p;
    obj.s.p.x = obj_pos.x;
    obj.s.p.y = obj_pos.y;
    obj.s.moved_dp = obj.s.p - prev_obj_pos;
    if length(obj.s.moved_dp) < 0.1 * MINIMUM_MOVE_START_DISTANCE * TICK_FLOAT_STEP // some arbitary small number
      obj.s.moved_dp = .{}; // Other systems like animation should ignore these tiny movemements.
  } // obj loop
}
