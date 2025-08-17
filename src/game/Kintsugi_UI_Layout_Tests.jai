DEBUG_LOGGING :: false;
PRINT_ON_PASS :: false;
debug_global := false;

DefaultLayoutSpec :: LayoutSpec.{
  root_dim_px = V2.{2000, 1500},
  rem_to_px = 16,
  measure_text_callback = MeasureText,
  log_flags = #run ifx DEBUG_LOGGING then LayoutLogFlags.ALL else .NONE,
};

MeasureText :: (p: MeasureTextParams) -> V2
{
  per_char := V2.{8, 16};
  result := V2.{p.text.count.(float), 1} * per_char;
  return result;
}

tests :: ()
{
  tests_simple_dim_min_max();
  tests_simple_fit_tree();
  tests_simple_percent_tree();
  tests_grow_with_percent_child();
  tests_grow();
  tests_fit_and_grow();
  tests_child_gap();
  tests_text_in_too_small_window();
}

tests_simple_dim_min_max :: ()
{
  LayoutBegin(DefaultLayoutSpec);
  b0 := CreateBox(.{layout = .{size.pref = .{Px(0), Px(0)},
                               size.min = .{Px(10), Px(40)},
                               size.max = .{Px(20), Px(30)}}});
  b1 := CreateBox(.{layout = .{size.pref = .{Px(100), Px(100)},
                               size.min = .{Px(10), Px(40)},
                               size.max = .{Px(20), Px(30)}}});
  LayoutEnd();

  CheckEQ(Inner2(b0), .{10, 30});
  CheckEQ(Inner2(b1), .{20, 30});
}

tests_simple_fit_tree :: ()
{
  LayoutBegin(DefaultLayoutSpec);
  b0 := CreateBox(.{layout.size.pref = .{Fit(), Px(10)}});
  Parent(b0);

  b00 := CreateBox(.{layout.size.pref = .{Fit(), Grow()}});
  b01 := CreateBox(.{layout.size.pref = .{Px(10), Grow()}});
  b02 := CreateBox(.{layout.size.pref = .{Fit(), Grow()}});

  b000: *Box;
  {
    Parent(b00);
    b000 = CreateBox(.{layout.size.pref = .{Px(7), Grow()}});
  }

  b020: *Box;
  b021: *Box;
  {
    Parent(b02);
    b020 = CreateBox(.{layout.size.pref = .{Px(13), Grow()}});
    b021 = CreateBox(.{layout.size.pref = .{Px(17), Grow()}});
  }
  LayoutEnd();

  CheckEQ(Inner2(b000), .{7, 10});
  CheckEQ(Inner2(b020), .{13, 10});
  CheckEQ(Inner2(b021), .{17, 10});
  CheckEQ(Inner2(b00), .{7, 10});
  CheckEQ(Inner2(b01), .{10, 10});
  CheckEQ(Inner2(b02), .{30, 10});
  CheckEQ(Inner2(b0), .{47, 10});
}

tests_simple_percent_tree :: ()
{
  LayoutBegin(DefaultLayoutSpec);
  b0 := CreateBox(.{layout.size.pref = .{Px(1000), Px(10)}});
  Parent(b0);

  b00 := CreateBox(.{layout.size.pref = .{Pct(0.2), Grow()}});
  b01 := CreateBox(.{layout.size.pref = .{Px(10), Grow()}});
  b02 := CreateBox(.{layout.size.pref = .{Pct(0.5), Grow()}});

  b000: *Box;
  {
    Parent(b00);
    b000 = CreateBox(.{layout.size.pref = .{Pct(0.75), Grow()}});
  }

  b020: *Box;
  b021: *Box;
  {
    Parent(b02);
    b020 = CreateBox(.{layout.size.pref = .{Pct(0.1), Grow()}});
    b021 = CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
  }
  LayoutEnd();

  CheckEQ(Inner2(b000), .{150, 10});
  CheckEQ(Inner2(b020), .{50, 10});
  CheckEQ(Inner2(b021), .{450, 10});
  CheckEQ(Inner2(b00), .{200, 10});
  CheckEQ(Inner2(b01), .{10, 10});
  CheckEQ(Inner2(b02), .{500, 10});
  CheckEQ(Inner2(b0), .{1000, 10});
}

tests_grow_with_percent_child :: ()
{
  LayoutBegin(DefaultLayoutSpec);
  l0 := CreateBox(.{layout.size.pref = .{Px(100), Px(10)}});
  Parent(l0);

  l1_a := CreateBox(.{layout.size.pref = .{Pct(0.4), Grow()}});
  l1_b := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
  Parent(l1_b);

  l2 := CreateBox(.{layout.size.pref = .{Pct(0.5), Grow()}});
  LayoutEnd();

  CheckEQ(Inner2(l0), .{100, 10});
  CheckEQ(Inner2(l1_a), .{40, 10});
  CheckEQ(Inner2(l1_b), .{60, 10});
  CheckEQ(Inner2(l2), .{30, 10});
}

tests_fit_and_grow :: ()
{
  // TEST: Fit on parent & grow on children.
  // Same as below but uses child_order = .DEFAULT (.LEFT_TO_RIGHT)
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout = .{size.pref = .{Fit(), Fit()},
                                     size.min.y = Px(100),
                                     padding = PaddingAll(Px(3))}});
    Parent(parent);
    child0 := CreateBox(.{layout.size.pref = .{Px(10), Px(15)},
                          layout.padding = PaddingAll(Px(10))});
    child1 := CreateBox(.{layout.size.pref = .{Grow(), Grow()},
                          layout.padding = .{Px(11), Px(12), Px(13), Px(14)}});
    LayoutEnd();

    c0_padding := V2.{10+10, 10+10};
    c0_inner := V2.{10, 15};
    c0_outer := c0_inner + c0_padding;
    CheckEQ(Inner2(child0), c0_inner);
    CheckEQ(Outer2(child0), c0_outer);

    c1_padding := V2.{11+12, 13+14};
    c1_inner := V2.{0, 100.0 - c1_padding.y};
    c1_outer := c1_inner + c1_padding;
    CheckEQ(Inner2(child1), c1_inner);
    CheckEQ(Outer2(child1), c1_outer);

    parent_inner := V2.{c0_outer.x + c1_outer.x, max(c0_outer.y, c1_outer.y)};
    CheckEQ(parent.inner, parent_inner);
  }

  // TEST: Fit on parent & grow on children.
  // Same as above but uses child_order = .TOP_TO_BOTTOM
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout = .{size.pref = .{Fit(), Fit()}, size.min.y = Px(100),
                                     padding = PaddingAll(Px(3)),
                                     child_order = .TOP_TO_BOTTOM}});
    Parent(parent);
    child0 := CreateBox(.{layout.size.pref = .{Px(10), Px(15)},
                          layout.padding = PaddingAll(Px(10))});
    child1 := CreateBox(.{layout.size.pref = .{Grow(), Grow()},
                          layout.padding = .{Px(11), Px(12), Px(13), Px(14)}});
    LayoutEnd();

    c0_padding := V2.{10+10, 10+10};
    c0_inner := V2.{10, 15};
    c0_outer := c0_inner + c0_padding;
    CheckEQ(Inner2(child0), c0_inner);
    CheckEQ(Outer2(child0), c0_outer);

    c1_padding := V2.{11+12, 13+14};
    c1_inner := V2.{c0_outer.x - c1_padding.x, 100.0 - c0_outer.y - c1_padding.y};
    c1_outer := c1_inner + c1_padding;
    CheckEQ(Inner2(child1), c1_inner);
    CheckEQ(Outer2(child1), c1_outer);

    parent_inner := V2.{max(c0_outer.x, c1_outer.x), c0_outer.y + c1_outer.y};
    CheckEQ(parent.inner, parent_inner);
  }
}

tests_grow :: ()
{
  // 3x just grow.
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.size.pref = .{Px(900), Px(600)}});
    Parent(parent);
    child0 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    child2 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    LayoutEnd();

    c_inner := V2.{300, 600};
    CheckEQ(Outer2(child0), c_inner);
    CheckEQ(Outer2(child1), c_inner);
    CheckEQ(Outer2(child2), c_inner);
    CheckEQ(parent.inner, V2.{900, 600});
  }

  // 3x grow with 1 max size contrain - should be indentical to above.
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.size.pref = .{Px(900), Px(600)}});
    Parent(parent);
    child0 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout = .{size.pref = .{Grow(), Grow()}, size.max.x = Px(300)}});
    child2 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    LayoutEnd();

    c_inner := V2.{300, 600};
    CheckEQ(Outer2(child0), c_inner);
    CheckEQ(Outer2(child1), c_inner);
    CheckEQ(Outer2(child2), c_inner);
    CheckEQ(parent.inner, V2.{900, 600});
  }

  // GROW with iterative solving
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.size.pref = .{Px(400), Px(20)}});
    Parent(parent);
    child0 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    child2 := CreateBox(.{layout = .{size.pref = .{Grow(), Grow()}, size.max.x = Px(70)}});
    child3 := CreateBox(.{layout = .{size.pref = .{Grow(), Grow()}, size.max.x = Px(120)}});
    LayoutEnd();

    CheckEQ(Outer2(child0), .{110, 20});
    CheckEQ(Outer2(child1), .{110, 20});
    CheckEQ(Outer2(child2), .{70, 20});
    CheckEQ(Outer2(child3), .{110, 20});
    CheckEQ(parent.inner, .{400, 20});
  }

  // GROW + size.min
  // @todo Should the results be:
  // .{150, 30}
  // .{600, 30}
  // .{150, 30}
  //  ? ? ?
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.size.pref = .{Px(900), Px(30)}});
    Parent(parent);
    child0 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout = .{size.pref = .{Grow(),Grow()}, size.min.x = Px(600)}});
    child2 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    LayoutEnd();

    CheckEQ(Outer2(child0), .{100, 30});
    CheckEQ(Outer2(child1), .{700, 30});
    CheckEQ(Outer2(child2), .{100, 30});
    CheckEQ(parent.inner, .{900, 30});
  }
}

tests_child_gap :: ()
{
  // Test if child gap is applied between 3 children.
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout = .{size.pref = .{Px(900), Px(600)},
                                     child_gap = Px(40)}});
    Parent(parent);
    child0 := CreateBox(.{layout.size.pref = .{Px(100), Grow()}});
    child1 := CreateBox(.{layout = .{size.pref = .{Px(200), Grow()},
                                     padding = PaddingAll(Px(15))}});
    child2 := CreateBox(.{layout.size.pref = .{Grow(), Grow()}});
    LayoutEnd();

    gap := 40.0;
    pad1 := 15.0;
    CheckEQ(child0.inner, V2.{100, 600});
    CheckEQ(child1.inner, V2.{200, 600 - pad1*2});
    CheckEQ(child2.inner, V2.{900 - (100+200 + pad1*2 + gap*2), 600});
    CheckEQ(parent.inner, V2.{900, 600});

    CheckEQ(child0.abs_p, V2.{0, 0});
    CheckEQ(child1.abs_p, V2.{100 + gap, 0});
    CheckEQ(child2.abs_p, V2.{100+200 + pad1*2 + gap*2, 0});
  }
}

tests_text_in_too_small_window :: ()
{
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout = .{size.min = .{Px(10), Px(20)},
                                     child_order = .TOP_TO_BOTTOM}});
    Parent(parent);

    child0 := CreateText("a");
    child1 := CreateText("bc");
    child2 := CreateText("def");
    LayoutEnd();

    CheckEQ(child0.abs_p, V2.{});
    CheckEQ(child1.abs_p, V2.{0, 16});
    CheckEQ(child2.abs_p, V2.{0, 16*2});
    CheckEQ(Outer2(child0), V2.{8, 16});
    CheckEQ(Outer2(child1), V2.{8*2, 16});
    CheckEQ(Outer2(child2), V2.{8*3, 16});
  }

  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.size.pref = .{Px(10), Px(20)},
                          layout.child_order = .TOP_TO_BOTTOM});
    Parent(parent);

    child0 := CreateText("a", .{layout.size = .{min.x = Px(10) /* this will get overwritten*/,
                                                max.y = Px(10)}});
    child1 := CreateText("bc");
    child2 := CreateText("def");
    LayoutEnd();

    CheckEQ(child0.abs_p, V2.{});
    CheckEQ(child1.abs_p, V2.{0, 10});
    CheckEQ(child2.abs_p, V2.{0, 10 + 16});
    CheckEQ(Outer2(child0), V2.{8, 10});
    CheckEQ(Outer2(child1), V2.{8*2, 16});
    CheckEQ(Outer2(child2), V2.{8*3, 16});
  }
}

//
// Tests setup
//
#import,file "Kintsugi_UI_Layout.jai";
#import "Basic";
#import "Math";
V2 :: Vector2;
CheckCount := 0;
CheckErrorCount := 0;

main :: ()
{
  tests();
  if CheckErrorCount print("% out of % checks failed.\n", CheckErrorCount, CheckCount);
  else               print("All % checks passed.\n", CheckCount);
  exit(xx CheckErrorCount);
}

CheckEQ :: (a: $T, b: T, loc := #caller_location)
{
  did_pass := a == b;
  Check(did_pass, "Condtion: % % %", a, ifx did_pass then "==" else "!=", b, loc=loc);
}

Check :: (did_pass: bool, message := "", args: ..Any, loc := #caller_location)
{
  CheckCount += 1;

  passfail := ifx did_pass then "passed" else "FAILED";
  if !did_pass then CheckErrorCount += 1;

  if !did_pass || PRINT_ON_PASS
  {
    builder := String_Builder.{allocator=temp};
    print_to_builder(*builder, "Test check % % at: %; ", CheckCount, passfail, loc);
    print_to_builder(*builder, message, ..args);
    print_to_builder(*builder, "\n");
    final_message := builder_to_string(*builder);
    print(final_message);
  }
}
