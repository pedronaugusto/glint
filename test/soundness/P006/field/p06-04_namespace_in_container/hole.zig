// P006 field: a namespace a container's declaration holds; the disallowed std.debug.print is reached
const std = @import("std");
const S = struct {
    const d = std.debug;
};

pub fn f() void {
    S.d.print("x", .{});
}
