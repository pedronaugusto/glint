//! Package test entry.
test {
    _ = @import("glint.zig");
    _ = @import("cli.zig");
    _ = @import("cli_test.zig");
    _ = @import("Runner_test.zig");
}
