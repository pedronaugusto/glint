// pre-sweep-2 A007: a local typed `std.meta.Child(dep.Locks)` (a std.Io.Mutex: Child of an array,
// which glint does not evaluate) is undecided in a plain function, but cleared in one that has any
// comptime parameter, though the parameter binds nothing the type depends on and no call's binding
// judges it.
const std = @import("std");
const dep = @import("dep.zig");
pub fn bump(comptime step: u32, io: std.Io, counter: *u32) void {
    var lock: std.meta.Child(dep.Locks) = .init;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    counter.* += step;
}
pub fn run(io: std.Io, counter: *u32) void {
    bump(2, io, counter);
}
