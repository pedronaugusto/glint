// a loop counted against list.items.len, which the loop itself grows a peer's k times: total is
// len + k, but the sum takes the bound as given (data, the memory's length)
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, list: *std.ArrayList(u8)) ![]u8 {
    var k = try r.takeInt(u32, .little);
    var total: usize = 0;
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (k > 0) {
            k -= 1;
            try list.append(gpa, 0);
        }
        total += 1;
    }
    return gpa.alloc(u8, total);
}
