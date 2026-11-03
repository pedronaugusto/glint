const std = @import("std");
pub fn say(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}
pub fn emit(comptime ns: type) void {
    ns.say("x\n", .{});
}
pub fn run() void {
    emit(@This());
}
