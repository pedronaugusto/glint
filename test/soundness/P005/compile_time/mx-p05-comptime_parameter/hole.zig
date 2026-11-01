// matrix: P005 compile_time: std.debug.print handed as a comptime parameter and called
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
fn emit(comptime say: anytype) void {
    say("x\n", .{});
}
pub fn run() void {
    emit(std.debug.print);
}
