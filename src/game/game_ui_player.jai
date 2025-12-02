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

  hud := CreateBox(.{layout.size.min = Fit2(),
                     layout.padding = PaddingAll(GAP_SIZE),
                     layout.child_gap = GAP_SIZE,
                     layout.child_order = .TOP_TO_BOTTOM,
                     bg_color = HUD_BG,
                     floating.attach_to = .ROOT,
                     floating.anchors = .{itself = .{horizontal = .CENTER, vertical = .BOTTOM},
                                          parent = .{horizontal = .CENTER, vertical = .BOTTOM}}});
  Parent(hud);

  player := G_GetGhost(.SHARED, G.player_key);
  hp_ratio := SafeDiv(player.hp, player.max_hp);


  {
    Parent(CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Rem(1.0)}, bg_color = BUTTON_BG}));
    CreateBox(.{layout.size = .{pref.x = Pct(hp_ratio), pref.y = Grow()}, bg_color = HEALTH_FG});
  }
  {
    Parent(CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Rem(1.0)}, bg_color = BUTTON_BG}));
    CreateBox(.{layout.size = .{pref.x = Pct(hp_ratio), pref.y = Grow()}, bg_color = ENERGY_FG});
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
                     floating.attach_to = .PARENT, floating.offset = Rem2(0.5)});

    cooldown_label := tprint("%", formatFloat(cooldown, trailing_width = 2, zero_removal = .NO));

    CreateText(cooldown_label, .{floating.attach_to = .PARENT, floating.offset = Rem2(-0.5),
                                 floating.anchors.itself = .{horizontal = .RIGHT, vertical = .BOTTOM},
                                 floating.anchors.parent = .{horizontal = .RIGHT, vertical = .BOTTOM}});
  }
}
