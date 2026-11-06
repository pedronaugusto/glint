// A012: a number from input checked against the program's limit, then read again from the peer before
// the call: the ceiling held the old value, not the one the list grows by.
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    var n = try r.takeInt(u32, .little);
    if (n > 4096) return error.TooBig;
    n = try r.takeInt(u32, .little);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendNTimes(gpa, 'x', n);
    return line.items.len;
}
