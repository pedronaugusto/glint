const std = @import("std");
fn quiet(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}
const Sink = struct {
    pub const write = quiet;
};
pub fn emit(comptime S: type) void {
    S.write("x\n", .{});
}
pub fn run() void {
    emit(Sink);
}
