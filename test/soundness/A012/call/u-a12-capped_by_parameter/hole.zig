// A012: a number from input checked against a limit the function is given, which its caller reads from
// the peer: a ceiling input sets holds nothing, so the list grows by a peer's number.
const std = @import("std");
fn grow(r: *std.Io.Reader, gpa: std.mem.Allocator, max: u32) !usize {
    const n = try r.takeInt(u32, .little);
    if (n > max) return error.TooBig;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendNTimes(gpa, 'x', n);
    return line.items.len;
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    return grow(r, gpa, try r.takeInt(u32, .little));
}
