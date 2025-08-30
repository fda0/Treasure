TICK_RATE :: 100;
TICK_MILLISECONDS_STEP :: 1000 / TICK_RATE;
TICK_FLOAT_STEP :: 1.0 / TICK_RATE;

TICK_Iterate :: ()
{
  #assert((1000 % TICK_MILLISECONDS_STEP) == 0);
  #assert((1000 / TICK_MILLISECONDS_STEP) == TICK_RATE);
  tick_count := G.tick_timestamp_accumulator / TICK_MILLISECONDS_STEP;
  G.tick_timestamp_accumulator -= tick_count * TICK_MILLISECONDS_STEP;

  for MakeRange(tick_count)
  {
    G.tick_number += 1;

    if NET_IsServer()
    {
      if tick_count > 1
      {
        log("Server is falling behind! Ticks clamped from % to 1. This avoids server death-spiral but causes simulation slowdown.", tick_count);
        tick_count = min(tick_count, 1);
      }
      TICK_AdvanceSimulation();
    }

    if NET_IsClient()
    {
      TICK_Playback();
      if G.client.playable_tick_deltas.tick_catchup > 0
      {
        G.client.playable_tick_deltas.tick_catchup -= 1;
        TICK_Playback();
      }
    }
  }
}

MINIMUM_MOVE_START_DISTANCE :: 0.05;
MELEE_ATTACK_DISTANCE :: 0.8;
PROJECTILE_HIT_DISTANCE :: 0.1;

TICK_AdvanceSimulation :: ()
{
  reset_attack_timers :: (obj: *Object)
  {
    obj.s.target = .{};
    obj.s.attack_t = min(obj.s.attack_t, 0.0);
    obj.s.attack_continous_t = 0.0;
  }

  if ServerSecondsSinceServerTick(G.last_sleeper_group_spawn, false) >= 15.0
  {
    G.sleepers_spawned_in_group_count = 0;
    G.last_sleeper_group_spawn = GetTick();
  }

  if G.sleepers_spawned_in_group_count < 5 &&
     ServerSecondsSinceServerTick(G.last_sleeper_spawn, false) >= 0.5
  {
    G.last_sleeper_spawn = GetTick();
    G.sleepers_spawned_in_group_count += 1;

    for team: BOTH_TEAMS
    {
      sleeper := OBJ_Create(.NETWORK,
        .MOVE | .COLLIDE | .DRAW_MODEL | .ANIMATE_ROTATION | .ANIMATE_TRACKS |
        .HAS_HP | .TARGETABLE | .PLAY_SOUNDS | .HAS_ACTION | .DELETE_ON_DEATH);
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

        sleeper.s.action = .{
          type = .ATTACK,
          target_object = OBJ_FindNearestToObj(sleeper, .NETWORK,
            .{require_flags = .IS_TURRET, common2 = .ARE_ENEMIES}).s.key,
        };
      }
    }
  }

  // temporary - player health regen
  for player_key: G.server.player_keys
  {
    player := OBJ_Get(.NETWORK, player_key);
    if !OBJ_Test(player, .{common = .IS_ALIVE }) continue;
    player.s.hp = min(player.s.hp + TICK_FLOAT_STEP * 60.0, player.s.max_hp);
  }

  // transfer action to player objects
  for player_key, player_index: G.server.player_keys
  {
    player := OBJ_Get(.NETWORK, player_key);
    if OBJ_IsNil(player) continue;
    action := SERVER_GetPlayerAction(xx player_index);
    player.s.action = action;
  }

  // apply actions
  for *obj: G.obj.network_objects
  {
    if OBJ_IsNil(obj) continue;
    if !OBJ_HasAnyFlag(obj, .HAS_ACTION) continue;

    obj.s.desired_dp = .{};
    if !OBJ_Test(obj, .{common = .IS_ALIVE }) continue;

    action := obj.s.action;

    if action.type == .ATTACK
    {
      targets_enemy := OBJ_Test2(OBJ_Get(.NETWORK, action.target_object), obj, .{common2 = .ARE_ENEMIES});
      if !targets_enemy then action.type = .PATHING;
    }

    obj_move_dir: V2;
    if action.type == .PATHING ||
       action.type == .PATHING_DIRECTION
    {
      obj_to_destination := action.world_p.xy - obj.s.p.xy;
      distance := length(obj_to_destination);
      if distance >= MINIMUM_MOVE_START_DISTANCE then obj_move_dir = obj_to_destination * (1.0 / distance);
    }

    // Advance attack timers
    attack_t_delta := TICK_FLOAT_STEP * obj.s.attack_speed;
    obj.s.attack_t += attack_t_delta;
    obj.s.attack_continous_t += attack_t_delta;

    if action.type != .ATTACK
      obj.s.is_attacking = false;

    // Handle action type .ATTACK
    if action.type == .ATTACK
    {
      if obj.s.target != action.target_object
      {
        reset_attack_timers(obj);
        obj.s.is_attacking = false;
      }

      obj.s.target = action.target_object;

      if obj.s.attack_t >= 0.0
        obj.s.is_attacking = true;

      attacked := OBJ_Get(.NETWORK, action.target_object);
      if !OBJ_IsNil(attacked)
      {
        obj_to_destination := attacked.s.p.xy - obj.s.p.xy;
        distance := length(obj_to_destination);

        if distance < MELEE_ATTACK_DISTANCE
        {
          obj.s.rotation = DirectionXYToRotationZ(attacked.s.p - obj.s.p);

          attack_damage := 10.0;
          while obj.s.attack_t >= obj.s.attack_landed_t
          {
            obj.s.attack_t -= obj.s.attack_cooldown_t;
            attacked.s.hp -= attack_damage;

            OBJ_PlayAnimation(attacked, .HIT);
            OBJ_PlaySound(attacked, .HIT);
          }
        }
        else if distance >= MINIMUM_MOVE_START_DISTANCE
        {
          obj_move_dir = obj_to_destination * (1.0 / distance);
          obj.s.is_attacking = false;
        }
      }
    }

    if !obj.s.is_attacking
      reset_attack_timers(obj);

    // Move obj
    obj_speed := 1.4 * TICK_FLOAT_STEP;
    obj.s.desired_dp = V3.{xy = obj_move_dir * obj_speed, z = 0};
  }

  for *turret: G.obj.network_objects
  {
    if !OBJ_HasAnyFlag(turret, .IS_TURRET) continue;

    alive_only_filter :: (o: *Object) -> bool
    {
      return o.s.hp > 0.0;
    }

    valid_enemy_test := OBJ_TestParams.{
      require_flags = .TARGETABLE,
      reject_flags = .IS_TURRET,
      common = .IS_ALIVE,
      common2 = .ARE_ENEMIES,
    };

    attack_target := OBJ_Get(.NETWORK, turret.s.target);
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

    turret.s.target = attack_target.s.key;
    turret.s.is_attacking = !OBJ_IsNil(attack_target);

    attack_t_delta := TICK_FLOAT_STEP * turret.s.attack_speed;
    if OBJ_IsNil(OBJ_Get(.NETWORK, turret.s.last_projectile))
    {
      additional_delta := TICK_FLOAT_STEP * 100.0;
      // delta is applied only if turret is on cooldown
      additional_delta = min(additional_delta, -turret.s.attack_t);
      additional_delta = max(additional_delta, 0.0);
      attack_t_delta += additional_delta;
    }

    turret.s.attack_t += attack_t_delta;
    turret.s.attack_continous_t += attack_t_delta;

    if turret.s.is_attacking
    {
      attack_damage := 16.0;

      while turret.s.attack_t >= turret.s.attack_landed_t
      {
        turret.s.attack_t -= turret.s.attack_cooldown_t;
        // attack_target.s.hp -= attack_damage;

        projectile := OBJ_Create(.NETWORK, .DRAW_MODEL | .TARGETED_PROJECTILE | .MANUAL_ROTATION);
        if !OBJ_IsNil(projectile)
        {
          projectile.s.model = ModelKey("Potion");
          projectile.s.p.xy = turret.s.p.xy;
          projectile.s.p.z = 4.1;
          projectile.s.target = attack_target.s.key;

          turret.s.last_projectile = projectile.s.key;
        }

        OBJ_PlaySound(attack_target, RngEnum_MinMaxClosed(*G.rng, AUDIO_SoundType.SWISH01, .SWISH05));
      }
    }
    else
    {
      reset_attack_timers(turret);
    }
  }

  for *projectile: G.obj.network_objects
  {
    if !OBJ_HasAnyFlag(projectile, .TARGETED_PROJECTILE) continue;

    target := OBJ_Get(.NETWORK, projectile.s.target);
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

  for *obj: G.obj.network_objects
  {
    if OBJ_IsNil(obj) continue;
    if OBJ_Test(obj, .{common = .IS_ALIVE})
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

  TICK_MoveAndCollideObjects();

  for * obj: G.obj.all_objects
  {
    if OBJ_HasAllFlags(obj, .ANIMATE_ROTATION)
    {
      if HasLength(obj.s.moved_dp)
        obj.s.rotation = DirectionXYToRotationZ(obj.s.moved_dp);
    }
  }
}

TICK_MoveAndCollideObjects :: ()
{
  for * obj: G.obj.network_objects
  {
    if !OBJ_HasAnyFlag(obj, .MOVE) continue;

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

      for * obstacle: G.obj.network_objects
      {
        if obj == obstacle continue;
        if !OBJ_HasAnyFlag(obstacle, .COLLIDE) continue;

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

TICK_Playback :: ()
{
  smallest_latest_server_tick: u64 = U64_MAX;
  biggest_oldest_server_tick: u64 = 0;
  for snap: G.client.snaps_of_objs
  {
    if snap.latest_server_tick < smallest_latest_server_tick
      smallest_latest_server_tick = snap.latest_server_tick;

    if snap.oldest_server_tick > biggest_oldest_server_tick
      biggest_oldest_server_tick = snap.oldest_server_tick;
  }

  if biggest_oldest_server_tick > G.client.next_playback_tick
  {
    Nlog(LOG_NetTick, #run String.join(
      "Server is too ahead from the client;",
      "biggest_oldest_server_tick: %,",
      "smallest_latest_server_tick: %,",
      "client's next_playback_tick: %,",
      "playback delay: %,",
      "playback catchup %,",
      "[bumping client's next_playback_tick]"),
      biggest_oldest_server_tick,
      smallest_latest_server_tick,
      G.client.next_playback_tick,
      G.client.current_playback_delay,
      G.client.playable_tick_deltas.tick_catchup);

    G.client.next_playback_tick = biggest_oldest_server_tick;
  }

  if smallest_latest_server_tick < G.client.next_playback_tick
  {
    Nlog(LOG_NetTick, #run String.join(
      "Ran out of tick playback state; ",
      "next_playback_tick: %, ",
      "smallest_latest_server_tick: %, ",
      "playback delay: %, ",
      "playback catchup %"),
      G.client.next_playback_tick,
      smallest_latest_server_tick,
      G.client.current_playback_delay,
      G.client.playable_tick_deltas.tick_catchup);
    return;
  }

  // calc current delay
  {
    current_playback_delay_u64 := smallest_latest_server_tick - G.client.next_playback_tick;
    G.client.current_playback_delay = CastSaturate(u16, current_playback_delay_u64);
  }

  if TickDeltas_AddTick(*G.client.playable_tick_deltas, smallest_latest_server_tick)
  {
    TickDeltas_UpdateCatchup(*G.client.playable_tick_deltas, G.client.current_playback_delay);
    if G.client.playable_tick_deltas.tick_catchup
    {
      Nlog(LOG_NetCatchup, "Current playback delay: %d,  Setting playback catchup to %d",
        G.client.current_playback_delay, G.client.playable_tick_deltas.tick_catchup);
    }
  }

  for net_index: MakeRange(OBJ_MAX_NETWORK_OBJECTS.(u32))
  {
    interpolated_sync := CLIENT_LerpObjSync(net_index, G.client.next_playback_tick);
    net_obj := OBJ_FromNetIndex(net_index);
    net_obj.s = interpolated_sync;
  }
  G.client.next_playback_tick += 1;
}
