//! A test root: the aegis pack's and the rule context's contract tests.
test {
    _ = @import("AegisPack_test.zig");
    _ = @import("RuleContext_test.zig");
    _ = @import("orNull_test.zig");
}
