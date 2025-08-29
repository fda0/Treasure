#scope_file;
using BOX;
HUD_BG :: #run C32_0xRGB(0x141824);
BUTTON_BG :: #run C32_0xRGB(0x1C2748);
HEALTH_GREEN :: #run C32_0xRGB(0x1Ca748);
#scope_export;

UI_BuildHUD :: ()
{
  hud := CreateBox(.{layout.size.min = Fit2(),
                     layout.padding = PaddingAll(Rem(1.0)),
                     layout.child_gap = Rem(1.0),
                     layout.child_order = .TOP_TO_BOTTOM,
                     bg_color = HUD_BG,
                     floating.attach_to = .ROOT,
                     floating.attach_points = .{itself = .{horizontal = .CENTER, vertical = .BOTTOM},
                                                parent = .{horizontal = .CENTER, vertical = .BOTTOM}}});
  Signal(Parent(hud));


  bar := CreateBox(.{layout.size = .{pref.x = Grow(), min.y = Rem(1.0)},
                     bg_color = BUTTON_BG});
  {
    player := OBJ_Get(.NETWORK, G.client.player_key);
    hp_ratio := SafeDiv(player.s.hp, player.s.max_hp);
    Parent(bar);
    CreateBox(.{layout.size = .{pref.x = Pct(hp_ratio), pref.y = Grow()},
                bg_color = HEALTH_GREEN});
  }


  skill_buttons := CreateBox(.{layout.size.min = Fit2(),
                               layout.child_gap = Rem(1.0)});
  Parent(skill_buttons);

  for 1 .. 4
  {
    button := CreateBox(.{layout.size.min = Rem2(5.0), bg_color = BUTTON_BG});
  }
}
