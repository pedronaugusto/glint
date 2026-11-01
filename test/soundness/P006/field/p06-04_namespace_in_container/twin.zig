// P006 field: a namespace a container's declaration holds; the allowed std.debug.assert is reached
const std = @import("std");
const S = struct {
    const d = std.debug;
};

pub fn f() void {
    S.d.assert(true);
}
