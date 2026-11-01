// matrix: a size a peer writes in decimal, parsed by std and unwrapped by try
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const text = try r.takeDelimiterExclusive('\n');
    const n = try std.fmt.parseInt(u32, text, 10);
    return gpa.alloc(u8, n);
}
