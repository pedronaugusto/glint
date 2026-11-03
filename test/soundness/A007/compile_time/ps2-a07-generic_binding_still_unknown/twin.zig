// pre-sweep-2 A007 twin: the same generic bound to a record holding a counter.
const std = @import("std");
const dep = @import("dep.zig");
fn use(comptime T: type) u32 {
    var x: std.meta.Child([1]T) = .{};
    x.n += 1;
    return x.n;
}
pub fn run() u32 {
    return use(dep.Plain);
}
