const std = @import("std");
const builtin = @import("builtin");
fn quiet(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}
/// std's print in a debug build.
pub const out = if (builtin.mode == .debug) std.debug.print else quiet;
