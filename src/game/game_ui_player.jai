#scope_file;
using,only(G) COMPS;
#scope_export;

#scope_file;
using BOX;
HUD_BG    :: #run PackedBGR(0x14_18_24);
BUTTON_BG :: #run PackedBGR(0x1C_27_48);
BUTTON_BG_INACTIVE :: #run PackedBGR(0x30_30_30);
BUTTON_BG_FLASH :: #run PackedBGR(0x4C_57_98);
HEALTH_FG :: #run PackedBGR(/*0x1C_a7_48*/ 0x27_96_26);
ENERGY_FG :: #run PackedBGR(0x9C_97_28);
TEXT_FG :: #run PackedBGR(0xcf_cf_cf);
TEXT_COOLDOWN :: #run PackedBGR(0x9f_9f_9f);
GAP_SIZE  :: #run Rem(0.5);
PADDING :: #run PaddingAll(GAP_SIZE);
#scope_export;

UI_BuildHUD :: ()
{
  button_dim := 3.5;

  Layer(.{text = .{font = xx FONT_Family.Inconsolata, font_size = Rem(1), color = TEXT_FG}});

  ff0 :: #bake_arguments formatFloat(trailing_width = 0);
  ff1 :: #bake_arguments formatFloat(trailing_width = 1);
  ff1n :: #bake_arguments formatFloat(trailing_width = 1, zero_removal = .NO);

  hud := CreateBox(.{layout.size.min = Fit2(),
                     layout.padding = PADDING,
                     layout.child_gap = GAP_SIZE,
                     layout.child_order = .TOP_TO_BOTTOM,
                     floating.attach_to = .ROOT,
                     floating.anchors = GetAnchor2(.CENTER, .BOTTOM)});
  Parent(hud);

  player := G_GetGhost(.SHARED, G.player_key);



  // effect tooltips
  {
    Parent(CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Fit()},
                       layout.child_gap = GAP_SIZE}));

    for player.effects
    {
      Parent(CreateBox(.{layout.size.min = Fit2(), bg_color = HUD_BG}));
      label := tprint("MS %", ff1n(it.time_left));
      CreateText(label, .{layout.padding = PADDING});
    }
  }


  background := CreateBox(.{layout.size.min = Fit2(),
                            layout.padding = PADDING,
                            layout.child_gap = GAP_SIZE,
                            layout.child_order = .TOP_TO_BOTTOM,
                            bg_color = HUD_BG});
  Parent(background);


  // skills
  {
    skill_buttons := CreateBox(.{layout = .{size.min = Fit2(), size.pref.x = Grow(),
                                            padding = PaddingH(Rem(button_dim)),
                                            child_gap = GAP_SIZE, child_align.x = .CENTER}});
    Parent(skill_buttons);

    for player.skills
    {
      skill_label := string.["Q", "W", "E", "R"][it_index];

      cooldown := max(0.0, it.cooldown_timer);

      bg_color := PackedLerp(BUTTON_BG, BUTTON_BG_INACTIVE, min(cooldown*8, 1.0));
      bg_color = PackedLerp(bg_color, BUTTON_BG_FLASH, Smoothstep(it.cooldown_timer, 0.2, 0.1) * Smoothstep(it.cooldown_timer, 0.0, 0.1));

      button := CreateBox(.{layout.size.min = Rem2(button_dim), bg_color = bg_color});
      Parent(button);

      Layer(.{text.font_size = Rem(0.9)});

      CreateText(skill_label,
                 .{floating.attach_to = .PARENT, floating.offset = Rem2(.{0.25, -0.25}),
                   floating.anchors = GetAnchor2(.LEFT, .BOTTOM)});

      cooldown_color := PackedSetAlphaF(TEXT_FG, Smoothstep(it.cooldown_timer, -0.1, 0.2));
      CreateText(tprint("%", ceil(cooldown)),
                 .{text.color = cooldown_color,
                   text.font_size = Rem(1.4),
                   floating.attach_to = .PARENT,
                   floating.anchors = GetAnchor2(.CENTER, .CENTER)});

      CreateText(tprint("%", it.cooldown_cost),
                 .{text.color = TEXT_COOLDOWN,
                   floating.attach_to = .PARENT, floating.offset = Rem2(-0.25),
                   floating.anchors = GetAnchor2(.RIGHT, .BOTTOM)});

      CreateText(tprint("%", it.energy_cost),
                 .{text.color = ENERGY_FG,
                   floating.attach_to = .PARENT, floating.offset = Rem2(.{-0.25, 0.25}),
                   floating.anchors = GetAnchor2(.RIGHT, .TOP)});
    }
  }


  // health / energy bar
  {
    health_ratio := SafeDiv(player.health, player.stats.max_health);
    energy_ratio := SafeDiv(player.energy, player.stats.max_energy);

    style_left := BoxSpec.{floating = .{attach_to = .PARENT,
      anchors = GetAnchor2(.LEFT, .CENTER),
      offset = Rem2(.{0.1, 0.01})}};

    style_right := style_left;
    style_right.floating.anchors = GetAnchor2(.RIGHT, .CENTER);
    style_right.floating.offset.x *= -1;

    {
      Parent(CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Rem(1.0)}, bg_color = BUTTON_BG}));
      CreateBox(.{layout.size = .{pref.x = Pct(health_ratio), pref.y = Grow()}, bg_color = HEALTH_FG});

      left := tprint("% / %", ff0(player.health), ff0(player.stats.max_health));
      CreateText(left, style_left);

      right := tprint("+%", ff1n(player.stats.health_regen));
      CreateText(right, style_right);
    }
    {
      Parent(CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Rem(1.0)}, bg_color = BUTTON_BG}));
      CreateBox(.{layout.size = .{pref.x = Pct(energy_ratio), pref.y = Grow()}, bg_color = ENERGY_FG});

      left := tprint("% / %", ff0(player.energy), ff0(player.stats.max_energy));
      CreateText(left, style_left);

      right := tprint("+%", ff1n(player.stats.energy_regen));
      CreateText(right, style_right);
    }
  }

  // stats side
  {
    stats_box := CreateBox(.{bg_color = HUD_BG,
                             layout = .{size.min = Fit2(),
                                        child_order = .TOP_TO_BOTTOM,
                                        child_gap = GAP_SIZE},
                             floating = .{attach_to = .PARENT,
                                          anchors.itself = GetAnchor(.RIGHT, .BOTTOM),
                                          anchors.parent = GetAnchor(.LEFT, .BOTTOM),
                                          offset.x = GAP_SIZE * -1}});
    Parent(stats_box);


    Layer(.{layout.padding = PADDING});
    CreateText(tprint("MS: %", ff1n(player.stats.move_speed)));
    CreateText(tprint("AS: %", ff1n(player.stats.attack_speed)));
  }

}
