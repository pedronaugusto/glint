// the same loop with no reset: it passes s.len times, whatever k is
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var k = try r.takeInt(u32, .little);
    const s = [_]u8{ 1, 2, 3, 4 };
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (k > 0 and i + 1 == s.len) {
            k -= 1;
        }
        i += 1;
        total += 1;
    }
    return gpa.alloc(u8, total);
}
