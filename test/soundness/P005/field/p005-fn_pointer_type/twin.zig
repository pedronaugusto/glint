// P005 field: a call through a run-time function pointer whose type is no generic's, so it holds
// no std.debug.print, whatever is stored there
const std = @import("std");
const Out = struct { say: ?*const fn ([]const u8) void = null };
var out: Out = .{};
pub fn set(say: *const fn ([]const u8) void) void {
    out.say = say;
}
pub fn run() void {
    if (out.say) |say| say("x\n");
}
