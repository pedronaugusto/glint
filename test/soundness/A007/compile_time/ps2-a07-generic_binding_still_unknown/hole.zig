// pre-sweep-2 A007: a generic's local typed `std.meta.Child([1]T)` is left to the bindings
// (bindingsJudge: comptime_dependent in generic code), but read with the call's binding
// (T = dep.Shared, which holds std.Io.Mutex) it still does not resolve, and no one reports it.
const std = @import("std");
const dep = @import("dep.zig");
fn use(comptime T: type, io: std.Io) u32 {
    var x: std.meta.Child([1]T) = .{};
    x.lock.lockUncancelable(io);
    defer x.lock.unlock(io);
    x.n += 1;
    return x.n;
}
pub fn run(io: std.Io) u32 {
    return use(dep.Shared, io);
}
