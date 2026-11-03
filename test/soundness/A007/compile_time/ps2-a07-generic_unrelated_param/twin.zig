// pre-sweep-2 A007 twin: the same local over a dependency's array of counters.
const std = @import("std");
const dep = @import("dep.zig");
pub fn bump(comptime step: u32, counter: *u32) void {
    var seen: std.meta.Child(dep.Counts) = 0;
    seen += step;
    counter.* += seen;
}
pub fn run(counter: *u32) void {
    bump(2, counter);
}
