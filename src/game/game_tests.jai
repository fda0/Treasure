#run TEST_run();

TEST_run :: ()
{
  TEST_queue(false);
  TEST_queue(true);
  TEST_math();
  TEST_lanes();
}

TEST_queue :: (high_minmax: bool)
{
  q: Queue(4, u32);

  if high_minmax
  {
    q.min = U64_MAX - 2;
    q.max = q.min;
  }

  assert(QueueIsEmpty(q));

  QueuePush(*q, 11);
  QueuePush(*q, 22);
  QueuePush(*q, 33); // not full (3/4)
  sum: u32; for q sum += it;
  assert(sum == 66);

  QueuePush(*q, 50); // full
  sum = 0; for q sum += it;
  assert(sum == 116);

  assert(QueueIsFull(q));

  // variants
  {
    sum = 0;
    for 0..3 sum += QueuePeek(q, it);
    assert(sum == 116);

    sum = 0;
    for 0..3 sum += QueuePeek(q, it);
    assert(sum == 116);

    sum = 0;
    for 0..3 sum += QueuePeekLast(q, it);
    assert(sum == 116);
  }

  QueuePush(*q).* = 80; // removed 11; added 80
  sum = 0; for q sum += it;
  assert(sum == 185);

  popped := QueuePop(*q); // removed 22
  assert(popped == 22);
  sum = 0; for q sum += it;
  assert(sum == 163);

  assert(QueueCount(q) == 3);
  assert(QueueEmptyCount(q) == 1);

  peeked := QueuePeek(q);
  assert(peeked == 33);

  peeked_pointer := QueuePeekPtr(*q);
  assert(peeked_pointer.* == 33);
}

TEST_math :: ()
{
  // rectangles
  {
    a := MakeRect(-10, -20, 30, 40);
    b := MakeRect(-15, -8, -2, 400);
    r := RangeIntersection(a, b);
    assert(r == MakeRect(-10, -8, -2, 40));
  }
}

TEST_lanes :: ()
{
  // LaneRangeFromIdxCount(work_count, lane_idx, lane_count) -> Range(s64)

  // lane_count = 1
  assert_eq(LaneRangeFromIdxCount(1, 0, 1), .{0, 1});
  assert_eq(LaneRangeFromIdxCount(2, 0, 1), .{0, 2});

  // work_count = 1, lane_count = 2
  assert_eq(LaneRangeFromIdxCount(1, 0, 2), .{0, 1});
  assert_eq(LaneRangeFromIdxCount(1, 1, 2), .{1, 1});

  // work_count = 2, lane_count = 2
  assert_eq(LaneRangeFromIdxCount(2, 0, 2), .{0, 1});
  assert_eq(LaneRangeFromIdxCount(2, 1, 2), .{1, 2});

  // work_count = 3, lane_count = 2
  assert_eq(LaneRangeFromIdxCount(3, 0, 2), .{0, 2}); // 2
  assert_eq(LaneRangeFromIdxCount(3, 1, 2), .{2, 3}); // 1

  // work_count = 18, lane_count = 5
  assert_eq(LaneRangeFromIdxCount(18, 0, 5), .{0, 4}); // 4
  assert_eq(LaneRangeFromIdxCount(18, 1, 5), .{4, 8}); // 4
  assert_eq(LaneRangeFromIdxCount(18, 2, 5), .{8, 12}); // 4
  assert_eq(LaneRangeFromIdxCount(18, 3, 5), .{12, 15}); // 3
  assert_eq(LaneRangeFromIdxCount(18, 4, 5), .{15, 18}); // 3
}

//
// Test helpers
//
assert_eq :: (a: $T, b: T, loc := #caller_location)
{
  assert(a == b, "% != %", a, b, loc=loc);
}
