// matrix: P005 field: std.debug.print called through @field naming it
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    @field(std.debug, "print")("x\n", .{});
}
