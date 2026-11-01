// P006 destructure: a namespace taken out of a tuple by a destructure; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const d, const m = .{ std.debug, std.mem };
    _ = m;
    d.assert(true);
}
