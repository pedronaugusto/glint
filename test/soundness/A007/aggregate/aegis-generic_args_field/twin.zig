// aegis A007 probe: a generic holds its anytype parameter's type by value as a field (airlock sys.zig's
// syncCall shape); bound to a tuple of numbers, it holds no lock.
const std = @import("std");
fn hold(args: anytype) void {
    const Held = struct { arguments: @TypeOf(args) };
    const held: Held = .{ .arguments = args };
    _ = held;
}
pub fn run() void {
    hold(.{ @as(u32, 1), @as(u32, 2) });
}
