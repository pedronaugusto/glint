// P005 field: the same, the pointer's type generic, holding std.debug.print
const std = @import("std");
const Out = struct { say: ?*const fn (comptime []const u8, anytype) void = null };
fn emit(comptime out: Out) void {
    if (out.say) |say| say("x\n", .{});
}
pub fn run() void {
    emit(.{ .say = &std.debug.print });
}
