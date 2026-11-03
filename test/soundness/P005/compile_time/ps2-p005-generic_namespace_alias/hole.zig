const std = @import("std");
const Sink = struct {
    pub const write = std.debug.print;
};
fn quiet(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}
pub fn emit(comptime S: type) void {
    S.write("x\n", .{});
}
pub fn run() void {
    emit(Sink);
}
