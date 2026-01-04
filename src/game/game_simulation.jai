#scope_file;
using,only(SV) COMPS;
#scope_export;

TICK_RATE :: 100;
TICK_MILLISECONDS_STEP :: 1000 / TICK_RATE;
TICK_FLOAT_STEP :: 1.0 / TICK_RATE;

MINIMUM_MOVE_START_DISTANCE :: 0.05;
MELEE_ATTACK_DISTANCE :: 0.8;
PROJECTILE_HIT_DISTANCE :: 0.1;

SIM_AdvanceByTick :: ()
{
  PerfFunc();

  // Spawn sleepers
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
      minion := SV_CreateMinion(team);
      if !OBJ_IsNil(minion)
      {
        sign := ifx team == .RED then -1.0 else 1.0;
        minion.p.xy = V2.{-sign, sign} * V2.{28, 28}/3;
        minion.activity = .{
          wants_to_attack = true,
          target = SV_FindNearestToObject(minion, .{require_flags = .IS_TURRET, common2 = .ARE_ENEMIES}).key,
        };
      }
    }
  }

  // Update things
  for *obj: SV.objects
  {
    if OBJ_IsNil(obj) continue;

    // Clear dead objects' activity
    if !OBJ_Test(obj, .{require_flags = .HAS_ACTIVITY, common = .IS_ALIVE_OR_NO_HP}) {
      obj.activity = .{};
    }

    // Apply AI (if alive)
    if OBJ_Test(obj, .{require_flags = .HAS_ACTIVITY, common = .IS_ALIVE_OR_NO_HP})
    {
      if obj.key == SV.enemy0 || obj.key == SV.enemy1
      {
        obj.activity.is_walking = true;
        obj.activity.walking_to.x = 2.0;
        obj.activity.walking_to.y = 2.0;
        if (obj.key == SV.enemy1) obj.activity.walking_to.y += 1.0;
      }

      if obj.key == SV.enemy1 && !OBJ_KeyIsZero(SV.users[0].key)
      {
        obj.activity.wants_to_attack = true;
        obj.activity.target = SV.users[0].key;
      }
    }

    // Run UpdateStats
    SIM_UpdateStats(obj);
  }

  // User actions -> modify object's activity
  for * user: SV.users
  {
    player_object := SV_GetObject(user.key);
    if OBJ_IsNil(player_object) continue;
    SIM_ConsumeActions(user, player_object);
  }

  // Advance state machine
  for *obj: SV.objects
  {
    if OBJ_IsNil(obj) continue;
    inline SIM_UpdateActivity(obj);
    inline SIM_UpdateTurret(obj);
    inline SIM_UpdateTargetedProjectile(obj);
    inline SIM_UpdateDeath(obj);
    inline SIM_UpdateMove(obj);
    inline SIM_UpdateRotation(obj);
  }
}

SIM_UpdateStats :: (obj: *Object)
{
  if !(obj.flags & .UPDATE_STATS) return;

  // init stats with base_stats
  for * obj.stats.all {
    it.* = obj.base_stats.all[it_index];
  }

  // apply effects
  for * obj.effects
  {
    it.time_left -= TICK_FLOAT_STEP;
    if it.time_left <= 0.0 {
      remove it;
      continue;
    }

    if it.op == .ADD {
      obj.stats.all[it.stat] += it.value;
    }
  }

  // Reduce skill cooldowns
  for * obj.skills {
    it.cooldown_timer -= TICK_FLOAT_STEP;
  }

  // HP regen
  if OBJ_Test(obj, .{common = .IS_ALIVE}) {
    obj.health += obj.stats.health_regen * TICK_FLOAT_STEP;
    obj.energy += obj.stats.energy_regen * TICK_FLOAT_STEP;
  }

  // Clamp health/energy to max
  obj.health = min(obj.health, obj.stats.max_health);
  obj.energy = min(obj.energy, obj.stats.max_energy);
}

SIM_UpdateRotation :: (obj: *Object)
{
  if !OBJ_HasAllFlags(obj, .ANIMATE_ROTATION) return;
  if HasLength(obj.moved_dp) {
    obj.rotation = DirectionXYToRotationZ(obj.moved_dp);
  }
}

SIM_ConsumeActions :: (user: *SV_User, obj: *Object)
{
  if !OBJ_Test(obj, .{require_flags = .HAS_ACTIVITY, common = .IS_ALIVE_OR_NO_HP}) return;

  while true
  {
    action, did_pop := QueuePop(*user.action_queue);
    if (!did_pop) break;

    reset_pathing := false;
    reset_attack := false;

    // ATTACK
    if action.kind == .ATTACK
    {
      reset_pathing = true;
      obj.activity.wants_to_attack = true;

      if obj.activity.target != action.target
      {
        obj.activity.is_attacking = false;
        obj.activity.attack_t = min(obj.activity.attack_t, 0.0);
      }
      obj.activity.target = action.target;
    }

    // PATHING
    if action.kind == .PATHING
    {
      reset_attack = true;
      obj.activity.is_walking = true;
      obj.activity.walking_to = action.position.xy;
    }

    // STOP_PATHING
    if action.kind == .STOP_PATHING {
      reset_pathing = true;
    }

    // RESETING unused stuff (to be refactored in the future when skills are more complicated)
    if reset_pathing
    {
      obj.activity.is_walking = false;
      obj.activity.walking_to = .{};
    }

    if reset_attack
    {
      obj.activity.wants_to_attack = false;
      obj.activity.is_attacking = false;
      obj.activity.target = .{};
    }

    for * obj.skills
    {
      action_skill_index := action.kind - .SKILL_0;
      if (xx it_index != action_skill_index) continue;
      if (it.cooldown_timer > 0.0) continue; // on cooldown
      if (obj.energy < it.energy_cost) continue; // not enough energy

      // apply costs
      it.cooldown_timer = it.cooldown_cost;
      obj.energy -= it.energy_cost;

      // apply effects
      if it_index == {
        case 0;
        // projectile; fixed dp; set hp at something + negative hp regen... perfect!
        proj := SV_CreateObject(.MOVE | .DRAW_MODEL | .DISABLE_MOUSE | .HAS_HP |
                                .UPDATE_STATS | .DIE_ON_CONTACT | .DELETE_ON_DEATH);
        proj.p = obj.p;
        proj.p.z = 0.5;
        proj.model = .Carrot;
        proj.team = obj.team;
        proj.base_stats.max_health = 1;
        proj.base_stats.health_regen = -1;
        proj.health = proj.base_stats.max_health;
        proj.collider = OBJ_ColliderFromRect(.{0.5, 0.5});

        direction := normalize(action.position.xy - obj.p.xy);
        speed := 5.0;
        proj.desired_dp = .{direction.x, direction.y, 0} * TICK_FLOAT_STEP * speed;

        case 1;
        array_add(*obj.effects, .{
          op = .ADD, stat = .MOVE_SPEED,
          value = 5.0, time_left = 3.0,
        });

        case 2;
        array_add(*obj.effects, .{
          op = .ADD, stat = .MOVE_SPEED,
          value = 10.0, time_left = 5.0,
        });

        case 3;
        for obj.effects {
          if (it.stat == .MOVE_SPEED) remove it;
        }
      }
    }
  }
}

SIM_UpdateActivity :: (obj: *Object)
{
  if !OBJ_HasAnyFlag(obj, .HAS_ACTIVITY) return;

  // Reset desired_dp
  obj.desired_dp = .{};

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

    obj_speed := obj.stats.move_speed * TICK_FLOAT_STEP;
    obj_speed = min(obj_speed, distance);
    obj.desired_dp = V3.{xy = normalize(pathing_direction) * obj_speed, z = 0};
  }

  // Advance attack timers
  attack_t_delta := TICK_FLOAT_STEP * obj.stats.attack_speed;
  activity.attack_t += attack_t_delta;

  // advance visual_attack_t
  if activity.is_attacking {
    activity.visual_attack_t += attack_t_delta;
  }

  if activity.is_attacking
  {
    obj.rotation = DirectionXYToRotationZ(target.p - obj.p);

    while activity.attack_t >= obj.attack_landed_t
    {
      activity.attack_t -= obj.attack_cooldown_t;
      SIM_DealDamage(target, obj, 40.0);

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
    activity.visual_attack_t = WrapFloat01(activity.attack_t);
  }
}

SIM_UpdateTurret :: (turret: *Object)
{
  if !OBJ_Test(turret, .{require_flags = .IS_TURRET, common = .IS_ALIVE_OR_NO_HP}) return;

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

  attack_t_delta := TICK_FLOAT_STEP * turret.stats.attack_speed;
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
      // attack_target.health -= attack_damage;

      projectile := SV_CreateObject(.DRAW_MODEL | .TARGETED_PROJECTILE | .MANUAL_ROTATION);
      if !OBJ_IsNil(projectile)
      {
        projectile.model = .Potion;
        projectile.p.xy = turret.p.xy;
        projectile.p.z = 4.1;
        projectile.activity.target = attack_target.key;

        turret.activity.last_projectile = projectile.key;
      }

      SIM_PlaySound(attack_target, RngEnum_MinMaxClosed(*SV.rng, AUDIO_SoundType.SWISH01, .SWISH05));
    }
  }
  else
  {
    activity.attack_t = min(activity.attack_t, 0.0);
    activity.target = .{};
  };
}

SIM_UpdateTargetedProjectile :: (projectile: *Object)
{
  if !OBJ_HasAnyFlag(projectile, .TARGETED_PROJECTILE) return;
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
      SIM_DealDamage(target, projectile, 25.0);
      SV_DeleteObject(projectile); // @todo deletion happening instantly is dumb actually
    }
  }
}

SIM_UpdateDeath :: (obj: *Object)
{
  if OBJ_Test(obj, .{common = .IS_ALIVE_OR_NO_HP})
  {
    obj.death_tick = 0;
  }
  else // IS_DEAD
  {
    if !obj.death_tick then obj.death_tick = SV.tick;

    death_t := SecondsBetweenTicks(SV.tick, obj.death_tick);

    max_death_time := 0.0;
    if OBJ_HasAnyFlag(obj, .POST_DEATH_DELAY)
    {
      max_death_time = 4.0;
      obj.p.z = -clamp(death_t - 2.0, 0.0, 10.0);
    }

    if OBJ_HasAnyFlag(obj, .RESPAWN) && death_t >= max_death_time
    {
      obj.p = .{};
      obj.health = obj.stats.max_health;
      obj.death_tick = 0;
    }

    if OBJ_HasAnyFlag(obj, .DELETE_ON_DEATH) && death_t >= max_death_time
    {
      SV_DeleteObject(obj);
    }
  }
}

SIM_UpdateMove :: (obj: *Object)
{
  PerfFunc();
  if OBJ_IsNil(obj) {
    return;
  }

  skillshot_mode := OBJ_HasAnyFlag(obj, .DIE_ON_CONTACT);

  obj.moved_dp = .{};
  if !OBJ_Test(obj, .{require_flags = .MOVE, common = .IS_ALIVE_OR_NO_HP}) {
    return;
  }

  // movement simulation
  obj_dp := obj.desired_dp.xy;
  obj_pos := obj.p.xy + obj_dp; // move obj

  // check collision
  for collision_iteration: 0..2 // support up to 3 overlapping wall collisions
  {
    closest_obstacle := OBJ_NilObject();
    closest_obstacle_separation_dist := FLOAT32_MAX;
    closest_obstacle_wall_normal: V2;

    obj_collider := obj.collider;
    OBJ_OffsetCollider(*obj_collider, obj_pos);

    for * obstacle: SV.objects
    {
      if obj == obstacle continue;

      // Reject obstacles
      if skillshot_mode {
        if !OBJ_Test2(obstacle, obj, .{common = .IS_ALIVE, common2 = .ARE_ENEMIES}) {
          continue;
        }
      } else {
        if !OBJ_Test(obstacle, .{require_flags = .COLLIDE, common = .IS_ALIVE_OR_NO_HP}) {
          continue;
        }
      }

      obstacle_pos := obstacle.p.xy;

      // @todo temporary hacky perf. optimization. This should be based on obj vs collider bounding boxes.
      if distance_squared(obj_pos, obstacle_pos) >= square(1.0) {
        continue;
      }

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
          if dot(normal, obstacle_dir) < 0 {
            continue;
          }

          d := DistanceBetweenRanges(projection_obj.ranges[it], projection_obstacle.ranges[it]);
          if d > 0.0 {
            // @info(mg) We can exit early from checking this
            //   obstacle since we found an axis that has
            //   a separation between obj and obstacle.
            continue obstacle; // skip this obstacle
          }

          if d > biggest_dist {
            biggest_dist = d;
            wall_normal = -normal;
          }
        } // projection loop
      } // sat_iteration loop

      if closest_obstacle_separation_dist > biggest_dist {
        closest_obstacle = obstacle;
        closest_obstacle_separation_dist = biggest_dist;
        closest_obstacle_wall_normal = wall_normal;
      }
    } // obstacle loop

    if closest_obstacle_separation_dist < 0.0 {
      if skillshot_mode {
        SIM_DealDamage(closest_obstacle, obj, 20);
        obj.health = 0;
        return;
      }

      move_out_dir := closest_obstacle_wall_normal;
      move_out_magnitude := -closest_obstacle_separation_dist;
      move_out := move_out_dir * move_out_magnitude;
      obj_pos = obj_pos + move_out;

      // Remove all velocity on collision axis
      // We might want to do something different here in the future!
      if move_out.x obj_dp.x = 0;
      if move_out.y obj_dp.y = 0;
    } else {
      // Collision not found, stop iterating
      break;
    }
  } // collision_iteration loop

  prev_obj_pos := obj.p;
  obj.p.x = obj_pos.x;
  obj.p.y = obj_pos.y;
  obj.moved_dp = obj.p - prev_obj_pos;
  if length(obj.moved_dp) < 0.1 * MINIMUM_MOVE_START_DISTANCE * TICK_FLOAT_STEP { // some arbitary small number
    obj.moved_dp = .{}; // Other systems like animation should ignore these tiny movemements.
  }
}

SIM_PlaySound :: (obj: *Object, type: AUDIO_SoundType)
{
  QueuePush(*obj.sound_requests, .{SV.tick, type});
}
SIM_PlayAnimation :: (obj: *Object, tag: AnimationTag)
{
  QueuePush(*obj.animation_requests, .{SV.tick, tag});
}

SIM_DealDamage :: (target: *Object, source: *Object, amount: float)
{
  target.health -= amount;
  SIM_PlaySound(target, .HIT);
  SIM_PlayAnimation(target, .HIT);
}

SIM_InitObjects :: ()
{
  // Add turrets
  {
    for team: BOTH_TEAMS
    {
      for tier: 0..2
      {
        if tier != 0 continue;

        turret := SV_CreateObject(
          .COLLIDE | .DRAW_MODEL | .HAS_HP | .UPDATE_STATS | .TARGETABLE | .PLAY_SOUNDS |
          .IS_TURRET | .MANUAL_ROTATION | .MANUAL_POSITION);

        if !OBJ_IsNil(turret)
        {
          turret.team = team;

          p := 6.0 + 10.0*tier;
          if team == .RED then p = -p;
          turret.p = .{-p,p,0};

          dim := 0.4;
          turret.collider = OBJ_ColliderFromRect(.{dim,dim});

          turret.model = .Plank;

          turret.base_stats.max_health = 400;
          turret.base_stats.attack_speed = 2.5;
          turret.health = turret.base_stats.max_health;
          turret.attack_landed_t = 0.1;
          turret.attack_cooldown_t = 5.0;
        }
      }
    }
  }

  {
    hero := SV_CreateHero(.Dude, .RED);
    SV.enemy0 = hero.key;
    if !OBJ_IsNil(hero)
    {
      hero.p.x = 3.0;
      hero.p.y = 1.0;
    }

    hero = SV_CreateHero(.Dude, .RED);
    SV.enemy1 = hero.key;
    if !OBJ_IsNil(hero)
    {
      hero.p.x = 3.2;
      hero.p.y = 2.0;
    }

    hero = SV_CreateHero(.Dude, .BLUE);
    if !OBJ_IsNil(hero)
    {
      hero.p.x = 3.4;
      hero.p.y = 3.0;
    }
  }
}
