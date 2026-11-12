//! A test root: the CLI's, the runner's and the library's contract tests. The contract tests are
//! split across roots (test_danger.zig, test_pack.zig) that compile and run as parallel steps.
test {
    _ = @import("Token_test.zig");
    _ = @import("build_gate_test.zig");
    _ = @import("glint");
    _ = @import("cli_test.zig");
    _ = @import("Runner_test.zig");
    _ = @import("contract_test.zig");
}

// The aegis files this binary's tests share (ci/aegis_sources.zig) are as they were frozen,
// whichever tests ran before this one in the shuffled order.
test "the shared base is as it was frozen" {
    try @import("aegis_sources").expectBaseFrozen();
}
