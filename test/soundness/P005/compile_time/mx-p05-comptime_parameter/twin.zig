// matrix: P005 compile_time: the same, through the program's own quiet output
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
fn emit(comptime say: anytype) void {
    say("x\n", .{});
}
pub fn run() void {
    emit(quiet);
}
