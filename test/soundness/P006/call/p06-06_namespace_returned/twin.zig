// P006 call: a namespace a function returns; the allowed std.debug.assert is reached
const std = @import("std");
fn namespace() type {
    return std.debug;
}

pub fn f() void {
    namespace().assert(true);
}
