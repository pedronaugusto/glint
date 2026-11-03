const std = @import("std");
/// An alias of std's print, in this (selected) file.
pub const say = std.debug.print;
pub fn emit(comptime ns: type) void {
    ns.say("x\n", .{});
}
pub fn run() void {
    emit(@This());
}
