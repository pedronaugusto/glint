// P009: std.mem.swap moves a pointer into a local into the caller's memory.
const std = @import("std");
pub fn f(slots: []*i32, k: usize) void {
    var j: i32 = 1;
    var p: *i32 = &j;
    std.mem.swap(*i32, &p, &slots[k]);
}
