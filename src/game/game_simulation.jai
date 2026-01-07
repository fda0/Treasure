#scope_file;
using,only(SV) COMPS;
#scope_export;

TICK_RATE :: 100;
TICK_MILLISECONDS_STEP :: 1000 / TICK_RATE;
TICK_FLOAT_STEP :: 1.0 / TICK_RATE;


ATTACK_COOLDOWN_T :: 1.0;
MINIMUM_MOVE_START_DISTANCE :: 0.05;
PROJECTILE_HIT_DISTANCE :: 0.1;

SIM_AdvanceByTick :: ()
{
  PerfFunc();

  SIM_SpawnObjects();

  // Update buildings
  for * team: SV.teams
  {
    prev_turret_is_dead := true;
    for team.turrets
    {
      turret := SV_GetObject(it);
      if !OBJ_IsNil(turret)
      {
        if prev_turret_is_dead {
          turret.flags &= ~(.CANT_DAMAGE);
        }
      }
      prev_turret_is_dead = OBJ_IsNil(turret) || OBJ_Test(turret, .{common = .IS_DEAD});
    }
  }

  // User actions -> modify object's activity
  for * user: SV.users
  {
    user_object := SV_GetObject(user.key);
    if OBJ_IsNil(user_object) continue;
    SIM_ConsumeActions(user, user_object);
  }

  // Advance state machine
  for *obj: SV.objects
  {
    if OBJ_IsNil(obj) continue;
    SIM_UpdateAI(obj);
    SIM_UpdateStats(obj);
    SIM_UpdateActivity(obj);
    SIM_UpdateTargetedProjectile(obj);
    SIM_UpdateDeath(obj);
    SIM_UpdateMove(obj);
    SIM_UpdateRotation(obj);
  }
}

SIM_SpawnObjects :: ()
{
  // Spawn minons
  if SecondsBetweenTicks(SV.tick, SV.last_minon_group_spawn, false) >= 40.0
  {
    SV.minons_spawned_in_group_count = 0;
    SV.last_minon_group_spawn = SV.tick;
  }

  if SV.minons_spawned_in_group_count < 5 &&
     SecondsBetweenTicks(SV.tick, SV.last_minon_spawn, false) >= 0.5
  {
    SV.last_minon_spawn = SV.tick;
    SV.minons_spawned_in_group_count += 1;

    for team: BOTH_TEAMS
    {
      minion := SV_CreateMinion(team);
      if !OBJ_IsNil(minion)
      {
        sign := ifx team == .RED then -1.0 else 1.0;
        minion.p.xy = V2.{-sign, sign} * V2.{28, 28}/3;
      }
    }
  }
}

SIM_UpdateAI :: (obj: *Object)
{
  if !OBJ_Test(obj, .{require_flags = .UPDATE_AI, common = .IS_ALIVE_OR_NO_HP}) {
    return;
  }

  if obj.key == SV.enemy0 || obj.key == SV.enemy1
  {
    obj.activity.is_walking = true;
    obj.activity.walking_to.x = 2.0;
    obj.activity.walking_to.y = 2.0;
    if (obj.key == SV.enemy1) obj.activity.walking_to.y += 1.0;
  }

  if obj.key == SV.enemy0 && !OBJ_KeyIsZero(SV.users[0].key)
  {
    obj.activity.wants_to_attack = true;
    obj.activity.target = SV.users[0].key;
  }

  if obj.model == .Zombie
  {
    target_params := OBJ_TestParams.{
      require_flags = .IS_TURRET,
      reject_flags = .CANT_DAMAGE,
      common = .IS_ALIVE,
      common2 = .ARE_ENEMIES
    };

    obj.activity.target = SV_FindNearestToObject(obj, target_params).key;
    obj.activity.wants_to_attack = !OBJ_KeyIsZero(obj.activity.target);
  }

  // Turrets
  if OBJ_HasAnyFlag(obj, .IS_TURRET)
  {
    valid_enemy_test := OBJ_TestParams.{
      require_flags = .TARGETABLE,
      reject_flags = .IS_TURRET,
      common = .IS_ALIVE,
      common2 = .ARE_ENEMIES,
    };

    if !obj.activity.is_attacking
    {
      nearest_target := SV_FindNearestToObject(obj, valid_enemy_test);
      if !OBJ_IsNil(nearest_target)
      {
        obj.activity.target = nearest_target.key;
        obj.activity.wants_to_attack = true;
      }
    }
  }
}

SIM_UpdateStats :: (obj: *Object)
{
  if !(obj.flags & .UPDATE_STATS) return;

  // init stats with base_stats
  memcpy(*obj.stats, *obj.base_stats, size_of(type_of(obj.stats)));

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

    if OBJ_Test(obj, .{common = .IS_DEAD}) {
      return;
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
        if !OBJ_IsNil(proj)
        {
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
        }

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

  // Clear dead objects' activity
  if OBJ_Test(obj, .{common = .IS_DEAD}) {
    activity.* = .{};
    return;
  }

  // Find attack target (and invalidate if needed)
  target := OBJ_NilObject();
  if activity.wants_to_attack || activity.is_attacking
  {
    activity.is_walking = false;

    target = SV_GetObject(activity.target);
    target_is_valid_enemy := OBJ_Test2(target, obj, .{reject_flags = .CANT_DAMAGE, common = .IS_ALIVE, common2 = .ARE_ENEMIES});
    if !target_is_valid_enemy
    {
      target = OBJ_NilObject();
      activity.target = .{};
      activity.is_attacking = false;
    }
  }

  // Check if attack is in range; if not start moving
  attack_is_out_of_range := true;
  if !OBJ_IsNil(target) && activity.wants_to_attack || activity.is_attacking
  {
    obj_to_target := target.p.xy - obj.p.xy;
    distance_to_target := length(obj_to_target);
    attack_is_out_of_range = distance_to_target > obj.stats.attack_range;

    activity.is_walking = attack_is_out_of_range;
    if activity.is_walking {
      activity.walking_to = target.p.xy;
      activity.is_attacking = false;
    }

    if !attack_is_out_of_range {
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

    while activity.attack_t >= obj.stats.attack_landed_t
    {
      activity.attack_t -= ATTACK_COOLDOWN_T;

      if OBJ_HasAnyFlag(obj, .RANGED_ATTACKS)
      {
        projectile := SV_CreateObject(.DRAW_MODEL | .TARGETED_PROJECTILE | .UPDATE_STATS | .MANUAL_ROTATION);
        if !OBJ_IsNil(projectile)
        {
          projectile.model = .Potion;
          projectile.p.xy = obj.p.xy;
          projectile.p.z = 4.1;
          projectile.activity.target = activity.target;
          projectile.base_stats.attack_damage = obj.stats.attack_damage;
          activity.last_projectile = projectile.key;
        }
      }
      else
      {
        SIM_DealDamage(target, obj, 20.0);
      }

      stop_attacking := false;
      stop_attacking |= attack_is_out_of_range; // @todo not needed here anymore?
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
      SIM_DealDamage(target, projectile, projectile.stats.attack_damage);
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
      obj.energy = obj.stats.max_energy;
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
    for team, team_index: BOTH_TEAMS
    {
      for tier: 0..2
      {
        turret := SV_CreateObject(
          .COLLIDE | .DRAW_MODEL | .DRAW_BARS | .HAS_HP | .UPDATE_AI | .UPDATE_STATS | .TARGETABLE | .PLAY_SOUNDS |
          .IS_TURRET | .HAS_ACTIVITY | .MANUAL_ROTATION | .MANUAL_POSITION | .RANGED_ATTACKS | .CANT_DAMAGE);
        SV.teams[team_index].turrets[tier] = turret.key;

        if !OBJ_IsNil(turret)
        {
          turret.team = team;

          p := 6.0 + 8.0*tier;
          if team == .RED then p = -p;
          turret.p = .{-p,p,0};

          dim := 0.4;
          turret.collider = OBJ_ColliderFromRect(.{dim,dim});

          turret.model = .Plank;

          turret.base_stats.max_health = 400;
          turret.base_stats.attack_speed = 0.6;
          turret.base_stats.attack_range = 4.0;
          turret.base_stats.attack_landed_t = 0.5;
          turret.base_stats.attack_damage = 20.0;

          turret.health = turret.base_stats.max_health;
        }
      }

      base := SV_CreateObject(.COLLIDE | .DRAW_MODEL | .DRAW_BARS | .HAS_HP | .UPDATE_STATS | .TARGETABLE | .PLAY_SOUNDS);
      if !OBJ_IsNil(base)
      {
        base.team = team;

        p := 6.0 + 22.0;
        if team == .RED then p = -p;
        base.p = .{-p,p,0};

        dim := 0.5;
        base.collider = OBJ_ColliderFromRect(.{dim,dim});
        base.model = .Dummy;
        base.base_stats.max_health = 400;
        base.health = base.base_stats.max_health;
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
