// matrix: P005 unwrap: std.debug.print called through .? of a comptime-known optional
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const maybe: ?@TypeOf(std.debug.print) = std.debug.print;
    maybe.?("x\n", .{});
}
