// glint-c: an allocation sized by a number parsed from a line a peer sends
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const line = try r.takeDelimiterExclusive('\n');
    const n = try std.fmt.parseInt(usize, line, 10);
    const copy = try gpa.alloc(u8, n);
    return copy.len;
}
