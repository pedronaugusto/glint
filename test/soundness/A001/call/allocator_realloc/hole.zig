// A001: std.mem.sliceAsBytes hands the caller governed cells' bytes.
const std = @import("std");
const aegis = @import("aegis");
const State = enum(u8) { idle, busy };
const A = aegis.Atomic(State);
pub fn f(cells: []A) []u8 {
    return std.mem.sliceAsBytes(cells);
}
