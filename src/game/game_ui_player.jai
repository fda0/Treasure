#scope_file;
using,only(G) COMPS;
#scope_export;

#scope_file;
using BOX;
HUD_BG    :: #run C32_0xRGB(0x14_18_24);
BUTTON_BG :: #run C32_0xRGB(0x1C_27_48);
BUTTON_BG_INACTIVE :: #run C32_0xRGB(0x30_30_30);
BUTTON_BG_FLASH :: #run C32_0xRGB(0x4C_57_98);
HEALTH_FG :: #run C32_0xRGB(0x1C_a7_48);
ENERGY_FG :: #run C32_0xRGB(0x9C_97_48);
TEXT_FG :: #run C32_0xRGB(0xcf_cf_cf);
GAP_SIZE  :: #run Rem(0.5);
#scope_export;

UI_BuildHUD :: ()
{
  Layer(.{text = .{font = xx FONT_Family.Inconsolata, font_size = Rem(1), color = TEXT_FG}});

  // ff0 :: (x) => formatFloat(x, trailing_width = 1, zero_removal = .NO);
  ff0 :: #bake_arguments formatFloat(trailing_width = 0);
  ff2 :: #bake_arguments formatFloat(trailing_width = 2, zero_removal = .NO);

  hud := CreateBox(.{layout.size.min = Fit2(),
                     layout.padding = PaddingAll(GAP_SIZE),
                     layout.child_gap = GAP_SIZE,
                     layout.child_order = .TOP_TO_BOTTOM,
                     bg_color = HUD_BG,
                     floating.attach_to = .ROOT,
                     floating.anchors = GetAnchor2(.CENTER, .BOTTOM)});
  Parent(hud);

  player := G_GetGhost(.SHARED, G.player_key);
  health_ratio := SafeDiv(player.health, OBJ_GetStat(player, .HEALTH));
  energy_ratio := SafeDiv(player.energy, OBJ_GetStat(player, .ENERGY));

  label_style := BoxSpec.{floating = .{attach_to = .PARENT,
                                       anchors = GetAnchor2(.LEFT, .CENTER),
                                       offset = Rem2(.{0.1, 0.01})}};

  {
    Parent(CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Rem(1.0)}, bg_color = BUTTON_BG}));
    CreateBox(.{layout.size = .{pref.x = Pct(health_ratio), pref.y = Grow()}, bg_color = HEALTH_FG});

    label := tprint("% / %", ff0(player.health), ff0(OBJ_GetStat(player, .HEALTH)));
    CreateText(label, label_style);
  }
  {
    Parent(CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Rem(1.0)}, bg_color = BUTTON_BG}));
    CreateBox(.{layout.size = .{pref.x = Pct(energy_ratio), pref.y = Grow()}, bg_color = ENERGY_FG});

    label := tprint("% / %", ff0(player.energy), ff0(OBJ_GetStat(player, .ENERGY)));
    CreateText(label, label_style);
  }


  skill_buttons := CreateBox(.{layout.size.min = Fit2(),
                               layout.child_gap = GAP_SIZE});
  Parent(skill_buttons);

  skill_labels := string.["Q", "W", "E", "R"];
  for skill_labels
  {
    cooldown_raw := player.skill_cooldowns[it_index];
    cooldown := max(0.0, cooldown_raw);

    bg_color := lerp(BUTTON_BG, BUTTON_BG_INACTIVE, min(cooldown*8, 1.0));
    bg_color = lerp(bg_color, BUTTON_BG_FLASH, Smoothstep(abs(cooldown_raw), 0.15, 0.0));

    button := CreateBox(.{layout.size.min = Rem2(3.5), bg_color = bg_color});
    Parent(button);

    CreateText(it, .{text.font = xx FONT_Family.PlayfairDisplay,
                     text.font_size = Rem(1),
                     floating.attach_to = .PARENT, floating.offset = Rem2(0.5)});

    cooldown_color := C32_SetAlphaf(TEXT_FG, Smoothstep(cooldown_raw, -0.1, 0.2));
    cooldown_label := tprint("%", ff2(cooldown));
    CreateText(cooldown_label, .{text.font = xx FONT_Family.Inconsolata, text.font_size = Rem(1),
                                 text.color = cooldown_color,
                                 floating.attach_to = .PARENT, floating.offset = Rem2(-0.5),
                                 floating.anchors = GetAnchor2(.RIGHT, .BOTTOM)});
  }
}
