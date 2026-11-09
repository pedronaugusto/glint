//! A test root: the aegis pack's and the rule context's contract tests.
test {
    _ = @import("AegisPack_test.zig");
    _ = @import("RuleContext_test.zig");
    _ = @import("orNull_test.zig");
}

// The aegis files this binary's tests share (ci/aegis_sources.zig) are as they were frozen,
// whichever tests ran before this one in the shuffled order.
test "the shared base is as it was frozen" {
    try @import("aegis_sources").expectBaseFrozen();
}
