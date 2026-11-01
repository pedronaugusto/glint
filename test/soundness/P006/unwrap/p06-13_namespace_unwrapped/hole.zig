// P006 unwrap: a namespace unwrapped from an optional by .?; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const opt: ?type = std.debug;
    opt.?.print("x", .{});
}
