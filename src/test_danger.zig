//! A test root: the danger rules' contract tests.
test {
    _ = @import("Danger_test.zig");
}

// The aegis files this binary's tests share (ci/aegis_sources.zig) are as they were frozen,
// whichever tests ran before this one in the shuffled order.
test "the shared base is as it was frozen" {
    try @import("aegis_sources").expectBaseFrozen();
}
