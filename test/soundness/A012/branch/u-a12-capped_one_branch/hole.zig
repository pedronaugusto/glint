// A012: the program's limit checked on one branch only: on the other path the list grows by the peer's
// number.
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, strict: bool) !usize {
    const n = try r.takeInt(u32, .little);
    if (strict) {
        if (n > 4096) return error.TooBig;
    }
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendNTimes(gpa, 'x', n);
    return line.items.len;
}
