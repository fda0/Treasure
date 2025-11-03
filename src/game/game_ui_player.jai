#scope_file;
using BOX;
HUD_BG    :: #run C32_0xRGB(0x14_18_24);
BUTTON_BG :: #run C32_0xRGB(0x1C_27_48);
HEALTH_FG :: #run C32_0xRGB(0x1C_a7_48);
ENERGY_FG :: #run C32_0xRGB(0x9C_97_48);
GAP_SIZE  :: #run Rem(0.5);
#scope_export;

UI_BuildHUD :: ()
{
  hud := CreateBox(.{layout.size.min = Fit2(),
                     layout.padding = PaddingAll(GAP_SIZE),
                     layout.child_gap = GAP_SIZE,
                     layout.child_order = .TOP_TO_BOTTOM,
                     bg_color = HUD_BG,
                     floating.attach_to = .ROOT,
                     floating.anchors = .{itself = .{horizontal = .CENTER, vertical = .BOTTOM},
                                          parent = .{horizontal = .CENTER, vertical = .BOTTOM}}});
  Parent(hud);

  player := CL_GetGhost(.SHARED, G.cl.player_key);
  hp_ratio := SafeDiv(player.o.hp, player.o.max_hp);


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

  for 1 .. 4
  {
    button := CreateBox(.{layout.size.min = Rem2(3.0), bg_color = BUTTON_BG});
  }
}
