// aegis A007 probe: a generic holds its anytype parameter's type by value as a field (airlock sys.zig's
// syncCall shape); bound to a tuple holding a raw std.Io.Mutex, the record holds the lock by value.
const std = @import("std");
fn hold(args: anytype) void {
    const Held = struct { arguments: @TypeOf(args) };
    const held: Held = .{ .arguments = args };
    _ = held;
}
pub fn run() void {
    const lock: std.Io.Mutex = .init;
    hold(.{ lock, @as(u32, 1) });
}
