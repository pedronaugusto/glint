//! A test root: the CLI's, the runner's and the library's contract tests. The contract tests are
//! split across roots (test_danger.zig, test_pack.zig) that compile and run as parallel steps.
test {
    _ = @import("Token_test.zig");
    _ = @import("Library_test.zig");
    _ = @import("build_gate_test.zig");
    _ = @import("glint");
    _ = @import("cli_test.zig");
    _ = @import("Runner_test.zig");
    _ = @import("contract_test.zig");
}
