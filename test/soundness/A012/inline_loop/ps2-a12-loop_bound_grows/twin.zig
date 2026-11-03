// the same loop with the growth after it: len passes, whatever k is
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, list: *std.ArrayList(u8)) ![]u8 {
    var k = try r.takeInt(u32, .little);
    var total: usize = 0;
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        total += 1;
    }
    if (k > 0) {
        k -= 1;
        try list.append(gpa, 0);
    }
    return gpa.alloc(u8, total);
}
