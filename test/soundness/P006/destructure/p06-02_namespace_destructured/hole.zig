// P006 destructure: a namespace taken out of a tuple by a destructure; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const d, const m = .{ std.debug, std.mem };
    _ = m;
    d.print("x", .{});
}
