// a counter stepped by sums both ways is counted against its bound: each of a peer's k steps
// back adds a pass, so total is 4 + k
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var k = try r.takeInt(u32, .little);
    var total: usize = 0;
    var i: usize = 0;
    while (i < 4) {
        i += 1;
        if (k > 0) {
            k -= 1;
            i -= 1;
        }
        total += 1;
    }
    return gpa.alloc(u8, total);
}
