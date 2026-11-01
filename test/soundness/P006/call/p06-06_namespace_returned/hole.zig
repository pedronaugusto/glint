// P006 call: a namespace a function returns; the disallowed std.debug.print is reached
const std = @import("std");
fn namespace() type {
    return std.debug;
}

pub fn f() void {
    namespace().print("x", .{});
}
