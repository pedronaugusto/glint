// review 7 A007: the same tuple holding numbers.
const std = @import("std");
const dep = @import("dep.zig");
const Pair = struct { @TypeOf(dep.count()), u32 };
pub fn run() u32 {
    var p: Pair = .{ dep.count(), 0 };
    p[1] += p[0];
    return p[1];
}
