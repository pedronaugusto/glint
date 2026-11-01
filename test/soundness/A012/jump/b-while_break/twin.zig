// matrix A012 jump: an unlabeled while breaks with input, its value checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var tries: u8 = 0;
    const n: u32 = while (tries < 3) : (tries += 1) {
        break try r.takeInt(u32, .little);
    } else 16;
    try limit.check(n);
    return gpa.alloc(u8, n);
}
