// matrix A010 inline_loop: an inline for sums a u8 and a u16 from input into a u64, which cannot overflow
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var t: u64 = 0;
    inline for (.{ u8, u16 }) |T| t += try r.takeInt(T, .little);
    return t;
}
