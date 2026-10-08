//! Package test entry.
test {
    _ = @import("AegisPack_test.zig");
    _ = @import("build_gate_test.zig");
    _ = @import("glint");
    _ = @import("cli.zig");
    _ = @import("cli_test.zig");
    _ = @import("Runner_test.zig");
    _ = @import("contract_test.zig");
    _ = @import("RuleContext_test.zig");
    _ = @import("Projection_test.zig");
}
