DEBUG_LOGGING :: false;
PRINT_ON_PASS :: false;
debug_global := false;

DefaultLayoutSpec :: LayoutSpec.{
  root_dim_px = V2.{2000, 1500},
  rem_to_px = 16,
  measure_text_callback = MeasureText,
  debug_logging = DEBUG_LOGGING,
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
  tests_grow();
  tests_fit_and_grow();
  tests_child_gap();
  tests_text_in_too_small_window();
}

tests_simple_dim_min_max :: ()
{
  LayoutBegin(DefaultLayoutSpec);
  b0 := CreateBox(.{layout = .{dim = .{Px(0), Px(0)},
                               dim_min = .{Px(10), Px(40)},
                               dim_max = .{Px(20), Px(30)}}});
  b1 := CreateBox(.{layout = .{dim = .{Px(100), Px(100)},
                               dim_min = .{Px(10), Px(40)},
                               dim_max = .{Px(20), Px(30)}}});
  LayoutEnd();

  CheckEQ(InnerDim2(b0), .{10, 30});
  CheckEQ(InnerDim2(b1), .{20, 30});
}

tests_fit_and_grow :: ()
{
  // TEST: Fit on parent & grow on children.
  // Same as below but uses direction = .DEFAULT (.LEFT_TO_RIGHT)
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout = .{dim = .{Fit(), Fit()},
                                     dim_min.y = Px(100),
                                     padding = PaddingAll(Px(3))}});
    Parent(parent);
    child0 := CreateBox(.{layout.dim = .{Px(10), Px(15)},
                          layout.padding = PaddingAll(Px(10))});
    child1 := CreateBox(.{layout.dim = .{Grow(), Grow()},
                          layout.padding = .{Px(11), Px(12), Px(13), Px(14)}});
    LayoutEnd();

    c0_padding := V2.{10+10, 10+10};
    c0_inner := V2.{10, 15};
    c0_outer := c0_inner + c0_padding;
    CheckEQ(InnerDim2(child0), c0_inner);
    CheckEQ(OuterDim2(child0), c0_outer);

    c1_padding := V2.{11+12, 13+14};
    c1_inner := V2.{0, 100.0 - c1_padding.y};
    c1_outer := c1_inner + c1_padding;
    CheckEQ(InnerDim2(child1), c1_inner);
    CheckEQ(OuterDim2(child1), c1_outer);

    parent_inner := V2.{c0_outer.x + c1_outer.x, max(c0_outer.y, c1_outer.y)};
    CheckEQ(parent.inner, parent_inner);
  }

  // TEST: Fit on parent & grow on children.
  // Same as above but uses direction = .TOP_TO_BOTTOM
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout = .{dim = .{Fit(), Fit()}, dim_min.y = Px(100),
                                     padding = PaddingAll(Px(3)),
                                     direction = .TOP_TO_BOTTOM}});
    Parent(parent);
    child0 := CreateBox(.{layout.dim = .{Px(10), Px(15)},
                          layout.padding = PaddingAll(Px(10))});
    child1 := CreateBox(.{layout.dim = .{Grow(), Grow()},
                          layout.padding = .{Px(11), Px(12), Px(13), Px(14)}});
    LayoutEnd();

    c0_padding := V2.{10+10, 10+10};
    c0_inner := V2.{10, 15};
    c0_outer := c0_inner + c0_padding;
    CheckEQ(InnerDim2(child0), c0_inner);
    CheckEQ(OuterDim2(child0), c0_outer);

    c1_padding := V2.{11+12, 13+14};
    c1_inner := V2.{c0_outer.x - c1_padding.x, 100.0 - c0_outer.y - c1_padding.y};
    c1_outer := c1_inner + c1_padding;
    CheckEQ(InnerDim2(child1), c1_inner);
    CheckEQ(OuterDim2(child1), c1_outer);

    parent_inner := V2.{max(c0_outer.x, c1_outer.x), c0_outer.y + c1_outer.y};
    CheckEQ(parent.inner, parent_inner);
  }
}

tests_grow :: ()
{
  // 3x just grow.
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.dim = .{Px(900), Px(600)}});
    Parent(parent);
    child0 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    child2 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    LayoutEnd();

    c_inner := V2.{300, 600};
    CheckEQ(OuterDim2(child0), c_inner);
    CheckEQ(OuterDim2(child1), c_inner);
    CheckEQ(OuterDim2(child2), c_inner);
    CheckEQ(parent.inner, V2.{900, 600});
  }

  // 3x grow with 1 max size contrain - should be indentical to above.
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.dim = .{Px(900), Px(600)}});
    Parent(parent);
    child0 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout = .{dim = .{Grow(), Grow()}, dim_max.x = Px(300)}});
    child2 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    LayoutEnd();

    c_inner := V2.{300, 600};
    CheckEQ(OuterDim2(child0), c_inner);
    CheckEQ(OuterDim2(child1), c_inner);
    CheckEQ(OuterDim2(child2), c_inner);
    CheckEQ(parent.inner, V2.{900, 600});
  }

  // GROW with iterative solving
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.dim = .{Px(400), Px(20)}});
    Parent(parent);
    child0 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    child2 := CreateBox(.{layout = .{dim = .{Grow(), Grow()}, dim_max.x = Px(70)}});
    child3 := CreateBox(.{layout = .{dim = .{Grow(), Grow()}, dim_max.x = Px(120)}});
    LayoutEnd();

    CheckEQ(OuterDim2(child0), .{110, 20});
    CheckEQ(OuterDim2(child1), .{110, 20});
    CheckEQ(OuterDim2(child2), .{70, 20});
    CheckEQ(OuterDim2(child3), .{110, 20});
    CheckEQ(parent.inner, .{400, 20});
  }

  // GROW + dim_min
  // @todo Should the results be:
  // .{150, 30}
  // .{600, 30}
  // .{150, 30}
  //  ? ? ?
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.dim = .{Px(900), Px(30)}});
    Parent(parent);
    child0 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    child1 := CreateBox(.{layout = .{dim = .{Grow(),Grow()}, dim_min.x = Px(600)}});
    child2 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
    LayoutEnd();

    CheckEQ(OuterDim2(child0), .{100, 30});
    CheckEQ(OuterDim2(child1), .{700, 30});
    CheckEQ(OuterDim2(child2), .{100, 30});
    CheckEQ(parent.inner, .{900, 30});
  }
}

tests_child_gap :: ()
{
  // Test if child gap is applied between 3 children.
  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.dim = .{Px(900), Px(600)},
                          layout.child_gap = Px(40)});
    Parent(parent);
    child0 := CreateBox(.{layout.dim = .{Px(100), Grow()}});
    child1 := CreateBox(.{layout.dim = .{Px(200), Grow()},
                          layout.padding = PaddingAll(Px(15))});
    child2 := CreateBox(.{layout.dim = .{Grow(), Grow()}});
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
    parent := CreateBox(.{layout.dim = .{Px(10), Px(20)},
                          layout.direction = .TOP_TO_BOTTOM});
    Parent(parent);

    child0 := CreateText("a");
    child1 := CreateText("bc");
    child2 := CreateText("def");
    LayoutEnd();

    CheckEQ(child0.abs_p, V2.{});
    CheckEQ(child1.abs_p, V2.{0, 16});
    CheckEQ(child2.abs_p, V2.{0, 16*2});
    CheckEQ(OuterDim2(child0), V2.{8, 16});
    CheckEQ(OuterDim2(child1), V2.{8*2, 16});
    CheckEQ(OuterDim2(child2), V2.{8*3, 16});
  }

  {
    LayoutBegin(DefaultLayoutSpec);
    parent := CreateBox(.{layout.dim = .{Px(10), Px(20)},
                          layout.direction = .TOP_TO_BOTTOM});
    Parent(parent);

    child0 := CreateText("a", .{layout.dim_min.x = Px(10), layout.dim_max.y = Px(10)});
    child1 := CreateText("bc");
    child2 := CreateText("def");
    LayoutEnd();

    CheckEQ(child0.abs_p, V2.{});
    CheckEQ(child1.abs_p, V2.{0, 10});
    CheckEQ(child2.abs_p, V2.{0, 10 + 16});
    CheckEQ(OuterDim2(child0), V2.{10, 10});
    CheckEQ(OuterDim2(child1), V2.{8*2, 16});
    CheckEQ(OuterDim2(child2), V2.{8*3, 16});
  }
}

//
// Tests setup
//
#import,file "brick_ui_layout.jai";
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
