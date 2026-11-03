// pre-sweep-2 A008 twin: the same generic bound to the record holding a public key.
const std = @import("std");
const dep = @import("dep.zig");
fn first(comptime T: type, w: *const T) u8 {
    const copy: std.meta.Child([1]T) = w.*;
    return copy.label;
}
pub fn run(w: *const dep.Shown) u8 {
    return first(dep.Shown, w);
}
