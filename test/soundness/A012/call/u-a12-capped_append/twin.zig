// A012: a list grown by a number from input checked against the program's own limit first
// (`if (n > 4096) return`): bounded by it, as `gpa.alloc(u8, n)` under the same check is (clean, see
// a012-free-existing's twin). glint flags appendNTimes ("sized by a number from input"): the check
// that decides alloc is not read for ArrayList's growth. Met while reducing conduit
// src/cgroup.zig:371 (`line.deinit(gpa)`).
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u32, .little);
    if (n > 4096) return error.TooBig;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendNTimes(gpa, 'x', n);
    return line.items.len;
}
