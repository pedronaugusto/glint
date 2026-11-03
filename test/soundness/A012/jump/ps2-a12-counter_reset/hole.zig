// a loop whose counter steps by a sum is counted against its bound, though the loop also
// resets the counter: a peer's k restarts it k times, so total is about 4 * k
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var k = try r.takeInt(u32, .little);
    const s = [_]u8{ 1, 2, 3, 4 };
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (k > 0 and i + 1 == s.len) {
            k -= 1;
            i = 0;
        }
        i += 1;
        total += 1;
    }
    return gpa.alloc(u8, total);
}
