// matrix: P005 address: std's log reached through a helper file that re-exports std
const helper = @import("helper.zig");
pub fn run() void {
    helper.std.log.info("x", .{});
}
