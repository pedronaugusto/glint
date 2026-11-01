// matrix A012 jump: an unlabeled while breaks with input on its first pass, its value the size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var tries: u8 = 0;
    const n: u32 = while (tries < 3) : (tries += 1) {
        break try r.takeInt(u32, .little);
    } else 16;
    return gpa.alloc(u8, n);
}
