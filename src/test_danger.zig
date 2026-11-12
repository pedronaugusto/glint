//! A test root: P007, P008 and P009, over the pinned aegis sources and a std laid out as 0.17's.
test {
    _ = @import("Unchecked_test.zig");
}

// The aegis files this binary's tests share (ci/aegis_sources.zig) are as they were frozen,
// whichever tests ran before this one in the shuffled order.
test "the shared base is as it was frozen" {
    try @import("aegis_sources").expectBaseFrozen();
}
