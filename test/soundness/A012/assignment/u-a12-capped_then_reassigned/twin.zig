// A012: a number from input read again, then checked against the program's limit before the call: the
// list grows by a held amount.
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    var n = try r.takeInt(u32, .little);
    n = try r.takeInt(u32, .little);
    if (n > 4096) return error.TooBig;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendNTimes(gpa, 'x', n);
    return line.items.len;
}
