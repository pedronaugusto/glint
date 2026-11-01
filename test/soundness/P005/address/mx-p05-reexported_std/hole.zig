// matrix: P005 address: std.debug.print reached through a helper file that re-exports std
const helper = @import("helper.zig");
pub fn run() void {
    helper.std.debug.print("x\n", .{});
}
